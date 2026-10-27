#!/usr/bin/env bash
# 只读：探测安装器及 KuberCon 安装所需的真实参数能力。
# 支持两种 PROFILE：
#   native-kubercon     — create cluster/config 带 --with-kubercon（理想交付 fork）
#   kk-artifact-then-cc — KubeKey 仅装 K8s+registry，平台靠 apply installer+CC
#                         （V22.6.0 下载中心真实介质）
# 禁止把 --with-kubesphere 当成常青云平台安装入口。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
REGISTRY_STRATEGY="${KC_REGISTRY_STRATEGY:-local}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

if [[ -z "${KC_NODE1:-}" ]]; then
  echo "错误: 请设置 KC_NODE1"
  exit 1
fi

if [[ ! "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "错误: KC_REMOTE_DIR 只能包含字母、数字、点、下划线、横线和斜线"
  exit 1
fi
if [[ "$REGISTRY_STRATEGY" != "local" && "$REGISTRY_STRATEGY" != "external" ]]; then
  echo "错误: KC_REGISTRY_STRATEGY 只能是 local 或 external"
  exit 1
fi

remote() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" "$@"
}

echo "=============================================================="
echo "  安装器二进制探测（${SSH_USER}@${KC_NODE1}:${REMOTE_DIR}）"
echo "=============================================================="

if ! remote "test -d '$REMOTE_DIR'"; then
  echo "错误: 远程目录不存在: $REMOTE_DIR"
  echo "      先把 kc/kk 与离线包拷到该目录。"
  exit 1
fi

remote "ls -l '$REMOTE_DIR'/kc '$REMOTE_DIR'/kk '$REMOTE_DIR'/kc_* '$REMOTE_DIR'/kk_* '$REMOTE_DIR'/kk-linux-* 2>/dev/null || true"
echo

HIT=$(remote "bash -s -- '$REMOTE_DIR' '$REGISTRY_STRATEGY'" <<'EOS'
set +e
cd "$1" || exit 1
registry_strategy="$2"

# 兼容下载中心文件名 kk-linux-amd64
if [ ! -e ./kk ] && [ -x ./kk-linux-amd64 ]; then
  ln -sfn kk-linux-amd64 kk
fi
if [ ! -e ./kk ] && [ -x ./kk_amd64 ]; then
  ln -sfn kk_amd64 kk
fi

has_platform_manifests=no
if [ -f kubercon-installer.yaml ] && [ -f cluster-configuration.yaml ]; then
  has_platform_manifests=yes
fi

for b in ./kc ./kk ./kc_amd64 ./kc_arm64 ./kk_amd64 ./kk_arm64 ./kk-linux-amd64; do
  [ -x "$b" ] || continue

  cluster_help=$("$b" create cluster --help 2>&1)
  cluster_rc=$?
  config_help=$("$b" create config --help 2>&1)
  config_rc=$?
  init_help=$("$b" init os --help 2>&1)
  init_rc=$?
  registry_help=$("$b" init registry --help 2>&1)
  registry_rc=$?
  [ "$cluster_rc" -eq 0 ] || { echo "REJECTED=$b reason=create-cluster-help"; continue; }

  has_init_os=no
  has_config=no
  has_cluster_filename=no
  has_init_filename=no
  has_kubercon_cluster=no
  has_kubercon_config=no
  has_kubesphere=no
  has_artifact=no
  has_yes=no
  registry_mode=none

  has_flag() {
    printf '%s\n' "$1" | grep -Eq -- "(^|[[:space:],])$2([=[:space:],]|$)"
  }
  [ "$init_rc" -eq 0 ] && has_flag "$init_help" --artifact && has_init_os=yes
  [ "$init_rc" -eq 0 ] && has_flag "$init_help" --filename && has_init_filename=yes
  [ "$config_rc" -eq 0 ] && has_flag "$config_help" --filename && has_config=yes
  has_flag "$cluster_help" --filename && has_cluster_filename=yes
  has_flag "$cluster_help" --with-kubercon && has_kubercon_cluster=yes
  [ "$config_rc" -eq 0 ] && has_flag "$config_help" --with-kubercon && has_kubercon_config=yes
  has_flag "$cluster_help" --with-kubesphere && has_kubesphere=yes
  has_flag "$cluster_help" --artifact && has_artifact=yes
  has_flag "$cluster_help" --yes && has_yes=yes
  if [[ "$registry_strategy" == "external" ]]; then
    registry_mode=external
  elif has_flag "$cluster_help" --with-registry; then
    registry_mode=inline
  elif [ "$registry_rc" -eq 0 ] &&
       has_flag "$registry_help" --artifact &&
       has_flag "$registry_help" --yes &&
       has_flag "$registry_help" --filename; then
    registry_mode=separate
  fi

  echo "MATRIX candidate=$b init_os=$has_init_os init_filename=$has_init_filename create_config=$has_config cluster_filename=$has_cluster_filename kubercon_create=$has_kubercon_cluster kubercon_config=$has_kubercon_config kubesphere=$has_kubesphere artifact=$has_artifact yes=$has_yes registry=$registry_mode manifests=$has_platform_manifests"

  emit_hit() {
    local profile="$1"
    echo "INSTALLER=$b"
    echo "PROFILE=$profile"
    echo "HAS_INIT_OS=$has_init_os"
    echo "HAS_CREATE_CONFIG=$has_config"
    echo "HAS_CLUSTER_FILENAME=$has_cluster_filename"
    echo "HAS_INIT_FILENAME=$has_init_filename"
    echo "HAS_KUBERCON_CREATE=$has_kubercon_cluster"
    echo "HAS_KUBERCON_CONFIG=$has_kubercon_config"
    echo "HAS_ARTIFACT=$has_artifact"
    echo "HAS_YES=$has_yes"
    echo "REGISTRY_MODE=$registry_mode"
    echo "PLATFORM_VIA=cc"
    [ "$profile" = native-kubercon ] && echo "PLATFORM_VIA=installer-flag"
    exit 0
  }

  # PROFILE 1: 原生 --with-kubercon
  if [ "$has_init_os" = yes ] &&
     [ "$has_config" = yes ] &&
     [ "$has_cluster_filename" = yes ] &&
     [ "$has_init_filename" = yes ] &&
     [ "$has_kubercon_cluster" = yes ] &&
     [ "$has_kubercon_config" = yes ] &&
     [ "$has_artifact" = yes ] &&
     [ "$has_yes" = yes ] &&
     [ "$registry_mode" != none ]; then
    emit_hit native-kubercon
  fi

  # PROFILE 2: V22.6 下载中心真实路径 — kk 装 K8s，平台靠 installer+CC
  if [ "$has_config" = yes ] &&
     [ "$has_cluster_filename" = yes ] &&
     [ "$has_artifact" = yes ] &&
     [ "$has_yes" = yes ] &&
     [ "$registry_mode" != none ] &&
     [ "$has_kubercon_cluster" = no ] &&
     [ "$has_platform_manifests" = yes ]; then
    echo "NOTE=using kk-artifact-then-cc; do NOT pass --with-kubesphere for platform install"
    emit_hit kk-artifact-then-cc
  fi

  echo "REJECTED=$b"
done
echo "INSTALLER="
echo "PROFILE=unsupported"
exit 2
EOS
) || true

echo "$HIT"
INSTALLER=$(echo "$HIT" | awk -F= '/^INSTALLER=/{print $2; exit}')
PROFILE=$(echo "$HIT" | awk -F= '/^PROFILE=/{print $2; exit}')
if [[ -z "$INSTALLER" || "$PROFILE" == "unsupported" || -z "$PROFILE" ]]; then
  echo
  echo "错误: 没有找到可用的安装 PROFILE。"
  echo "      支持:"
  echo "        native-kubercon     — 需 --with-kubercon"
  echo "        kk-artifact-then-cc — 需 artifact + 同目录 kubercon-installer.yaml/cluster-configuration.yaml"
  echo "      禁止用 --with-kubesphere 冒充常青云平台安装。"
  exit 1
fi

echo
echo "结论: 后续命令使用远程 ${REMOTE_DIR}/${INSTALLER#./}"
echo "      INSTALLER=$INSTALLER"
echo "      PROFILE=$PROFILE"
echo "      REGISTRY_MODE=$(echo "$HIT" | awk -F= '/^REGISTRY_MODE=/{print $2; exit}')"
if [[ "$PROFILE" == "kk-artifact-then-cc" ]]; then
  echo "      平台安装路径: create cluster(仅 K8s) → apply installer.yaml → apply CC"
fi
exit 0
