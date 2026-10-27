#!/bin/bash
# kubercon-health-check.sh
# 常青云容器云平台健康巡检（只读）
# 用法: ./kubercon-health-check.sh
#
# 覆盖：平台身份与版本、节点、控制面组件、异常 Pod、事件、存储、组件开关。
# 组件名与命名空间一律探测取得，不硬编码 ks-* / kubercon-*。

set -uo pipefail

SYS_NS="${KUBERCON_SYSTEM_NS:-kubercon-system}"

section() {
  echo
  echo "=============================================================="
  echo "  $1"
  echo "=============================================================="
}

# 连通性前置检查：不做这一步，后续每条命令都会失败并被误读成「一切正常」
if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 未找到 kubectl。"
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "错误: 无法连接 Kubernetes 集群，巡检中止。"
  echo "      当前 KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
  echo "      请确认 kubeconfig 与网络可达后重试；不要把本次输出当作健康结论。"
  exit 1
fi

section "0. 平台身份与版本"
if ! kubectl get ns "$SYS_NS" >/dev/null 2>&1; then
  echo "警告: 未找到命名空间 ${SYS_NS}，该集群可能不是常青云部署。"
  echo "实际存在的疑似平台命名空间："
  kubectl get ns -o name 2>/dev/null | grep -iE 'kubercon|kubesphere' || echo "  （无）"
  echo "如命名空间不同，请用 KUBERCON_SYSTEM_NS=<实际名> 重新运行。"
else
  echo "平台命名空间: $SYS_NS"
  if kubectl -n "$SYS_NS" get cc kubercon-installer >/dev/null 2>&1; then
    echo -n "平台版本(label): "
    kubectl -n "$SYS_NS" get cc kubercon-installer -o jsonpath='{.metadata.labels.version}' 2>/dev/null
    echo
    echo -n "镜像 tag:        "
    kubectl -n "$SYS_NS" get cc kubercon-installer -o jsonpath='{.spec.kubercon_tag}' 2>/dev/null
    echo
    echo -n "镜像仓库:        "
    kubectl -n "$SYS_NS" get cc kubercon-installer -o jsonpath='{.spec.kubercon_registry}' 2>/dev/null
    echo
  else
    echo "未找到 ClusterConfiguration/kubercon-installer（非安装器部署或权限不足）"
  fi
fi

echo -n "Kubernetes 版本: "
kubectl version -o json 2>/dev/null | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('serverVersion',{}).get('gitVersion','未知'))" 2>/dev/null \
  || kubectl version --short 2>/dev/null | grep -i server

section "1. 节点状态"
kubectl get nodes -o wide
echo
echo "--- 非 Ready 节点 ---"
kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print}' || true
if [ -z "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"')" ]; then
  echo "全部 Ready"
fi

section "1b. Kubernetes 控制面（形态判定 + 健康度）"
CP_POD=$(kubectl -n kube-system get pod --no-headers 2>/dev/null \
  | grep -E 'kube-apiserver|kube-scheduler|kube-controller-manager|etcd')
if [ -z "$CP_POD" ]; then
  echo "kube-system 下无控制面 Pod → systemd 二进制形态。"
  echo
  echo "→ 控制面日志不在集群内，kubectl 取不到。需登录节点："
  echo "    journalctl -u kube-apiserver -u kube-scheduler -u kube-controller-manager -u etcd"
  echo "  注意：kubectl -n kube-system logs deploy/kube-scheduler 在任何形态下都不成立。"
else
  echo "$CP_POD"
  echo
  echo "→ 静态 Pod 形态，可用 kubectl -n kube-system logs <pod名> 取日志。"
fi
echo
echo "--- 控制面健康度（经 apiserver 侧面验证）---"
kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -vE '^\[\+\]' | head -10
RZ=$(kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -cE '^\[-\]' || true)
if [ "${RZ:-0}" = "0" ]; then
  echo "所有子系统 readyz 正常"
else
  echo "有 $RZ 个子系统未就绪（上面以 [-] 开头的项）"
fi

section "1c. 时间同步与证书有效期"
# 平台默认不配置 NTP（kk 只在显式设置 spec.system.ntpServers 时才动 chrony）。
# 时钟偏移会同时打击证书校验、etcd 选举、审计与链路追踪的时序。
echo "--- 节点时钟偏移（用 node lease，kubelet 每 10s 续期）---"
LEASE_JSON=$(kubectl -n kube-node-lease get lease -o json 2>/dev/null)
if [ -z "$LEASE_JSON" ]; then
  echo "无法读取 kube-node-lease（权限不足或版本差异），跳过。"
else
  echo "$LEASE_JSON" | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
now=datetime.datetime.now(datetime.timezone.utc)
worst=0.0
for l in d.get('items',[]):
    rt=(l.get('spec') or {}).get('renewTime')
    if not rt: continue
    t=datetime.datetime.fromisoformat(rt.replace('Z','+00:00'))
    diff=(t-now).total_seconds()
    worst=max(worst,abs(diff))
    flag='  [!]' if abs(diff)>60 else '     '
    print('%s %-24s %+8.1f 秒' % (flag, l['metadata']['name'], diff))
print()
print('正值 = 节点时钟超前本机。这是相对偏移，超标不能直接断定是节点错，也可能是本机未同步。')
if worst>60:
    print()
    print('[!] 最大偏移 %.1f 秒，超过 60 秒阈值。需登录节点定性：' % worst)
    print('      timedatectl status      # NTP synchronized 是否 yes')
    print('      chronyc tracking        # System time 偏移与 Stratum')
    print('      chronyc sources -v      # 是否真有可用时间源')
    print('    离线环境常见成因：无公网 NTP 源且客户未自建，kk 也未配置 ntpServers。')
else:
    print('偏移在 60 秒阈值内。')
"
fi

echo
echo "--- 客户端证书有效期（多数「证书到期」其实是这个）---"
CC=$(kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null)
if [ -z "$CC" ]; then
  echo "当前 kubeconfig 未使用客户端证书（可能是 token 认证），跳过。"
elif ! command -v openssl >/dev/null 2>&1; then
  echo "未找到 openssl，跳过。"
else
  DATES=$(echo "$CC" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)
  if [ -z "$DATES" ]; then
    echo "无法解析证书。"
  else
    echo "$DATES"
    END=${DATES#notAfter=}
    python3 - "$END" <<'PY' 2>/dev/null || echo "（有效期换算失败，请人工判读上面日期）"
import sys, datetime
try:
    t = datetime.datetime.strptime(sys.argv[1].strip(), '%b %d %H:%M:%S %Y %Z')
except ValueError:
    sys.exit(1)
left = (t - datetime.datetime.utcnow()).days
if left < 0:
    print('  [!] 已过期 %d 天 —— kubectl 会报 Unauthorized，而 Web 控制台仍可登录' % -left)
elif left < 30:
    print('  [!] 仅剩 %d 天，尽快续期' % left)
else:
    print('  剩余 %d 天' % left)
PY
  fi
fi

section "2. 平台命名空间"
kubectl get ns -o name 2>/dev/null | sed 's|namespace/||' | \
  grep -iE 'kubercon|kubesphere|openpitrix|deepflow|open-telemetry|istio' || echo "未发现平台相关命名空间"

section "3. 控制面组件（探测真实名称）"
if kubectl get ns "$SYS_NS" >/dev/null 2>&1; then
  kubectl -n "$SYS_NS" get deploy,sts,ds -o wide 2>/dev/null
  echo
  echo "--- 副本未就绪的工作负载 ---"
  kubectl -n "$SYS_NS" get deploy --no-headers 2>/dev/null | \
    awk '{split($2,a,"/"); if (a[1]!=a[2]) print $0}' || true
else
  echo "跳过（命名空间不存在）"
fi

section "3b. 准入 Webhook（写操作阻塞风险）"
# 平台注册的 Webhook 多数为 failurePolicy: Fail（v22.5.0 实测 26/38 条），后端不可达即拒绝写操作；
# Ignore 的只是跳过校验，不阻塞。本脚本只关注 Fail 的部分。
# 这是「突然什么都创建不了」的头号成因，且症状表现为权限错误，极易误判成 RBAC 或配额问题。
WH_JSON=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json 2>/dev/null)
EP_JSON=$(kubectl get endpoints -A -o json 2>/dev/null)

if [ -z "$WH_JSON" ] || [ -z "$EP_JSON" ]; then
  echo "无法读取 Webhook 配置或 Endpoints（权限不足）。跳过。"
else
  printf '%s\n%s' "$WH_JSON" "$EP_JSON" | python3 -c "
import json,sys
raw = sys.stdin.read()
# 两段 JSON 拼接，用解码器逐个读出
dec = json.JSONDecoder()
objs, idx = [], 0
while idx < len(raw):
    while idx < len(raw) and raw[idx] in ' \t\r\n':
        idx += 1
    if idx >= len(raw):
        break
    o, idx = dec.raw_decode(raw, idx)
    objs.append(o)
if len(objs) < 2:
    print('解析失败，跳过。')
    sys.exit(0)
wh, ep = objs[0], objs[1]

# 后端就绪端点数
ready = {}
for e in ep.get('items', []):
    k = (e['metadata']['namespace'], e['metadata']['name'])
    ready[k] = sum(len(s.get('addresses') or []) for s in (e.get('subsets') or []))

fail, total = {}, 0
for c in wh.get('items', []):
    for w in c.get('webhooks', []):
        total += 1
        if w.get('failurePolicy') != 'Fail':
            continue
        svc = (w.get('clientConfig') or {}).get('service') or {}
        if not svc:
            continue
        key = (svc.get('namespace'), svc.get('name'))
        fail.setdefault(key, set()).add(c['metadata']['name'])

print('Webhook 总数 %d，其中 failurePolicy=Fail 且有服务后端的，按后端归组：' % total)
print()
bad = []
for (ns, name), cfgs in sorted(fail.items()):
    n = ready.get((ns, name))
    if n is None:
        st, flag = '无 Endpoints 对象', True
    elif n == 0:
        st, flag = '就绪端点 0（会阻塞写操作）', True
    else:
        st, flag = '就绪端点 %d' % n, False
    mark = '  [!] ' if flag else '      '
    print('%s%s/%s  —  %s' % (mark, ns, name, st))
    for cfg in sorted(cfgs):
        print('          ← %s' % cfg)
    if flag:
        bad.append('%s/%s' % (ns, name))
print()
if bad:
    print('[!] 以下后端不可用，其关联 Webhook 匹配到的写操作会被全部拒绝：')
    for b in bad:
        print('      ' + b)
else:
    print('所有 Fail 策略 Webhook 的后端均有就绪端点。')
"
  echo
  echo "--- 准入链实测（server 端演练，不落盘）---"
  # 用最少假设的方式验证：真实走完准入链但不写入。
  # 比拼 jsonpath 反推可靠——路径写错会得到空值，误判成后端全挂。
  PROBE=$(kubectl -n default create configmap kubercon-admission-probe \
    --from-literal=probe=1 --dry-run=server 2>&1)
  if echo "$PROBE" | grep -q 'server dry run'; then
    echo "准入链通畅（${PROBE}）"
  elif echo "$PROBE" | grep -qi 'webhook'; then
    echo "[!] 准入链被 Webhook 阻断："
    echo "$PROBE" | head -3
    echo "    → 报错信息里的 webhook 名字就是故障点，对照上面的后端表定位。"
  elif echo "$PROBE" | grep -qiE 'forbidden|cannot create'; then
    echo "当前凭据无 default 命名空间创建权限，本项无法判定（不代表准入链异常）。"
  else
    echo "$PROBE" | head -3
  fi
fi

section "4. 全平台异常 Pod"
ABNORMAL=$(kubectl get pod -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
if [ -z "$ABNORMAL" ]; then
  echo "无异常 Pod"
else
  echo "$ABNORMAL"
fi

echo
echo "--- 重启次数最多的 Pod（Top 10）---"
kubectl get pod -A -o json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows=[]
for i in d.get('items',[]):
    st=i.get('status',{}).get('containerStatuses') or []
    r=sum(c.get('restartCount',0) for c in st)
    if r:
        rows.append((r, i['metadata']['namespace'], i['metadata']['name']))
if not rows:
    print('无重启记录')
for r,ns,n in sorted(rows, reverse=True)[:10]:
    print(f'{r:>6}  {ns}/{n}')
"

section "5. 最近集群事件（Warning）"
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -25 \
  || echo "无法读取事件"

section "6. 存储"
echo "--- StorageClass ---"
kubectl get sc -o custom-columns=\
NAME:.metadata.name,\
DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class",\
PROVISIONER:.provisioner 2>/dev/null || echo "无 StorageClass"

echo
echo "--- 未绑定的 PVC ---"
PENDING_PVC=$(kubectl get pvc -A --field-selector=status.phase=Pending --no-headers 2>/dev/null)
if [ -z "$PENDING_PVC" ]; then
  echo "无 Pending PVC"
else
  echo "$PENDING_PVC"
fi

section "6b. 节点磁盘、inode 与驱逐阈值"
# 关键：驱逐阈值必须从运行中的 kubelet 读，不能凭默认值或代码模板推断。
# v22.6.0 的 kk 模板只写了 memory.available 与 pid.available，
# 而 evictionHard 是整体替换而非逐键合并——按该模板渲染的 kubelet 会丢掉
# nodefs/imagefs/inodesFree 三项，磁盘写满和 inode 耗尽都不会触发驱逐。
for NODE in $(kubectl get node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "--- 节点 $NODE ---"
  CFGZ=$(kubectl get --raw "/api/v1/nodes/$NODE/proxy/configz" 2>/dev/null)
  if [ -z "$CFGZ" ]; then
    echo "  无法读取 kubelet configz（权限不足或 kubelet 只读端口关闭）。"
    echo "  → 无法确认驱逐阈值，不要假设磁盘/inode 有保护。"
  else
    echo "$CFGZ" | python3 -c "
import json,sys
k=json.load(sys.stdin).get('kubeletconfig',{})
eh=k.get('evictionHard') or {}
print('  evictionHard :', json.dumps(eh,ensure_ascii=False))
print('  evictionSoft :', json.dumps(k.get('evictionSoft'),ensure_ascii=False))
print('  imageGC      : 高 %s%% / 低 %s%%' % (k.get('imageGCHighThresholdPercent'),
                                              k.get('imageGCLowThresholdPercent')))
missing=[s for s in ('nodefs.available','imagefs.available','nodefs.inodesFree') if s not in eh]
if missing:
    print()
    print('  [!] evictionHard 缺少: %s' % ', '.join(missing))
    print('      该节点磁盘写满或 inode 耗尽【不会】触发 DiskPressure，也不会驱逐 Pod，')
    print('      会直接硬崩（containerd 无法写层、etcd 无法写 WAL）。属高危配置。')
else:
    print('  磁盘与 inode 驱逐保护齐全。')
"
  fi
  kubectl get node "$NODE" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d['status']['conditions']:
    if c['type'] in ('DiskPressure','PIDPressure','MemoryPressure') and c['status']!='False':
        print('  [!] %s = %s (%s)' % (c['type'], c['status'], c.get('reason','')))
print('  ephemeral-storage capacity:', d['status']['capacity'].get('ephemeral-storage'))
"
  echo
done

echo "--- 驱逐与磁盘相关事件 ---"
DISK_EV=$(kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null \
  | grep -iE 'Evicted|FreeDiskSpaceFailed|ImageGCFailed|EvictionThresholdMet|NodeHasDiskPressure' | tail -10)
[ -n "$DISK_EV" ] && echo "$DISK_EV" || echo "无相关事件"

echo
echo "--- 本地存储的宿主机路径（排查磁盘占用时要 du 的目录）---"
LP=$(kubectl -n kube-system get cm local-path-config -o jsonpath='{.data.config\.json}' 2>/dev/null)
if [ -n "$LP" ]; then
  echo "$LP" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get('nodePathMap',[]):
    print('  %-42s %s' % (m.get('node'), ','.join(m.get('paths',[]))))
"
  echo "  → 不要照抄文档里的 /opt/local-path-provisioner，以上面实际值为准。"
else
  echo "  未找到 kube-system/local-path-config（可能用 OpenEBS 方案或其他存储）。"
fi

cat <<'EOF'

--- inode 耗尽必须登录节点查（kubectl 查不到）---
  症状迷惑性强：df -h 显示磁盘尚有大量剩余，但创建文件报 no space left on device。

  df -i                       # 看 Inodes / IUse% 列，不是看块空间
  df -h /var/lib /mnt/localfs

  平台磁盘消耗集中在（按排查顺序）：
    /mnt/localfs           local-path 的 PV 数据 —— 监控/日志/ClickHouse 全在这里，最易失控
    /var/lib/containerd    镜像与容器层，受 imageGC 约束
    /var/lib/etcd          etcd 数据与 WAL，受 quotaBackendBytes 约束
    /var/backups/kube_etcd etcd 备份，保留 5 份
    /var/log               容器日志与 journal

  注意 local-path 不强制容量限制：PVC 申请 10Gi 实际可写满整块盘。
  PVC 的 requests 只能当参考，真实占用需在节点上 du -sh /mnt/localfs/*
EOF

section "7. 可插拔组件开关"
if kubectl -n "$SYS_NS" get cc kubercon-installer >/dev/null 2>&1; then
  kubectl -n "$SYS_NS" get cc kubercon-installer -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
spec=d.get('spec',{})
keys=['alerting','auditing','devops','events','logging','metrics_server','servicemesh','gatekeeper','edgeruntime','deepflow']
for k in keys:
    v=spec.get(k)
    if isinstance(v,dict) and 'enabled' in v:
        print(f'  {k:<16} {v[\"enabled\"]}')
op=spec.get('openpitrix',{}).get('store',{}).get('enabled')
if op is not None: print(f'  {\"openpitrix.store\":<16} {op}')
np=spec.get('network',{}).get('networkpolicy',{}).get('enabled')
if np is not None: print(f'  {\"networkpolicy\":<16} {np}')
mc=spec.get('multicluster',{}).get('clusterRole')
if mc: print(f'  {\"multicluster\":<16} {mc}')
osx=spec.get('common',{}).get('opensearch',{}).get('enabled')
esx=spec.get('common',{}).get('es',{}).get('enabled')
print(f'  日志后端: opensearch={osx} es={esx}')
"
else
  echo "跳过（无法读取 ClusterConfiguration）"
fi

section "巡检结束"
echo "写操作（组件启停、节点维护、etcd 恢复）请按运维手册走变更单，勿在巡检后即席执行。"
