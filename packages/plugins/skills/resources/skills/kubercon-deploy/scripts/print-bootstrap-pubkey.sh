#!/usr/bin/env bash
# 打印本机 SSH 公钥与云控制台粘贴说明（D9 密码登录不可靠时用）。
# 不修改任何远程状态；不执行 ssh-copy-id。
set -euo pipefail

SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"

PUB=""
if [[ -f "${SSH_KEY}.pub" ]]; then
  PUB=$(cat "${SSH_KEY}.pub")
elif [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  PUB=$(cat "$HOME/.ssh/id_ed25519.pub")
  SSH_KEY="$HOME/.ssh/id_ed25519"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  PUB=$(cat "$HOME/.ssh/id_rsa.pub")
  SSH_KEY="$HOME/.ssh/id_rsa"
fi

echo "=============================================================="
echo "  SSH 公钥引导（云控制台粘贴）"
echo "=============================================================="
echo
if [[ -z "$PUB" ]]; then
  echo "本机未找到公钥。请先生成（示例）:"
  echo "  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
  exit 1
fi

echo "使用的密钥: $SSH_KEY"
echo
echo "---- 请完整复制下面一行到云控制台「SSH 公钥 / 登录凭证」----"
echo "$PUB"
echo "---- 复制结束 ----"
echo
echo "说明:"
echo "  1. 青云等公有云：控制台改 root 密码 ≠ SSH 密码立即可用；优先写公钥。"
echo "  2. 粘贴后等 10～30 秒，再用:"
echo "       ssh -o BatchMode=yes -i $SSH_KEY root@<公网IP> 'hostname'"
echo "  3. 同 IP 重建虚机若报 HOST IDENTIFICATION HAS CHANGED:"
echo "       向用户索取「确认 D9H」后执行: ssh-keygen -R <IP>"
echo "       （禁止静默 -R）"
echo "  4. 本脚本不执行 ssh-copy-id；写 authorized_keys 属危险步骤 D9。"
exit 0
