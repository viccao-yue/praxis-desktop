# 被其它脚本 source。为「只有 node1 有公网」追加跳板。
# KC_JUMP_HOST 形如 root@139.198.125.24 或 139.198.125.24
kubercon_jump_host() {
  local raw="${KC_JUMP_HOST:-}"
  raw="${raw#*@}"
  raw="${raw%%:*}"
  printf '%s' "$raw"
}

kubercon_ssh_opts() {
  local target="${1:-}"
  local port="${2:-${KC_SSH_PORT:-22}}"
  local key="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
  local user="${KC_SSH_USER:-root}"
  [[ "$key" == "~/"* ]] && key="$HOME/${key#\~/}"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
    -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -p "$port")
  [[ -f "$key" ]] && SSH_OPTS+=(-i "$key")
  local jump_host
  jump_host=$(kubercon_jump_host)
  [[ -n "$jump_host" && -n "$target" ]] || return 0
  [[ "$target" == "$jump_host" ]] && return 0
  local jump_user="$user"
  [[ "${KC_JUMP_HOST:-}" == *@* ]] && jump_user="${KC_JUMP_HOST%%@*}"
  local jump_port="${KC_JUMP_PORT:-${KC_SSH_PORT:-22}}"
  local proxy
  proxy=$(printf 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p %q' "$jump_port")
  [[ -f "$key" ]] && proxy+=" $(printf -- '-i %q' "$key")"
  proxy+=" $(printf '%q@%q' "$jump_user" "$jump_host") -W %h:%p"
  SSH_OPTS+=(-o "ProxyCommand=$proxy")
}
