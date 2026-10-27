#!/usr/bin/env bash
# 确认 D7 后：清理「create cluster 失败留下的半装状态」，以便按同一指纹重新启动一次安装。
# 仅用于 POC / 明确可重建的节点。生产多节点慎用。
#
# 必须清干净 etcd「存在」判定相关文件，否则 kk 会走 ExistETCDHealthCheck
# （日志可见 Health check on exist etcd），在 :2379 拒连后失败。
#
# 清理范围：
#   - stop/disable kubelet、etcd
#   - kubeadm reset -f（若存在）
#   - /var/lib/etcd、/etc/kubernetes、kubelet pki、CNI
#   - etcd 残留：/etc/etcd.env、/etc/ssl/etcd、etcd.service、/usr/local/bin/etcd*
#   - 归档并删除 /tmp/kubercon-create.status；停止 watchdog；wipe Dead screen 会话名
#
# 不清理：本地 registry 数据、离线包、config.yaml、已装 OS 依赖。
# 建议顺序：本脚本 → fix-registry-containerd.sh → start-create-cluster.sh
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "$INVENTORY" || -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1 或 KC_INVENTORY_FILE"
[[ "${KC_CONFIRMED_D7:-}" == "确认 D7" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "只有用户确认 D7 清理方案后，才可设置 KC_CONFIRMED_D7='确认 D7'（或 KC_AUTONOMOUS=1）"

if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  KC_INVENTORY_FILE="$INVENTORY" KC_SSH_KEY="$SSH_KEY" "$SCRIPT_DIR/stop-containerd-watch.sh" || true
  failed=0
  while IFS=$'\t' read -r name address _ user port _; do
    echo "=== D7 recover node=$name ==="
    if ! env -u KC_INVENTORY_FILE KC_NODE1="$address" KC_SSH_USER="$user" KC_SSH_PORT="$port" \
      KC_SSH_KEY="$SSH_KEY" KC_REMOTE_DIR="$REMOTE_DIR" KC_CONFIRMED_D7="${KC_CONFIRMED_D7:-}" \
      KC_AUTONOMOUS="${KC_AUTONOMOUS:-}" "$0"; then
      failed=1
    fi
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ address _ user port _ <<<"$first"
  opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port")
  [[ -f "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")
  state=SUCCESS; ((failed == 0)) || state=BLOCKED
  ssh "${opts[@]}" "$user@$address" \
    "printf '%s finished=%s\\n' $(printf '%q' "$state") \"\$(date -Is)\" > /tmp/kubercon-recovery.aggregate.status"
  ((failed == 0)) || die "至少一个节点 D7 恢复失败；aggregate=BLOCKED"
  echo "MULTINODE_D7_RECOVER_DONE nodes=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" count)"
  exit 0
fi

kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q' "$REMOTE_DIR")" <<'EOS'
set -euo pipefail
dir="$1"

if screen -ls 2>/dev/null | grep -E '[.]kubercon-install[[:space:]]+[(](Attached|Detached)[)]' >/dev/null; then
  echo "错误: 安装器仍在运行，D7 禁止清理"
  screen -ls || true
  exit 1
fi
if [[ -f /tmp/kubercon-create.status ]] &&
   ! grep -qE '^(FAILED|START_FAILED) ' /tmp/kubercon-create.status; then
  if grep -q '^RUNNING ' /tmp/kubercon-create.status &&
     ! pgrep -af '(^|/)(kk|kc) create cluster' >/dev/null 2>&1; then
    echo "NOTE: 接受无安装器进程的孤儿 RUNNING 状态，按失败归档"
  else
    echo "错误: create 状态非可恢复失败态，禁止清理"
    cat /tmp/kubercon-create.status
    exit 1
  fi
fi
watch_pid=$(cat /tmp/kubercon-containerd-watch.pid 2>/dev/null || true)
if [[ -n "$watch_pid" ]] && kill -0 "$watch_pid" 2>/dev/null; then
  kill "$watch_pid"
fi
rm -f /tmp/kubercon-containerd-watch.pid
echo "STOPPED_BY_D7 finished=$(date -Is)" > /tmp/kubercon-containerd-watch.status

echo "=== D7 recover: stop control plane / etcd ==="
systemctl stop kubelet 2>/dev/null || true
systemctl disable --now etcd 2>/dev/null || true
systemctl stop etcd 2>/dev/null || true

if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f || true
fi

echo "=== wipe kubernetes + etcd presence markers ==="
rm -rf /var/lib/etcd /etc/kubernetes /var/lib/kubelet/pki
mkdir -p /var/lib/etcd
chmod 700 /var/lib/etcd
rm -f /etc/cni/net.d/* 2>/dev/null || true

# kk 用二进制/env/certs/unit 判断「etcd exists」→ ExistETCDHealthCheck
rm -f /etc/etcd.env
rm -rf /etc/ssl/etcd
rm -f /etc/systemd/system/etcd.service /usr/lib/systemd/system/etcd.service
rm -f /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/etcdutl
systemctl daemon-reload || true
systemctl reset-failed etcd 2>/dev/null || true

if [[ -f /tmp/kubercon-create.status ]]; then
  archive="/tmp/kubercon-create.failed.$(date +%Y%m%d-%H%M%S)"
  cp -a /tmp/kubercon-create.status "$archive.status"
  [[ ! -f /tmp/kubercon-create.log ]] || cp -a /tmp/kubercon-create.log "$archive.log"
  echo "失败证据已归档: $archive"
fi
rm -f /tmp/kubercon-create.status
screen -wipe >/dev/null 2>&1 || true

[[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal &&
   ! -d /etc/kubernetes/manifests && ! -f /etc/etcd.env &&
   ! -x /usr/local/bin/etcd ]] ||
  { echo "错误: D7 后仍有残留"; exit 1; }

echo "D7_RECOVER_DONE (etcd presence markers removed)"
EOS
