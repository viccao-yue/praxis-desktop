#!/usr/bin/env bash
# 多节点 D9：本机 deploy key → node1（跳板）→ 各 peer；并确保 node1 自信任 id_rsa（kk 需要）。
# 重置虚机 / hostkey 变更时配合确认 D9H 刷新 known_hosts。
#
# 用法:
#   export KC_INVENTORY_FILE=... KC_SSH_KEY=~/.ssh/kubercon_deploy
#   export KC_JUMP_HOST=root@<node1公网>   # 仅 node1 有公网时
#   KC_CONFIRMED_D9='确认 D9' ./scripts/bootstrap-multinode-ssh.sh
#   # 同 IP 重建后:
#   KC_CONFIRMED_D9='确认 D9' KC_CONFIRMED_D9H='确认 D9H' ./scripts/bootstrap-multinode-ssh.sh
#
# 可选一次性密码写 peer 公钥（本机与 node1 均需 sshpass）:
#   KC_SSH_BOOTSTRAP_PASSWORD='...' KC_CONFIRMED_D9='确认 D9' ./scripts/bootstrap-multinode-ssh.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_USER="${KC_SSH_USER:-root}"
SSH_PORT="${KC_SSH_PORT:-22}"
PASSWORD="${KC_SSH_BOOTSTRAP_PASSWORD:-}"

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || die "请设置 KC_INVENTORY_FILE"
[[ "${KC_CONFIRMED_D9:-}" == "确认 D9" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D9='确认 D9' 或 KC_AUTONOMOUS=1"
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] || die "本机私钥不存在: $SSH_KEY"
[[ -f "${SSH_KEY}.pub" ]] || die "本机公钥不存在: ${SSH_KEY}.pub"
PUB=$(cat "${SSH_KEY}.pub")
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

if [[ "${KC_CONFIRMED_D9H:-}" == "确认 D9H" ]]; then
  echo "NOTE: D9H 刷新 known_hosts"
  while IFS=$'\t' read -r _name address _internal _user _port _roles; do
    ssh-keygen -R "$address" 2>/dev/null || true
    ssh-keygen -R "[$address]:$SSH_PORT" 2>/dev/null || true
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
  jump=$(kubercon_jump_host)
  [[ -n "$jump" ]] && ssh-keygen -R "$jump" 2>/dev/null || true
fi

node1_mgmt=""
while IFS=$'\t' read -r _name address internal _user _port roles; do
  if [[ ",$roles," == *,registry,* && ",$roles," == *,control-plane,* ]]; then
    node1_mgmt="$address"
    break
  fi
  if [[ -z "$node1_mgmt" && ",$roles," == *,control-plane,* ]]; then
    node1_mgmt="$address"
  fi
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
[[ -n "$node1_mgmt" ]] || die "inventory 无 control-plane"
export KC_NODE1="${KC_NODE1:-$node1_mgmt}"
export KC_JUMP_HOST="${KC_JUMP_HOST:-${SSH_USER}@${node1_mgmt}}"

probe() {
  local target="$1"
  kubercon_ssh_opts "$target" "$SSH_PORT"
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "${SSH_USER}@${target}" 'hostname' >/dev/null 2>&1
}

write_pubkey_direct_password() {
  local target="$1"
  command -v sshpass >/dev/null ||
    die "需要 sshpass 才能用 KC_SSH_BOOTSTRAP_PASSWORD 写 $target"
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -p "$SSH_PORT" "${SSH_USER}@${target}" \
    "umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; grep -qxF $(printf '%q' "$PUB") .ssh/authorized_keys || echo $(printf '%q' "$PUB") >> .ssh/authorized_keys; chmod 600 .ssh/authorized_keys"
}

echo "=== probe / bootstrap node1=$node1_mgmt ==="
if ! probe "$node1_mgmt"; then
  if [[ -n "$PASSWORD" ]]; then
    echo "NOTE: node1 BatchMode 失败，尝试密码写入 deploy 公钥"
    write_pubkey_direct_password "$node1_mgmt"
    probe "$node1_mgmt" || die "密码写入后仍无法登录 node1"
  else
    echo "错误: 无法 BatchMode 登录 node1 ($node1_mgmt)"
    "$SCRIPT_DIR/print-bootstrap-pubkey.sh" || true
    exit 1
  fi
fi

kubercon_ssh_opts "$node1_mgmt" "$SSH_PORT"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node1_mgmt}" \
  "bash -s -- $(printf '%q' "$PUB")" <<'EOS'
set -euo pipefail
pub="$1"
if [[ -f /etc/ssh/sshd_config ]]; then
  if ! grep -qE '^AllowTcpForwarding[[:space:]]+yes' /etc/ssh/sshd_config; then
    sed -ri 's/^#?AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    grep -qE '^AllowTcpForwarding[[:space:]]+yes' /etc/ssh/sshd_config ||
      echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    echo SSHD_TCP_FORWARDING_ENABLED
  fi
fi
umask 077
mkdir -p /root/.ssh
if [[ ! -f /root/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa
  echo GENERATED_NODE1_ID_RSA
fi
self=$(cat /root/.ssh/id_rsa.pub)
touch /root/.ssh/authorized_keys
grep -qxF "$pub" /root/.ssh/authorized_keys || echo "$pub" >> /root/.ssh/authorized_keys
grep -qxF "$self" /root/.ssh/authorized_keys || echo "$self" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_rsa
command -v sshpass >/dev/null || {
  dnf install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null ||
    apt-get install -y sshpass 2>/dev/null || true
}
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@127.0.0.1 hostname >/dev/null
echo NODE1_SELF_SSH_OK
EOS

failed=0
while IFS=$'\t' read -r name address internal _user _port _roles; do
  [[ "$address" == "$node1_mgmt" ]] && continue
  echo "=== peer $name address=$address internal=$internal ==="
  # inventory.address 对 peer 常为内网 IP；经 KC_JUMP_HOST ProxyCommand 访问
  target="$address"
  if probe "$target"; then
    echo "PEER_OK $name (deploy-key)"
  elif [[ -n "$PASSWORD" ]]; then
    echo "NOTE: $name BatchMode 失败，经 node1 密码写入公钥"
    kubercon_ssh_opts "$node1_mgmt" "$SSH_PORT"
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node1_mgmt}" \
      "bash -s -- $(printf '%q ' "$internal" "$PUB" "$PASSWORD" "$SSH_PORT")" <<'EOS'
set -euo pipefail
peer="$1"; pub="$2"; pw="$3"; port="$4"
command -v sshpass >/dev/null || { echo "错误: node1 无 sshpass"; exit 1; }
sshpass -p "$pw" ssh -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -p "$port" "root@$peer" \
  "umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; grep -qxF '$pub' .ssh/authorized_keys || echo '$pub' >> .ssh/authorized_keys; chmod 600 .ssh/authorized_keys"
EOS
    then
      echo "PEER_FAIL $name (password write)"
      failed=1
      continue
    fi
    probe "$target" || { echo "PEER_FAIL $name (after password)"; failed=1; continue; }
    echo "PEER_OK $name (password→key)"
  else
    echo "PEER_FAIL $name — 云控制台贴公钥，或设 KC_SSH_BOOTSTRAP_PASSWORD"
    failed=1
    continue
  fi
  # node1 id_rsa.pub → peer（kk 从 node1 连 peer）
  kubercon_ssh_opts "$node1_mgmt" "$SSH_PORT"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node1_mgmt}" \
    "bash -s -- $(printf '%q' "$internal")" <<'EOS' || true
set -euo pipefail
peer="$1"
self=$(cat /root/.ssh/id_rsa.pub)
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$peer" \
  "umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; grep -qxF '$self' .ssh/authorized_keys || echo '$self' >> .ssh/authorized_keys; chmod 600 .ssh/authorized_keys"
EOS
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)

(( failed == 0 )) || {
  echo
  "$SCRIPT_DIR/print-bootstrap-pubkey.sh" || true
  exit 1
}
echo "MULTINODE_SSH_BOOTSTRAP_OK node1=$node1_mgmt"
