#!/usr/bin/env bash
# 当探测结果为 REGISTRY_MODE=separate 时，经用户明确确认 D6R 后，
# 在 node1 后台初始化本地 registry。不会安装 screen 或覆盖旧状态。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INSTALLER="${KC_INSTALLER:-}"
OFFLINE="${KC_OFFLINE:-}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n "$INVENTORY" ]]; then
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  [[ "${KC_PROFILE:-}" == kk-artifact-then-cc ]] ||
    die "v1.6 多节点保证范围只支持 KC_PROFILE=kk-artifact-then-cc"
  [[ "$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)" != external-prod ]] ||
    die "external-prod 使用外部 Harbor，禁止执行 D6R"
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ inv_address _ inv_user inv_port _ <<<"$first"
  KC_NODE1="${KC_NODE1:-$inv_address}"
  SSH_USER="$inv_user"; SSH_PORT="$inv_port"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
fi
[[ "${KC_CONFIRMED_D6R:-}" == "确认 D6R" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "只有用户已明确回复「确认 D6R」后，才可设置 KC_CONFIRMED_D6R='确认 D6R'（或 KC_AUTONOMOUS=1）"
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ -n "${KC_PROFILE:-}" ]] || die "请设置 KC_PROFILE（D6R 前须先 validate config）"
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_DIR 含不安全字符"
[[ "$INSTALLER" =~ ^\./[A-Za-z0-9._-]+$ ]] || die "请设置安全的 KC_INSTALLER"
[[ "$OFFLINE" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || die "请设置安全的 KC_OFFLINE"

echo "NOTE: D6R 前校验 config.yaml"
KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
  KC_REMOTE_DIR="$REMOTE_DIR" KC_PROFILE="$KC_PROFILE" KC_INVENTORY_FILE="$INVENTORY" \
  "$SCRIPT_DIR/validate-cluster-config.sh" ||
  die "config 未通过；多节点请重跑 prepare-multinode-config.sh 再 D6R"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$INSTALLER" "$OFFLINE" "${INVENTORY:+1}")" <<'EOS'
set -uo pipefail
dir="$1"; installer="$2"; offline="$3"; use_inventory="$4"
cd "$dir" || exit 1
if [[ "$use_inventory" == 1 ]]; then
  grep -q '^SUCCESS ' /tmp/kubercon-init-os.status 2>/dev/null ||
    { echo "错误: 多节点 D5 init os 尚未 SUCCESS"; exit 1; }
  d5_fp=$(
    {
      sha256sum "$installer" "$offline" config.yaml | awk '{print $1}'
      python3 - <<'PY'
import hashlib,json
d=json.load(open("inventory.json"))
print(hashlib.sha256(json.dumps(d,sort_keys=True,separators=(",",":")).encode()).hexdigest())
PY
    } | sha256sum | awk '{print $1}'
  )
  recorded=$(sed -n 's/.* fingerprint=\([^ ]*\).*/\1/p' /tmp/kubercon-init-os.status)
  [[ "$recorded" == "$d5_fp" ]] ||
    { echo "错误: D5 后 installer/offline/config/inventory 已变化，必须重新 D5"; exit 1; }
fi
command -v screen >/dev/null 2>&1 ||
  { echo "错误: node1 没有 screen；请在 D2 阶段安装"; exit 1; }
# openEuler 最小系统常缺 tar/gzip；缺了会在 InstallRegistryBinary 中途失败，白等一轮
for need in tar gzip python3 curl; do
  command -v "$need" >/dev/null 2>&1 ||
    { echo "错误: 缺少 $need。请在 D2 安装: yum/dnf install -y tar gzip unzip which screen python3 curl"; exit 1; }
done
[[ -x "$installer" && -f "$offline" && -f config.yaml ]] ||
  { echo "错误: 安装器、离线包或 config.yaml 不完整"; exit 1; }
if systemctl is-active registry >/dev/null 2>&1 ||
   systemctl is-active harbor >/dev/null 2>&1; then
  echo "错误: 已有 registry/harbor 服务运行，但没有可核验的本次状态，禁止重复初始化"
  exit 1
fi
help=$("$installer" init registry --help 2>&1) || exit 1
has_flag() { printf '%s\n' "$help" | grep -Eq -- "(^|[[:space:],])$1([=[:space:],]|$)"; }
has_flag --artifact ||
  { echo "错误: 安装器没有 init registry --artifact 能力"; exit 1; }
has_flag --yes ||
  { echo "错误: 安装器没有 init registry --yes 能力"; exit 1; }
has_flag --filename ||
  { echo "错误: 安装器没有 init registry --filename 能力"; exit 1; }
# registry 制品指纹只使用文件内容 hash，不把路径名和后续 K8s 配置改动混入。
# config 语义由 validate-cluster-config.sh 保证；单节点 registry 始终是 node1。
fingerprint=$(
  {
    sha256sum "$installer" | awk '{print $1}'
    sha256sum "$offline" | awk '{print $1}'
    if [[ "$use_inventory" == 1 ]]; then
      python3 - "$dir/inventory.json" <<'PY'
import hashlib,json,sys
data=json.load(open(sys.argv[1]))
raw=json.dumps(data,sort_keys=True,separators=(",",":")).encode()
print(hashlib.sha256(raw).hexdigest())
PY
    fi
  } | sha256sum | awk '{print $1}'
) || { echo "错误: 无法计算 installer/artifact 内容指纹"; exit 1; }

status=/tmp/kubercon-registry.status
[[ ! -e "$status" ]] ||
  { echo "错误: 已存在 registry 状态，禁止自动覆盖："; cat "$status"; exit 1; }
if screen -ls 2>/dev/null | grep -q '[.]kubercon-registry'; then
  echo "错误: 已有同名活动或残留会话，禁止重复启动"
  exit 1
fi

stamp=$(date +%Y%m%d-%H%M%S)
log="/tmp/kubercon-registry.${stamp}.log"
runner="/tmp/kubercon-registry.${stamp}.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'cd %q\n' "$dir"
  printf '%q init registry --filename config.yaml --artifact %q --yes 2>&1 | tee %q\n' "$installer" "$offline" "$log"
  echo 'installer_rc=${PIPESTATUS[0]}'
  printf 'if (( installer_rc == 0 )) && grep -Fq %q %q; then\n' \
    'Pipeline[InitRegistryPipeline] execute successfully' "$log"
  printf '  printf "SUCCESS rc=0 fingerprint=%s finished=%%s log=%%s\\n" "$(date -Is)" %q > %q\n' "$fingerprint" "$log" "$status"
  echo '  exit 0'
  echo 'fi'
  echo 'failure_rc=$installer_rc; reason=installer-failed'
  echo 'if (( failure_rc == 0 )); then failure_rc=1; reason=missing-success-marker; fi'
  printf 'printf "FAILED rc=%%s installer_rc=%%s reason=%%s fingerprint=%s finished=%%s log=%%s\\n" "$failure_rc" "$installer_rc" "$reason" "$(date -Is)" %q > %q\n' "$fingerprint" "$log" "$status"
  echo 'exit "$failure_rc"'
} > "$runner"
chmod 700 "$runner"
ln -sfn "$log" /tmp/kubercon-registry.log
printf 'RUNNING fingerprint=%s started=%s log=%s runner=%s\n' "$fingerprint" "$(date -Is)" "$log" "$runner" > "$status"
screen -dmS kubercon-registry bash "$runner" ||
  { printf 'START_FAILED finished=%s log=%s\n' "$(date -Is)" "$log" > "$status"; exit 1; }
sleep 1
if ! screen -ls 2>/dev/null | grep -q '[.]kubercon-registry'; then
  if grep -q '^SUCCESS ' "$status" 2>/dev/null; then
    echo "registry 已快速成功完成。"
    cat "$status"
    exit 0
  fi
  echo "警告: registry 会话已快速退出，请立即查看状态和日志："
  cat "$status"
  tail -n 30 "$log" 2>/dev/null || true
  exit 1
fi
echo "registry 初始化已启动。完成后状态必须为 SUCCESS，才能执行 D6。"
echo "查看: cat $status; tail -n 30 /tmp/kubercon-registry.log"
EOS
