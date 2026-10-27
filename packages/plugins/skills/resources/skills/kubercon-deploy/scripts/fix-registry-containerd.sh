#!/usr/bin/env bash
# D6R 成功后、create cluster 前：修正 kk 写入的 containerd 镜像仓库配置。
# 现场事实（V22.6.0 + separate registry）：
#   1) 本地 registry 只监听 HTTPS:443，kk 常写成 http:// → pull 连 :80 被拒
#   2) pause 在仓库命名空间 kubercon/，kk 常写成 kubesphere/pause
#   3) config.yaml 的 namespaceOverride 应设为 kubercon
#   4) insecureRegistries 含私有仓时 kk 会写 http:// mirror；HTTPS-only registry 必须清空该项
#   5) create 过程中 kk 会重写 containerd 并丢掉 config_path——D6 期间需配合 watchdog 反复打补丁
# 本脚本幂等、不清理集群；可在 D6 前/中多次执行。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
REGISTRY_HOST="${KC_LOCAL_REGISTRY:-docker.kubercon.local}"
PAUSE_IMAGE="${KC_PAUSE_IMAGE:-${REGISTRY_HOST}/kubercon/pause:3.9}"
CA_PEM="${KC_REGISTRY_CA:-/etc/ssl/registry/ssl/ca.pem}"
NS_OVERRIDE="${KC_NAMESPACE_OVERRIDE:-kubercon}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SKIP_CONFIG_PATCH="${KC_SKIP_CONFIG_PATCH:-0}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

die() { echo "错误: $*" >&2; exit 1; }
if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "$INVENTORY" ]] || die "KC_INVENTORY_FILE 不存在"
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  REGISTRY_HOST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["privateRegistry"])' "$INVENTORY")
  CA_PEM=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["registryCAPath"])' "$INVENTORY")
  PAUSE_IMAGE="${KC_PAUSE_IMAGE:-${REGISTRY_HOST}/kubercon/pause:3.9}"
  failed=0
  while IFS=$'\t' read -r name address _ user port _; do
    echo "=== fix containerd node=$name address=$address ==="
    if ! env -u KC_INVENTORY_FILE \
      KC_NODE1="$address" KC_SSH_USER="$user" KC_SSH_PORT="$port" KC_SSH_KEY="$SSH_KEY" \
      KC_REMOTE_DIR="$REMOTE_DIR" KC_LOCAL_REGISTRY="$REGISTRY_HOST" KC_PAUSE_IMAGE="$PAUSE_IMAGE" \
      KC_REGISTRY_CA="$CA_PEM" KC_NAMESPACE_OVERRIDE="$NS_OVERRIDE" \
      KC_SKIP_CONFIG_PATCH="$SKIP_CONFIG_PATCH" "$0"; then
      failed=1
    fi
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
  (( failed == 0 )) || die "至少一个节点 containerd 修复失败"
  echo "MULTINODE_REGISTRY_CONTAINERD_FIXED"
  exit 0
fi
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$REGISTRY_HOST" "$PAUSE_IMAGE" "$CA_PEM" "$NS_OVERRIDE" "$SKIP_CONFIG_PATCH")" <<'EOS'
set -euo pipefail
dir="$1"; registry_host="$2"; pause_image="$3"; ca_pem="$4"; ns_override="$5"; skip_config_patch="$6"

command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3（D2 依赖）"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "错误: 需要 curl（D2 依赖）"; exit 1; }
# 首次 D6：kk create 才会安装 containerd。此时跳过补丁，交给 watchdog 在
# Generate containerd config 之后立刻反复打补丁（与单节点 POC 恢复路径一致）。
if [[ ! -f /etc/containerd/config.toml ]]; then
  echo "NOTE: 尚无 /etc/containerd/config.toml，跳过首次 fix（watchdog 将在 create 中途接管）"
  exit 0
fi
# kk 在 registry 节点保留 ca.pem，同步到其他节点时改名为 ca.crt。
if [[ ! -f "$ca_pem" ]]; then
  for alt in "${ca_pem%/*}/ca.crt" "${ca_pem%.pem}.crt"; do
    [[ -f "$alt" ]] && ca_pem="$alt" && break
  done
fi
[[ -f "$ca_pem" ]] || { echo "错误: 无 registry CA: $4 或同目录 ca.crt"; exit 1; }

# HTTPS 探测
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${registry_host}/v2/" || true)
[[ "$code" == "200" || "$code" == "401" ]] || {
  echo "错误: https://${registry_host}/v2/ 不可达 (http_code=$code)"
  exit 1
}

mkdir -p "/etc/containerd/certs.d/${registry_host}"
cat > "/etc/containerd/certs.d/${registry_host}/hosts.toml" <<TOML
server = "https://${registry_host}"
[host."https://${registry_host}"]
  ca = "${ca_pem}"
TOML

export PAUSE_IMAGE="$pause_image"
python3 - <<'PY'
import os, re
from pathlib import Path
p = Path("/etc/containerd/config.toml")
pause = os.environ["PAUSE_IMAGE"]
# containerd 1.7+: config_path 与 mirrors 互斥；并存则 CRI 插件加载失败
# → RuntimeService/ImageService Unimplemented。只用 certs.d/hosts.toml。
lines = p.read_text().splitlines()
out = []
i = 0
while i < len(lines):
    l = lines[i]
    if 'registry.mirrors' in l:
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith('['):
            i += 1
        continue
    out.append(l)
    i += 1
text = '\n'.join(out) + '\n'
needle = '[plugins."io.containerd.grpc.v1.cri".registry]'
if needle in text:
    text = re.sub(
        r'\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]\n(?:\s*config_path\s*=\s*"[^"]*"\n)?',
        needle + '\n      config_path = "/etc/containerd/certs.d"\n',
        text,
        count=1,
    )
text = re.sub(
    r'sandbox_image\s*=\s*"[^"]*"',
    f'sandbox_image = "{pause}"',
    text,
    count=1,
)
p.write_text(text)
print("containerd config patched (config_path only, mirrors removed)")
PY
grep -Fq 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml ||
  { echo "错误: containerd patch 后仍无 config_path"; exit 1; }
if grep -q 'registry\.mirrors' /etc/containerd/config.toml; then
  echo "错误: containerd config_path 与 registry.mirrors 仍并存"
  exit 1
fi

if [[ -f "$dir/config.yaml" ]]; then
  if [[ "$skip_config_patch" == "1" ]]; then
    echo "NOTE: skip_config_patch=1，不改 config.yaml（避免破坏 D6R fingerprint）"
    grep -n 'namespaceOverride\|privateRegistry\|insecureRegistries' "$dir/config.yaml" || true
  else
    if grep -q 'namespaceOverride:' "$dir/config.yaml"; then
      sed -i "s/namespaceOverride:.*/namespaceOverride: \"${ns_override}\"/" "$dir/config.yaml"
    else
      echo "警告: config.yaml 无 namespaceOverride 字段，请人工核对"
    fi
    if grep -q 'insecureRegistries:' "$dir/config.yaml"; then
      sed -i 's/insecureRegistries:.*/insecureRegistries: []/' "$dir/config.yaml"
    fi
    grep -n 'namespaceOverride\|privateRegistry\|insecureRegistries' "$dir/config.yaml" || true
  fi
fi

systemctl restart containerd
sleep 3
systemctl is-active --quiet containerd ||
  { systemctl status containerd --no-pager -l || true; echo "错误: containerd 重启失败"; exit 1; }
command -v crictl >/dev/null || { echo "错误: 缺 crictl，无法验证 CRI"; exit 1; }
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/tmp/kc-cri-info.json 2>/tmp/kc-cri-info.err ||
  { cat /tmp/kc-cri-info.err; echo "错误: CRI RuntimeService 不可用"; exit 1; }
if ! crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull "$pause_image" 2>/tmp/kc-pause-pull.err; then
  echo "错误: CRI ImageService 无法拉取 pause；ctr 成功也不能证明 kubelet 可用"
  cat /tmp/kc-pause-pull.err || true
  exit 1
fi
crictl --runtime-endpoint unix:///run/containerd/containerd.sock images |
  grep -F "$pause_image" >/dev/null || { echo "错误: pause 镜像拉取后不可见"; exit 1; }

echo "REGISTRY_CONTAINERD_FIXED host=$registry_host pause=$pause_image ns=$ns_override skip_config=$skip_config_patch"
EOS
