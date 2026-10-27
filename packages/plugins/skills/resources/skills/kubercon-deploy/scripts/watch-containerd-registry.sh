#!/usr/bin/env bash
# D6 期间：在 node1 后台对抗 kk 反复把 containerd 写成 http mirror / 丢掉 config_path。
# 本脚本在**本机**调用：SSH 到 node1 启动 nohup 循环后立即返回（不阻塞）。
# 由 start-create-cluster.sh 在 create 启动前调用；启动失败必须使 D6 失败。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REGISTRY_HOST="${KC_LOCAL_REGISTRY:-docker.kubercon.local}"
PAUSE_IMAGE="${KC_PAUSE_IMAGE:-${REGISTRY_HOST}/kubercon/pause:3.9}"
CA_PEM="${KC_REGISTRY_CA:-/etc/ssl/registry/ssl/ca.pem}"
INTERVAL="${KC_WATCH_INTERVAL:-5}"
INVENTORY="${KC_INVENTORY_FILE:-}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

die() { echo "错误: $*" >&2; exit 1; }
if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "$INVENTORY" ]] || die "KC_INVENTORY_FILE 不存在"
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  REGISTRY_HOST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["privateRegistry"])' "$INVENTORY")
  CA_PEM=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["registryCAPath"])' "$INVENTORY")
  PAUSE_IMAGE="${KC_PAUSE_IMAGE:-${REGISTRY_HOST}/kubercon/pause:3.9}"
  KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" \
    "$SCRIPT_DIR/stop-containerd-watch.sh" >/dev/null ||
    die "无法清理多节点 stale watchdog"
  while IFS=$'\t' read -r name address _ user port _; do
    echo "=== start watchdog node=$name ==="
    if ! env -u KC_INVENTORY_FILE \
      KC_NODE1="$address" KC_SSH_USER="$user" KC_SSH_PORT="$port" KC_SSH_KEY="$SSH_KEY" \
      KC_LOCAL_REGISTRY="$REGISTRY_HOST" KC_PAUSE_IMAGE="$PAUSE_IMAGE" KC_REGISTRY_CA="$CA_PEM" \
      KC_WATCH_INTERVAL="$INTERVAL" KC_CONFIRMED_D6="${KC_CONFIRMED_D6:-}" \
      KC_AUTONOMOUS="${KC_AUTONOMOUS:-}" "$0"; then
      KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" \
        "$SCRIPT_DIR/stop-containerd-watch.sh" || true
      die "节点 $name watchdog 启动失败，已尝试停止全部 watcher"
    fi
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)

  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ first_address _ first_user first_port _ <<<"$first"
  AGG_SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$first_port")
  [[ -f "$SSH_KEY" ]] && AGG_SSH_OPTS+=(-i "$SSH_KEY")
  aggregate=$(ssh "${AGG_SSH_OPTS[@]}" "${first_user}@${first_address}" \
    "bash -s -- $(printf '%q ' "$REMOTE_DIR/inventory.json" "$INTERVAL")" <<'EOS'
set -euo pipefail
inventory="$1"; interval="$2"
status=/tmp/kubercon-containerd-watch.aggregate.status
pidfile=/tmp/kubercon-containerd-watch.aggregate.pid
[[ -f "$inventory" ]] || { echo "missing remote inventory"; exit 1; }
old=$(cat "$pidfile" 2>/dev/null || true)
if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then kill "$old" || true; fi
nohup bash -c '
set +e
inventory="'"$inventory"'"; interval="'"$interval"'"
status=/tmp/kubercon-containerd-watch.aggregate.status
pidfile=/tmp/kubercon-containerd-watch.aggregate.pid
echo $$ > "$pidfile"
read -r key user port < <(python3 - "$inventory" <<'"'"'PY'"'"'
import json,sys
d=json.load(open(sys.argv[1])); print(d["ssh"]["privateKeyPath"],d["ssh"]["user"],d["ssh"]["port"])
PY
)
python3 - "$inventory" <<'"'"'PY'"'"' > /tmp/kubercon-watch-nodes.tsv
import json,sys
for n in json.load(open(sys.argv[1]))["nodes"]: print(n["name"],n["internalAddress"],sep="\t")
PY
stop_all_watchers() {
  while IFS=$'"'"'\t'"'"' read -r name host; do
    ssh -i "$key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$user@$host" \
      '"'"'p=$(cat /tmp/kubercon-containerd-watch.pid 2>/dev/null); [[ -z "$p" ]] || kill "$p" 2>/dev/null || true; rm -f /tmp/kubercon-containerd-watch.pid; echo "STOPPED aggregate" > /tmp/kubercon-containerd-watch.status'"'"' || true
  done < /tmp/kubercon-watch-nodes.tsv
}
echo "RUNNING started=$(date -Is)" > "$status"
while true; do
  create=$(cat /tmp/kubercon-create.status 2>/dev/null)
  if [[ "$create" =~ ^(SUCCESS|FAILED|START_FAILED) ]]; then
    stop_all_watchers
    echo "STOPPED finished=$(date -Is) create_status=${create%% *}" > "$status"
    rm -f "$pidfile" /tmp/kubercon-watch-nodes.tsv
    exit 0
  fi
  failed=""
  while IFS=$'"'"'\t'"'"' read -r name host; do
    remote=$(ssh -i "$key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$user@$host" \
      '"'"'s=$(cat /tmp/kubercon-containerd-watch.status 2>/dev/null); p=$(cat /tmp/kubercon-containerd-watch.pid 2>/dev/null); [[ "$s" == RUNNING* && -n "$p" ]] && kill -0 "$p" 2>/dev/null; rc=$?; printf "%s\n" "$s"; exit "$rc"'"'"' 2>/dev/null)
    rc=$?
    if ((rc != 0)) || [[ "$remote" == FAILED* ]]; then failed="$name"; break; fi
  done < /tmp/kubercon-watch-nodes.tsv
  if [[ -n "$failed" ]]; then
    echo "FAILED node=$failed finished=$(date -Is)" > "$status"
    stop_all_watchers
    rm -f "$pidfile" /tmp/kubercon-watch-nodes.tsv
    exit 70
  fi
  sleep "$interval"
done
' >/tmp/kubercon-containerd-watch.aggregate.log 2>&1 &
disown || true
sleep 1
pid=$(cat "$pidfile" 2>/dev/null || true)
[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && grep -q '^RUNNING ' "$status" ||
  { cat "$status" 2>/dev/null || true; exit 1; }
echo "WATCHDOG_STARTED aggregate_pid=$pid"
EOS
) || {
    KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" \
      "$SCRIPT_DIR/stop-containerd-watch.sh" || true
    die "多节点 watchdog 聚合器启动失败，已停止全部 watcher"
  }
  echo "$aggregate"
  exit 0
fi
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"
[[ "${KC_AUTONOMOUS:-}" == "1" || "${KC_CONFIRMED_D6:-}" == "确认 D6" ]] ||
  die "需要 KC_CONFIRMED_D6='确认 D6' 或 KC_AUTONOMOUS=1"

out=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q' "$REGISTRY_HOST") $(printf '%q' "$PAUSE_IMAGE") $(printf '%q' "$CA_PEM") $(printf '%q' "$INTERVAL")" <<'EOS'
set -euo pipefail
registry_host="$1"; pause_image="$2"; ca_pem="$3"; interval="$4"
pidfile=/tmp/kubercon-containerd-watch.pid
log=/tmp/kubercon-containerd-watch.log
watch_status=/tmp/kubercon-containerd-watch.status

command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3（D2 依赖）"; exit 1; }
# 首次 D6：kk create 才会下发 crictl / 同步 registry CA。启动阶段不强制；
# 循环内在文件齐备后再打补丁与 CRI 校验。
if ! command -v crictl >/dev/null 2>&1; then
  echo "NOTE: 尚无 crictl，watchdog 先启动；containerd/crictl 出现后再校验"
fi
if [[ ! -f "$ca_pem" ]]; then
  for alt in "${ca_pem%/*}/ca.crt" "${ca_pem%.pem}.crt"; do
    [[ -f "$alt" ]] && ca_pem="$alt" && break
  done
fi
if [[ ! -f "$ca_pem" ]]; then
  echo "NOTE: 尚无 registry CA（$3），watchdog 先启动；kk 同步后再补丁"
fi

if [[ -f "$pidfile" ]]; then
  old=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    echo "WATCHDOG_ALREADY_RUNNING pid=$old"
    exit 0
  fi
  rm -f "$pidfile"
fi
rm -f "$watch_status"

# 后台循环：create 状态终态后自停
nohup bash -c '
set +e
registry_host="'"$registry_host"'"
pause_image="'"$pause_image"'"
ca_pem="'"$ca_pem"'"
interval="'"$interval"'"
log=/tmp/kubercon-containerd-watch.log
status=/tmp/kubercon-create.status
watch_status=/tmp/kubercon-containerd-watch.status
echo $$ > /tmp/kubercon-containerd-watch.pid
echo "watch start $(date -Is) host=$registry_host" >> "$log"
echo "RUNNING pid=$$ started=$(date -Is)" > "$watch_status"
while true; do
  if [[ -f "$status" ]] && grep -qE "^(SUCCESS|FAILED|START_FAILED) " "$status" 2>/dev/null; then
    echo "watch stop $(date -Is) $(head -1 "$status")" >> "$log"
    echo "STOPPED finished=$(date -Is) create_status=$(head -1 "$status")" > "$watch_status"
    rm -f /tmp/kubercon-containerd-watch.pid
    exit 0
  fi
  if [[ ! -f /etc/containerd/config.toml ]]; then
    sleep "$interval"; continue
  fi
  # CA 可能稍后由 kk 同步到非 registry 节点
  effective_ca="$ca_pem"
  if [[ ! -f "$effective_ca" ]]; then
    for alt in "${ca_pem%/*}/ca.crt" "${ca_pem%.pem}.crt" /etc/ssl/registry/ssl/ca.pem /etc/ssl/registry/ssl/ca.crt; do
      [[ -f "$alt" ]] && effective_ca="$alt" && break
    done
  fi
  if [[ ! -f "$effective_ca" ]]; then
    sleep "$interval"; continue
  fi
  mkdir -p "/etc/containerd/certs.d/${registry_host}"
  cat > "/etc/containerd/certs.d/${registry_host}/hosts.toml" <<TOML
server = "https://${registry_host}"
[host."https://${registry_host}"]
  ca = "${effective_ca}"
TOML
  changed=$(PAUSE_IMAGE="$pause_image" python3 - <<'"'"'PY'"'"'
import os, re
from pathlib import Path
p = Path("/etc/containerd/config.toml")
pause = os.environ["PAUSE_IMAGE"]
raw = p.read_text()
lines = raw.splitlines()
out = []
i = 0
while i < len(lines):
    l = lines[i]
    if "registry.mirrors" in l:
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith("["):
            i += 1
        continue
    out.append(l)
    i += 1
text = "\n".join(out) + "\n"
needle = '"'"'[plugins."io.containerd.grpc.v1.cri".registry]'"'"'
if needle in text:
    text = re.sub(
        r'"'"'\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]\n(?:\s*config_path\s*=\s*"[^"]*"\n)?'"'"',
        needle + '"'"'\n      config_path = "/etc/containerd/certs.d"\n'"'"',
        text,
        count=1,
    )
text2 = re.sub(r'"'"'sandbox_image\s*=\s*"[^"]*"'"'"', f'"'"'sandbox_image = "{pause}"'"'"', text, count=1)
if text2 != raw:
    p.write_text(text2)
    print("patched")
else:
    print("ok")
PY
)
  if [[ "$changed" == "patched" ]]; then
    echo "$(date -Is) patched" >> "$log"
    if ! systemctl restart containerd >/dev/null 2>&1; then
      echo "FAILED reason=containerd-restart finished=$(date -Is)" > "$watch_status"
      echo "$(date -Is) FATAL containerd restart failed" >> "$log"
      rm -f /tmp/kubercon-containerd-watch.pid
      exit 70
    fi
    # crictl 可能尚未随 kk 下发；有则校验，无则继续轮询等待
    if command -v crictl >/dev/null 2>&1; then
      if ! crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null 2>&1; then
        echo "FAILED reason=cri finished=$(date -Is)" > "$watch_status"
        echo "$(date -Is) FATAL CRI validation failed" >> "$log"
        rm -f /tmp/kubercon-containerd-watch.pid
        exit 70
      fi
    else
      echo "$(date -Is) patched but crictl missing; defer CRI check" >> "$log"
    fi
  fi
  sleep "$interval"
done
' >>"$log" 2>&1 &
disown || true
sleep 1
pid=$(cat "$pidfile" 2>/dev/null || true)
[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || {
  echo "错误: watchdog 未能保持运行；见 $log"
  tail -n 30 "$log" 2>/dev/null || true
  exit 1
}
grep -q '^RUNNING ' "$watch_status" ||
  { echo "错误: watchdog 状态不是 RUNNING"; cat "$watch_status" 2>/dev/null || true; exit 1; }
echo "WATCHDOG_STARTED pid=$pid log=$log"
EOS
) || die "无法启动 containerd watchdog"

echo "$out"
echo "$out" | grep -qE 'WATCHDOG_(STARTED|ALREADY_RUNNING)' ||
  die "watchdog 未确认启动: $out"
