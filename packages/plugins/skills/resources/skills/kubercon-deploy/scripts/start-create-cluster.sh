#!/usr/bin/env bash
# 经用户明确确认 D6 后，在 node1 的 detached screen 中启动一次 create cluster。
# 本脚本再次验证实际二进制能力，并用状态文件记录成功/失败；不会安装 screen，
# 不会清理旧状态，也不会重跑已启动过的安装。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INSTALLER="${KC_INSTALLER:-}"
OFFLINE="${KC_OFFLINE:-}"
REGISTRY_MODE="${KC_REGISTRY_MODE:-}"
# native-kubercon | kk-artifact-then-cc — 禁止默认 native（V22.6 下载中心真实路径是 kk-artifact-then-cc）
PROFILE="${KC_PROFILE:-}"
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
  [[ -z "$PROFILE" || "$PROFILE" == kk-artifact-then-cc ]] ||
    die "v1.6 多节点保证范围只支持 KC_PROFILE=kk-artifact-then-cc"
  inv_profile=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ inv_address _ inv_user inv_port _ <<<"$first"
  KC_NODE1="${KC_NODE1:-$inv_address}"
  SSH_USER="$inv_user"; SSH_PORT="$inv_port"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
  if [[ "$inv_profile" == external-prod ]]; then
    [[ -z "$REGISTRY_MODE" || "$REGISTRY_MODE" == external ]] ||
      die "external-prod 必须使用 KC_REGISTRY_MODE=external"
    REGISTRY_MODE=external
  else
    [[ -z "$REGISTRY_MODE" || "$REGISTRY_MODE" == separate ]] ||
      die "$inv_profile 必须使用 KC_REGISTRY_MODE=separate"
    REGISTRY_MODE=separate
  fi
fi
[[ "${KC_CONFIRMED_D6:-}" == "确认 D6" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "只有用户已明确回复「确认 D6」后，才可设置 KC_CONFIRMED_D6='确认 D6'（或 KC_AUTONOMOUS=1）"
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ -n "$INSTALLER" ]] || die "请设置 KC_INSTALLER（detect-installer.sh 输出的 ./kc 或 ./kk）"
[[ -n "$OFFLINE" ]] || die "请设置 KC_OFFLINE（远程离线包文件名）"
[[ -n "$PROFILE" ]] || die "请设置 KC_PROFILE=native-kubercon 或 kk-artifact-then-cc（禁止省略；V22.6 下载中心用后者）"
[[ -n "$REGISTRY_MODE" ]] || die "请设置 KC_REGISTRY_MODE=inline|separate|external（V22.6 本机仓多为 separate）"
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_DIR 含不安全字符"
[[ "$INSTALLER" =~ ^\./[A-Za-z0-9._-]+$ ]] || die "KC_INSTALLER 只接受 ./kc、./kk 等相对文件名"
[[ "$OFFLINE" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || die "KC_OFFLINE 只接受不含路径和空格的 .tar.gz 文件名"
[[ "$REGISTRY_MODE" == "inline" || "$REGISTRY_MODE" == "separate" || "$REGISTRY_MODE" == "external" ]] ||
  die "KC_REGISTRY_MODE 只能是 inline、separate 或 external"
[[ "$PROFILE" == "native-kubercon" || "$PROFILE" == "kk-artifact-then-cc" ]] ||
  die "KC_PROFILE 只能是 native-kubercon 或 kk-artifact-then-cc"

if [[ -n "$INVENTORY" ]]; then
  echo "NOTE: D6 前重渲染 config.yaml（hosts.address=internalAddress，避免公网 hairpin）"
  tmp_cfg=$(mktemp)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" render-config --output "$tmp_cfg"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "umask 077; cat > $(printf '%q' "$REMOTE_DIR/config.yaml")" < "$tmp_cfg"
  rm -f "$tmp_cfg"
  KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
    KC_REMOTE_DIR="$REMOTE_DIR" KC_INVENTORY_FILE="$INVENTORY" KC_PROFILE="$PROFILE" \
    "$SCRIPT_DIR/validate-cluster-config.sh" ||
    die "D6 前 config 校验失败"
  echo "NOTE: D6 前净化 hosts / 空 kubernetes·etcd 骨架"
  KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" \
    "$SCRIPT_DIR/precreate-sanitize.sh" ||
    die "D6 前 precreate-sanitize 失败"
  echo "NOTE: D6 多节点 full 全量门禁"
  KC_INVENTORY_FILE="$INVENTORY" KC_PREFLIGHT_PHASE=full KC_SSH_KEY="$SSH_KEY" \
    KC_REMOTE_DIR="$REMOTE_DIR" "$SCRIPT_DIR/preflight-multinode.sh" ||
    die "多节点 full 门禁失败"
else
  # 单节点：同样清空骨架与 127.0.1.1 抢解析（无 inventory 时 precreate-sanitize 不可用）
  echo "NOTE: D6 前单节点净化 hosts / 空 kubernetes·etcd 骨架"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" 'bash -s' <<'EOS' || die "单节点 precreate-sanitize 失败"
set -euo pipefail
if [[ -d /etc/kubernetes/manifests ]] && [[ -z "$(ls -A /etc/kubernetes/manifests 2>/dev/null || true)" ]]; then
  if [[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal ]]; then
    rm -rf /etc/kubernetes
    echo "REMOVED_EMPTY_KUBERNETES"
  fi
fi
if [[ -d /var/lib/etcd ]] && [[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal ]]; then
  rm -rf /var/lib/etcd
  echo "REMOVED_EMPTY_ETCD"
fi
tmp=$(mktemp)
grep -vE '^127\.0\.1\.1[[:space:]]|^fe80:' /etc/hosts > "$tmp" || true
cat "$tmp" > /etc/hosts
rm -f "$tmp"
echo "SINGLE_NODE_SANITIZE_OK"
EOS
fi

# 先做远端残留预检，再启 watchdog（避免 FAILED 状态导致 watchdog 秒退，掩盖真因）
echo "NOTE: D6 远端预检（status / etcd / screen）"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$INSTALLER" "$OFFLINE" "$REGISTRY_MODE" "$PROFILE" "${INVENTORY:+1}")" <<'EOP' || die "D6 远端预检失败"
set -euo pipefail
dir="$1"; installer="$2"; offline="$3"; registry_mode="$4"; profile="$5"; multinode="$6"
cd "$dir" || { echo "错误: 目录不存在: $dir"; exit 1; }
[[ -x "$installer" && -f "$offline" && -f config.yaml ]] ||
  { echo "错误: installer/offline/config.yaml 不完整"; exit 1; }
if [[ "$multinode" == 1 ]]; then
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
  d5_recorded=$(sed -n 's/.* fingerprint=\([^ ]*\).*/\1/p' /tmp/kubercon-init-os.status)
  [[ "$d5_recorded" == "$d5_fp" ]] ||
    { echo "错误: D5 后输入已变化，必须重新 D5"; exit 1; }
fi
if [[ -f /tmp/kubercon-create.status ]]; then
  echo "错误: 已存在 /tmp/kubercon-create.status："
  cat /tmp/kubercon-create.status
  echo "禁止覆盖。失败重装须确认 D7 后 recover-failed-create.sh"
  exit 1
fi
if systemctl is-active kubelet >/dev/null 2>&1 ||
   compgen -G '/etc/kubernetes/manifests/*.yaml' >/dev/null ||
   [[ -d /var/lib/etcd/member || -d /var/lib/etcd/wal ]]; then
  echo "错误: 发现 kubelet/控制面/etcd 残留，禁止 create；走 D7"
  exit 1
fi
if [[ -x /usr/local/bin/etcd || -f /etc/etcd.env || -d /etc/ssl/etcd ]]; then
  echo "错误: 发现 etcd 存在判定物（binary/env/certs）。D7 必须清干净，否则会走 ExistETCDHealthCheck"
  ls -la /usr/local/bin/etcd /etc/etcd.env /etc/ssl/etcd 2>/dev/null || true
  exit 1
fi
if screen -ls 2>/dev/null | grep -q '[.]kubercon-install'; then
  echo "错误: 存在 kubercon-install screen 会话"
  screen -ls || true
  exit 1
fi
command -v python3 >/dev/null && command -v curl >/dev/null && command -v screen >/dev/null || {
  echo "错误: 缺少 python3/curl/screen（D2）"
  exit 1
}
help=$("$installer" create cluster --help 2>&1)
for flag in --filename --artifact --yes; do
  echo "$help" | grep -Eq -- "(^|[[:space:],])${flag}([=[:space:],]|$)" ||
    { echo "错误: 安装器缺少 $flag"; exit 1; }
done
if [[ "$profile" == "native-kubercon" ]]; then
  echo "$help" | grep -Eq -- '(^|[[:space:],])--with-kubercon([=[:space:],]|$)' ||
    { echo "错误: native-kubercon 缺 --with-kubercon"; exit 1; }
fi
if [[ "$multinode" == 1 ]]; then
  delivery_profile=$(python3 -c 'import json;print(json.load(open("inventory.json"))["profile"])')
  if [[ "$delivery_profile" != external-prod ]]; then
    echo "$help" | grep -Eq -- '(^|[[:space:],])--with-local-storage([=[:space:],]|$)' ||
      { echo "错误: 多节点本地存储需要 --with-local-storage，但安装器不支持"; exit 1; }
  fi
fi
if [[ "$registry_mode" == "separate" ]]; then
  fp=$(
    {
      sha256sum "$installer" | awk '{print $1}'
      sha256sum "$offline" | awk '{print $1}'
      if [[ "$multinode" == 1 ]]; then
        python3 - "$dir/inventory.json" <<'PY'
import hashlib,json,sys
d=json.load(open(sys.argv[1]))
print(hashlib.sha256(json.dumps(d,sort_keys=True,separators=(",",":")).encode()).hexdigest())
PY
      fi
    } | sha256sum | awk '{print $1}'
  )
  status=/tmp/kubercon-registry.status
  recorded=$(sed -n 's/.* fingerprint=\([^ ]*\).*/\1/p' "$status" 2>/dev/null)
  [[ -f "$status" ]] && grep -q '^SUCCESS ' "$status" && [[ "$recorded" == "$fp" ]] || {
    echo "错误: D6R 未成功或 installer/offline 内容指纹不一致"
    cat "$status" 2>/dev/null || true
    exit 1
  }
fi
echo "D6_PRECHECK_OK"
EOP

# D4 门禁：namespaceOverride / insecureRegistries 等必须在 D6R 前就正确
echo "NOTE: 校验 config.yaml 门禁"
KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
  KC_REMOTE_DIR="$REMOTE_DIR" KC_PROFILE="$PROFILE" KC_INVENTORY_FILE="$INVENTORY" \
  "$SCRIPT_DIR/validate-cluster-config.sh" ||
  die "config.yaml 未通过门禁；单节点请重跑 prepare-single-node-config.sh，必要时重跑 D6R"

# V22.6 separate registry：create 前修 containerd；中途靠 watchdog 对抗 kk 回写
WATCHDOG_STARTED=0
if [[ "$PROFILE" == "kk-artifact-then-cc" && "$REGISTRY_MODE" == "separate" ]]; then
  echo "NOTE: D6 前执行 fix-registry-containerd.sh（仅 containerd，不改 config.yaml）"
  KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
    KC_REMOTE_DIR="$REMOTE_DIR" KC_SKIP_CONFIG_PATCH=1 KC_INVENTORY_FILE="$INVENTORY" \
    "$SCRIPT_DIR/fix-registry-containerd.sh" ||
    die "fix-registry-containerd 失败；禁止带着错误 registry 配置启动 create cluster"
  echo "NOTE: 启动 containerd registry watchdog（失败则禁止 create）"
  KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
    KC_INVENTORY_FILE="$INVENTORY" KC_REMOTE_DIR="$REMOTE_DIR" \
    KC_CONFIRMED_D6="${KC_CONFIRMED_D6:-}" KC_AUTONOMOUS="${KC_AUTONOMOUS:-}" \
    "$SCRIPT_DIR/watch-containerd-registry.sh" ||
    die "watchdog 启动失败；禁止裸跑 create cluster（首轮几乎必败）"
  WATCHDOG_STARTED=1
  if [[ -n "$INVENTORY" ]]; then
    # 首次 create 前全节点可能尚无 containerd；CRI pull 门禁只能在 containerd 出现后做。
    # 以 node1 是否已有 config.toml 判断：无则 defer 给 create 中途 watchdog。
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
      'test -f /etc/containerd/config.toml' 2>/dev/null; then
      if ! KC_INVENTORY_FILE="$INVENTORY" KC_PREFLIGHT_PHASE=post-registry KC_SSH_KEY="$SSH_KEY" \
        KC_REMOTE_DIR="$REMOTE_DIR" "$SCRIPT_DIR/preflight-multinode.sh"; then
        KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" \
          "$SCRIPT_DIR/stop-containerd-watch.sh" || true
        die "多节点 CRI/registry 镜像门禁失败"
      fi
    else
      echo "NOTE: node1 尚无 containerd，跳过 post-registry CRI 门禁（首次 D6）"
    fi
  fi
fi

if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$INSTALLER" "$OFFLINE" "$REGISTRY_MODE" "$PROFILE" "${INVENTORY:+1}")" <<'EOS'
set -uo pipefail
dir="$1"; installer="$2"; offline="$3"; registry_mode="$4"; profile="$5"; multinode="$6"
cd "$dir" || { echo "错误: 目录不存在: $dir"; exit 1; }

command -v screen >/dev/null 2>&1 ||
  { echo "错误: node1 没有 screen。请在 D2 系统准备阶段安装，不能在 D6 中静默改系统。"; exit 1; }
[[ -x "$installer" ]] || { echo "错误: 安装器不存在或不可执行: $installer"; exit 1; }
[[ -f "$offline" ]] || { echo "错误: 离线包不存在: $offline"; exit 1; }
[[ -f config.yaml ]] || { echo "错误: 缺少 $dir/config.yaml；create config 必须显式 --filename config.yaml"; exit 1; }
if systemctl is-active kubelet >/dev/null 2>&1 ||
   compgen -G '/etc/kubernetes/manifests/*.yaml' >/dev/null ||
   [[ -d /var/lib/etcd/member || -d /var/lib/etcd/wal ]]; then
  echo "错误: 发现 kubelet/控制面 manifest/etcd 数据。可能是旧状态文件随重启丢失，禁止再次 create cluster。"
  echo "先收集现场；只有用户明确确认 D7 的清理方案后才能处理。"
  exit 1
fi

help=$("$installer" create cluster --help 2>&1) ||
  { echo "错误: 无法读取 create cluster help"; exit 1; }
has_flag() { printf '%s\n' "$help" | grep -Eq -- "(^|[[:space:],])$1([=[:space:],]|$)"; }
required_flags=(--filename --artifact --yes)
if [[ "$profile" == "native-kubercon" ]]; then
  required_flags+=(--with-kubercon)
fi
for flag in "${required_flags[@]}"; do
  has_flag "$flag" ||
    { echo "错误: 安装器缺少必需参数 $flag，拒绝启动"; exit 1; }
done
with_local_storage=0
if [[ "$multinode" == 1 ]]; then
  delivery_profile=$(python3 -c 'import json;print(json.load(open("inventory.json"))["profile"])')
  if [[ "$delivery_profile" != external-prod ]]; then
    has_flag --with-local-storage ||
      { echo "错误: 多节点本地 profile 需要 --with-local-storage"; exit 1; }
    with_local_storage=1
  fi
fi
# 混合路径禁止误加 --with-kubesphere
if [[ "$profile" == "kk-artifact-then-cc" ]] && has_flag --with-kubesphere; then
  echo "NOTE: PROFILE=kk-artifact-then-cc，create cluster 将不传 --with-kubesphere"
fi
if [[ "$registry_mode" == "inline" ]]; then
  has_flag --with-registry ||
    { echo "错误: 安装器不支持 inline registry；先探测并走 separate registry 流程"; exit 1; }
fi
fingerprint=$(
  {
    sha256sum "$installer" | awk '{print $1}'
    sha256sum "$offline" | awk '{print $1}'
    if [[ "$multinode" == 1 ]]; then
      python3 - "$dir/inventory.json" <<'PY'
import hashlib,json,sys
d=json.load(open(sys.argv[1]))
print(hashlib.sha256(json.dumps(d,sort_keys=True,separators=(",",":")).encode()).hexdigest())
PY
    fi
  } | sha256sum | awk '{print $1}'
) || { echo "错误: 无法计算 installer/artifact 内容指纹"; exit 1; }
if [[ "$registry_mode" == "separate" ]]; then
  registry_status=/tmp/kubercon-registry.status
  recorded_fingerprint=$(sed -n 's/.* fingerprint=\([^ ]*\).*/\1/p' "$registry_status" 2>/dev/null)
  [[ -f "$registry_status" ]] && grep -q '^SUCCESS ' "$registry_status" &&
    [[ "$recorded_fingerprint" == "$fingerprint" ]] ||
    { echo "错误: separate registry 尚未成功；先按确认 D6R 运行 start-init-registry.sh"; exit 1; }
fi

status=/tmp/kubercon-create.status
if [[ -f "$status" ]]; then
  echo "错误: 已存在安装状态文件 $status："
  cat "$status"
  echo "禁止自动覆盖。若是已失败且用户决定重装，须按确认 D7 清理后再启动。"
  exit 1
fi
if screen -ls 2>/dev/null | grep -E '[.]kubercon-install[[:space:]]+[(](Attached|Detached)[)]' >/dev/null; then
  echo "错误: 已有活动安装会话，禁止重复启动"
  exit 1
fi
if screen -ls 2>/dev/null | grep -q '[.]kubercon-install'; then
  echo "错误: 存在同名 Dead/Unknown 会话。先人工核对日志，禁止自动 screen -wipe 后重启。"
  exit 1
fi

stamp=$(date +%Y%m%d-%H%M%S)
log="/tmp/kubercon-create.${stamp}.log"
runner="/tmp/kubercon-create.${stamp}.sh"
registry_arg=()
[[ "$registry_mode" == "inline" ]] && registry_arg=(--with-registry)

{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'cd %q\n' "$dir"
  echo '{'
  if [[ "$profile" == "native-kubercon" ]]; then
    printf '%q create cluster --filename config.yaml --with-kubercon ' "$installer"
  else
    # kk-artifact-then-cc: 只装 K8s(+registry 已由 D6R 或 inline 处理)，平台后续 apply CC
    printf '%q create cluster --filename config.yaml ' "$installer"
  fi
  if [[ ${#registry_arg[@]} -gt 0 ]]; then printf '%q ' "${registry_arg[@]}"; fi
  if [[ "$with_local_storage" == 1 ]]; then printf '%q ' --with-local-storage; fi
  printf -- '--artifact %q --yes 2>&1 | tee %q\n' "$offline" "$log"
  echo '  exit ${PIPESTATUS[0]}'
  echo '} &'
  echo 'installer_pid=$!'
  echo 'watch_failed=0'
  if [[ "$profile" == "kk-artifact-then-cc" && "$registry_mode" == "separate" ]]; then
    if [[ "$multinode" == 1 ]]; then
      watch_status=/tmp/kubercon-containerd-watch.aggregate.status
      watch_pidfile=/tmp/kubercon-containerd-watch.aggregate.pid
    else
      watch_status=/tmp/kubercon-containerd-watch.status
      watch_pidfile=/tmp/kubercon-containerd-watch.pid
    fi
    echo 'while kill -0 "$installer_pid" 2>/dev/null; do'
    printf '  if grep -q "^FAILED " %q 2>/dev/null; then\n' "$watch_status"
    echo '    echo "FATAL: containerd watchdog failed; abort installer" | tee -a '"$(printf '%q' "$log")"
    echo '    pkill -TERM -P "$installer_pid" 2>/dev/null || true'
    echo '    kill "$installer_pid" 2>/dev/null || true'
    echo '    watch_failed=1'
    echo '    break'
    echo '  fi'
    printf '  watch_pid=$(cat %q 2>/dev/null || true)\n' "$watch_pidfile"
    echo '  if [[ -z "$watch_pid" ]] || ! kill -0 "$watch_pid" 2>/dev/null; then'
    echo '    echo "FATAL: containerd watchdog exited unexpectedly; abort installer" | tee -a '"$(printf '%q' "$log")"
    echo '    pkill -TERM -P "$installer_pid" 2>/dev/null || true'
    echo '    kill "$installer_pid" 2>/dev/null || true'
    echo '    watch_failed=1'
    echo '    break'
    echo '  fi'
    echo '  sleep 5'
    echo 'done'
  fi
  echo 'wait "$installer_pid"'
  echo 'installer_rc=$?'
  echo 'if (( watch_failed == 1 )); then installer_rc=70; fi'
  printf 'if (( installer_rc == 0 )) && grep -Fq %q %q; then\n' \
    'Pipeline[CreateClusterPipeline] execute successfully' "$log"
  printf '  printf "SUCCESS rc=0 fingerprint=%s finished=%%s log=%%s\\n" "$(date -Is)" %q > %q\n' "$fingerprint" "$log" "$status"
  echo '  exit 0'
  echo 'fi'
  # SaveKubeConfig 经公网 EIP:6443 超时是云上 hairpin 假失败：若本机 API 与三节点已 Ready，补完 cm 并记 SUCCESS
  echo 'if grep -q "SaveKubeConfig" '"$(printf '%q' "$log")"' && grep -Eq "i/o timeout|connection timed out|dial tcp .*6443" '"$(printf '%q' "$log")"'; then'
  echo '  export KUBECONFIG=/etc/kubernetes/admin.conf'
  echo '  if command -v kubectl >/dev/null && curl -sk --connect-timeout 3 https://127.0.0.1:6443/readyz >/dev/null; then'
  echo '    ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '\''$2=="Ready"{c++} END{print c+0}'\'')'
  echo '    total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d " ")'
  echo '    if [[ -n "$total" && "$ready" == "$total" && "$total" -ge 1 ]]; then'
  echo '      kubectl get ns kubekey-system >/dev/null 2>&1 || kubectl create ns kubekey-system'
  echo '      kubectl -n kubekey-system delete cm kubeconfig --ignore-not-found >/dev/null 2>&1 || true'
  echo '      kubectl -n kubekey-system create configmap kubeconfig --from-file=config=/etc/kubernetes/admin.conf'
  printf '      printf "SUCCESS rc=0 fingerprint=%s finished=%%s log=%%s note=healed-save-kubeconfig-hairpin\\n" "$(date -Is)" %q > %q\n' "$fingerprint" "$log" "$status"
  echo '      echo "NOTE: SaveKubeConfig 公网超时已自愈（集群 Ready + 本机 API OK）" | tee -a '"$(printf '%q' "$log")"
  echo '      exit 0'
  echo '    fi'
  echo '  fi'
  echo 'fi'
  echo 'failure_rc=$installer_rc; reason=installer-failed'
  echo 'if (( failure_rc == 0 )); then failure_rc=1; reason=missing-success-marker; fi'
  printf 'printf "FAILED rc=%%s installer_rc=%%s reason=%%s fingerprint=%s finished=%%s log=%%s\\n" "$failure_rc" "$installer_rc" "$reason" "$(date -Is)" %q > %q\n' "$fingerprint" "$log" "$status"
  echo 'exit "$failure_rc"'
} > "$runner"
chmod 700 "$runner"
ln -sfn "$log" /tmp/kubercon-create.log
printf 'RUNNING fingerprint=%s started=%s log=%s runner=%s\n' "$fingerprint" "$(date -Is)" "$log" "$runner" > "$status"

if ! screen -dmS kubercon-install bash "$runner"; then
  printf 'START_FAILED finished=%s log=%s runner=%s\n' "$(date -Is)" "$log" "$runner" > "$status"
  echo "错误: screen 启动失败"
  exit 1
fi

sleep 1
if ! screen -ls 2>/dev/null | grep -q '[.]kubercon-install'; then
  if grep -q '^SUCCESS ' "$status" 2>/dev/null; then
    echo "安装已快速成功完成。"
    cat "$status"
    exit 0
  fi
  echo "警告: 会话已快速退出，请立即查看状态和日志："
  cat "$status"
  tail -n 30 "$log" 2>/dev/null || true
  exit 1
fi
echo "安装已启动且仅启动一次。"
echo "状态: $status"
echo "日志: $log"
echo "轮询: cat $status; tail -n 30 /tmp/kubercon-create.log"
EOS
then
  # 响应丢失不等于 screen 未启动；先重连确认，避免误停 watchdog 和安装器。
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "grep -q '^RUNNING ' /tmp/kubercon-create.status 2>/dev/null &&
     screen -ls 2>/dev/null | grep -q '[.]kubercon-install'"; then
    watch_pidfile=/tmp/kubercon-containerd-watch.pid
    [[ -n "$INVENTORY" ]] && watch_pidfile=/tmp/kubercon-containerd-watch.aggregate.pid
    if (( WATCHDOG_STARTED == 0 )) || ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
      "p=\$(cat $(printf '%q' "$watch_pidfile") 2>/dev/null); [ -n \"\$p\" ] && kill -0 \"\$p\" 2>/dev/null"; then
      echo "警告: 启动响应中断，但已重连确认 create 正在运行。"
      exit 0
    fi
  fi
  if (( WATCHDOG_STARTED == 1 )); then
    KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
      KC_INVENTORY_FILE="$INVENTORY" \
      "$SCRIPT_DIR/stop-containerd-watch.sh" || true
  fi
  die "D6 screen 启动失败；watchdog 已尝试停止"
fi
