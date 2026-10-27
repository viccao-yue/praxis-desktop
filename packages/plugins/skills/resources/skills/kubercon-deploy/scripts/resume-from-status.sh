#!/usr/bin/env bash
# 根据 node1 上的状态文件，打印并可选执行「下一未完成阶段」。
# 解决本机 agent/SSH 长流水线中断后，远端状态已 SUCCESS 却不知从哪续的问题。
#
# 用法:
#   export KC_NODE1=... KC_SSH_KEY=... KC_INVENTORY_FILE=...  # 多节点
#   export KC_PROFILE=kk-artifact-then-cc KC_REGISTRY_MODE=separate
#   export KC_INSTALLER=./kk KC_OFFLINE=kubercon-offline-....tar.gz
#   ./scripts/resume-from-status.sh                 # 只诊断
#   KC_RESUME_EXECUTE=1 ./scripts/resume-from-status.sh   # 执行下一阶段
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INVENTORY="${KC_INVENTORY_FILE:-}"
EXECUTE="${KC_RESUME_EXECUTE:-0}"
PROFILE="${KC_PROFILE:-}"
REGISTRY_MODE="${KC_REGISTRY_MODE:-}"
INSTALLER="${KC_INSTALLER:-}"
OFFLINE="${KC_OFFLINE:-}"

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ -f "$SSH_KEY" || "$SSH_KEY" == "~/"* ]] || true
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"

remote_cat() {
  local f="$1"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "cat $(printf '%q' "$f") 2>/dev/null || true"
}

status_kind() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo absent
  elif [[ "$s" == SUCCESS* ]]; then
    echo SUCCESS
  elif [[ "$s" == RUNNING* ]]; then
    echo RUNNING
  elif [[ "$s" == FAIL* || "$s" == FAILED* || "$s" == ERROR* ]]; then
    echo FAILED
  else
    echo UNKNOWN
  fi
}

init_os=$(remote_cat /tmp/kubercon-init-os.status)
registry=$(remote_cat /tmp/kubercon-registry.status)
create=$(remote_cat /tmp/kubercon-create.status)
io_k=$(status_kind "$init_os")
rg_k=$(status_kind "$registry")
cr_k=$(status_kind "$create")

echo "=============================================================="
echo "  resume-from-status @ ${SSH_USER}@${KC_NODE1}"
echo "=============================================================="
echo "init-os:  ${io_k}${init_os:+ → }$init_os"
echo "registry: ${rg_k}${registry:+ → }$registry"
echo "create:   ${cr_k}${create:+ → }$create"
echo

next=""
hint=""

if [[ "$cr_k" == SUCCESS ]]; then
  next=d8
  hint="集群已 SUCCESS。下一阶段: apply-platform-after-k8s.sh → accept-check.sh"
elif [[ "$cr_k" == RUNNING ]]; then
  next=wait-create
  hint="create 仍在跑。轮询: cat /tmp/kubercon-create.status；看日志 /tmp/kubercon-create.log"
elif [[ "$cr_k" == FAILED ]]; then
  next=d7
  hint="create FAILED。保留证据；确认 D7 后 recover-failed-create.sh，禁止直接重跑 D6"
elif [[ "$rg_k" == SUCCESS && "$cr_k" == absent ]]; then
  next=d6
  hint="D6R SUCCESS 且尚无 create。下一阶段: start-create-cluster.sh（确认 D6）"
elif [[ "$rg_k" == RUNNING ]]; then
  next=wait-registry
  hint="registry 仍在跑。轮询 /tmp/kubercon-registry.status"
elif [[ "$rg_k" == FAILED ]]; then
  next=d6r-retry
  hint="registry FAILED。查日志后 reset-registry-attempt.sh，再确认 D6R"
elif [[ "$io_k" == SUCCESS && "$rg_k" == absent ]]; then
  if [[ -n "$INVENTORY" ]]; then
    profile=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
    if [[ "$profile" == external-prod ]]; then
      next=d6
      hint="external-prod 跳过 D6R。下一阶段: start-create-cluster.sh"
    else
      next=d6r
      hint="D5 SUCCESS。下一阶段: start-init-registry.sh（确认 D6R）"
    fi
  else
    next=d6r
    hint="D5 SUCCESS。下一阶段: start-init-registry.sh（确认 D6R）"
  fi
elif [[ "$io_k" == RUNNING ]]; then
  next=wait-init-os
  hint="init-os 仍在跑。轮询 /tmp/kubercon-init-os.status"
elif [[ "$io_k" == FAILED ]]; then
  next=d5-retry
  hint="init-os FAILED。查日志后人工处理，再确认 D5"
else
  next=from-start
  hint="尚无 D5 成功态。请从 hardware/D2/传包/D4/D5 按 SKILL 流程开始，不要盲跑 create"
fi

echo "NEXT=$next"
echo "HINT: $hint"
echo

if [[ "$EXECUTE" != "1" ]]; then
  echo "只读诊断结束。要执行下一阶段请设: KC_RESUME_EXECUTE=1"
  exit 0
fi

run_env() {
  export KC_NODE1 KC_SSH_USER KC_SSH_KEY KC_SSH_PORT KC_REMOTE_DIR
  export KC_INVENTORY_FILE="${INVENTORY}"
  export KC_JUMP_HOST="${KC_JUMP_HOST:-}"
  export KC_PROFILE="${PROFILE}"
  export KC_REGISTRY_MODE="${REGISTRY_MODE}"
  export KC_INSTALLER="${INSTALLER}"
  export KC_OFFLINE="${OFFLINE}"
  export KC_AUTONOMOUS="${KC_AUTONOMOUS:-1}"
}

case "$next" in
  d6)
    [[ -n "$PROFILE" && -n "$REGISTRY_MODE" && -n "$INSTALLER" && -n "$OFFLINE" ]] ||
      die "执行 D6 需要 KC_PROFILE / KC_REGISTRY_MODE / KC_INSTALLER / KC_OFFLINE"
    run_env
    export KC_CONFIRMED_D6="${KC_CONFIRMED_D6:-确认 D6}"
    echo "EXECUTE: start-create-cluster.sh"
    exec "$SCRIPT_DIR/start-create-cluster.sh"
    ;;
  d6r)
    [[ -n "$PROFILE" && -n "$INSTALLER" && -n "$OFFLINE" ]] ||
      die "执行 D6R 需要 KC_PROFILE / KC_INSTALLER / KC_OFFLINE"
    run_env
    export KC_CONFIRMED_D6R="${KC_CONFIRMED_D6R:-确认 D6R}"
    echo "EXECUTE: start-init-registry.sh"
    exec "$SCRIPT_DIR/start-init-registry.sh"
    ;;
  d8)
    run_env
    export KC_CONFIRMED_D8I="${KC_CONFIRMED_D8I:-确认 D8I}"
    export KC_CONFIRMED_D8C="${KC_CONFIRMED_D8C:-确认 D8C}"
    echo "EXECUTE: apply-platform-after-k8s.sh"
    "$SCRIPT_DIR/apply-platform-after-k8s.sh"
    echo "EXECUTE: accept-check.sh"
    exec "$SCRIPT_DIR/accept-check.sh"
    ;;
  wait-create|wait-registry|wait-init-os)
    echo "阶段仍在运行，无需 EXECUTE。请轮询远端 status。"
    exit 0
    ;;
  d7|d6r-retry|d5-retry|from-start)
    echo "需要人工按 HINT 处理，RESUME_EXECUTE 不会自动执行危险恢复。"
    exit 2
    ;;
  *)
    die "未知 NEXT=$next"
    ;;
esac
