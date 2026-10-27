# kubercon-deploy · 常青云容器云自动部署技能

给豆包、WorkBuddy、Claude Code、Cursor 等 Agent 使用：按交付规范，**本机 SSH 远程驱动**服务器，执行常青云（KuberCon）离线安装。

**当前版本：1.7.0**（见 `CHANGELOG.md`；成功口径见 `references/SUCCESS-CRITERIA.md`）

发布状态：**field-validated**（青云 `local-haproxy` 3 节点重置首装 + 平台验收已通过）。完整 **delivery-certified** 仍须真实环境完成 D7 恢复演练与 D11 HA。

## 与 kubercon-kubectl 的分工

| 技能 | 做什么 |
| --- | --- |
| **kubercon-deploy** | 装集群 / 在已有 K8s 上装平台 |
| **kubercon-kubectl**（可选外部技能） | 集群已存在后的巡检与排障，不随本包提供 |

## 覆盖模式

1. **单节点 POC** — 本机先探测 PROFILE → 分相传包 → 两阶段预检 → D6R/D6（自动修 registry）→ 平台 apply
2. **多节点正式交付** — 固定 3 control-plane/etcd + 任意 worker；inventory 驱动 local-haproxy、local-kube-vip、external-prod
3. **已有 Kubernetes 只装平台** — 独立预检，分两次确认 apply 随包 installer manifest 与 cc

## 1.7 首过与省时间要点

1. **传 11G 之前**跑 `detect-installer-local.sh`（确认 `native-kubercon` 或 `kk-artifact-then-cc`）
2. **`rsync-offline.sh`**：`light` → `heavy`（去重、可续传、失败重试、sha256 失败删坏包）
3. **多节点先** `bootstrap-multinode-ssh.sh`（跳板 forwarding + peer 密钥）
4. **D2 依赖含** `tar gzip unzip which screen`；无外网 peer 靠 `rpms-min`
5. **D6 自动** sanitize + fix/watchdog；中断后 `resume-from-status.sh`
6. kk **hosts.address 只用 internalAddress**（单节点/多节点一致）
7. 平台验收含 expire cookie；同 EIP 重装提醒清浏览器 Cookie
8. 多节点统一 inventory；禁止手抄拓扑开装
9. containerd/fix/watchdog/recover 覆盖全部节点

## 安全设计

- **每个危险步骤**须用户回复步骤编号（如 `确认 D6`），只说「继续」不够
- 脚本默认**只读**（预检 / 探测 / 验收）；验收默认 SSH 到 node1，避免连错集群
- A/B 预检分 `hardware`（挂盘前）与 `full`（挂盘后），避免标准三盘拓扑死锁
- 模式 C 使用独立预检，不会把已有 kubelet 当残留
- 验收是**闭合判定**：查不到数据算不通过并以退出码 1 结束
- 后台启动器要求环境中存在字面量 `确认 D6`（或 `KC_AUTONOMOUS=1`）
- 禁止未确认重装；失败或断线后禁止再跑 `create cluster`
- `disable-model-invocation: true`：装机必须由人显式发起

## 目录

```text
kubercon-deploy/
├── SKILL.md
├── README.md
├── CHANGELOG.md
├── notes/                          # 现场问题回写（发版输入）
├── references/
│   ├── REFERENCE.md
│   └── TROUBLESHOOTING.md
├── templates/
│   ├── config-single.yaml
│   ├── config-three-node.yaml
│   ├── cluster-configuration-minimal.yaml
│   └── kubercon-installer-v22.6.0.yaml
└── scripts/
    ├── preflight-ssh.sh
    ├── preflight-multinode.sh
    ├── probe-multinode-network.sh
    ├── inventory.py
    ├── prepare-multinode-system.sh
    ├── prepare-multinode-config.sh
    ├── start-init-os.sh
    ├── detect-installer-local.sh   # 传大包前
    ├── detect-installer.sh
    ├── print-bootstrap-pubkey.sh
    ├── rsync-offline.sh
    ├── ssh-run.sh
    ├── existing-k8s-preflight.sh
    ├── validate-mode-c-manifests.sh
    ├── start-init-registry.sh
    ├── prepare-single-node-config.sh
    ├── fix-registry-containerd.sh
    ├── watch-containerd-registry.sh
    ├── stop-containerd-watch.sh
    ├── reset-registry-attempt.sh
    ├── recover-failed-create.sh
    ├── start-create-cluster.sh
    ├── apply-platform-after-k8s.sh
    ├── ha-failover-check.sh
    └── accept-check.sh
```

## 安装到 Agent

```bash
# 在解压目录执行；不要使用作者电脑的绝对路径
cp -R ./kubercon-deploy ~/.claude/skills/kubercon-deploy
chmod +x ~/.claude/skills/kubercon-deploy/scripts/*.sh
```

## 快速预检 / 快路径

```bash
export KC_NODE1=10.10.10.11
export KC_SSH_KEY=~/.ssh/id_rsa
export KC_MEDIA_DIR=/path/to/download-center   # 含 kk + yaml + offline

./scripts/print-bootstrap-pubkey.sh            # 密钥不通时
KC_PREFLIGHT_PHASE=hardware ./scripts/preflight-ssh.sh
./scripts/detect-installer-local.sh            # 先探 PROFILE
KC_TRANSFER_PHASE=light ./scripts/rsync-offline.sh
# D2/D3 后：
KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh
KC_PREFLIGHT_PHASE=full ./scripts/preflight-ssh.sh
./scripts/detect-installer.sh
# 装完后：
./scripts/accept-check.sh
```

## 事实来源与版本边界

本包已内置 v22.6.0 的 installer manifest 与轻量 CC。现场版本、默认密码、apiVersion 以**离线包与实际安装器探测结果**为准。

- 有 `--with-kubercon` → `native-kubercon`
- 无 `--with-kubercon` 但有 installer+cc → `kk-artifact-then-cc`（**不要**用 `--with-kubesphere` 冒充）
- 两者皆无 → **停止**，向研发要正确介质
