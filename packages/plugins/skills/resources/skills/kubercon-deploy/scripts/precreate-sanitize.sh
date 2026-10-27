#!/usr/bin/env bash
# D6 前净化：去掉 init-os/registry 留下的「假残留」与会抢解析的 127.0.1.1/fe80 hostname。
# 幂等；不清理真实 etcd member/wal 或非空 kubernetes manifests。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"
INVENTORY="${KC_INVENTORY_FILE:-}"
LOCAL_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$LOCAL_KEY" == "~/"* ]] && LOCAL_KEY="$HOME/${LOCAL_KEY#\~/}"
[[ -n "$INVENTORY" && -f "$INVENTORY" ]] || { echo "错误: 请设置 KC_INVENTORY_FILE"; exit 1; }
"$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate

hosts_block=$(python3 - "$INVENTORY" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for n in d["nodes"]:
    print(f'{n["internalAddress"]} {n["name"]} {n["name"]}.cluster.local')
if d["profile"] != "external-prod":
    cp=next(n for n in d["nodes"] if "control-plane" in n["roles"])
    print(cp["internalAddress"], d["cluster"]["privateRegistry"].split(":")[0])
api = d["cluster"]["apiAddress"] or next(
    n["internalAddress"] for n in d["nodes"] if "control-plane" in n["roles"]
)
print(api, d["cluster"]["apiDomain"])
PY
)
hosts_b64=$(printf '%s\n' "$hosts_block" | base64 | tr -d '\n')

failed=0
while IFS=$'\t' read -r name address _ user port roles; do
  echo "=== precreate-sanitize node=$name ==="
  kubercon_ssh_opts "$address" "$port"
  if ! ssh "${SSH_OPTS[@]}" "$user@$address" \
    "bash -s -- $(printf '%q ' "$name" "$hosts_b64" "$roles")" <<'EOS'
set -euo pipefail
name="$1"; hosts_b64="$2"; roles="$3"

# 1) 空 kubernetes/etcd 目录：init registry / init os 可能创建空骨架，full 预检会误判「残留」
if [[ -d /etc/kubernetes/manifests ]] && [[ -z "$(ls -A /etc/kubernetes/manifests 2>/dev/null || true)" ]]; then
  if [[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal ]]; then
    rm -rf /etc/kubernetes
    echo "REMOVED_EMPTY_KUBERNETES"
  fi
fi
if [[ -d /var/lib/etcd ]] && [[ ! -d /var/lib/etcd/member && ! -d /var/lib/etcd/wal ]]; then
  rm -rf /var/lib/etcd
  echo "REMOVED_EMPTY_ETCD"
fi

# 2) hosts：managed 块置顶；去掉 127.0.1.1 / fe80 对本机 hostname 的抢占
tmp=$(mktemp)
awk '
  $0=="# BEGIN KUBERCON MANAGED" {skip=1; next}
  $0=="# END KUBERCON MANAGED" {skip=0; next}
  !skip {print}
' /etc/hosts > "$tmp"
grep -vE '^127\.0\.1\.1[[:space:]]|^fe80:' "$tmp" \
  | grep -vE '[[:space:]](node[0-9]+|'"$name"')(\.cluster\.local)?([[:space:]]|$)' \
  > "${tmp}.2" || true
{
  echo "# BEGIN KUBERCON MANAGED"
  printf '%s' "$hosts_b64" | base64 -d
  echo "# END KUBERCON MANAGED"
  cat "${tmp}.2"
} > /etc/hosts
rm -f "$tmp" "${tmp}.2"

# 3) 解析门禁：本机名与 inventory 内网 IP 必须一致
expected=$(printf '%s' "$hosts_b64" | base64 -d | awk -v n="$name" '$2==n{print $1; exit}')
got=$(getent ahostsv4 "$name" | awk 'NR==1{print $1}')
[[ -n "$expected" && "$got" == "$expected" ]] ||
  { echo "错误: $name 解析为 ${got:-空}，期望 $expected"; exit 1; }
echo "HOSTS_OK name=$name ip=$got"
EOS
  then
    failed=1
  fi
done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)
((failed == 0)) || { echo "错误: precreate-sanitize 失败"; exit 1; }
echo "PRECREATE_SANITIZE_OK"
