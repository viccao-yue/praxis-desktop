#!/usr/bin/env bash
# V22.6：从已校验 inventory 确定性生成 3CP/etcd + 任意 worker config.yaml。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INVENTORY="${KC_INVENTORY_FILE:-}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || die "请设置 KC_INVENTORY_FILE"
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_DIR 含不安全字符"
[[ "${KC_CONFIRMED_D4:-}" == "确认 D4" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D4='确认 D4' 或 KC_AUTONOMOUS=1"

"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
NODE_LINE=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
IFS=$'\t' read -r NODE_NAME NODE_ADDRESS _ SSH_USER SSH_PORT _ <<<"$NODE_LINE"
[[ -n "$NODE_ADDRESS" ]] || die "inventory 无首节点"
NODE1="${KC_NODE1:-$NODE_ADDRESS}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
  -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -p "$SSH_PORT")
[[ -f "$LOCAL_KEY" ]] && SSH_OPTS+=(-i "$LOCAL_KEY")

tmp_config=$(mktemp)
tmp_inventory=$(mktemp)
trap 'rm -f "$tmp_config" "$tmp_inventory"' EXIT
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" render-config --output "$tmp_config"
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" normalize > "$tmp_inventory"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE1}" \
  "bash -s -- $(printf '%q' "$REMOTE_DIR")" <<'EOS'
set -euo pipefail
dir="$1"
mkdir -p "$dir"
if [[ -f "$dir/config.yaml" ]]; then
  cp -a "$dir/config.yaml" "$dir/config.yaml.bak.$(date +%Y%m%d-%H%M%S)"
fi
EOS
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE1}" \
  "umask 077; cat > $(printf '%q' "$REMOTE_DIR/inventory.json")" < "$tmp_inventory"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE1}" \
  "umask 077; cat > $(printf '%q' "$REMOTE_DIR/config.yaml")" < "$tmp_config"

echo "MULTINODE_CONFIG_WRITTEN node1=$NODE_NAME address=$NODE1 profile=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)"
KC_NODE1="$NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_PORT="$SSH_PORT" KC_SSH_KEY="$LOCAL_KEY" \
  KC_REMOTE_DIR="$REMOTE_DIR" KC_INVENTORY_FILE="$INVENTORY" \
  KC_PROFILE="${KC_PROFILE:-kk-artifact-then-cc}" \
  "$SCRIPT_DIR/validate-cluster-config.sh"
