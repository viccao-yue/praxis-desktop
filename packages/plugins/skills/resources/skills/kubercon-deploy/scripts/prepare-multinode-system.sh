#!/usr/bin/env bash
# D2+D3：按 inventory 幂等准备所有节点的依赖、hostname、hosts、swap 与内核参数。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
INVENTORY="${KC_INVENTORY_FILE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || { echo "错误: 请设置 KC_INVENTORY_FILE"; exit 1; }
[[ "${KC_CONFIRMED_D2:-}" == "确认 D2" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: 需要 KC_CONFIRMED_D2='确认 D2' 或 KC_AUTONOMOUS=1"; exit 1; }
[[ "${KC_CONFIRMED_D3:-}" == "确认 D3" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  { echo "错误: 需要 KC_CONFIRMED_D3='确认 D3' 或 KC_AUTONOMOUS=1"; exit 1; }
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

hosts_block=$(python3 - "$INVENTORY" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for n in d["nodes"]: print(n["internalAddress"],n["name"])
if d["profile"] != "external-prod":
    cp=next(n for n in d["nodes"] if "control-plane" in n["roles"])
    print(cp["internalAddress"],d["cluster"]["privateRegistry"].split(":")[0])
print(d["cluster"]["apiAddress"] or next(n["internalAddress"] for n in d["nodes"] if "control-plane" in n["roles"]),d["cluster"]["apiDomain"])
PY
)
hosts_b64=$(printf '%s\n' "$hosts_block" | base64 | tr -d '\n')

# 有外网的首节点（通常 node1）预下载最小 RPM，并 scp 到其余节点，供无外网 dnf 失败时离线安装
{
  read -r _seed_name seed_address _ seed_user seed_port _
} < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
kubercon_ssh_opts "$seed_address" "$seed_port"
echo "NOTE: 从 $_seed_name($seed_address) 预分发最小离线 RPM（若可上网）"
ssh "${SSH_OPTS[@]}" "$seed_user@$seed_address" 'bash -s' <<'EOS' || echo "NOTE: seed 下载 RPM 跳过（可稍后由各节点在线 dnf 安装）"
set -euo pipefail
mkdir -p /opt/kubercon/rpms-min
cd /opt/kubercon/rpms-min
if ! compgen -G '*.rpm' >/dev/null; then
  dnf download tar gzip unzip which screen python3 curl rsync chrony timedatex libcurl || exit 0
fi
EOS
while IFS=$'\t' read -r name address _ user port _; do
  [[ "$address" == "$seed_address" ]] && continue
  kubercon_ssh_opts "$seed_address" "$seed_port"
  ssh "${SSH_OPTS[@]}" "$seed_user@$seed_address" \
    "bash -s -- $(printf '%q ' "$address")" <<'EOS' || true
set -euo pipefail
peer="$1"
[[ -d /opt/kubercon/rpms-min ]] || exit 0
compgen -G '/opt/kubercon/rpms-min/*.rpm' >/dev/null || exit 0
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_rsa "root@$peer" \
  'mkdir -p /opt/kubercon/rpms-min'
scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_rsa \
  /opt/kubercon/rpms-min/*.rpm "root@$peer:/opt/kubercon/rpms-min/" || true
EOS
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)

failed=0
while IFS=$'\t' read -r name address _ user port _; do
  echo "=== prepare node=$name address=$address ==="
  kubercon_ssh_opts "$address" "$port"
  if ! ssh "${SSH_OPTS[@]}" "$user@$address" \
    "bash -s -- $(printf '%q ' "$name" "$hosts_b64")" <<'EOS'
set -euo pipefail
name="$1"; hosts_b64="$2"
pkgs=(tar gzip unzip which screen python3 curl rsync)
# chrony 包提供 chronyd/chronyc，没有名为 chrony 的可执行文件
need_pkgs=0
for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || need_pkgs=1; done
command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1 || need_pkgs=1
install_offline_rpms() {
  local dir
  for dir in /opt/kubercon/rpms-min /opt/kubercon/rpms; do
    [[ -d "$dir" ]] || continue
    compgen -G "$dir/*.rpm" >/dev/null || continue
    echo "NOTE: 使用离线 RPM: $dir"
    if rpm -Uvh --nodeps --force "$dir"/*.rpm; then
      return 0
    fi
    dnf -y install --disablerepo='*' --nogpgcheck "$dir"/*.rpm && return 0
  done
  return 1
}
if (( need_pkgs == 1 )); then
  if command -v dnf >/dev/null; then
    if ! dnf install -y "${pkgs[@]}" chrony timedatex 2>/tmp/kc-pkg.err; then
      echo "NOTE: dnf 在线安装失败，尝试离线 RPM"
      install_offline_rpms || {
        echo "错误: dnf 安装依赖失败（无外网节点须先由有外网节点离线分发 RPM）。详见 /tmp/kc-pkg.err"
        exit 1
      }
    fi
  elif command -v yum >/dev/null; then
    yum install -y "${pkgs[@]}" chrony ||
      { echo "错误: yum 安装依赖失败（检查外网/镜像源）"; exit 1; }
  elif command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y tar gzip unzip screen python3 curl rsync chrony ||
      { echo "错误: apt 安装依赖失败（检查外网/镜像源）"; exit 1; }
  else
    echo "错误: 不支持的包管理器"; exit 1
  fi
fi
for p in tar gzip screen python3 curl rsync; do
  command -v "$p" >/dev/null || { echo "错误: 仍缺少 $p"; exit 1; }
done
command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1 ||
  { echo "错误: 仍缺少 chrony"; exit 1; }
hostnamectl set-hostname "$name"
# managed 块置顶；去掉 cloud-init 常见的 127.0.1.1 / fe80 hostname，避免抢解析
tmp=$(mktemp)
awk '
  $0=="# BEGIN KUBERCON MANAGED" {skip=1; next}
  $0=="# END KUBERCON MANAGED" {skip=0; next}
  !skip {print}
' /etc/hosts > "$tmp"
grep -vE '^127\.0\.1\.1[[:space:]]|^fe80:' "$tmp" \
  | grep -vE '[[:space:]]'"$name"'(\.cluster\.local)?([[:space:]]|$)' \
  > "${tmp}.2" || true
{
  echo "# BEGIN KUBERCON MANAGED"
  printf '%s' "$hosts_b64" | base64 -d
  echo "# END KUBERCON MANAGED"
  cat "${tmp}.2"
} > /etc/hosts
rm -f "$tmp" "${tmp}.2"
expected=$(printf '%s' "$hosts_b64" | base64 -d | awk -v n="$name" '$2==n{print $1; exit}')
got=$(getent ahostsv4 "$name" | awk 'NR==1{print $1}')
[[ -n "$expected" && "$got" == "$expected" ]] ||
  { echo "错误: hostname 解析为 ${got:-空}，期望 $expected"; exit 1; }
swapoff -a
sed -ri '/\sswap\s/s/^([^#])/#\1/' /etc/fstab
systemctl disable --now firewalld 2>/dev/null || true
systemctl disable --now ufw 2>/dev/null || true
if command -v setenforce >/dev/null; then setenforce 0 || true; fi
[[ ! -f /etc/selinux/config ]] || sed -ri 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
cat > /etc/modules-load.d/kubercon.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-kubercon.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
# 跳板/ProxyJump 需要 TCP forwarding；青云 openEuler 默认常关
if [[ -f /etc/ssh/sshd_config ]]; then
  if ! grep -qE '^AllowTcpForwarding[[:space:]]+yes' /etc/ssh/sshd_config; then
    sed -ri 's/^#?AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    grep -qE '^AllowTcpForwarding[[:space:]]+yes' /etc/ssh/sshd_config ||
      echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    echo "SSHD_TCP_FORWARDING_ENABLED"
  fi
fi
echo "SYSTEM_PREPARED node=$name"
EOS
  then
    failed=1
  fi
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
((failed == 0)) || { echo "错误: 至少一个节点系统准备失败"; exit 1; }
echo "MULTINODE_SYSTEM_PREPARED"
