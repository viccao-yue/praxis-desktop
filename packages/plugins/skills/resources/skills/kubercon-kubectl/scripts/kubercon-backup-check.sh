#!/bin/bash
# kubercon-backup-check.sh
# 常青云容器云备份能力自检（只读）
# 用法: ./kubercon-backup-check.sh
#
# 重要限制：etcd 自动备份由宿主机 systemd 管理，kubectl 查不到。
# 本脚本只做「集群侧能查的部分」，并输出必须登录节点人工核对的清单。
# 不要把本脚本通过就当成「备份没问题」——真正的结论取决于节点侧核对结果。
# 命名空间可用环境变量覆盖：KUBERCON_SYSTEM_NS

set -uo pipefail

SYS_NS="${KUBERCON_SYSTEM_NS:-kubercon-system}"

section() {
  echo
  echo "=============================================================="
  echo "  $1"
  echo "=============================================================="
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 未找到 kubectl。"
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "错误: 无法连接 Kubernetes 集群，自检中止。"
  echo "      当前 KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
  echo "      请确认 kubeconfig 与网络可达后重试；不要把本次输出当作「备份未配置」的结论。"
  exit 1
fi

section "1. etcd 部署形态（决定后续所有命令的写法）"
ETCD_POD=$(kubectl -n kube-system get pod --no-headers 2>/dev/null | grep -i etcd)
if [ -z "$ETCD_POD" ]; then
  echo "kube-system 下无 etcd Pod。"
  echo
  echo "→ 形态判定：systemd 二进制部署（kk/KubeKey 默认）"
  echo "  证书目录 : /etc/ssl/etcd/ssl/（非 /etc/kubernetes/pki/etcd/）"
  echo "  客户端证书: admin-<主机名>.pem / admin-<主机名>-key.pem / ca.pem"
  echo "  进程管理 : systemctl {status,stop,start} etcd"
  echo "  数据目录 : /var/lib/etcd"
  echo
  echo "  注意：运维手册与通用文档里「移走 /etc/kubernetes/manifests/etcd.yaml」"
  echo "        的流程在本集群不适用，该文件不存在。"
  echo
  echo "  自动备份：type=kubekey 才会安装备份脚本与 timer，本形态应当有，第 6 节核对。"
else
  echo "$ETCD_POD"
  echo
  echo "→ 形态判定：静态 Pod（etcd.type=kubeadm）"
  echo "  证书目录 : /etc/kubernetes/pki/etcd/"
  echo "  进程管理 : 移走 /etc/kubernetes/manifests/etcd.yaml"
  echo
  echo "  ⚠ 自动备份：kk 的 BackupModule 带 Skip: etcd.Type != kubekey，"
  echo "    本形态下备份模块被跳过，**不存在任何自动备份**。"
  echo "    必须自建备份方案，不要假设有备份。"
fi

section "2. etcd 健康度（经 apiserver 侧面验证）"
LIVEZ=$(kubectl get --raw='/livez/etcd' 2>&1)
if [ "$LIVEZ" = "ok" ]; then
  echo "/livez/etcd = ok  → apiserver 到 etcd 链路正常"
else
  echo "/livez/etcd 返回异常: $LIVEZ"
  echo "→ 控制面存储链路有问题，先处理这个，不要在此状态下做备份或变更。"
fi
kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -i etcd || true

echo
echo "--- DB 体积（对照配额，默认配额为 etcd 内置 2GiB）---"
DB_BYTES=$(kubectl get --raw='/metrics' 2>/dev/null \
  | awk '/^apiserver_storage_db_total_size_in_bytes/ {print $2; exit}')
if [ -n "$DB_BYTES" ]; then
  python3 - "$DB_BYTES" <<'PY'
import sys
b = float(sys.argv[1])
qu = 2 * 1024**3
print("DB 体积: %.1f MB  (%.1f%% of 2GiB 默认配额)" % (b/1024/1024, b/qu*100))
if b/qu > 0.8:
    print("→ 已超配额 80%，接近 NOSPACE 只读告警。需立即压缩+defrag，或上调 quotaBackendBytes。")
elif b/qu > 0.5:
    print("→ 已过配额一半，安排 defrag 并评估是否上调 quotaBackendBytes。")
else:
    print("→ 距配额尚远。注意：自动压缩只回收逻辑版本，物理空间仍需定期 defrag 才归还。")
PY
else
  echo "未取到 apiserver_storage_db_total_size_in_bytes 指标（权限或版本差异）。"
fi

section "3. 平台侧 etcd 监控开关"
if kubectl -n "$SYS_NS" get cc kubercon-installer >/dev/null 2>&1; then
  ETCD_CFG=$(kubectl -n "$SYS_NS" get cc kubercon-installer \
    -o jsonpath='{.spec.etcd}' 2>/dev/null)
  if [ -z "$ETCD_CFG" ]; then
    echo "cc 中无 spec.etcd 字段。"
  else
    echo "$ETCD_CFG"
    MON=$(kubectl -n "$SYS_NS" get cc kubercon-installer \
      -o jsonpath='{.spec.etcd.monitoring}' 2>/dev/null)
    echo
    if [ "$MON" = "true" ]; then
      echo "→ etcd 监控已开启，11 条标准告警规则（etcd-mixin）生效。"
    else
      echo "→ etcd 监控关闭（monitoring=false，这是默认值）。"
      echo
      echo "  平台自带 11 条标准 etcd 告警规则，但开关关闭时全部不生效："
      echo "    成员存活  etcdMembersDown / etcdInsufficientMembers"
      echo "    Leader    etcdNoLeader / etcdHighNumberOfLeaderChanges"
      echo "    请求失败  etcdHighNumberOfFailedProposals / etcdHighNumberOfFailedGRPCRequests"
      echo "    延迟      etcdGRPCRequestsSlow / etcdHighCommitDurations /"
      echo "              etcdHighFsyncDurations / etcdMemberCommunicationSlow"
      echo "    容量      etcdExcessiveDatabaseGrowth"
      echo
      echo "  当前状态等于「控制面存储无任何告警」，etcd 磁盘变慢或 DB 异常增长不会被发现。"
      echo "  生产交付应置为 true；多节点还需把 endpointIps 从 localhost 改为实际 IP 列表。"
      echo "  属配置变更，走变更单。"
    fi
  fi
else
  echo "未找到 cc kubercon-installer，无法判断监控开关。"
fi

section "4. 应用级备份组件"
FOUND=0
for kw in velero restic kasten stash; do
  HIT=$(kubectl get pod -A --no-headers 2>/dev/null | grep -i "$kw")
  if [ -n "$HIT" ]; then
    echo "发现 $kw 相关工作负载："
    echo "$HIT"
    FOUND=1
  fi
done
if [ "$FOUND" = "0" ]; then
  echo "未发现任何应用级备份组件（velero/restic/kasten/stash）。"
  echo
  echo "→ 这是预期结果：安装器不含应用级备份组件，kc 也无 backup 子命令。"
  echo "  客户问「平台自带备份吗」，准确回答："
  echo "    etcd 控制面元数据有自动定时备份；应用数据与 PV 需另配方案（如自建 Velero）。"
fi

section "5. 存储层容灾能力"
SC_LIST=$(kubectl get sc --no-headers 2>/dev/null)
if [ -z "$SC_LIST" ]; then
  echo "未发现任何 StorageClass。"
else
  echo "$SC_LIST"
  echo
  LOCAL_SC=$(echo "$SC_LIST" | grep -iE 'local-path|local' | awk '{print $1}')
  if [ -n "$LOCAL_SC" ]; then
    for sc in $LOCAL_SC; do
      PROV=$(kubectl get sc "$sc" -o jsonpath='{.provisioner}' 2>/dev/null)
      echo "SC $sc 的 provisioner = $PROV"
    done
    echo
    echo "→ 本地存储（local-path 类）的 PV 绑定在具体节点目录上："
    echo "  节点故障即数据丢失，不支持跨节点迁移，不具备容灾能力。"
    echo "  生产方案需换 Ceph 或企业级共享存储，并在 cc 中为 monitoring/logging/deepflow 显式指定 storageClass。"
  fi
fi

section "6. 必须登录节点人工核对的项（kubectl 查不到）"
cat <<'EOF'
在 etcd 节点上执行：

  # 1) 定时器与上次执行结果
  systemctl list-timers | grep backup-etcd
  systemctl status backup-etcd.service

  # 2) 关键：看备份的【实际产出】，而不是 timer 是否 active
  ls -lt /var/backups/kube_etcd/ | head -5
  ls -l  /var/backups/kube_etcd/*/snapshot.db
  du -sh /var/backups/kube_etcd/

  为什么必须看产出：备份脚本首行是 set -o errexit，第一步跑的
  ETCDCTL_API=2 etcdctl backup 是 etcd v2 遗留命令（v3.5 起废弃）。
  该步一旦失败，脚本立即退出，后面真正有用的 snapshot.db 根本不会生成。
  timer 是 oneshot，失败只记录在 systemctl status 里。
  这是「以为有备份、实际没有」最可能的成因。

安装器默认值（kc-installer 代码，非手册）：
  脚本      /usr/local/bin/kube-scripts/etcd-backup.sh
  单元      backup-etcd.service + backup-etcd.timer
  执行时间  每天 02:00
  备份目录  /var/backups/kube_etcd/etcd-<年-月-日-时-分-秒>/
  保留份数  5

与运维手册第 11 章的冲突（以代码和现场实测为准）：
  手册说「每 6 小时、保留 7 天」，实际是「每天一次、保留 5 份」。
  对客户承诺 RPO 前，务必以现场实测值为准。

backupPeriod 改动后必须核对（换算非线性）：
  ≥1440 一律变成每天 02:00，更大的值被静默忽略；
  非 60 整数倍会被错算（填 90 → 每小时第 30 分，频率翻倍）。
  只有 60 的整数倍且 <1440 符合直觉。改完用 systemctl list-timers 核对。

三个盲区：
  1. 备份落在节点本地盘，节点整机损坏则备份一起丢。必须自行外传。
  2. 单节点环境下数据与备份同盘，等于没有备份。
  3. 快照含全部 Secret 明文（平台未启用静态加密 EncryptionConfiguration）。
     持有 snapshot.db 等同持有集群全部凭据：镜像仓库密码、数据库连接串、
     TLS 私钥、License 私钥。外传必须加密，存储权限按集群管理员同级管控。
     等保/密评场景需说明：平台默认不启用静态加密，须交付时单独配置。

行业标准要求但平台未自动化的项：
  自动压缩   已启用（ETCD_AUTO_COMPACTION_RETENTION 默认 8 小时），合规
  碎片整理   无自动化，需定期 etcdctl defrag（多节点逐台滚动，会短暂阻塞）
  DB 配额    quotaBackendBytes 无默认，回落 etcd 内置 2GiB；
             达配额进入 NOSPACE 只读，压缩后不自动恢复，须手工 etcdctl alarm disarm
  恢复演练   无，建议至少半年一次同版本环境完整演练并留存记录
EOF

section "自检完成"
echo "本脚本全部为只读操作，未修改任何资源。"
echo "第 6 节的节点侧核对未完成前，不要下「备份正常」的结论。"
