#!/usr/bin/env bash
# Inventory 驱动的多节点只读门禁：硬件、磁盘、SSH 鉴权、解析与 registry 客户端。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
INVENTORY="${KC_INVENTORY_FILE:-}"
PHASE="${KC_PREFLIGHT_PHASE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
MIN_CPU="${KC_MIN_CPU:-8}"
MIN_MEM_GB="${KC_MIN_MEM_GB:-16}"
MAX_SKEW="${KC_MAX_SKEW_S:-5}"

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || die "请设置 KC_INVENTORY_FILE"
[[ "$PHASE" == "hardware" || "$PHASE" == "full" || "$PHASE" == "post-registry" ]] ||
  die "KC_PREFLIGHT_PHASE 必须是 hardware|full|post-registry"
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

PROFILE=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
NODE_COUNT=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" count)
NODE_LINES=()
while IFS= read -r line; do NODE_LINES+=("$line"); done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
IFS=$'\t' read -r FIRST_NAME FIRST_ADDRESS FIRST_INTERNAL SSH_USER SSH_PORT FIRST_ROLES <<<"${NODE_LINES[0]}"
NODE1="${KC_NODE1:-$FIRST_ADDRESS}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
  -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -p "$SSH_PORT")
[[ -f "$LOCAL_KEY" ]] && SSH_OPTS+=(-i "$LOCAL_KEY")

remote() {
  local host="$1"; shift
  kubercon_ssh_opts "$host" "$SSH_PORT"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

FAIL=0
declare -a EPOCHS=()
declare -a ARCHES=()
echo "MULTINODE_PREFLIGHT phase=$PHASE profile=$PROFILE nodes=$NODE_COUNT"

for line in "${NODE_LINES[@]}"; do
  IFS=$'\t' read -r name address internal user port roles <<<"$line"
  echo "--- node=$name management=$address internal=$internal roles=$roles ---"
  if ! remote "$address" true >/dev/null 2>&1; then
    echo "BAD 本机无法以密钥 SSH 到 $name ($address)"
    FAIL=1
    continue
  fi
  report=$(remote "$address" 'bash -s' <<'EOS'
set -euo pipefail
avail() { local p="$1"; while [[ ! -e "$p" && "$p" != / ]]; do p=$(dirname "$p"); done; df -Pk "$p" | awk 'NR==2{print int($4/1024/1024)}'; }
total() { local p="$1"; while [[ ! -e "$p" && "$p" != / ]]; do p=$(dirname "$p"); done; df -Pk "$p" | awk 'NR==2{print int($2/1024/1024)}'; }
fs() { local p="$1"; while [[ ! -e "$p" && "$p" != / ]]; do p=$(dirname "$p"); done; findmnt -n -o SOURCE --target "$p" 2>/dev/null || echo unknown; }
echo "ARCH=$(uname -m)"
echo "CPU=$(nproc)"
echo "MEM_GB=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
echo "EPOCH=$(date +%s)"
echo "ROOT_TOTAL=$(total /)"
echo "ROOT_AVAIL=$(avail /)"
for item in containerd:/var/lib/containerd etcd:/var/lib/etcd openebs:/var/openebs/local; do
  key=${item%%:*}; path=${item#*:}
  echo "${key^^}_TOTAL=$(total "$path")"
  echo "${key^^}_AVAIL=$(avail "$path")"
  echo "${key^^}_FS=$(fs "$path")"
done
echo "ROOT_FS=$(fs /)"
echo "KUBELET=$(systemctl is-active kubelet 2>/dev/null || true)"
[[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal ]] && echo "ETCD_CLEAN=1" || echo "ETCD_CLEAN=0"
[[ ! -d /etc/kubernetes/manifests ]] && echo "MANIFESTS_CLEAN=1" || echo "MANIFESTS_CLEAN=0"
echo "FIREWALLD=$(systemctl is-active firewalld 2>/dev/null || true)"
echo "SWAP=$(swapon --noheadings 2>/dev/null | wc -l | tr -d ' ')"
missing=()
for cmd in tar gzip unzip which screen python3 curl rsync; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
echo "MISSING=${missing[*]}"
EOS
  ) || { echo "BAD 无法采集 $name"; FAIL=1; continue; }
  value() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' <<<"$report"; }
  arch=$(value ARCH); cpu=$(value CPU); mem=$(value MEM_GB); epoch=$(value EPOCH)
  ARCHES+=("$arch"); EPOCHS+=("$epoch")
  (( cpu >= MIN_CPU )) || { echo "BAD CPU=${cpu}<${MIN_CPU}"; FAIL=1; }
  (( mem >= MIN_MEM_GB )) || { echo "BAD MEM=${mem}G<${MIN_MEM_GB}G"; FAIL=1; }
  [[ "$(value KUBELET)" != active && "$(value ETCD_CLEAN)" == 1 && "$(value MANIFESTS_CLEAN)" == 1 ]] ||
    { echo "BAD 存在 Kubernetes/etcd 残留"; FAIL=1; }
  if [[ "$PHASE" != "hardware" ]]; then
    [[ -z "$(value MISSING)" ]] || { echo "BAD 缺依赖: $(value MISSING)"; FAIL=1; }
    [[ "$(value FIREWALLD)" != active ]] || { echo "BAD firewalld 仍 active"; FAIL=1; }
    [[ "$(value SWAP)" == 0 ]] || { echo "BAD swap 未关闭"; FAIL=1; }
    rootfs=$(value ROOT_FS); cfs=$(value CONTAINERD_FS); efs=$(value ETCD_FS); ofs=$(value OPENEBS_FS)
    if [[ "${KC_ALLOW_SHARED_ROOT:-}" == "1" ]]; then
      echo "NOTE: KC_ALLOW_SHARED_ROOT=1，允许 containerd/etcd/openebs 共用 root（仅测试）"
      # 测试口径：不按分盘容量累加，只要求根盘剩余足够放下离线包与镜像缓存。
      (( $(value ROOT_AVAIL) >= 120 )) ||
        { echo "BAD 共用 / 时可用空间不足: avail=$(value ROOT_AVAIL)G need=120G"; FAIL=1; }
    else
      [[ "$rootfs" != "$cfs" ]] ||
        { echo "BAD containerd 必须独立于 root 文件系统"; FAIL=1; }
      if [[ ",$roles," == *,etcd,* ]]; then
        [[ "$rootfs" != "$efs" && "$cfs" != "$efs" ]] ||
          { echo "BAD etcd 节点的 etcd 数据盘必须独立"; FAIL=1; }
      fi
      (( $(value CONTAINERD_TOTAL) >= 190 && $(value CONTAINERD_AVAIL) >= 150 )) ||
        { echo "BAD containerd 数据盘不足"; FAIL=1; }
      if [[ ",$roles," == *,etcd,* ]]; then
        (( $(value ETCD_TOTAL) >= 95 && $(value ETCD_AVAIL) >= 70 )) ||
          { echo "BAD etcd 数据盘不足"; FAIL=1; }
      fi
      if [[ "$PROFILE" != external-prod ]]; then
        [[ "$rootfs" != "$ofs" && "$cfs" != "$ofs" ]] ||
          { echo "BAD root/containerd/openebs 必须是不同文件系统"; FAIL=1; }
        if [[ ",$roles," == *,etcd,* ]]; then
          [[ "$ofs" != "$efs" ]] || { echo "BAD etcd 与 openebs 必须分盘"; FAIL=1; }
        fi
        (( $(value OPENEBS_TOTAL) >= 190 && $(value OPENEBS_AVAIL) >= 150 )) ||
          { echo "BAD openebs 数据盘不足"; FAIL=1; }
      fi
    fi
  fi
done

[[ $(printf '%s\n' "${ARCHES[@]}" | sort -u | wc -l | tr -d ' ') == 1 ]] ||
  { echo "BAD 节点架构不一致"; FAIL=1; }
if ((${#EPOCHS[@]} == NODE_COUNT)); then
  min=${EPOCHS[0]}; max=${EPOCHS[0]}
  for epoch in "${EPOCHS[@]}"; do ((epoch < min)) && min=$epoch; ((epoch > max)) && max=$epoch; done
  (( max - min <= MAX_SKEW )) || { echo "BAD 时钟偏差 $((max-min))s > ${MAX_SKEW}s"; FAIL=1; }
fi

if [[ "$PHASE" != "hardware" ]]; then
  echo "--- node1 使用 inventory 私钥验证所有内网节点 ---"
  if ! remote "$NODE1" "bash -s -- $(printf '%q ' "$REMOTE_DIR/inventory.json")" <<'EOS'
set -euo pipefail
inventory="$1"
python3 - "$inventory" <<'PY' > /tmp/kubercon-inventory-nodes.tsv
import json,sys
d=json.load(open(sys.argv[1]))
for n in d["nodes"]:
    print(n["name"], n["internalAddress"], sep="\t")
print(d["ssh"]["privateKeyPath"], d["ssh"]["user"], d["ssh"]["port"], sep="\t", file=sys.stderr)
PY
read -r key user port < <(python3 - "$inventory" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(d["ssh"]["privateKeyPath"],d["ssh"]["user"],d["ssh"]["port"])
PY
)
[[ -f "$key" ]] || { echo "node1 私钥不存在: $key"; exit 1; }
while IFS=$'\t' read -r name internal; do
  ssh -i "$key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "$user@$internal" 'true' || { echo "node1 -> $name($internal) 密钥 SSH 失败"; exit 1; }
done < /tmp/kubercon-inventory-nodes.tsv
rm -f /tmp/kubercon-inventory-nodes.tsv
EOS
  then
    echo "BAD node1 到集群节点的真实 SSH 失败"
    FAIL=1
  fi

  registry=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["privateRegistry"])' "$INVENTORY")
  registry_ca=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["registryCAPath"])' "$INVENTORY")
  registry_host=${registry%%:*}
  expected_registry_ip="$FIRST_INTERNAL"
  api_domain=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["apiDomain"])' "$INVENTORY")
  api_address=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["apiAddress"])' "$INVENTORY")
  expected_api_ip="${api_address:-$FIRST_INTERNAL}"
  for line in "${NODE_LINES[@]}"; do
    IFS=$'\t' read -r name address internal user port roles <<<"$line"
    resolved=$(remote "$address" "getent ahostsv4 $(printf '%q' "$registry_host") | awk 'NR==1{print \$1}'" 2>/dev/null || true)
    if [[ -z "$resolved" ]]; then
      echo "BAD $name 无法解析 $registry_host"; FAIL=1
    elif [[ "$PROFILE" != external-prod && "$resolved" != "$expected_registry_ip" ]]; then
      echo "BAD $name 将 $registry_host 解析为 $resolved，期望 $expected_registry_ip"; FAIL=1
    fi
    resolved_api=$(remote "$address" "getent ahostsv4 $(printf '%q' "$api_domain") | awk 'NR==1{print \$1}'" 2>/dev/null || true)
    [[ "$resolved_api" == "$expected_api_ip" ]] ||
      { echo "BAD $name 将 API 域名解析为 ${resolved_api:-空}，期望 $expected_api_ip"; FAIL=1; }
    for dst_line in "${NODE_LINES[@]}"; do
      IFS=$'\t' read -r dst_name _ dst_internal _ _ _ <<<"$dst_line"
      resolved_node=$(remote "$address" "getent ahostsv4 $(printf '%q' "$dst_name") | awk 'NR==1{print \$1}'" 2>/dev/null || true)
      [[ "$resolved_node" == "$dst_internal" ]] ||
        { echo "BAD $name 将 $dst_name 解析为 ${resolved_node:-空}，期望 $dst_internal"; FAIL=1; }
      remote "$address" "timeout 5 bash -c '</dev/tcp/$dst_internal/$SSH_PORT'" >/dev/null 2>&1 ||
        { echo "BAD $name -> $dst_name:$SSH_PORT TCP 不通"; FAIL=1; }
    done
    if [[ "$PHASE" == post-registry || "$PROFILE" == external-prod ]]; then
      code=$(remote "$address" "bash -s -- $(printf '%q ' "$registry_ca" "$registry")" <<'EOS' 2>/dev/null || true)
set -euo pipefail
ca="$1"; registry="$2"
if [[ ! -f "$ca" ]]; then
  for alt in "${ca%/*}/ca.crt" "${ca%.pem}.crt"; do
    [[ -f "$alt" ]] && ca="$alt" && break
  done
fi
[[ -f "$ca" ]] || exit 2
curl --cacert "$ca" --silent --show-error --connect-timeout 5 -o /dev/null -w '%{http_code}' "https://${registry}/v2/"
EOS
      [[ "$code" == 200 || "$code" == 401 ]] ||
        { echo "BAD $name 无法通过 TLS 访问 registry (code=${code:-000})"; FAIL=1; }
      if [[ "$PHASE" == post-registry && "$PROFILE" != external-prod ]]; then
        for image in "$registry/kubercon/pause:3.9" "$registry/kubercon/alpine:3.14"; do
          remote "$address" "crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull $(printf '%q' "$image") >/dev/null" ||
            { echo "BAD $name 无法通过 CRI 拉取 $image"; FAIL=1; }
        done
      fi
    fi
  done
fi

if (( FAIL )); then
  echo "MULTINODE_PREFLIGHT_FAILED"
  exit 1
fi
echo "MULTINODE_PREFLIGHT_OK phase=$PHASE nodes=$NODE_COUNT profile=$PROFILE"
