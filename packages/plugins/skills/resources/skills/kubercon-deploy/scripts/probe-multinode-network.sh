#!/usr/bin/env bash
# D3：在安装前临时监听 Kubernetes/etcd/CNI 端口，机械验证全互通后清理。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
INVENTORY="${KC_INVENTORY_FILE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || { echo "错误: 请设置 KC_INVENTORY_FILE"; exit 1; }
[[ "${KC_CONFIRMED_D3:-}" == "确认 D3" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: 临时端口探针需要 KC_CONFIRMED_D3='确认 D3' 或 KC_AUTONOMOUS=1"; exit 1; }
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

NODE_LINES=()
while IFS= read -r line; do NODE_LINES+=("$line"); done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
FAILED=0
for dst_line in "${NODE_LINES[@]}"; do
  IFS=$'\t' read -r dst_name dst_address dst_internal dst_user dst_port dst_roles <<<"$dst_line"
  tcp_ports=(10250)
  [[ ",$dst_roles," == *,control-plane,* ]] && tcp_ports+=(6443)
  [[ ",$dst_roles," == *,etcd,* ]] && tcp_ports+=(2379 2380)
  ports_csv=$(IFS=,; echo "${tcp_ports[*]}")
  kubercon_ssh_opts "$dst_address" "$dst_port"
  opts=("${SSH_OPTS[@]}")
  echo "=== network probe destination=$dst_name ==="
  ssh "${opts[@]}" "$dst_user@$dst_address" "bash -s -- $(printf '%q' "$ports_csv")" <<'EOS'
set -euo pipefail
ports_csv="$1"
IFS=, read -r -a ports <<<"$ports_csv"
for p in "${ports[@]}"; do
  ss -lnt "( sport = :$p )" | grep -q LISTEN &&
    { echo "端口 $p 已被占用，现场不干净"; exit 1; }
done
rm -f /tmp/kubercon-netprobe.ready /tmp/kubercon-netprobe.results
nohup python3 - "$ports_csv" <<'PY' >/tmp/kubercon-netprobe.log 2>&1 &
import select,socket,time
tcp=[]
for port in map(int,__import__("sys").argv[1].split(",")):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(("0.0.0.0",port)); s.listen(32); s.setblocking(False); tcp.append(s)
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); udp.bind(("0.0.0.0",4789)); udp.setblocking(False)
open("/tmp/kubercon-netprobe.ready","w").write("ready\n")
end=time.time()+120
with open("/tmp/kubercon-netprobe.results","a",buffering=1) as out:
    while time.time()<end:
        readable,_,_=select.select(tcp+[udp],[],[],1)
        for s in readable:
            if s is udp:
                data,addr=s.recvfrom(1024)
                if data==b"kubercon-vxlan-probe": out.write(f"udp:4789:{addr[0]}\n")
            else:
                conn,addr=s.accept(); out.write(f"tcp:{s.getsockname()[1]}:{addr[0]}\n"); conn.close()
PY
echo $! >/tmp/kubercon-netprobe.pid
for _ in $(seq 1 20); do [[ -f /tmp/kubercon-netprobe.ready ]] && exit 0; sleep 0.2; done
cat /tmp/kubercon-netprobe.log; exit 1
EOS
  cleanup() {
    ssh "${opts[@]}" "$dst_user@$dst_address" \
      'p=$(cat /tmp/kubercon-netprobe.pid 2>/dev/null); [[ -z "$p" ]] || kill "$p" 2>/dev/null || true; rm -f /tmp/kubercon-netprobe.pid /tmp/kubercon-netprobe.ready' >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  expected=0
  for src_line in "${NODE_LINES[@]}"; do
    IFS=$'\t' read -r src_name src_address _ src_user src_port _ <<<"$src_line"
    kubercon_ssh_opts "$src_address" "$src_port"
    src_opts=("${SSH_OPTS[@]}")
    if ssh "${src_opts[@]}" "$src_user@$src_address" \
      "python3 - $(printf '%q ' "$dst_internal" "$ports_csv")" <<'PY'
import socket,sys
host=sys.argv[1]
for port in map(int,sys.argv[2].split(",")):
    with socket.create_connection((host,port),5):
        pass
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for _ in range(3): s.sendto(b"kubercon-vxlan-probe",(host,4789))
PY
    then
      expected=$((expected+1))
    else
      echo "BAD $src_name -> $dst_name TCP 探针失败"
      FAILED=1
    fi
  done
  sleep 1
  counts=$(ssh "${opts[@]}" "$dst_user@$dst_address" \
    "python3 - $(printf '%q ' "$expected" "$ports_csv")" <<'PY'
import sys
n=int(sys.argv[1]); ports=map(int,sys.argv[2].split(","))
lines=open("/tmp/kubercon-netprobe.results").read().splitlines()
for p in ports:
    if sum(x.startswith(f"tcp:{p}:") for x in lines)<n: raise SystemExit(f"tcp {p} missing")
if sum(x.startswith("udp:4789:") for x in lines)<n: raise SystemExit("udp 4789 missing")
print("ok")
PY
  ) || true
  [[ "$counts" == ok ]] || { echo "BAD $dst_name 缺 TCP/UDP 返回记录"; FAILED=1; }
  cleanup
  trap - EXIT
done
((FAILED == 0)) || {
  echo "MULTINODE_NETWORK_PROBE_FAILED"
  echo "提示: 云安全组须放通节点互访（至少 TCP 6443/2379-2380/10250 与 UDP 4789；"
  echo "      测试环境可对 VPC 网段放行 TCP/UDP 全部）。主机防火墙关闭不等于 SG 已通。"
  exit 1
}
echo "MULTINODE_NETWORK_PROBE_OK"
