#!/usr/bin/env bash
# 只读门禁：SSH 连通、资源、残留 Kubernetes、节点间网络与时钟。
# 不达标必须失败，禁止把「能连上」当成「可以开装」。
#
# 采集脚本一律用带引号的 heredoc（<<'EOS'），保证所有 $ 在远程展开。
# 用不带引号的 <<EOS 会让 $(hostname)/$(nproc) 在发起机上求值，
# 结果是拿本机配置替服务器背书，门禁失效。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

MIN_CPU="${KC_MIN_CPU:-8}"
MIN_MEM_GB="${KC_MIN_MEM_GB:-16}"
PHASE="${KC_PREFLIGHT_PHASE:-}"
# 节点间允许的时钟偏差（秒）。串行 SSH 自身有 1~2s 延迟，阈值不能定太小。
MAX_SKEW_S="${KC_MAX_SKEW_S:-5}"

NODES=()
[[ -n "${KC_NODE1:-}" ]] && NODES+=("$KC_NODE1")
[[ -n "${KC_NODE2:-}" ]] && NODES+=("$KC_NODE2")
[[ -n "${KC_NODE3:-}" ]] && NODES+=("$KC_NODE3")

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "错误: 请设置 KC_NODE1（可选 KC_NODE2/KC_NODE3）"
  echo "示例: KC_NODE1=10.10.10.11 KC_SSH_KEY=~/.ssh/id_rsa $0"
  exit 1
fi
if [[ "$PHASE" != "hardware" && "$PHASE" != "full" ]]; then
  echo "错误: 必须设置 KC_PREFLIGHT_PHASE=hardware（挂盘前）或 full（挂盘后最终门禁）"
  exit 1
fi

if [[ ${#NODES[@]} -eq 1 ]]; then
  TOPOLOGY=single
  # df 以 GiB 取整；标称 200G 磁盘通常显示约 186~199G，门槛留 5% 计量余量。
  MIN_ROOT_TOTAL_GB="${KC_MIN_ROOT_TOTAL_GB:-190}"
  REQUIRE_SEPARATE_CONTAINERD="${KC_REQUIRE_SEPARATE_CONTAINERD:-0}"
else
  TOPOLOGY=three
  MIN_ROOT_TOTAL_GB="${KC_MIN_ROOT_TOTAL_GB:-95}"
  REQUIRE_SEPARATE_CONTAINERD="${KC_REQUIRE_SEPARATE_CONTAINERD:-1}"
fi
MIN_ROOT_AVAIL_GB="${KC_MIN_ROOT_AVAIL_GB:-80}"
MIN_CONTAINERD_TOTAL_GB="${KC_MIN_CONTAINERD_TOTAL_GB:-190}"
MIN_CONTAINERD_AVAIL_GB="${KC_MIN_CONTAINERD_AVAIL_GB:-150}"
MIN_ETCD_TOTAL_GB="${KC_MIN_ETCD_TOTAL_GB:-95}"
MIN_ETCD_AVAIL_GB="${KC_MIN_ETCD_AVAIL_GB:-70}"
MIN_OPENEBS_TOTAL_GB="${KC_MIN_OPENEBS_TOTAL_GB:-190}"
MIN_OPENEBS_AVAIL_GB="${KC_MIN_OPENEBS_AVAIL_GB:-150}"

remote() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

field() { echo "$1" | awk -F= -v k="^$2=" '$0 ~ k {sub(/^[^=]*=/, ""); print; exit}'; }
disk_sets_overlap() {
  local left="$1" right="$2" disk
  for disk in ${left//,/ }; do
    [[ ",$right," == *",$disk,"* ]] && return 0
  done
  return 1
}

echo "=============================================================="
echo "  KuberCon 部署预检（SSH，只读门禁）"
echo "=============================================================="
echo "用户: $SSH_USER    密钥: ${SSH_KEY}    端口: $SSH_PORT"
echo "节点: ${NODES[*]}"
echo "阶段: $PHASE    拓扑: $TOPOLOGY"
echo "门槛: CPU>=${MIN_CPU} 内存>=${MIN_MEM_GB}G 根盘总量>=${MIN_ROOT_TOTAL_GB}G/可用>=${MIN_ROOT_AVAIL_GB}G"
if [[ "$PHASE" == "full" ]]; then
  echo "      containerd 文件系统总量>=${MIN_CONTAINERD_TOTAL_GB}G/可用>=${MIN_CONTAINERD_AVAIL_GB}G"
  [[ "$TOPOLOGY" == "three" ]] &&
    echo "      etcd>=${MIN_ETCD_TOTAL_GB}G/${MIN_ETCD_AVAIL_GB}G，openebs>=${MIN_OPENEBS_TOTAL_GB}G/${MIN_OPENEBS_AVAIL_GB}G，且三盘独立"
fi
echo

FAIL=0
declare -a NODE_SKEWS=()
declare -a NODE_ARCHS=()

for host in "${NODES[@]}"; do
  echo "--------------------------------------------------------------"
  echo "  节点 $host"
  echo "--------------------------------------------------------------"
  if ! remote "$host" 'echo OK' >/dev/null 2>&1; then
    echo "  失败: SSH 不通（用户/端口/密钥/防火墙任一不对都会这样）"
    FAIL=1
    echo
    continue
  fi

  # 同时记录本地/远程采集窗口，用中点抵消串行 SSH 与采集耗时。
  LOCAL_EPOCH_START=$(date +%s)
  REPORT=$(remote "$host" 'bash -s' <<'EOS'
set +e
echo "HOST=$(hostname)"
echo "EPOCH_START=$(date +%s)"
echo "ARCH=$(uname -m)"
echo "KERNEL=$(uname -r)"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "OS=${PRETTY_NAME:-$NAME}"
else
  echo "OS=unknown"
fi
echo "CPU=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
echo "MEM_GB=$(( ${MEM_KB:-0} / 1024 / 1024 ))"

# 某路径所在文件系统的可用 GB；路径不存在就上溯到最近存在的祖先
avail_gb() {
  p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  df -P "$p" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}
total_gb() {
  p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  df -P "$p" 2>/dev/null | awk 'NR==2 {printf "%d", $2/1024/1024}'
}
echo "ROOT_TOTAL_GB=$(total_gb /)"
echo "DISK_AVAIL_GB=$(avail_gb /)"
echo "CONTAINERD_TOTAL_GB=$(total_gb /var/lib/containerd)"
echo "CONTAINERD_AVAIL_GB=$(avail_gb /var/lib/containerd)"
echo "ETCD_TOTAL_GB=$(total_gb /var/lib/etcd)"
echo "ETCD_AVAIL_GB=$(avail_gb /var/lib/etcd)"
echo "OPENEBS_TOTAL_GB=$(total_gb /var/openebs/local)"
echo "OPENEBS_AVAIL_GB=$(avail_gb /var/openebs/local)"
mount_of() {
  p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  df -P "$p" 2>/dev/null | awk 'NR==2 {print $6}'
}
echo "CONTAINERD_FS=$(mount_of /var/lib/containerd)"
echo "ROOT_FS=$(mount_of /)"
echo "ETCD_FS=$(mount_of /var/lib/etcd)"
echo "OPENEBS_FS=$(mount_of /var/openebs/local)"
backing_disks() {
  p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  src=$(findmnt -n -o SOURCE --target "$p" 2>/dev/null)
  [ -n "$src" ] || return
  disks=$(lsblk -sno NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk" {print $1}' | sort -u | paste -sd, -)
  [ -n "$disks" ] && printf '%s' "$disks" || printf 'unknown:%s' "$src"
}
echo "ROOT_DISKS=$(backing_disks /)"
echo "CONTAINERD_DISKS=$(backing_disks /var/lib/containerd)"
echo "ETCD_DISKS=$(backing_disks /var/lib/etcd)"
echo "OPENEBS_DISKS=$(backing_disks /var/openebs/local)"

echo "SWAP=$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')"
if systemctl is-active chronyd >/dev/null 2>&1 || systemctl is-active ntpd >/dev/null 2>&1 || systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
  echo "TIMESYNC=active"
else
  echo "TIMESYNC=inactive"
fi
if systemctl is-active kubelet >/dev/null 2>&1; then
  echo "KUBELET=active"
else
  echo "KUBELET=inactive"
fi
if [ -d /etc/kubernetes/manifests ] && ls /etc/kubernetes/manifests/*.yaml >/dev/null 2>&1; then
  echo "K8S_MANIFESTS=yes"
else
  echo "K8S_MANIFESTS=no"
fi
if [ -d /var/lib/etcd/member ] || [ -d /var/lib/etcd/wal ]; then
  echo "ETCD_DATA=yes"
else
  echo "ETCD_DATA=no"
fi
echo "EPOCH_END=$(date +%s)"
EOS
) || REPORT=""
  LOCAL_EPOCH_END=$(date +%s)

  if [[ -z "$REPORT" ]]; then
    echo "  失败: 远程采集没有返回任何内容"
    FAIL=1
    echo
    continue
  fi
  echo "$REPORT" | sed 's/^/  /'

  host_name=$(field "$REPORT" HOST)
  arch=$(field "$REPORT" ARCH)
  cpu=$(field "$REPORT" CPU)
  mem=$(field "$REPORT" MEM_GB)
  disk=$(field "$REPORT" DISK_AVAIL_GB)
  root_total=$(field "$REPORT" ROOT_TOTAL_GB)
  ctotal=$(field "$REPORT" CONTAINERD_TOTAL_GB)
  cdisk=$(field "$REPORT" CONTAINERD_AVAIL_GB)
  etotal=$(field "$REPORT" ETCD_TOTAL_GB)
  edisk=$(field "$REPORT" ETCD_AVAIL_GB)
  ototal=$(field "$REPORT" OPENEBS_TOTAL_GB)
  odisk=$(field "$REPORT" OPENEBS_AVAIL_GB)
  cfs=$(field "$REPORT" CONTAINERD_FS)
  rootfs=$(field "$REPORT" ROOT_FS)
  efs=$(field "$REPORT" ETCD_FS)
  ofs=$(field "$REPORT" OPENEBS_FS)
  root_disks=$(field "$REPORT" ROOT_DISKS)
  containerd_disks=$(field "$REPORT" CONTAINERD_DISKS)
  etcd_disks=$(field "$REPORT" ETCD_DISKS)
  openebs_disks=$(field "$REPORT" OPENEBS_DISKS)
  epoch_start=$(field "$REPORT" EPOCH_START)
  epoch_end=$(field "$REPORT" EPOCH_END)
  swap=$(field "$REPORT" SWAP)
  timesync=$(field "$REPORT" TIMESYNC)
  kubelet=$(field "$REPORT" KUBELET)
  manifests=$(field "$REPORT" K8S_MANIFESTS)
  etcd_data=$(field "$REPORT" ETCD_DATA)

  if [[ ! "$cpu" =~ ^[0-9]+$ || ! "$mem" =~ ^[0-9]+$ ||
        ! "$root_total" =~ ^[0-9]+$ || ! "$disk" =~ ^[0-9]+$ ||
        ! "$epoch_start" =~ ^[0-9]+$ || ! "$epoch_end" =~ ^[0-9]+$ ]]; then
    echo "  失败: CPU/内存/磁盘/时钟采集结果缺失或不是整数，判定不可信"
    FAIL=1
    echo
    continue
  fi

  NODE_SKEWS+=("$(( (epoch_start + epoch_end - LOCAL_EPOCH_START - LOCAL_EPOCH_END) / 2 ))")
  NODE_ARCHS+=("${arch:-unknown}")

  if [[ "${cpu:-0}" -lt "$MIN_CPU" ]]; then
    echo "  失败: CPU ${cpu} < ${MIN_CPU}"
    FAIL=1
  fi
  # /proc/meminfo 整数 GB 常比标称少 1G（16G 机会报 15）
  mem_floor=$((MIN_MEM_GB - 1))
  if [[ "${mem:-0}" -lt "$mem_floor" ]]; then
    echo "  失败: 内存 ${mem}G < ${MIN_MEM_GB}G（按 ${mem_floor}G 门禁）"
    FAIL=1
  fi
  if [[ "$root_total" -lt "$MIN_ROOT_TOTAL_GB" ]]; then
    echo "  失败: 根盘总量 ${root_total}G < ${MIN_ROOT_TOTAL_GB}G"
    FAIL=1
  fi
  if [[ "$disk" -lt "$MIN_ROOT_AVAIL_GB" ]]; then
    echo "  失败: 根盘可用 ${disk}G < ${MIN_ROOT_AVAIL_GB}G"
    FAIL=1
  fi
  if [[ "$PHASE" == "full" ]]; then
    if [[ ! "$ctotal" =~ ^[0-9]+$ || ! "$cdisk" =~ ^[0-9]+$ ]]; then
      echo "  失败: containerd 文件系统容量采集失败"
      FAIL=1
    else
      if [[ "$ctotal" -lt "$MIN_CONTAINERD_TOTAL_GB" || "$cdisk" -lt "$MIN_CONTAINERD_AVAIL_GB" ]]; then
        echo "  失败: /var/lib/containerd 文件系统（${cfs:-?}）总量/可用 ${ctotal}G/${cdisk}G，要求至少 ${MIN_CONTAINERD_TOTAL_GB}G/${MIN_CONTAINERD_AVAIL_GB}G"
        FAIL=1
      fi
    fi
    if [[ "$REQUIRE_SEPARATE_CONTAINERD" == "1" && "$cfs" == "$rootfs" ]]; then
      echo "  失败: 三节点要求 /var/lib/containerd 独立挂载，当前与根目录同在 ${rootfs:-?}"
      FAIL=1
    fi
    if [[ "$TOPOLOGY" == "three" ]]; then
      if [[ ! "$etotal" =~ ^[0-9]+$ || ! "$edisk" =~ ^[0-9]+$ ||
            ! "$ototal" =~ ^[0-9]+$ || ! "$odisk" =~ ^[0-9]+$ ]]; then
        echo "  失败: etcd/openebs 文件系统容量采集失败"
        FAIL=1
      else
        if [[ "$etotal" -lt "$MIN_ETCD_TOTAL_GB" || "$edisk" -lt "$MIN_ETCD_AVAIL_GB" ]]; then
          echo "  失败: /var/lib/etcd 文件系统总量/可用 ${etotal}G/${edisk}G，要求至少 ${MIN_ETCD_TOTAL_GB}G/${MIN_ETCD_AVAIL_GB}G"
          FAIL=1
        fi
        if [[ "$ototal" -lt "$MIN_OPENEBS_TOTAL_GB" || "$odisk" -lt "$MIN_OPENEBS_AVAIL_GB" ]]; then
          echo "  失败: /var/openebs/local 文件系统总量/可用 ${ototal}G/${odisk}G，要求至少 ${MIN_OPENEBS_TOTAL_GB}G/${MIN_OPENEBS_AVAIL_GB}G"
          FAIL=1
        fi
      fi
      if [[ "$efs" == "$rootfs" || "$ofs" == "$rootfs" ||
            "$cfs" == "$efs" || "$cfs" == "$ofs" || "$efs" == "$ofs" ]]; then
        echo "  失败: 三节点的 containerd、etcd、openebs 必须分别挂载到不同数据盘"
        FAIL=1
      fi
      if [[ -z "$root_disks" || -z "$containerd_disks" || -z "$etcd_disks" || -z "$openebs_disks" ||
            "$root_disks" == unknown:* || "$containerd_disks" == unknown:* ||
            "$etcd_disks" == unknown:* || "$openebs_disks" == unknown:* ]]; then
        echo "  失败: 无法用 findmnt/lsblk 确认四个文件系统的底层物理盘"
        FAIL=1
      elif disk_sets_overlap "$root_disks" "$containerd_disks" ||
           disk_sets_overlap "$root_disks" "$etcd_disks" ||
           disk_sets_overlap "$root_disks" "$openebs_disks" ||
           disk_sets_overlap "$containerd_disks" "$etcd_disks" ||
           disk_sets_overlap "$containerd_disks" "$openebs_disks" ||
           disk_sets_overlap "$etcd_disks" "$openebs_disks"; then
        echo "  失败: 文件系统挂载点不同，但底层物理盘仍有复用（root=$root_disks containerd=$containerd_disks etcd=$etcd_disks openebs=$openebs_disks）"
        FAIL=1
      fi
    fi
  fi
  if [[ "${swap:-0}" != "0" ]]; then
    echo "  警告: 检测到 ${swap} 个 swap 设备，kubelet 要求关闭（init os 会处理，但请确认）"
  fi
  if [[ "$timesync" == "inactive" ]]; then
    echo "  警告: 未检测到 chronyd/ntpd/systemd-timesyncd 在运行，时钟会逐渐漂移"
  fi
  if [[ "$kubelet" == "active" || "$manifests" == "yes" || "$etcd_data" == "yes" ]]; then
    echo "  失败: 发现残留 Kubernetes（kubelet=${kubelet} manifests=${manifests} etcd_data=${etcd_data}）"
    echo "        不要继续 create cluster。先排障或经确认后清理。"
    echo "        若本意是「已有 K8s，只装平台」，请走模式 C，不要跑 create cluster。"
    FAIL=1
  fi
  echo
done

if [[ ${#NODES[@]} -ge 2 ]]; then
  echo "--------------------------------------------------------------"
  echo "  节点间网络与时钟"
  echo "--------------------------------------------------------------"
  for src in "${NODES[@]}"; do
    for dst in "${NODES[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      if remote "$src" "ping -c 1 -W 2 '$dst'" >/dev/null 2>&1; then
        echo "  $src -> $dst  ICMP OK"
      else
        echo "  $src -> $dst  ICMP 不通（可能被策略禁止，继续检查 TCP）"
      fi
      if remote "$src" "timeout 3 bash -c '</dev/tcp/$dst/$SSH_PORT'" >/dev/null 2>&1; then
        echo "  $src -> $dst:$SSH_PORT  TCP OK"
      else
        echo "  失败: $src -> $dst:$SSH_PORT TCP 不通，安装器无法 SSH 管理该节点"
        FAIL=1
      fi
    done
  done

  # 架构必须一致，否则离线包只能装一部分节点
  if [[ ${#NODE_ARCHS[@]} -ge 2 ]]; then
    uniq_arch=$(printf '%s\n' "${NODE_ARCHS[@]}" | sort -u | tr '\n' ' ')
    if [[ $(printf '%s\n' "${NODE_ARCHS[@]}" | sort -u | wc -l | tr -d ' ') -gt 1 ]]; then
      echo "  失败: 节点架构不一致（${uniq_arch}），一份离线包装不了混合架构"
      FAIL=1
    else
      echo "  架构一致: ${uniq_arch}（请与离线包架构核对）"
    fi
  fi

  # 比较各节点相对发起机的偏移之差，已抵掉串行 SSH 的往返延迟
  if [[ ${#NODE_SKEWS[@]} -ge 2 ]]; then
    min="${NODE_SKEWS[0]}"; max="${NODE_SKEWS[0]}"
    for s in "${NODE_SKEWS[@]}"; do
      [[ "$s" -lt "$min" ]] && min="$s"
      [[ "$s" -gt "$max" ]] && max="$s"
    done
    spread=$(( max - min ))
    if [[ "$spread" -gt "$MAX_SKEW_S" ]]; then
      echo "  失败: 节点间时钟相差约 ${spread}s > ${MAX_SKEW_S}s（证书与 etcd 会出问题）"
      FAIL=1
    else
      echo "  时钟偏差约 ${spread}s，在 ${MAX_SKEW_S}s 以内"
    fi
  fi
  echo
fi

echo "=============================================================="
if [[ "$FAIL" -ne 0 ]]; then
  echo "预检未通过：不要进入危险步骤。"
  echo "不要把本次输出当成可以开装。"
  exit 1
fi
echo "预检通过：SSH 管理通道、资源/磁盘门槛、无残留 K8s 与时钟检查均满足。"
echo "注意：尚未监听的 6443/2379/2380/CNI 端口不能靠安装前 connect 判断；仍须按端口矩阵放通。"
echo "下一步仍须按步骤编号确认（例如「确认 D2」）后再改系统。"
exit 0
