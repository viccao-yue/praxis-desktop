#!/usr/bin/env bash
# 仅重置失败的 D6R 状态，保留日志证据；不会删除 registry 数据。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ address _ SSH_USER SSH_PORT _ <<<"$first"
  KC_NODE1="${KC_NODE1:-$address}"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
fi
[[ -n "${KC_NODE1:-}" ]] || { echo "错误: 请设置 KC_NODE1"; exit 1; }
[[ "${KC_CONFIRMED_D6R_RESET:-}" == "确认重置 D6R" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: 需要 KC_CONFIRMED_D6R_RESET='确认重置 D6R' 或 KC_AUTONOMOUS=1"; exit 1; }

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" 'bash -s' <<'EOS'
set -euo pipefail
status=/tmp/kubercon-registry.status
[[ -f "$status" ]] || { echo "D6R 状态不存在，无需重置"; exit 0; }
grep -q '^FAILED ' "$status" || {
  echo "错误: 只允许重置 FAILED 状态"
  cat "$status"
  exit 1
}
if systemctl is-active --quiet registry 2>/dev/null ||
   pgrep -af 'registry.*serve|harbor' >/dev/null 2>&1; then
  echo "错误: 检测到 registry 仍在运行；先诊断，禁止掩盖部分成功状态"
  exit 1
fi
archive="/tmp/kubercon-registry.failed.$(date +%Y%m%d-%H%M%S)"
cp -a "$status" "$archive.status"
[[ ! -f /tmp/kubercon-registry.log ]] || cp -a /tmp/kubercon-registry.log "$archive.log"
rm -f "$status"
echo "REGISTRY_FAILED_STATE_RESET archive=$archive"
EOS
