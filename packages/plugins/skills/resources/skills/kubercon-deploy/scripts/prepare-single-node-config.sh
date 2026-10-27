#!/usr/bin/env bash
# V22.6 单节点 POC：生成确定性的 config.yaml，避免 kk 默认双节点/明文密码模板。
# 必须在 D6R 前运行；会覆盖远端 config.yaml，因此需要 D4 确认。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
NODE_NAME="${KC_NODE_NAME:-node1}"
NODE_ADDRESS="${KC_NODE_ADDRESS:-${KC_NODE1:-}}"
INTERNAL_ADDRESS="${KC_NODE_INTERNAL_ADDRESS:-}"
REMOTE_PRIVATE_KEY="${KC_REMOTE_PRIVATE_KEY:-/root/.ssh/id_rsa}"
K8S_VERSION="${KC_KUBERNETES_VERSION:-v1.28.15}"
REGISTRY="${KC_LOCAL_REGISTRY:-docker.kubercon.local}"
POD_CIDR="${KC_POD_CIDR:-10.233.64.0/18}"
SERVICE_CIDR="${KC_SERVICE_CIDR:-10.233.0.0/18}"
API_DOMAIN="${KC_API_DOMAIN:-lb.kubercon.local}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1（SSH 地址）"
[[ -n "$NODE_ADDRESS" ]] || die "请设置 KC_NODE_ADDRESS（本机 SSH/公网，不写入 kk hosts.address）"
[[ -n "$INTERNAL_ADDRESS" ]] || die "请设置 KC_NODE_INTERNAL_ADDRESS（VPC 内网；写入 kk hosts.address）"
[[ "${KC_CONFIRMED_D4:-}" == "确认 D4" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D4='确认 D4' 或 KC_AUTONOMOUS=1"
[[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "KC_NODE_NAME 不是合法 DNS label"
[[ "$NODE_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]] || die "KC_NODE_ADDRESS 格式不安全"
[[ "$INTERNAL_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]] || die "KC_NODE_INTERNAL_ADDRESS 格式不安全"
[[ "$K8S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "KC_KUBERNETES_VERSION 格式错误"
[[ "$REGISTRY" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "KC_LOCAL_REGISTRY 格式错误"
[[ "$REMOTE_PRIVATE_KEY" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_PRIVATE_KEY 必须是安全的绝对路径"
[[ "$POD_CIDR" =~ ^[0-9A-Fa-f:./]+$ && "$SERVICE_CIDR" =~ ^[0-9A-Fa-f:./]+$ ]] ||
  die "Pod/Service CIDR 格式不安全"
[[ "$API_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "KC_API_DOMAIN 格式不安全"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$NODE_NAME" "$NODE_ADDRESS" "$INTERNAL_ADDRESS" "$REMOTE_PRIVATE_KEY" "$K8S_VERSION" "$REGISTRY" "$POD_CIDR" "$SERVICE_CIDR" "$API_DOMAIN")" <<'EOS'
set -euo pipefail
dir="$1"; node="$2"; address="$3"; internal="$4"; key="$5"
k8s="$6"; registry="$7"; pod_cidr="$8"; svc_cidr="$9"; api_domain="${10}"
mkdir -p "$dir"
cd "$dir"
[[ -f "$key" ]] || { echo "错误: node1 上私钥不存在: $key"; exit 1; }
chmod 600 "$key"
[[ ! -f config.yaml ]] || cp -a config.yaml "config.yaml.bak.$(date +%Y%m%d-%H%M%S)"

cat > config.yaml <<EOF
apiVersion: kubekey.kubesphere.io/v1alpha2
kind: Cluster
metadata:
  name: kubercon
spec:
  hosts:
  - {name: ${node}, arch: amd64, address: ${internal}, internalAddress: ${internal}, user: root, privateKeyPath: "${key}"}
  roleGroups:
    etcd:
    - ${node}
    control-plane:
    - ${node}
    worker:
    - ${node}
    registry:
    - ${node}
  controlPlaneEndpoint:
    domain: ${api_domain}
    address: ""
    port: 6443
  kubernetes:
    version: ${k8s}
    clusterName: cluster.local
    autoRenewCerts: true
    containerManager: containerd
  etcd:
    type: kubekey
  network:
    plugin: calico
    kubePodsCIDR: ${pod_cidr}
    kubeServiceCIDR: ${svc_cidr}
    multusCNI:
      enabled: false
  storage:
    openebs:
      basePath: /var/openebs/local
  registry:
    type: registry
    privateRegistry: "${registry}"
    namespaceOverride: "kubercon"
    registryMirrors: []
    insecureRegistries: []
    auths: {}
  addons: []
EOF
echo "SINGLE_NODE_CONFIG_WRITTEN $dir/config.yaml"
EOS

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
  KC_REMOTE_DIR="$REMOTE_DIR" KC_PROFILE="${KC_PROFILE:-kk-artifact-then-cc}" \
  KC_EXPECT_NODES=1 KC_LOCAL_REGISTRY="$REGISTRY" \
  "$SCRIPT_DIR/validate-cluster-config.sh"
