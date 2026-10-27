#!/usr/bin/env bash
# 停止遗留的 containerd watchdog。D7 恢复或 D6 启动失败时调用。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  failed=0
  while IFS=$'\t' read -r _ address _ user port _; do
    env -u KC_INVENTORY_FILE KC_NODE1="$address" KC_SSH_USER="$user" KC_SSH_PORT="$port" \
      KC_SSH_KEY="$SSH_KEY" "$0" || failed=1
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ address _ user port _ <<<"$first"
  opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port")
  [[ -f "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")
  ssh "${opts[@]}" "$user@$address" \
    'p=$(cat /tmp/kubercon-containerd-watch.aggregate.pid 2>/dev/null); [[ -z "$p" ]] || kill "$p" 2>/dev/null || true; rm -f /tmp/kubercon-containerd-watch.aggregate.pid; echo "STOPPED_BY_OPERATOR" > /tmp/kubercon-containerd-watch.aggregate.status' ||
    failed=1
  ((failed == 0))
  exit
fi
[[ -n "${KC_NODE1:-}" ]] || { echo "错误: 请设置 KC_NODE1"; exit 1; }
kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" 'bash -s' <<'EOS'
set -euo pipefail
pidfile=/tmp/kubercon-containerd-watch.pid
if [[ -f "$pidfile" ]]; then
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  fi
fi
rm -f "$pidfile"
echo "STOPPED_BY_OPERATOR finished=$(date -Is)" > /tmp/kubercon-containerd-watch.status
echo "WATCHDOG_STOPPED"
EOS
