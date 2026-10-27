#!/usr/bin/env bash
# D11：逐个停止单个控制面的 kubelet+apiserver，从存活节点验证 API 仍可用并恢复。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
INVENTORY="${KC_INVENTORY_FILE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || { echo "错误: 请设置 KC_INVENTORY_FILE"; exit 1; }
[[ "${KC_CONFIRMED_D11:-}" == "确认 D11" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: HA 演练需 KC_CONFIRMED_D11='确认 D11' 或 KC_AUTONOMOUS=1"; exit 1; }
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

PROFILE=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
API_ADDRESS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["apiAddress"])' "$INVENTORY")
first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
IFS=$'\t' read -r _ _ _ user port _ <<<"$first"

restore() {
  local address="$1"
  kubercon_ssh_opts "$address" "$port"
  ssh "${SSH_OPTS[@]}" "$user@$address" 'systemctl start kubelet' >/dev/null 2>&1 || true
}

probe_server() {
  case "$PROFILE" in
    local-haproxy) printf '%s\n' "https://127.0.0.1:6443" ;;
    *) printf 'https://%s:6443\n' "$API_ADDRESS" ;;
  esac
}

pick_probe_address() {
  local isolated="$1" probe=""
  while IFS=$'\t' read -r name address _ _ _ roles; do
    [[ "$name" == "$isolated" ]] && continue
    [[ ",$roles," == *,control-plane,* ]] || continue
    probe="$address"
    break
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
  [[ -n "$probe" ]] || return 1
  printf '%s\n' "$probe"
}

while IFS=$'\t' read -r name address _ _ _ roles; do
  [[ ",$roles," == *,control-plane,* ]] || continue
  probe_address=$(pick_probe_address "$name") ||
    { echo "错误: 找不到未隔离的控制面来探测 API"; exit 1; }
  echo "=== HA failover: isolate $name probe_from=$probe_address ==="
  kubercon_ssh_opts "$address" "$port"
  ssh "${SSH_OPTS[@]}" "$user@$address" 'bash -s' <<'EOS'
set -euo pipefail
systemctl stop kubelet
ids=$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name kube-apiserver -q)
[[ -n "$ids" ]] || { systemctl start kubelet; echo "无 kube-apiserver container"; exit 1; }
for id in $ids; do crictl --runtime-endpoint unix:///run/containerd/containerd.sock stop "$id"; done
EOS
  trap 'restore "$address"' EXIT
  ok=0
  server=$(probe_server)
  for _ in $(seq 1 12); do
    kubercon_ssh_opts "$probe_address" "$port"
    if ssh "${SSH_OPTS[@]}" "$user@$probe_address" \
      "kubectl --kubeconfig=/root/.kube/config --server=$(printf '%q' "$server") --insecure-skip-tls-verify get --raw=/readyz 2>/dev/null" |
      grep -qx ok; then
      ok=1; break
    fi
    sleep 5
  done
  ((ok == 1)) || { echo "错误: 隔离 $name 后从 $probe_address 探测 $server 不可用"; exit 1; }
  restore "$address"
  trap - EXIT
  ready=""
  for _ in $(seq 1 60); do
    kubercon_ssh_opts "$probe_address" "$port"
    ready=$(ssh "${SSH_OPTS[@]}" "$user@$probe_address" \
      "kubectl --kubeconfig=/root/.kube/config --server=$(printf '%q' "$server") --insecure-skip-tls-verify get node $(printf '%q' "$name") -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)
    [[ "$ready" == True ]] && break
    sleep 5
  done
  [[ "$ready" == True ]] || { echo "错误: $name 未在 5 分钟内恢复 Ready"; exit 1; }
  echo "HA_NODE_FAILOVER_OK node=$name probe_from=$probe_address"
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
echo "HA_FAILOVER_OK controlPlane=3"
