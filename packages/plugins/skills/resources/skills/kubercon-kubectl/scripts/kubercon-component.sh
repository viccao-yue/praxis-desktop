#!/bin/bash
# kubercon-component.sh
# 常青云平台组件清单、状态与日志（只读）
# 用法:
#   ./kubercon-component.sh              列出控制面全部组件与就绪状态
#   ./kubercon-component.sh <组件名>      查看单个组件详情、事件与错误日志
#   ./kubercon-component.sh --scan       扫描所有组件近 10 分钟的错误日志
#
# 组件名一律从集群探测。常青云历史版本中 ks-* 与 kubercon-* 命名可能并存，
# 本脚本不做任何前缀假设。

set -uo pipefail

SYS_NS="${KUBERCON_SYSTEM_NS:-kubercon-system}"
ARG="${1:-}"

section() {
  echo
  echo "--------------------------------------------------------------"
  echo "  $1"
  echo "--------------------------------------------------------------"
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

if ! kubectl get ns "$SYS_NS" >/dev/null 2>&1; then
  echo "错误: 命名空间 $SYS_NS 不存在。"
  echo "疑似平台命名空间："
  kubectl get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -iE 'kubercon|kubesphere' || echo "  （无）"
  echo "用 KUBERCON_SYSTEM_NS=<实际名> 重新运行。"
  exit 1
fi

list_components() {
  kubectl -n "$SYS_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

# ---------- 模式一：全部组件总览 ----------
if [ -z "$ARG" ]; then
  echo "=============================================================="
  echo "  常青云控制面组件总览    命名空间: $SYS_NS"
  echo "=============================================================="

  section "Deployment"
  kubectl -n "$SYS_NS" get deploy -o custom-columns=\
NAME:.metadata.name,\
READY:.status.readyReplicas,\
DESIRED:.spec.replicas,\
IMAGE:.spec.template.spec.containers[0].image 2>/dev/null

  section "StatefulSet / DaemonSet"
  kubectl -n "$SYS_NS" get sts,ds -o wide 2>/dev/null || echo "无"

  section "未就绪的组件"
  NOTREADY=$(kubectl -n "$SYS_NS" get deploy --no-headers 2>/dev/null | \
    awk '{split($2,a,"/"); if (a[1]!=a[2]) print "  " $1 "  " $2}')
  if [ -z "$NOTREADY" ]; then
    echo "  全部就绪"
  else
    echo "$NOTREADY"
  fi

  section "kc 工具可用性"
  if command -v kc >/dev/null 2>&1; then
    echo "kc 已安装: $(command -v kc)"
    echo "组件清单（kc 视角）："
    kc component list 2>/dev/null | head -30 || echo "  kc 执行失败，改用上方 kubectl 结果"
  else
    echo "kc 未安装。本脚本全部功能不依赖 kc；"
    echo "如需 kc 的 enable/reset/watch 能力，请向交付索取二进制。"
  fi

  section "用法"
  cat <<EOF
  查看单个组件:  $0 <组件名>
  扫描错误日志:  $0 --scan
EOF
  exit 0
fi

# ---------- 模式二：扫描全部组件错误日志 ----------
if [ "$ARG" = "--scan" ]; then
  echo "=============================================================="
  echo "  组件错误日志扫描（近 10 分钟）  命名空间: $SYS_NS"
  echo "=============================================================="
  FOUND=0
  while IFS= read -r comp; do
    [ -z "$comp" ] && continue
    HITS=$(kubectl -n "$SYS_NS" logs "deploy/$comp" --since=10m --tail=200 2>/dev/null | \
      grep -iE 'fatal|error|panic' | tail -5)
    if [ -n "$HITS" ]; then
      FOUND=1
      echo
      echo "===== $comp ====="
      echo "$HITS"
    fi
  done < <(list_components)
  if [ "$FOUND" -eq 0 ]; then
    echo
    echo "所有组件近 10 分钟无 error/fatal/panic 级日志。"
  fi
  exit 0
fi

# ---------- 模式三：单组件详情 ----------
COMP="$ARG"
if ! kubectl -n "$SYS_NS" get deploy "$COMP" >/dev/null 2>&1; then
  echo "错误: 在 $SYS_NS 中找不到组件 $COMP"
  echo
  echo "实际存在的组件（注意 ks-* 与 kubercon-* 可能并存）："
  list_components | sed 's/^/  /'
  exit 1
fi

echo "=============================================================="
echo "  组件详情: $COMP    命名空间: $SYS_NS"
echo "=============================================================="

section "1. 工作负载状态"
kubectl -n "$SYS_NS" get deploy "$COMP" -o wide
echo

# 从 Deployment 自身取 selector，避免猜测标签键
SELECTOR=$(kubectl -n "$SYS_NS" get deploy "$COMP" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ml=d['spec']['selector'].get('matchLabels',{})
print(','.join(f'{k}={v}' for k,v in ml.items()))
")
if [ -n "$SELECTOR" ]; then
  echo "Pod（selector: $SELECTOR）："
  kubectl -n "$SYS_NS" get pod -l "$SELECTOR" -o wide 2>/dev/null
else
  echo "无法解析 selector，按名称模糊匹配："
  kubectl -n "$SYS_NS" get pod 2>/dev/null | grep "$COMP"
fi

section "2. 镜像与副本"
kubectl -n "$SYS_NS" get deploy "$COMP" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
sp=d['spec']; st=d.get('status',{})
print('  期望副本:', sp.get('replicas'))
print('  就绪副本:', st.get('readyReplicas', 0))
for c in sp['template']['spec'].get('containers',[]):
    r=c.get('resources',{})
    print(f\"  容器 {c['name']}\")
    print(f\"    镜像:     {c.get('image')}\")
    print(f\"    requests: {r.get('requests','-')}\")
    print(f\"    limits:   {r.get('limits','-')}\")
"

section "3. 滚动更新状态"
kubectl -n "$SYS_NS" rollout status "deploy/$COMP" --timeout=5s 2>&1 | head -5
echo
kubectl -n "$SYS_NS" rollout history "deploy/$COMP" 2>/dev/null | head -10

section "4. 相关事件"
kubectl -n "$SYS_NS" get events --sort-by='.lastTimestamp' 2>/dev/null | grep "$COMP" | tail -15 \
  || echo "无相关事件"

section "5. 日志（末 100 行）"
kubectl -n "$SYS_NS" logs "deploy/$COMP" --tail=100 2>&1 || echo "无法获取日志"

section "6. 错误级日志（近 30 分钟）"
kubectl -n "$SYS_NS" logs "deploy/$COMP" --since=30m --tail=500 2>/dev/null | \
  grep -iE 'fatal|error|panic' | tail -20 || echo "无 error/fatal/panic 级日志"

section "写操作参考（需变更单，勿即席执行）"
cat <<EOF
  滚动重启:   kubectl -n $SYS_NS rollout restart deploy/$COMP --dry-run=server
  重置配置:   kc com reset --name $COMP
  镜像热更新: kc com watch --name $COMP --image <仓库>/<镜像>:<标签>
              （热更新不写回 ClusterConfiguration，验证后须同步回写 cc）
  启停组件:   改 ClusterConfiguration 的 spec.<组件>.enabled，由安装器调谐
EOF
