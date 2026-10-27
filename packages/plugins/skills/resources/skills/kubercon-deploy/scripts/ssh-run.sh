#!/usr/bin/env bash
# 在 KC_NODE1/2/3 上执行同一条远程命令。默认只读友好；调用方须自行做危险确认。
# 用法:
#   KC_NODE1=x.x.x.x ./ssh-run.sh --all -- 'hostname'
#   KC_NODE1=x ./ssh-run.sh --node1 -- 'df -h'
#   KC_NODE1=x KC_NODE2=y ./ssh-run.sh --nodes 1,2 -- 'uname -m'
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

usage() {
  cat <<'USAGE'
在 KC_NODE1/2/3 上执行同一条远程命令。默认只读友好；调用方须自行做危险确认。
用法:
  KC_NODE1=x.x.x.x ./ssh-run.sh --all -- 'hostname'
  KC_NODE1=x ./ssh-run.sh --node1 -- 'df -h'
  KC_NODE1=x KC_NODE2=y ./ssh-run.sh --nodes 1,2 -- 'uname -m'
环境变量: KC_SSH_USER(root) KC_SSH_KEY(~/.ssh/id_rsa) KC_SSH_PORT(22)
USAGE
  exit 1
}

TARGETS=()
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --node1) TARGETS+=("${KC_NODE1:?KC_NODE1 未设置}"); shift ;;
    --node2) TARGETS+=("${KC_NODE2:?KC_NODE2 未设置}"); shift ;;
    --node3) TARGETS+=("${KC_NODE3:?KC_NODE3 未设置}"); shift ;;
    --nodes)
      shift
      IFS=',' read -r -a idxs <<< "${1:-}"
      for i in "${idxs[@]}"; do
        [[ "$i" =~ ^[123]$ ]] || { echo "错误: --nodes 只接受 1/2/3，收到 '$i'"; exit 1; }
        var="KC_NODE${i}"
        h="${!var:-}"
        [[ -n "$h" ]] || { echo "KC_NODE${i} 未设置"; exit 1; }
        TARGETS+=("$h")
      done
      shift
      ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

if [[ "$MODE" == "all" ]]; then
  TARGETS=()
  [[ -n "${KC_NODE1:-}" ]] && TARGETS+=("$KC_NODE1")
  [[ -n "${KC_NODE2:-}" ]] && TARGETS+=("$KC_NODE2")
  [[ -n "${KC_NODE3:-}" ]] && TARGETS+=("$KC_NODE3")
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "错误: 未指定目标节点"
  usage
fi

if [[ $# -eq 0 ]]; then
  echo "错误: 缺少远程命令"
  usage
fi

CMD=("$@")
FAIL=0
for host in "${TARGETS[@]}"; do
  echo "===== ${SSH_USER}@${host} ====="
  kubercon_ssh_opts "$host" "$SSH_PORT"
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "${CMD[@]}"; then
    FAIL=1
  fi
  echo
done
exit "$FAIL"
