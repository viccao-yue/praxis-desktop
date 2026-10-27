#!/bin/bash
# kubercon-tenant-inspect.sh
# 常青云多租户资源盘点（只读）
# 用法:
#   ./kubercon-tenant-inspect.sh                列出全部企业空间及其项目数
#   ./kubercon-tenant-inspect.sh <企业空间名>     盘点该企业空间：项目、配额、工作负载
#
# 常青云是「平台 → 企业空间(Workspace) → 项目(Namespace)」三级租户结构。
# 项目通过 kubercloud.com/workspace 标签归属企业空间（部分版本保留
# kubesphere.io/workspace 兼容标签，本脚本两者都查）。

set -uo pipefail

WORKSPACE="${1:-}"

section() {
  echo
  echo "--------------------------------------------------------------"
  echo "  $1"
  echo "--------------------------------------------------------------"
}

# 取某项目的企业空间标签值（兼容两种标签键）
ns_workspace() {
  local ns="$1" ws
  ws=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.kubercloud\.com/workspace}' 2>/dev/null)
  [ -z "$ws" ] && ws=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.kubesphere\.io/workspace}' 2>/dev/null)
  echo "$ws"
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 未找到 kubectl。"
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "错误: 无法连接 Kubernetes 集群。"
  echo "      当前 KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
  exit 1
fi

if ! kubectl get workspaces >/dev/null 2>&1; then
  echo "错误: 无法读取 Workspace 资源。"
  echo
  echo "可能原因："
  echo "  1) 该集群不是常青云部署（缺少 tenant.kubercloud.com CRD）"
  echo "  2) 当前 kubeconfig 权限不足（Workspace 为集群级资源）"
  echo
  echo "现有的 kubercloud.com CRD："
  kubectl get crd -o name 2>/dev/null | grep kubercloud.com | sed 's|customresourcedefinition.apiextensions.k8s.io/|  |' \
    || echo "  （无，确认平台类型）"
  exit 1
fi

# ---------- 模式一：全部企业空间总览 ----------
if [ -z "$WORKSPACE" ]; then
  echo "=============================================================="
  echo "  常青云企业空间总览"
  echo "=============================================================="

  section "企业空间列表"
  kubectl get workspaces -o wide 2>/dev/null

  section "企业空间 → 项目数 / Pod 数"
  printf "  %-28s %-8s %-8s\n" "WORKSPACE" "PROJECTS" "PODS"
  printf "  %-28s %-8s %-8s\n" "----------------------------" "--------" "--------"
  while IFS= read -r ws; do
    [ -z "$ws" ] && continue
    NS_LIST=$(kubectl get ns -l "kubercloud.com/workspace=$ws" -o name 2>/dev/null | sed 's|namespace/||')
    if [ -z "$NS_LIST" ]; then
      NS_LIST=$(kubectl get ns -l "kubesphere.io/workspace=$ws" -o name 2>/dev/null | sed 's|namespace/||')
    fi
    NS_COUNT=$(echo "$NS_LIST" | grep -c . || true)
    POD_COUNT=0
    for ns in $NS_LIST; do
      C=$(kubectl -n "$ns" get pod --no-headers 2>/dev/null | grep -c . || true)
      POD_COUNT=$((POD_COUNT + C))
    done
    printf "  %-28s %-8s %-8s\n" "$ws" "$NS_COUNT" "$POD_COUNT"
  done < <(kubectl get workspaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  section "未归属任何企业空间的项目"
  ORPHAN=0
  while IFS= read -r ns; do
    [ -z "$ns" ] && continue
    case "$ns" in
      kube-*|kubercon-*|kubesphere-*|openpitrix-*|default|deepflow|open-telemetry|istio-system) continue ;;
    esac
    if [ -z "$(ns_workspace "$ns")" ]; then
      echo "  $ns"
      ORPHAN=1
    fi
  done < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [ "$ORPHAN" -eq 0 ] && echo "  无（业务项目均已归属）"

  section "企业空间级配额（quota.kubercloud.com）"
  QUOTA_OUT=$(kubectl get resourcequotas.quota.kubercloud.com 2>/dev/null)
  if [ -n "$QUOTA_OUT" ]; then
    echo "$QUOTA_OUT"
  else
    echo "  未设置任何企业空间级配额（或无该 CRD）"
  fi

  section "用法"
  echo "  盘点单个企业空间:  $0 <企业空间名>"
  exit 0
fi

# ---------- 模式二：单企业空间明细 ----------
if ! kubectl get workspace "$WORKSPACE" >/dev/null 2>&1; then
  echo "错误: 找不到企业空间 $WORKSPACE"
  echo
  echo "现有企业空间："
  kubectl get workspaces -o jsonpath='{range .items[*]}{"  "}{.metadata.name}{"\n"}{end}' 2>/dev/null
  exit 1
fi

echo "=============================================================="
echo "  企业空间盘点: $WORKSPACE"
echo "=============================================================="

section "1. 企业空间定义"
kubectl get workspace "$WORKSPACE" -o yaml 2>/dev/null | head -40

section "2. 下属项目"
NS_LIST=$(kubectl get ns -l "kubercloud.com/workspace=$WORKSPACE" -o name 2>/dev/null | sed 's|namespace/||')
if [ -z "$NS_LIST" ]; then
  NS_LIST=$(kubectl get ns -l "kubesphere.io/workspace=$WORKSPACE" -o name 2>/dev/null | sed 's|namespace/||')
fi
if [ -z "$NS_LIST" ]; then
  echo "  该企业空间下无项目，或项目未打 workspace 标签"
else
  for ns in $NS_LIST; do
    echo "  $ns"
  done
fi

section "3. 各项目资源占用"
for ns in $NS_LIST; do
  echo
  echo ">>> 项目: $ns"
  echo "    工作负载："
  kubectl -n "$ns" get deploy,sts,ds --no-headers 2>/dev/null | sed 's/^/      /' || echo "      无"
  echo "    Pod 状态汇总："
  kubectl -n "$ns" get pod --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | sed 's/^/      /' || echo "      无 Pod"
  echo "    配额占用："
  if kubectl -n "$ns" get resourcequota --no-headers 2>/dev/null | grep -q .; then
    kubectl -n "$ns" describe resourcequota 2>/dev/null | grep -E '^  [a-z]' | sed 's/^/      /' | head -12
  else
    echo "      未设置 ResourceQuota"
  fi
  echo "    PVC："
  kubectl -n "$ns" get pvc --no-headers 2>/dev/null | sed 's/^/      /' || echo "      无"
done

section "4. 企业空间成员与角色"
echo "WorkspaceRole："
kubectl get workspaceroles -A 2>/dev/null | grep "$WORKSPACE" | sed 's/^/  /' || echo "  无"
echo
echo "WorkspaceRoleBinding："
kubectl get workspacerolebindings -A 2>/dev/null | grep "$WORKSPACE" | sed 's/^/  /' || echo "  无"

section "5. DevOps 项目"
kubectl get devopsprojects -o wide 2>/dev/null | grep -E "NAME|$WORKSPACE" || echo "  无关联 DevOps 项目"

section "6. 网络隔离策略"
for ns in $NS_LIST; do
  NP=$(kubectl -n "$ns" get namespacenetworkpolicies --no-headers 2>/dev/null | grep -c . || true)
  K8SNP=$(kubectl -n "$ns" get networkpolicies --no-headers 2>/dev/null | grep -c . || true)
  echo "  $ns: 平台策略=$NP  原生策略=$K8SNP"
done

section "盘点结束"
echo "配额调整、项目删除等写操作请按用户手册与变更流程执行。"
