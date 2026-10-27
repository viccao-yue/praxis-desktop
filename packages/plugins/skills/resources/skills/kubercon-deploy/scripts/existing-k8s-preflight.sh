#!/usr/bin/env bash
# 模式 C 专用只读门禁：验证目标集群身份、节点、存储和 cluster-admin 权限，
# 并拒绝覆盖已有/半装的 KuberCon。不要用裸机 preflight-ssh.sh 替代。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_KUBECONFIG="${KC_REMOTE_KUBECONFIG:-/root/.kube/config}"
EXPECTED_API="${KC_EXPECT_APISERVER_HOST:-}"
EXPECTED_UID="${KC_EXPECT_CLUSTER_UID:-}"
EXPECTED_NODES="${KC_EXPECT_NODES:-}"
REGISTRY_HOST="${KC_PLATFORM_REGISTRY_HOST:-}"
REGISTRY_PORT="${KC_PLATFORM_REGISTRY_PORT:-}"
EXPECTED_SC="${KC_EXPECT_STORAGE_CLASS:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

[[ -n "${KC_NODE1:-}" ]] || { echo "错误: 请设置 KC_NODE1"; exit 1; }
[[ "$REMOTE_KUBECONFIG" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
  { echo "错误: KC_REMOTE_KUBECONFIG 必须是仅含安全字符的绝对路径"; exit 1; }
[[ -n "$EXPECTED_API" ]] || { echo "错误: 模式 C 必须设置 KC_EXPECT_APISERVER_HOST"; exit 1; }
[[ "$EXPECTED_NODES" =~ ^[1-9][0-9]*$ ]] || { echo "错误: 模式 C 必须设置 KC_EXPECT_NODES"; exit 1; }
[[ "$REGISTRY_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "错误: 请设置安全的 KC_PLATFORM_REGISTRY_HOST"; exit 1; }
[[ "$REGISTRY_PORT" =~ ^[0-9]+$ ]] || { echo "错误: 请设置 KC_PLATFORM_REGISTRY_PORT（常见 443 或 5000）"; exit 1; }

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT
k() {
  : > "$ERRF"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "export KUBECONFIG='$REMOTE_KUBECONFIG'; kubectl $(printf '%q ' "$@")" 2>"$ERRF"
}
show_err() { [[ -s "$ERRF" ]] && sed 's/^/    /' "$ERRF"; }
fail_now() { echo "错误: $1"; show_err; exit 1; }
server_host() {
  local authority="${1#*://}"; authority="${authority%%/*}"
  if [[ "$authority" == \[* ]]; then
    authority="${authority#\[}"; printf '%s\n' "${authority%%\]*}"
  else
    printf '%s\n' "${authority%%:*}"
  fi
}

echo "=============================================================="
echo "  模式 C：已有 Kubernetes 只装平台（只读门禁）"
echo "=============================================================="

SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}') ||
  fail_now "读不到 API server"
ACTUAL_API=$(server_host "$SERVER")
[[ "$ACTUAL_API" == "$EXPECTED_API" ]] ||
  { echo "错误: 集群身份不符，预期 $EXPECTED_API，实际 $ACTUAL_API"; exit 1; }
echo "API server: $SERVER（身份匹配）"
CLUSTER_UID=$(k get ns kube-system -o jsonpath='{.metadata.uid}') ||
  fail_now "读不到 kube-system UID"
[[ -n "$CLUSTER_UID" ]] || fail_now "kube-system UID 为空"
if [[ -n "$EXPECTED_UID" && "$CLUSTER_UID" != "$EXPECTED_UID" ]]; then
  echo "错误: 集群 UID 不符，预期 $EXPECTED_UID，实际 $CLUSTER_UID"
  exit 1
fi
if [[ "$ACTUAL_API" == "127.0.0.1" || "$ACTUAL_API" == "localhost" || "$ACTUAL_API" == "::1" ]]; then
  [[ -n "$EXPECTED_UID" ]] ||
    { echo "错误: API 是回环地址，必须设置 KC_EXPECT_CLUSTER_UID 精确确认目标集群"; exit 1; }
fi
echo "集群 UID: $CLUSTER_UID"
VERSION=$(k get --raw /version) || fail_now "取不到 Kubernetes 版本"
echo "Kubernetes 版本: $VERSION"

NODES=$(k get nodes --no-headers) || fail_now "取不到节点"
[[ -n "$NODES" ]] || fail_now "节点列表为空"
COUNT=$(printf '%s\n' "$NODES" | grep -c . || true)
[[ "$COUNT" == "$EXPECTED_NODES" ]] ||
  { echo "错误: 节点数 $COUNT 与预期 $EXPECTED_NODES 不符"; exit 1; }
NOT_READY=$(printf '%s\n' "$NODES" | awk '$2 !~ /^Ready/ {print}')
[[ -z "$NOT_READY" ]] ||
  { echo "错误: 存在未 Ready 节点:"; echo "$NOT_READY"; exit 1; }
echo "节点: $COUNT/$EXPECTED_NODES Ready"

ARCHS=$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}') ||
  fail_now "取不到节点架构"
ARCH_COUNT=$(printf '%s\n' "$ARCHS" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
[[ "$ARCH_COUNT" == "1" ]] ||
  { echo "错误: 节点架构不一致:"; echo "$ARCHS"; exit 1; }
echo "架构: $(printf '%s\n' "$ARCHS" | grep -v '^$' | sort -u)"

CAN_ADMIN=$(k auth can-i '*' '*') || fail_now "无法验证集群权限"
[[ "$CAN_ADMIN" == "yes" ]] ||
  { echo "错误: 当前身份不是 cluster-admin，无法安全安装平台级 CRD/RBAC"; exit 1; }
echo "权限: cluster-admin"

SC=$(k get sc) || fail_now "取不到 StorageClass"
[[ -n "$SC" ]] || { echo "错误: 没有 StorageClass"; exit 1; }
if [[ -n "$EXPECTED_SC" ]]; then
  printf '%s\n' "$SC" | awk -v want="$EXPECTED_SC" 'NR>1 && $1==want {found=1} END {exit !found}' ||
    { echo "错误: 指定的 StorageClass 不存在: $EXPECTED_SC"; exit 1; }
  echo "指定 StorageClass: $EXPECTED_SC（须写入 cc）"
else
  printf '%s\n' "$SC" | grep -q '(default)' ||
    { echo "错误: 没有默认 StorageClass；设置 KC_EXPECT_STORAGE_CLASS 后重跑"; exit 1; }
  echo "默认 StorageClass: 已存在"
fi

if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "getent hosts '$REGISTRY_HOST' >/dev/null && timeout 5 bash -c '</dev/tcp/$REGISTRY_HOST/$REGISTRY_PORT'"; then
  echo "错误: node1 无法解析或连接镜像仓库 ${REGISTRY_HOST}:${REGISTRY_PORT}"
  exit 1
fi
echo "镜像仓库: node1 可连接 ${REGISTRY_HOST}:${REGISTRY_PORT}"
echo "注意: 多节点已有集群还须由用户确认其它节点具有同等 DNS/网络/证书信任。"

if k get ns kubercon-system >/dev/null 2>&1; then
  echo "错误: 已存在 kubercon-system；可能是已装或半装平台，禁止覆盖"
  exit 1
fi
if k get ns kubesphere-system >/dev/null 2>&1; then
  echo "错误: 已存在 kubesphere-system；先人工评估兼容/迁移，禁止硬装"
  exit 1
fi
if k get crd clusterconfigurations.installer.kubercloud.com >/dev/null 2>&1; then
  echo "错误: 已存在 KuberCon installer CRD；可能有残留，禁止重复安装"
  exit 1
fi

echo "=============================================================="
echo "模式 C 预检通过：目标身份、节点、架构、权限、默认存储与残留检查均通过。"
echo "下一步须先展示 installer manifest diff 并取得「确认 D8I」；"
echo "installer Available 后，再展示 cc diff 并取得「确认 D8C」。"
