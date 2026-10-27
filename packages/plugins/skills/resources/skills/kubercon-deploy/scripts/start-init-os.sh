#!/usr/bin/env bash
# D5：从 node1 以 screen 对 inventory 中全部节点执行一次 init os。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INVENTORY="${KC_INVENTORY_FILE:-}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INSTALLER="${KC_INSTALLER:-}"
OFFLINE="${KC_OFFLINE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || { echo "错误: 请设置 KC_INVENTORY_FILE"; exit 1; }
[[ "${KC_CONFIRMED_D5:-}" == "确认 D5" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: 需要 KC_CONFIRMED_D5='确认 D5' 或 KC_AUTONOMOUS=1"; exit 1; }
[[ "$INSTALLER" =~ ^\./[A-Za-z0-9._-]+$ ]] || { echo "错误: KC_INSTALLER 格式错误"; exit 1; }
[[ "$OFFLINE" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || { echo "错误: KC_OFFLINE 格式错误"; exit 1; }
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
IFS=$'\t' read -r _ address _ user port _ <<<"$first"
opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port")
[[ -f "$LOCAL_KEY" ]] && opts+=(-i "$LOCAL_KEY")

ssh "${opts[@]}" "$user@$address" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$INSTALLER" "$OFFLINE")" <<'EOS'
set -euo pipefail
dir="$1"; installer="$2"; offline="$3"
cd "$dir"
[[ -x "$installer" && -f "$offline" && -f config.yaml && -f inventory.json ]] ||
  { echo "错误: D5 输入不完整"; exit 1; }
help=$("$installer" init os --help 2>&1)
for flag in --filename --artifact; do
  grep -Eq -- "(^|[[:space:],])${flag}([=[:space:],]|$)" <<<"$help" ||
    { echo "错误: init os 缺 $flag"; exit 1; }
done
status=/tmp/kubercon-init-os.status
[[ ! -f "$status" ]] || { echo "错误: D5 状态已存在"; cat "$status"; exit 1; }
screen -ls 2>/dev/null | grep -q '[.]kubercon-init-os' &&
  { echo "错误: D5 screen 已存在"; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S)
log="/tmp/kubercon-init-os.${stamp}.log"
runner="/tmp/kubercon-init-os.${stamp}.sh"
fingerprint=$(
  {
    sha256sum "$installer" "$offline" config.yaml | awk '{print $1}'
    python3 - inventory.json <<'PY'
import hashlib,json
d=json.load(open("inventory.json"))
print(hashlib.sha256(json.dumps(d,sort_keys=True,separators=(",",":")).encode()).hexdigest())
PY
  } | sha256sum | awk '{print $1}'
)
cat > "$runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cd $(printf '%q' "$dir")
$(printf '%q' "$installer") init os --filename config.yaml --artifact $(printf '%q' "$offline") 2>&1 | tee $(printf '%q' "$log")
rc=\${PIPESTATUS[0]}
if ((rc == 0)); then
  printf 'SUCCESS rc=0 fingerprint=%s finished=%s log=%s\n' $(printf '%q' "$fingerprint") "\$(date -Is)" $(printf '%q' "$log") > $(printf '%q' "$status")
else
  printf 'FAILED rc=%s fingerprint=%s finished=%s log=%s\n' "\$rc" $(printf '%q' "$fingerprint") "\$(date -Is)" $(printf '%q' "$log") > $(printf '%q' "$status")
fi
exit "\$rc"
EOF
chmod 700 "$runner"
printf 'RUNNING fingerprint=%s started=%s log=%s\n' "$fingerprint" "$(date -Is)" "$log" > "$status"
screen -dmS kubercon-init-os bash "$runner"
sleep 1
screen -ls 2>/dev/null | grep -q '[.]kubercon-init-os' ||
  grep -q '^SUCCESS ' "$status" ||
  { cat "$status"; exit 1; }
echo "INIT_OS_STARTED status=$status log=$log"
EOS
