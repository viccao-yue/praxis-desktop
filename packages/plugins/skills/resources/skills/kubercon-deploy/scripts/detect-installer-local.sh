#!/usr/bin/env bash
# 本机介质目录探测安装 PROFILE（不依赖 SSH、不依赖 11G 离线包已上传）。
# 用途：传大包之前先确认二进制路径，避免「先传 2 小时再发现 PROFILE=unsupported」。
#
# 用法:
#   KC_MEDIA_DIR=/path/to/media ./scripts/detect-installer-local.sh
#   KC_MEDIA_DIR=... KC_REGISTRY_STRATEGY=local ./scripts/detect-installer-local.sh
set -uo pipefail

MEDIA_DIR="${KC_MEDIA_DIR:-}"
REGISTRY_STRATEGY="${KC_REGISTRY_STRATEGY:-local}"

die() { echo "错误: $*" >&2; exit 1; }

[[ -n "$MEDIA_DIR" ]] || die "请设置 KC_MEDIA_DIR（本机介质目录，含 kk/kc 与可选 yaml）"
[[ -d "$MEDIA_DIR" ]] || die "KC_MEDIA_DIR 不存在: $MEDIA_DIR"
[[ "$REGISTRY_STRATEGY" == "local" || "$REGISTRY_STRATEGY" == "external" ]] ||
  die "KC_REGISTRY_STRATEGY 只能是 local 或 external"

cd "$MEDIA_DIR" || die "无法进入 $MEDIA_DIR"

echo "=============================================================="
echo "  本机安装器探测（传大包前）: $MEDIA_DIR"
echo "=============================================================="
ls -l kc kk kc_* kk_* kk-linux-* 2>/dev/null || true
echo

# 兼容下载中心文件名
if [[ ! -e ./kk && -x ./kk-linux-amd64 ]]; then
  ln -sfn kk-linux-amd64 kk
fi

has_platform_manifests=no
if [[ -f kubercon-installer.yaml && -f cluster-configuration.yaml ]]; then
  has_platform_manifests=yes
fi

found=
for b in ./kc ./kk ./kc_amd64 ./kc_arm64 ./kk_amd64 ./kk_arm64 ./kk-linux-amd64; do
  [[ -x "$b" ]] || continue

  cluster_help=$("$b" create cluster --help 2>&1) || continue
  config_help=$("$b" create config --help 2>&1) || true
  init_help=$("$b" init os --help 2>&1) || true
  registry_help=$("$b" init registry --help 2>&1) || true

  has_flag() {
    printf '%s\n' "$1" | grep -Eq -- "(^|[[:space:],])$2([=[:space:],]|$)"
  }

  has_init_os=no; has_config=no; has_cluster_filename=no; has_init_filename=no
  has_kubercon_cluster=no; has_kubercon_config=no; has_artifact=no; has_yes=no
  registry_mode=none

  has_flag "$init_help" --artifact && has_init_os=yes
  has_flag "$init_help" --filename && has_init_filename=yes
  has_flag "$config_help" --filename && has_config=yes
  has_flag "$cluster_help" --filename && has_cluster_filename=yes
  has_flag "$cluster_help" --with-kubercon && has_kubercon_cluster=yes
  has_flag "$config_help" --with-kubercon && has_kubercon_config=yes
  has_flag "$cluster_help" --artifact && has_artifact=yes
  has_flag "$cluster_help" --yes && has_yes=yes

  if [[ "$REGISTRY_STRATEGY" == "external" ]]; then
    registry_mode=external
  elif has_flag "$cluster_help" --with-registry; then
    registry_mode=inline
  elif has_flag "$registry_help" --artifact && has_flag "$registry_help" --yes && has_flag "$registry_help" --filename; then
    registry_mode=separate
  fi

  echo "MATRIX candidate=$b kubercon_create=$has_kubercon_cluster artifact=$has_artifact yes=$has_yes registry=$registry_mode manifests=$has_platform_manifests"

  if [[ "$has_init_os" == yes && "$has_config" == yes && "$has_cluster_filename" == yes &&
        "$has_init_filename" == yes && "$has_kubercon_cluster" == yes &&
        "$has_kubercon_config" == yes && "$has_artifact" == yes &&
        "$has_yes" == yes && "$registry_mode" != none ]]; then
    found=native-kubercon
    echo "INSTALLER=$b"
    echo "PROFILE=native-kubercon"
    echo "REGISTRY_MODE=$registry_mode"
    echo "PLATFORM_VIA=installer-flag"
    echo
    echo "结论: PROFILE=native-kubercon — 可以开始传离线大包。"
    exit 0
  fi

  if [[ "$has_config" == yes && "$has_cluster_filename" == yes &&
        "$has_artifact" == yes && "$has_yes" == yes &&
        "$registry_mode" != none && "$has_kubercon_cluster" == no &&
        "$has_platform_manifests" == yes ]]; then
    found=kk-artifact-then-cc
    echo "NOTE=using kk-artifact-then-cc; do NOT pass --with-kubesphere"
    echo "INSTALLER=$b"
    echo "PROFILE=kk-artifact-then-cc"
    echo "REGISTRY_MODE=$registry_mode"
    echo "PLATFORM_VIA=cc"
    echo
    echo "结论: PROFILE=kk-artifact-then-cc（V22.6 下载中心真实路径）。"
    echo "      可以开始传离线大包；装完 K8s 后走 apply-platform-after-k8s.sh。"
    echo "      下载中心文件名 kk-linux-amd64 ≠ 一定带 --with-kubercon（本 PROFILE 正常）。"
    exit 0
  fi

  echo "REJECTED=$b"
done

echo
echo "错误: 本机介质无法匹配可用 PROFILE。"
echo "      最小清单（模式 A）:"
echo "        1) kk* 或 kc* 安装器"
echo "        2) kubercon-offline-*.tar.gz (+ .sha256)"
echo "        3) 若无 --with-kubercon：还必须有 kubercon-installer.yaml + cluster-configuration.yaml"
echo "      禁止用 --with-kubesphere 冒充常青云平台。"
exit 1
