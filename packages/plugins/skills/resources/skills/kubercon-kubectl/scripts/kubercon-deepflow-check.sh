#!/bin/bash
# kubercon-deepflow-check.sh
# 常青云容器云链路追踪（DeepFlow + OTel）链路自检（只读）
# 用法: ./kubercon-deepflow-check.sh
#
# 按数据流顺序检查：cc 开关 → otel-agent → deepflow-server → ClickHouse → BFF。
# 适用 v22.6.0 及以后（安装器默认部署 DeepFlow）；旧版本为现场单独部署，命名空间可能不同。
# 命名空间可用环境变量覆盖：KUBERCON_SYSTEM_NS / DEEPFLOW_NS / OTEL_NS

set -uo pipefail

SYS_NS="${KUBERCON_SYSTEM_NS:-kubercon-system}"
DF_NS="${DEEPFLOW_NS:-deepflow}"
OTEL_NS="${OTEL_NS:-open-telemetry}"

section() {
  echo
  echo "=============================================================="
  echo "  $1"
  echo "=============================================================="
}

# 连通性前置检查：不做这一步，后续每条命令都会失败并被误读成「组件没装」
if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 未找到 kubectl。"
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "错误: 无法连接 Kubernetes 集群，自检中止。"
  echo "      当前 KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
  echo "      请确认 kubeconfig 与网络可达后重试；不要把本次输出当作「链路追踪未部署」的结论。"
  exit 1
fi

section "0. 是否启用（ClusterConfiguration 开关）"
if kubectl -n "$SYS_NS" get cc kubercon-installer >/dev/null 2>&1; then
  DF_ENABLED=$(kubectl -n "$SYS_NS" get cc kubercon-installer \
    -o jsonpath='{.spec.deepflow.enabled}' 2>/dev/null)
  if [ -z "$DF_ENABLED" ]; then
    echo "cc 中无 spec.deepflow 字段。"
    echo "→ 该集群可能早于 v22.6.0，DeepFlow 为现场单独部署，开关不由安装器管理。"
  else
    echo "spec.deepflow.enabled = $DF_ENABLED"
    [ "$DF_ENABLED" = "false" ] && \
      echo "→ 已显式关闭。下面各命名空间若为空属预期，不是故障。"
  fi
  echo -n "storageClass:  "
  SC=$(kubectl -n "$SYS_NS" get cc kubercon-installer \
    -o jsonpath='{.spec.deepflow.storageClass}' 2>/dev/null)
  echo "${SC:-（空，用集群默认 SC）}"
  echo -n "retentionDays: "
  kubectl -n "$SYS_NS" get cc kubercon-installer \
    -o jsonpath='{.spec.deepflow.retentionDays}' 2>/dev/null
  echo
else
  echo "未找到 ClusterConfiguration/kubercon-installer（非安装器部署或权限不足）"
fi

section "1. OTel 接入层（$OTEL_NS）"
if kubectl get ns "$OTEL_NS" >/dev/null 2>&1; then
  kubectl -n "$OTEL_NS" get ds,pod -o wide 2>/dev/null
  echo
  echo "--- otel-agent 监听端口（应含 4317/gRPC 与 4318/HTTP）---"
  kubectl -n "$OTEL_NS" get svc -o wide 2>/dev/null || echo "无 Service"
else
  echo "命名空间 $OTEL_NS 不存在。"
  echo "→ 应用侧若通过 OTLP 上报，链路会断在第一跳。确认是否本就未启用 OTel 接入。"
fi

section "2. DeepFlow 采集与存储（$DF_NS）"
if kubectl get ns "$DF_NS" >/dev/null 2>&1; then
  kubectl -n "$DF_NS" get deploy,sts,ds 2>/dev/null
  echo
  echo "--- 非 Running 的 Pod ---"
  ABN=$(kubectl -n "$DF_NS" get pod --no-headers 2>/dev/null | grep -v 'Running\|Completed')
  [ -z "$ABN" ] && echo "全部正常" || echo "$ABN"

  echo
  echo "--- 镜像 tag（agent 的 tag 必须 <= server 的 tag，倒挂会连不上）---"
  kubectl -n "$DF_NS" get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
    | grep -E 'server|agent' || echo "未取到"
else
  echo "命名空间 $DF_NS 不存在 → DeepFlow 未部署。"
fi

section "3. ClickHouse 存储（最常见故障点，默认申请 200Gi）"
if kubectl get ns "$DF_NS" >/dev/null 2>&1; then
  echo "--- PVC 绑定状态 ---"
  PVCS=$(kubectl -n "$DF_NS" get pvc --no-headers 2>/dev/null)
  if [ -z "$PVCS" ]; then
    echo "无 PVC。→ 该部署用的是 hostPath（all_in_one_local_storage=true），数据直接落宿主机目录。"
    echo "  开发/测试可接受；生产环境必须改用 PVC，否则节点故障即丢数据。"
  else
    kubectl -n "$DF_NS" get pvc 2>/dev/null
  fi
  echo
  PENDING=$(kubectl -n "$DF_NS" get pvc --field-selector=status.phase=Pending --no-headers 2>/dev/null)
  if [ -n "$PENDING" ]; then
    echo "存在 Pending PVC，链路追踪必然无数据："
    echo "$PENDING"
    echo "→ 依次查：有没有默认 StorageClass、磁盘余量、cc 里 deepflow.storageClass 是否指向了不存在的 SC。"
  fi
  echo "--- 集群 StorageClass（确认默认 SC 是否存在）---"
  kubectl get sc -o custom-columns=\
NAME:.metadata.name,\
DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class",\
PROVISIONER:.provisioner 2>/dev/null || echo "无 StorageClass"
else
  echo "跳过（命名空间不存在）"
fi

section "4. 平台查询层 BFF（$SYS_NS）"
if kubectl -n "$SYS_NS" get deploy deepflow-trace-bff >/dev/null 2>&1; then
  kubectl -n "$SYS_NS" get deploy deepflow-trace-bff -o wide 2>/dev/null
  echo
  echo "--- BFF 近期错误日志 ---"
  kubectl -n "$SYS_NS" logs deploy/deepflow-trace-bff --tail=50 --since=10m 2>/dev/null \
    | grep -iE 'error|fail|refused|timeout' | tail -15 || echo "近 10 分钟无明显错误"
else
  echo "未找到 deepflow-trace-bff。"
  echo "→ 控制台链路追踪页面走的是这个服务，缺失则页面必然无数据。"
  echo "  v22.6.0 由安装器部署；更早的版本需现场单独部署，未部署属预期。"
fi

section "自检结束"
echo "排障顺序按数据流走：应用埋点 → otel-agent → deepflow-server → ClickHouse → BFF → 控制台。"
echo "先定位断在哪一段，不要一上来重启 deepflow-server。"
echo "本脚本只读。启停 deepflow（patch cc）属变更操作，需走变更单。"
