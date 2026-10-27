#!/usr/bin/env bash
# D4 后：把 V22.6 separate registry 必改字段写入远端 config.yaml（幂等）。
# 须在 D6R 之前执行；改完后必须再跑 validate-cluster-config.sh，再跑 D6R。
# 需要确认 D4 或 KC_AUTONOMOUS=1。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
NS_OVERRIDE="${KC_NAMESPACE_OVERRIDE:-kubercon}"
PRIVATE_REGISTRY="${KC_LOCAL_REGISTRY:-docker.kubercon.local}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ "${KC_CONFIRMED_D4:-}" == "确认 D4" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D4='确认 D4' 或 KC_AUTONOMOUS=1"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q' "$REMOTE_DIR") $(printf '%q' "$NS_OVERRIDE") $(printf '%q' "$PRIVATE_REGISTRY")" <<'EOS'
set -euo pipefail
dir="$1"; ns="$2"; preg="$3"
cd "$dir"
[[ -f config.yaml ]] || { echo "错误: 缺少 config.yaml；先 create config --filename config.yaml"; exit 1; }

# 备份一次
cp -a config.yaml "config.yaml.bak.$(date +%Y%m%d-%H%M%S)"

if grep -q 'namespaceOverride:' config.yaml; then
  sed -i "s/namespaceOverride:.*/namespaceOverride: \"${ns}\"/" config.yaml
else
  echo "错误: config.yaml 无 namespaceOverride 字段"
  exit 1
fi
if grep -q 'insecureRegistries:' config.yaml; then
  sed -i 's/insecureRegistries:.*/insecureRegistries: []/' config.yaml
else
  echo "错误: config.yaml 无 insecureRegistries 字段"
  exit 1
fi
if grep -q 'privateRegistry:' config.yaml; then
  sed -i "s/privateRegistry:.*/privateRegistry: \"${preg}\"/" config.yaml
fi

# 禁止 etcd.type=kubercon
if grep -A5 -E 'etcd:[[:space:]]*$' config.yaml | grep -qE 'type:[[:space:]]*kubercon'; then
  sed -i '/^  etcd:/,/^  [a-z]/ s/type:[[:space:]]*kubercon/type: kubekey/' config.yaml || true
fi

echo "=== patched fields ==="
grep -nE 'namespaceOverride|insecureRegistries|privateRegistry' config.yaml || true
grep -A3 -E 'etcd:[[:space:]]*$' config.yaml | head -5 || true
echo "CONFIG_PATCHED"
EOS

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KC_NODE1="$KC_NODE1" KC_SSH_USER="$SSH_USER" KC_SSH_KEY="$SSH_KEY" KC_SSH_PORT="$SSH_PORT" \
  KC_REMOTE_DIR="$REMOTE_DIR" KC_PROFILE="${KC_PROFILE:?请设置 KC_PROFILE}" \
  "$SCRIPT_DIR/validate-cluster-config.sh"
