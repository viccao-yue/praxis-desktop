#!/usr/bin/env bash
# 模式 C apply 前的本地只读门禁。参数必须是已修改后的实际交付文件。
set -euo pipefail

[[ $# -eq 2 ]] || {
  echo "用法: $0 <kubercon-installer.yaml> <cluster-configuration.yaml>" >&2
  exit 1
}
INSTALLER_MANIFEST="$1"
CC_MANIFEST="$2"
[[ -f "$INSTALLER_MANIFEST" ]] || { echo "错误: 文件不存在: $INSTALLER_MANIFEST"; exit 1; }
[[ -f "$CC_MANIFEST" ]] || { echo "错误: 文件不存在: $CC_MANIFEST"; exit 1; }

if grep -En 'REPLACE_|CHANGEME|<[^>]+>' "$INSTALLER_MANIFEST" "$CC_MANIFEST"; then
  echo "错误: 清单仍含占位符，禁止进入 D8I/D8C"
  exit 1
fi
grep -Eq '^kind:[[:space:]]+CustomResourceDefinition$' "$INSTALLER_MANIFEST" ||
  { echo "错误: installer manifest 缺 CRD"; exit 1; }
grep -Eq '^kind:[[:space:]]+ClusterRole$' "$INSTALLER_MANIFEST" ||
  { echo "错误: installer manifest 缺 ClusterRole"; exit 1; }
grep -Eq '^kind:[[:space:]]+Deployment$' "$INSTALLER_MANIFEST" ||
  { echo "错误: installer manifest 缺 Deployment"; exit 1; }
grep -Eq '^[[:space:]]*image:[[:space:]]+[^[:space:]]+:[^[:space:]]+$' "$INSTALLER_MANIFEST" ||
  { echo "错误: installer image 缺 registry/repository 或显式 tag"; exit 1; }
grep -Eq '^kind:[[:space:]]+ClusterConfiguration$' "$CC_MANIFEST" ||
  { echo "错误: CC 文件 kind 不正确"; exit 1; }
grep -Eq '^[[:space:]]+adminPassword:[[:space:]]+"?[^"[:space:]]{12,}"?[[:space:]]*$' "$CC_MANIFEST" ||
  { echo "错误: adminPassword 为空或少于 12 个非空白字符"; exit 1; }

echo "Mode C manifests validation OK"
sha256sum "$INSTALLER_MANIFEST" "$CC_MANIFEST"
