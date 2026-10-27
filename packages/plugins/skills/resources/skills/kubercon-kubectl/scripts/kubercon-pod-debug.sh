#!/bin/bash
# kubercon-pod-debug.sh
# 常青云容器云 Pod 排障信息收集（只读）
# 用法: ./kubercon-pod-debug.sh <Pod名> [项目名]
#
# 相比通用 kubectl 排障，额外输出：项目所属企业空间、项目配额占用
# （常青云多租户下 Pending 的首要根因是项目配额打满，而非节点资源不足）。

set -uo pipefail

POD_NAME="${1:?用法: $0 <Pod名> [项目名]}"
NAMESPACE="${2:-default}"

section() {
  echo
  echo "--------------------------------------------------------------"
  echo "  $1"
  echo "--------------------------------------------------------------"
}

echo "=============================================================="
echo "  Pod 排障: $POD_NAME    项目: $NAMESPACE"
echo "=============================================================="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 未找到 kubectl。"
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "错误: 无法连接 Kubernetes 集群。"
  echo "      当前 KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get pod "$POD_NAME" >/dev/null 2>&1; then
  echo "错误: 在项目 $NAMESPACE 中找不到 Pod $POD_NAME"
  echo
  echo "该项目下的 Pod："
  kubectl -n "$NAMESPACE" get pod 2>/dev/null || echo "  （项目不存在或无权限）"
  echo
  echo "或跨项目搜索同名 Pod："
  kubectl get pod -A 2>/dev/null | grep -- "$POD_NAME" || echo "  （全集群未找到）"
  exit 1
fi

section "1. 租户归属（项目 → 企业空间）"
WS=$(kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.labels.kubercloud\.com/workspace}' 2>/dev/null)
if [ -z "$WS" ]; then
  WS=$(kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.labels.kubesphere\.io/workspace}' 2>/dev/null)
fi
if [ -n "$WS" ]; then
  echo "所属企业空间: $WS"
else
  echo "未标注企业空间标签（可能是系统项目，或标签键与预期不同）"
  echo "该项目实际标签："
  kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null | tr ',' '\n' | sed 's/^/  /'
  echo
fi

section "2. Pod 状态"
kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o wide
echo
echo "容器状态明细："
kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
st=d.get('status',{})
print('  phase:', st.get('phase'))
for c in (st.get('containerStatuses') or []):
    state=list(c.get('state',{}).keys())
    reason=''
    for k,v in c.get('state',{}).items():
        if isinstance(v,dict) and v.get('reason'):
            reason=v['reason']
    print(f\"  - {c['name']}: ready={c.get('ready')} restarts={c.get('restartCount')} state={state} {reason}\")
for c in (st.get('initContainerStatuses') or []):
    print(f\"  - (init) {c['name']}: ready={c.get('ready')} restarts={c.get('restartCount')}\")
"

section "3. 调度与节点"
NODE=$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
if [ -n "$NODE" ]; then
  echo "所在节点: $NODE"
  kubectl get node "$NODE" -o wide 2>/dev/null
  echo
  echo "节点资源分配："
  kubectl describe node "$NODE" 2>/dev/null | sed -n '/Allocated resources/,/^Events/p' | head -20
else
  echo "未调度到节点（Pending）。检查以下三项："
  echo
  echo "  a) 项目资源配额（常青云多租户首要根因）"
  kubectl -n "$NAMESPACE" describe resourcequota 2>/dev/null | grep -E 'Name:|Resource|used|hard|  [a-z]' | head -20 \
    || echo "     该项目无 ResourceQuota"
  echo
  echo "  b) 节点选择器与容忍"
  kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{"     nodeSelector: "}{.spec.nodeSelector}{"\n     tolerations: "}{.spec.tolerations}{"\n"}' 2>/dev/null
  echo
  echo "  c) PVC 绑定状态"
  kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
vols=[v['persistentVolumeClaim']['claimName'] for v in d['spec'].get('volumes',[]) if v.get('persistentVolumeClaim')]
print('     引用 PVC:', vols if vols else '无')
"
fi

section "4. 资源请求与限制"
kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d['spec'].get('containers',[]):
    r=c.get('resources',{})
    print(f\"  {c['name']}: requests={r.get('requests','-')} limits={r.get('limits','-')}\")
"

section "5. 镜像与拉取凭据"
kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d['spec'].get('containers',[]):
    print(f\"  镜像: {c.get('image')}\")
ips=d['spec'].get('imagePullSecrets') or []
print('  拉取密钥:', [s.get('name') for s in ips] if ips else '无（依赖节点匿名拉取）')
"
echo "  提示: 离线环境镜像地址应指向客户 Harbor，而非 docker.changqingyun.cn"

section "6. Pod 事件"
kubectl -n "$NAMESPACE" get events \
  --field-selector involvedObject.name="$POD_NAME" \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -25 || echo "无相关事件"

section "7. 当前容器日志（每容器末 80 行）"
kubectl -n "$NAMESPACE" logs "$POD_NAME" --all-containers=true --timestamps=true --tail=80 2>&1 \
  || echo "无法获取日志（容器可能尚未启动）"

section "8. 上一次崩溃日志（CrashLoopBackOff 关键）"
kubectl -n "$NAMESPACE" logs "$POD_NAME" --previous --all-containers=true --tail=80 2>/dev/null \
  || echo "无上一次容器日志（未发生过重启）"

section "9. 完整描述"
kubectl -n "$NAMESPACE" describe pod "$POD_NAME" 2>/dev/null

section "后续手动排查"
cat <<EOF
  进入容器:   kubectl -n $NAMESPACE exec -it $POD_NAME -- sh
  临时调试:   kubectl -n $NAMESPACE debug $POD_NAME -it --image=busybox
  端口转发:   kubectl -n $NAMESPACE port-forward $POD_NAME <本地端口>:<容器端口>
EOF
