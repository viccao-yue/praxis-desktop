#!/usr/bin/env bash
# 离线介质本机 → node1 传输（可断点续传 + sha256）。
# 公有云跨网传 11G 常见 1～3 小时；断线后重跑本脚本即可续传，禁止删掉重来。
#
# 相位（省时间关键）:
#   light — 只传安装器 + yaml + sha256（数 MB），供远端 detect / 本机已 detect 后的轻量同步
#   heavy — 只传 *.tar.gz 离线大包
#   all   — light 然后 heavy（默认）
#
# 用法:
#   export KC_NODE1=... KC_SSH_KEY=... KC_MEDIA_DIR=/path/to/media
#   ./scripts/rsync-offline.sh              # all
#   KC_TRANSFER_PHASE=light ./scripts/rsync-offline.sh
#   KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
MEDIA_DIR="${KC_MEDIA_DIR:-}"
PHASE="${KC_TRANSFER_PHASE:-all}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
  -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }

[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ -n "$MEDIA_DIR" ]] || die "请设置 KC_MEDIA_DIR"
[[ -d "$MEDIA_DIR" ]] || die "KC_MEDIA_DIR 不存在: $MEDIA_DIR"
[[ "$PHASE" == "light" || "$PHASE" == "heavy" || "$PHASE" == "all" ]] ||
  die "KC_TRANSFER_PHASE 只能是 light|heavy|all"
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_DIR 不安全"
command -v rsync >/dev/null || die "本机没有 rsync，请先安装"

ssh_base=(ssh "${SSH_OPTS[@]}")
rsync_ssh="ssh"
for o in "${SSH_OPTS[@]}"; do
  rsync_ssh+=" $(printf '%q' "$o")"
done

echo "=============================================================="
echo "  离线介质传输 phase=$PHASE → ${SSH_USER}@${KC_NODE1}:${REMOTE_DIR}"
echo "  源: $MEDIA_DIR"
echo "  预期: 公有云跨网大包 1～3h；断线重跑本脚本续传"
echo "=============================================================="

# 远端准备目录；缺 rsync 时尝试安装（有外网）
"${ssh_base[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q' "$REMOTE_DIR")" <<'EOS'
set -euo pipefail
dir="$1"
mkdir -p "$dir"
if ! command -v rsync >/dev/null 2>&1; then
  echo "NOTE: 远端无 rsync，尝试安装…"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y rsync || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rsync || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y rsync || true
  fi
fi
command -v rsync >/dev/null 2>&1 || {
  echo "错误: 远端仍无 rsync。无外网时请离线补包，或改用 scp（不可可靠续传）。"
  exit 1
}
echo "REMOTE_RSYNC_OK"
EOS

RSYNC_COMMON=(-av --partial --inplace --progress --timeout=300
  -e "$rsync_ssh")

transfer_light() {
  echo "--- phase light: 安装器 + 平台 yaml + sha256 ---"
  local files=()
  local match
  shopt -s nullglob
  for match in \
    "$MEDIA_DIR"/kk "$MEDIA_DIR"/kk-linux-amd64 "$MEDIA_DIR"/kk_amd64 "$MEDIA_DIR"/kk_arm64 \
    "$MEDIA_DIR"/kc "$MEDIA_DIR"/kc_amd64 "$MEDIA_DIR"/kc_arm64 \
    "$MEDIA_DIR"/kubercon-installer.yaml "$MEDIA_DIR"/cluster-configuration.yaml \
    "$MEDIA_DIR"/local-path-storage.yaml \
    "$MEDIA_DIR"/*.sha256sum "$MEDIA_DIR"/*.sha256
  do
    [[ -f "$match" ]] && files+=("$match")
  done
  shopt -u nullglob
  if [[ -n "$INVENTORY" ]]; then
    local script_dir profile storage_manifest
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    "$script_dir/inventory.py" --inventory "$INVENTORY" validate
    profile=$("$script_dir/inventory.py" --inventory "$INVENTORY" profile)
    if [[ "$profile" == external-prod ]]; then
      storage_manifest=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["storageBootstrapManifest"])' "$INVENTORY")
      [[ -f "$MEDIA_DIR/$storage_manifest" ]] ||
        die "external-prod 缺存储 bootstrap manifest: $MEDIA_DIR/$storage_manifest"
      files+=("$MEDIA_DIR/$storage_manifest")
    fi
  fi
  ((${#files[@]} > 0)) || die "light 相位没有可传文件（需要 kk/kc 与/或 yaml）"
  rsync "${RSYNC_COMMON[@]}" "${files[@]}" \
    "${SSH_USER}@${KC_NODE1}:${REMOTE_DIR}/"
  "${ssh_base[@]}" "${SSH_USER}@${KC_NODE1}" \
    "cd $(printf '%q' "$REMOTE_DIR") && { [ -x kk-linux-amd64 ] && [ ! -e kk ] && ln -sfn kk-linux-amd64 kk; true; } && chmod +x kk kc kk-* kc_* 2>/dev/null || true"
  echo "LIGHT_DONE"
}

transfer_heavy() {
  echo "--- phase heavy: 离线 tar.gz（可续传）---"
  shopt -s nullglob
  local tars=("$MEDIA_DIR"/kubercon-offline-*.tar.gz "$MEDIA_DIR"/*-offline-*.tar.gz)
  shopt -u nullglob
  # 两个 glob 会命中同一文件（如 kubercon-offline-*.tar.gz 也匹配 *-offline-*.tar.gz）
  local real=() seen=""
  local t base
  for t in "${tars[@]}"; do
    [[ -f "$t" ]] || continue
    base=$(basename "$t")
    [[ " $seen " == *" $base "* ]] && continue
    seen+=" $base"
    real+=("$t")
  done
  ((${#real[@]} >= 1)) || die "未找到离线包 kubercon-offline-*.tar.gz"
  ((${#real[@]} == 1)) || {
    echo "警告: 找到多个不同名离线包，将全部传输:"
    printf '  %s\n' "${real[@]}"
  }

  local retries="${KC_RSYNC_RETRIES:-3}"
  local attempt=1 start elapsed
  while (( attempt <= retries )); do
    echo "NOTE: heavy rsync attempt $attempt/$retries"
    start=$(date +%s)
    if rsync "${RSYNC_COMMON[@]}" "${real[@]}" \
      "${SSH_USER}@${KC_NODE1}:${REMOTE_DIR}/"; then
      elapsed=$(( $(date +%s) - start ))
      echo "HEAVY_RSYNC_DONE elapsed=${elapsed}s attempt=$attempt"
      break
    fi
    echo "警告: heavy rsync 失败 attempt=$attempt"
    if (( attempt == retries )); then
      die "heavy rsync 连续失败 ${retries} 次；可重跑本脚本续传"
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  echo "--- 远端字节数 + sha256 校验（失败删坏包）---"
  local local_sizes=""
  for t in "${real[@]}"; do
    local_sizes+="$(basename "$t")=$(wc -c < "$t" | tr -d ' ') "
  done
  if ! "${ssh_base[@]}" "${SSH_USER}@${KC_NODE1}" \
    "bash -s -- $(printf '%q' "$REMOTE_DIR") $(printf '%q' "$local_sizes")" <<'EOS'
set -euo pipefail
cd "$1"
expect_sizes="$2"
# 字节数预检
for pair in $expect_sizes; do
  name=${pair%%=*}; want=${pair#*=}
  [[ -f "$name" ]] || { echo "错误: 远端缺 $name"; exit 1; }
  got=$(wc -c < "$name" | tr -d ' ')
  [[ "$got" == "$want" ]] || {
    echo "错误: $name 字节数 mismatch local=$want remote=$got；删除坏包"
    rm -f "$name"
    exit 1
  }
done
ok=0
for s in *.sha256sum *.sha256; do
  [[ -f "$s" ]] || continue
  echo "checking $s"
  if ! sha256sum -c "$s"; then
    echo "错误: sha256 失败，删除对应坏包"
    # 从 checksum 文件名推断 tar；或删所有 offline tar
    rm -f kubercon-offline-*.tar.gz *-offline-*.tar.gz 2>/dev/null || true
    exit 1
  fi
  ok=1
done
[[ "$ok" == 1 ]] || {
  echo "警告: 无 .sha256sum 文件；改为对 tar.gz 打印摘要供人工核对"
  sha256sum kubercon-offline-*.tar.gz *-offline-*.tar.gz 2>/dev/null || true
  exit 0
}
echo "SHA256_OK"
EOS
  then
    die "远端校验失败（坏包已删）。请重跑: KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh"
  fi
}

case "$PHASE" in
  light) transfer_light ;;
  heavy) transfer_heavy ;;
  all) transfer_light; transfer_heavy ;;
esac

echo
echo "传输完成 phase=$PHASE。下一步:"
echo "  1) 若尚未探测: KC_REMOTE_DIR=$REMOTE_DIR ./scripts/detect-installer.sh"
echo "  2) D2 系统准备须含: tar gzip unzip which screen"
echo "  3) 公有云双地址: inventory/SSH 可用公网；kk hosts.address 必须用 internalAddress"
exit 0
