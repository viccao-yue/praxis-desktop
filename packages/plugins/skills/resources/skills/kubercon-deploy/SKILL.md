---
name: kubercon-deploy
description: >-
  按常青云交付规范，通过本机 SSH 远程驱动服务器，离线安装 KuberCon 容器集群（单节点 POC、3 control-plane/etcd + 任意 worker 多节点交付、已有 Kubernetes 仅装平台）。
  覆盖介质校验、系统准备、config.yaml 生成与改写、安装器探测（kc/kk）、init os、create cluster、平台验收与 License。
  当用户提到安装常青云、部署 KuberCon、kc init os、kc create cluster、kk create cluster、离线包安装、单节点/三节点 POC、已有集群装平台时使用。
  Deploy Changqingyun KuberCon clusters via SSH-driven offline install.
license: 内部使用
# 装机技能必须由人显式发起，不允许模型在无关对话里自行加载并开始装。
disable-model-invocation: true
metadata:
  author: 常青云交付与运维
  version: "1.7.0"
  keywords: "常青云,KuberCon,安装,部署,kc,kk,init os,create cluster,离线包,单节点,三节点,已有K8s,SSH"
compatibility: >-
  本机需能 SSH 到目标节点（建议 root）；目标节点为交付支持的 Linux；现场提供与 OS/架构匹配的安装器二进制与离线包。
  先探测现场到底是 ./kc 还是 ./kk 带 create cluster。已有 K8s 场景由人工 apply，Agent 只做检查与生成清单。
---

# 常青云容器云自动部署技能

在客户服务器上**按交付流程安装**常青云容器云（KuberCon）。本技能与 `kubercon-kubectl` 分工明确：

| 技能 | 时机 |
| --- | --- |
| **kubercon-deploy（本技能）** | 集群还不存在，或已有裸 K8s、要装平台 |
| **kubercon-kubectl**（同包内置） | 集群已存在，做巡检 / 排障 / 组件运维 |

权威流程以**现场离线包说明 + 安装器 `create config` 生成结果**为准。仓库里的 POC 手册仅作结构参考；与源码冲突时听源码与现场二进制。

开始前先定位并进入**当前宿主实际解压的技能根目录**，再运行 `./scripts/...`。不要写死作者电脑路径，也不要假设当前项目仓库包含本技能。

## 0. 三条硬性纪律

**1. 每个危险步骤必须按编号确认。**
用户只说「帮我全部装好 / 继续 / 是」不够。必须先打印：步骤编号、目标 IP、完整命令、影响范围；用户回复包含 **`确认 D2`** 这种编号后才执行该步。未回复对应编号前**禁止执行**。

危险步骤：关 SELinux / 防火墙、格式化数据盘、改 `/etc/fstab`、写 `config.yaml`、`init os`、`create cluster`、`delete cluster`、`ssh-copy-id`、对已有集群 apply 安装器 / ClusterConfiguration。

**2. 本机 SSH 远程驱动，安装命令只在安装节点执行。**
- 单节点：所有安装器命令在该节点执行。
- 三节点：安装器命令**只在 node1** 执行；禁止在 node2/node3 再跑一遍安装。
- 本机负责：SSH 连通、批量系统准备、把介质拷到 node1、远程触发安装与验收。

**3. 失败先留日志，禁止未确认就 delete / 重跑 create cluster。**
`create cluster` 失败或会话断开后，**禁止再执行一次安装**。先查状态文件、`screen -ls` 与日志。未与用户确认前禁止 `delete cluster`。远程安装器长任务必须进 screen；本地 rsync 不得错放进远程 screen。

## 1. 开场：选定模式并收集参数

先问清并记录（缺一项就停，不要猜）：

1. **拓扑模式**（三选一）
   - A. 单节点 POC（etcd + control-plane + worker + registry 同机）
   - B. 多节点正式交付（固定 3 control-plane+etcd，worker 0..N；inventory 驱动）
   - C. 已有 Kubernetes，只装常青云平台（**人工主导**，见第 6 节）
2. **节点清单**：IP、主机名、SSH 用户（默认 root）、端口（默认 22）、认证方式（密钥或已配置的 SSH config）。脚本为避免挂起启用 `BatchMode=yes`，**不支持交互密码**；只有密码时先由用户人工建立密钥登录（D9）。
3. **介质**：本机或节点上的安装器路径、离线包路径、`.sha256sum`；OS 发行版与架构是否与包一致
4. **版本**：Kubernetes 版本、平台版本标签（以离线包为准）
5. **网段**：是否占用 `10.233.0.0/16`；若冲突，客户给出的 Pod/Service CIDR
6. **控制面入口**：无 VIP / 有独立 VIP / 已有外部 LB（见第 5.1 节，缺这项不准写三节点 config）
7. **集群身份**：预期 API server 主机；若 kubeconfig 使用回环地址，还要先只读取得并让用户确认 `kube-system` Namespace UID
8. **License**：是否已有已签名 `.lic`
9. **组件边界**：POC 默认**不开** DevOps / Service Mesh / 全量日志。v22.06 DeepFlow 产品默认开且 ClickHouse 要 200Gi，POC 资源不够须显式确认关闭。

向用户复述参数表，确认无误后再进入预检。
**规格以实测为准**：`nproc` / `free -b` / `lsblk`，不以云控制台口头规格为准。

## 1.0 开场检查表（v1.7）

开装前口头确认，缺一项就停：

1. 云**安全组**已放通节点互访（至少 6443/2379-2380/10250/UDP 4789；关主机防火墙 ≠ SG 已通）
2. inventory 双地址：`address` 可公网 SSH，`internalAddress` 必须 VPC 内网（写入 kk 的只用内网）
3. 正式交付**禁止** `KC_ALLOW_SHARED_ROOT=1`（仅 POC 测试）
4. 同 EIP **重装/重置**后：浏览器须清该站点 Cookie（否则普通窗口像闪退，无痕只是空 cookie）
5. 长任务中断后用 `./scripts/resume-from-status.sh` 看 NEXT，勿盲重跑 create

## 1.1 模式 A 单节点快路径（减少总耗时）

POC 现场最大浪费来自：**先传 11G → 再发现安装器不对**，以及 **create cluster 首轮必败再 D7 重来**。按下面顺序执行：

```text
D9 密钥可达
  → hardware 预检（规格不足可先 light 传，后扩容）
  → 本机 detect-installer-local（确认 PROFILE，零传输成本）
  → rsync light（kk + yaml + sha256，数秒～数分钟）
  → D2/D3（依赖必须含 tar gzip unzip which screen python3 curl）
  → rsync heavy（11G，公有云 1～3h，可续传）
  → 远端 detect-installer 复核
  → D4 prepare-single-node-config（四角色同机，公网/内网分栏）+ validate
  → D5 init os（如适用）
  → D6R init registry → SUCCESS
  → D6 create（脚本自动 fix-registry + watchdog）→ SUCCESS
  → apply-platform-after-k8s（PROFILE=kk-artifact-then-cc）
  → accept-check → 控制台 :30880
```

密钥不通时先跑 `./scripts/print-bootstrap-pubkey.sh`，用云控制台粘贴公钥（不要死磕密码 SSH）。

## 2. SSH 工作模型与脚本

```bash
export KC_SSH_USER=root
export KC_SSH_PORT=22
export KC_NODE1=10.10.10.11
# 三节点时再设 KC_NODE2 / KC_NODE3
export KC_SSH_KEY=~/.ssh/id_rsa
export KC_REMOTE_DIR=/opt/kubercon
```

不要把密码写进技能文档或长期聊天记录。跳板机场景让用户先在 `~/.ssh/config` 配好 `ProxyJump`，并把 `KC_NODE1` 设成对应 Host 别名；所有脚本只做非交互密钥登录，失败立即退出。

优先跑只读脚本（相对本技能根目录）：

```bash
KC_PREFLIGHT_PHASE=hardware ./scripts/preflight-ssh.sh  # A/B 挂盘前
# D1 挂盘和 D2/D3 系统准备后：
KC_PREFLIGHT_PHASE=full ./scripts/preflight-ssh.sh      # A/B 最终门禁
# 传大包前（本机介质目录，强烈推荐）:
KC_MEDIA_DIR=/path/to/media ./scripts/detect-installer-local.sh
./scripts/detect-installer.sh       # 远端复核
./scripts/accept-check.sh           # 装完验收，默认 SSH 到 node1
./scripts/existing-k8s-preflight.sh # 仅模式 C；不要对已有 K8s 跑裸机预检
```

`accept-check.sh` **默认不使用本机 kubeconfig**，避免连到另一个集群还报验收通过。只有用户明确要求时才设 `KC_ACCEPT_LOCAL=1`。

## 2.1 安装器二进制探测（A/B 必做；大包传输前做一次）

运维用的 `kc`（kubectl 插件）**没有** `init os` / `create cluster`。离线包里的 `./kc` 才可能是安装器；有的现场二进制叫 `kk`。同名或同子命令仍不代表兼容。

**下载中心文件名 `kk-linux-amd64` ≠ 一定带 `--with-kubercon`。** V22.6.0 实测只有 `--with-kubesphere`，但同目录有 `kubercon-installer.yaml` + `cluster-configuration.yaml` 时走 `kk-artifact-then-cc`，这是正常交付路径，不是失败。

```bash
# ① 本机先探（不传 11G）
export KC_MEDIA_DIR=/path/to/download-center-files
export KC_REGISTRY_STRATEGY=local   # 或 external
./scripts/detect-installer-local.sh

# ② 介质上到 node1 后再复核
./scripts/detect-installer.sh
```

### 模式 A 最小介质清单

| 必需 | 说明 |
| --- | --- |
| `kk*` 或 `kc*` | 安装器二进制 |
| `kubercon-offline-*.tar.gz` + `.sha256` | 离线大包 |
| `kubercon-installer.yaml` + `cluster-configuration.yaml` | 无 `--with-kubercon` 时必需（PROFILE=`kk-artifact-then-cc`） |
| `local-path-storage.yaml` | 单节点首过保证必需（裸集群默认无 SC） |

**禁止**直接套用下载中心 `config-sample.yaml` 里的他人 IP / Harbor 密码；模式 A 必须用 `prepare-single-node-config.sh` 生成，模式 B 才以 `create config` 为底稿人工核对。

探测脚本输出 `INSTALLER`、`PROFILE`、`REGISTRY_MODE`：

| PROFILE | 含义 | create cluster |
| --- | --- | --- |
| `native-kubercon` | 交付 fork 带 `--with-kubercon` | 带 `--with-kubercon` |
| `kk-artifact-then-cc` | V22.6 下载中心真实路径：kk 只有 KubeKey 能力，同目录有 installer+cc | **不**传 `--with-kubercon` / `--with-kubesphere`；装完 K8s 后跑 `scripts/apply-platform-after-k8s.sh` |

任一 PROFILE 都**禁止**用 `--with-kubesphere` 冒充常青云平台。`KC_AUTONOMOUS=1` 时允许跳过口头确认编号（仅用于用户明确要求全自动验收的场合）。

## 2.2 离线包传输（十几 GB，不能当成普通 scp）

离线包通常 10～20 GB。公有云跨网预期 **1～3 小时**；直接 `scp` 易断且难续传。统一用：

```bash
export KC_MEDIA_DIR=/path/to/media
export KC_NODE1=... KC_SSH_KEY=...
# 推荐：本机 detect 通过后
KC_TRANSFER_PHASE=light ./scripts/rsync-offline.sh   # kk + yaml，先完成
# … D2/D3 可与用户确认穿插 …
KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh   # 大包，可断点续传
# 或一次跑完:
./scripts/rsync-offline.sh   # phase=all
```

脚本会：远端探测/尝试安装 `rsync`、`ServerAliveInterval`、`--partial --inplace`、传完 `sha256sum -c`。

要点：

- rsync 必须在**能读取本机源文件的发起机**执行；不能放进 node1 的远程 screen。
- 断了就**重跑同一条**（`--partial` 续传），不要删掉重来。
- 校验失败即停，不要解包。
- 只有安装器二进制需要 `chmod +x`；离线包不用解压，`-a` 参数直接吃 tar.gz。
- 三节点时离线包**只传 node1**。
- 密钥失败：`./scripts/print-bootstrap-pubkey.sh` → 云控制台粘贴公钥。

## 3. 危险步骤清单（按编号确认）

每一步执行前单独确认；用户说停，立即停下并汇报已做与未做。

| 序号 | 步骤 | 为何危险 | 用户必须回复 |
| --- | --- | --- | --- |
| D1 | 格式化 / 挂载数据盘 | 可能清盘 | `确认 D1` |
| D2 | 关 SELinux / 防火墙 / swap | 改变主机安全策略 | `确认 D2` |
| D3 | 改 hostname / hosts / sysctl | 影响现网解析 | `确认 D3` |
| D4 | 覆盖写入 `config.yaml` | 错误配置会装错集群 | `确认 D4` |
| D5 | `init os` | 改多台系统依赖 | `确认 D5` |
| D6R | `init registry`（仅探测为 separate） | 在 node1 创建本地镜像仓库 | `确认 D6R` |
| D6 | `create cluster` | 最长、最重；失败难回滚 | `确认 D6` |
| D7 | `delete cluster` / 重装 | 销毁集群 | `确认 D7` |
| D8I | 已有集群 apply installer CRD/RBAC/Deployment | 创建高权限控制器 | `确认 D8I` |
| D8C | 已有集群 apply ClusterConfiguration | 触发平台安装 | `确认 D8C` |
| D9 | `ssh-copy-id` 写远程 authorized_keys | 改变登录信任 | `确认 D9` |
| D10 | 绕过控制台手工写 License Secret | 可能破坏验签与历史记录 | `确认 D10` |
| D11 | 多节点逐控制面 HA 故障切换演练 | 会短暂停止单节点 kubelet/apiserver | `确认 D11` |

模式 C 不跑裸机预检、安装器探测、init os 或 create cluster；改走 `existing-k8s-preflight.sh`，并分别确认 D8I、D8C。

## 4. 模式 A：单节点 POC

1. **密钥**：不通则 `print-bootstrap-pubkey.sh` + 云控制台；同 IP 重建需 `确认 D9H` 再 `ssh-keygen -R`。
2. **挂盘前预检**：`KC_PREFLIGHT_PHASE=hardware ./scripts/preflight-ssh.sh`。规格不足可先 light 传介质，后扩容再 full。
3. **本机探测**：`KC_MEDIA_DIR=... ./scripts/detect-installer-local.sh`（确认 PROFILE 后再传大包）。
4. **light 传包** → **可选挂盘 + D2/D3**（D2 依赖必须含 `tar gzip unzip which screen python3 curl`）→ **heavy 传包**。
5. **最终预检**：`KC_PREFLIGHT_PHASE=full ./scripts/preflight-ssh.sh`；失败不得继续。
6. **远端复核**：`./scripts/detect-installer.sh`，记录 `INSTALLER` / `PROFILE` / `REGISTRY_MODE`。
7. **生成确定性单节点配置**（`确认 D4`）。不要使用 kk 默认双节点模板：
   ```bash
   export KC_PROFILE=kk-artifact-then-cc   # 以探测为准
   export KC_NODE_ADDRESS=<SSH/公网IP>           # 仅本机 SSH，不写入 kk hosts.address
   export KC_NODE_INTERNAL_ADDRESS=<内网IP>      # 写入 kk hosts.address（防 hairpin）
   export KC_LOCAL_REGISTRY=docker.kubercon.local
   KC_CONFIRMED_D4='确认 D4' ./scripts/prepare-single-node-config.sh
   # 自动 validate：hosts 恰好 1 个，四个 roleGroups 都只能是 node1
   ```
   `privateKeyPath` 必须是 **node1 上**存在的私钥；公有云必须显式区分公网与内网地址（v1.7 起 kk 侧只用内网）。
8. **系统依赖**（`确认 D5`）：有匹配 artifact 时 `init os ...`。
9. **registry + 集群**：D6R（需 `KC_PROFILE`）→ D6（预检+validate+fix+watchdog）。
10. **平台**（`kk-artifact-then-cc`）：`apply-platform-after-k8s.sh`。
11. **验收**：`accept-check.sh`；必须实际取得 200/302→`/login`，并用 CC 中 adminPassword 换取 token。写操作需正式 License（见 `references/SUCCESS-CRITERIA.md`）。

## 5. 模式 B：3 control-plane/etcd + 任意 worker

v1.6 多节点只接受 inventory 驱动，不再允许手抄 `config-three-node.yaml` 直接开装。固定 3 个 control-plane+etcd，worker 可为 0..N；至少一个节点具有 worker role。

### 5.1 三种交付 profile

| profile | API 入口 | registry | 平台存储 |
| --- | --- | --- | --- |
| `local-haproxy` | 纯 worker 上 HAProxy（无纯 worker 时各 CP 走本机 127.0.0.1:6443），`apiAddress=""` | node1 separate registry | KubeKey/OpenEBS 默认 SC |
| `local-kube-vip` | kube-vip，必须提供未占用 VIP | node1 separate registry | KubeKey/OpenEBS 默认 SC |
| `external-prod` | 预置外部 LB IP | 预置匿名只读 Harbor | 预置后端 + 离线 CSI bootstrap manifest |

外部设施由客户预置；技能只在 Harbor TLS/镜像、LB 参数和 StorageClass/PVC smoke 可机械验证时进入保证范围。

### 5.2 确定性执行流程

```bash
export KC_JUMP_HOST=root@<node1公网IP>   # 仅 node1 有公网时必须设置
export KC_INVENTORY_FILE=/path/to/inventory.json
export KC_MEDIA_DIR=/path/to/media
export KC_SSH_KEY=~/.ssh/id_rsa
export KC_PROFILE=kk-artifact-then-cc
export KC_INSTALLER=./kk
export KC_OFFLINE=kubercon-offline-<实际文件名>.tar.gz

./scripts/inventory.py --inventory "$KC_INVENTORY_FILE" validate
# 重置/首装密钥（可选密码一次性写 peer）
KC_CONFIRMED_D9='确认 D9' ./scripts/bootstrap-multinode-ssh.sh
# 同 IP 重建加: KC_CONFIRMED_D9H='确认 D9H'

KC_PREFLIGHT_PHASE=hardware ./scripts/preflight-multinode.sh

# D1 按 lsblk 人工确认并挂载；etcd 节点要求 root/containerd/etcd/openebs 四盘，
# 纯 worker 要求 root/containerd/openebs 三盘。
# 仅测试可设 KC_ALLOW_SHARED_ROOT=1，允许全部落在 /（正式交付禁止）。
KC_CONFIRMED_D2='确认 D2' KC_CONFIRMED_D3='确认 D3' ./scripts/prepare-multinode-system.sh
KC_CONFIRMED_D3='确认 D3' ./scripts/probe-multinode-network.sh
KC_TRANSFER_PHASE=light ./scripts/rsync-offline.sh
KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh
KC_CONFIRMED_D4='确认 D4' ./scripts/prepare-multinode-config.sh
KC_PREFLIGHT_PHASE=full ./scripts/preflight-multinode.sh

KC_CONFIRMED_D5='确认 D5' ./scripts/start-init-os.sh
# 轮询 /tmp/kubercon-init-os.status，必须 SUCCESS

# local-* profile 执行；external-prod 必须跳过 D6R
KC_CONFIRMED_D6R='确认 D6R' ./scripts/start-init-registry.sh
# 轮询 /tmp/kubercon-registry.status，必须 SUCCESS

KC_CONFIRMED_D6='确认 D6' ./scripts/start-create-cluster.sh
# D6 自动：重渲染 hosts.address=internalAddress → precreate-sanitize → full 门禁
# → fix（无 containerd 则跳过）→ watchdog → create；SaveKubeConfig 公网超时可自愈

KC_CONFIRMED_D8I='确认 D8I' KC_CONFIRMED_D8C='确认 D8C' \
  ./scripts/apply-platform-after-k8s.sh
# D8 自动：OpenEBS 补装、PVC nodeSelector smoke、accessTokenMaxAge、OAuth=kubercloud、expire cookie
./scripts/accept-check.sh
```

长任务中断后：

```bash
./scripts/resume-from-status.sh              # 只读看 NEXT=
KC_RESUME_EXECUTE=1 ./scripts/resume-from-status.sh   # 续跑 D6R/D6/D8（需已设 PROFILE/INSTALLER/OFFLINE）
```

`start-create-cluster.sh` 只在 node1 启动安装器，但 preflight/fix/watchdog/recover 覆盖 inventory 全部节点。任一节点失败即 aggregate 失败，禁止退化继续。

**inventory 双地址约定（v1.7）**：`address` 可写公网 EIP 供本机 SSH；`internalAddress` 必须写 VPC 内网。渲染到 kk 的 `hosts.address` **只用** `internalAddress`（单节点 `prepare-single-node-config` 同样）。否则云上 EIP:6443 hairpin 会把已 Ready 的集群误判失败。

### 5.3 恢复与 HA 交付验收

- D6 失败：保留全节点证据；`KC_CONFIRMED_D7='确认 D7' ./scripts/recover-failed-create.sh`。只有 aggregate `SUCCESS` 且 D5/D6R 指纹仍匹配，才允许重跑 D6；不要重复 D5/D6R。
- 普通验收包含：节点集合、3 etcd endpoint、3 apiserver `/readyz`、LB/VIP、全节点 CRI pull、PVC smoke、平台核心、控制台与 admin 登录。
- 正式 HA 演练：`KC_CONFIRMED_D11='确认 D11' ./scripts/ha-failover-check.sh`，逐个隔离控制面并验证 API 持续可用与节点恢复。

## 6. 模式 C：已有 Kubernetes，只装平台（人工主导）

模式 C 有独立闭环，不使用 A/B 的裸机门禁。默认只读；两次 apply 分别取得 D8I、D8C。

只读前置（不通过则停）：

```bash
export KC_EXPECT_APISERVER_HOST=<已确认的 API 主机/VIP/域名>
export KC_EXPECT_NODES=<已有集群节点数>
# API 使用 127.0.0.1/localhost 时还必须设置：
# export KC_EXPECT_CLUSTER_UID=<用户已确认的 kube-system UID>
export KC_PLATFORM_REGISTRY_HOST=<docker.changqingyun.cn 或客户 Harbor 主机>
export KC_PLATFORM_REGISTRY_PORT=<443 或现场端口>
# 没有默认 SC、但已选择有效 SC 时：
# export KC_EXPECT_STORAGE_CLASS=<必须写入 cc 的名称>
./scripts/existing-k8s-preflight.sh
```

- 已有 `kubercon-system` / `kubesphere-system` → 禁止重复硬装
- 无默认 StorageClass → 先规划存储
- 核对本集群 API server 地址，避免装到别的集群
- 镜像是否可达（`docker.changqingyun.cn` 或客户 Harbor）；离线须先导入并改 registry 字段
- v22.06 若要开 DeepFlow，确认能配出约 200Gi 的 ClickHouse PVC；POC 不够就在 cc 里显式 `deepflow.enabled: false`

交付物均在 standalone 技能包内：

1. `templates/kubercon-installer-v22.6.0.yaml`：CRD、Namespace、RBAC、installer Deployment。先核对镜像 registry/tag，与现场制品不一致就停。展示 diff，取得 `确认 D8I` 后由指定的人 apply，并等待 Deployment Available。
2. `templates/cluster-configuration-minimal.yaml`：改 registry/tag/storageClass/adminPassword/DeepFlow。展示 diff，取得 `确认 D8C` 后 apply。

两步不能颠倒；只 apply CC 不会创建 installer。禁止把旧环境整份 cc 直接 apply，也禁止以 `kc install installer` 代替这两个已审阅文件。

先对**已修改后的副本**运行机械门禁；它会拒绝 `REPLACE_*`、缺失对象、无 tag 镜像和过短密码：

```bash
./scripts/validate-mode-c-manifests.sh \
  ./kubercon-installer-v22.6.0.yaml ./cluster-configuration-minimal.yaml
```

通过后记录输出的 SHA256，再把两份小文件复制到 node1 的 `/opt/kubercon/`，核对远端 SHA256 一致。严格按以下顺序。`kubectl diff` 返回 1 表示“存在差异”，不是命令失败；但其它错误必须停止：

```bash
# 只读预览后展示给用户
./scripts/ssh-run.sh --node1 -- \
  'kubectl diff -f /opt/kubercon/kubercon-installer-v22.6.0.yaml; rc=$?; test $rc -eq 0 -o $rc -eq 1'

# 用户回复「确认 D8I」后才能执行
./scripts/ssh-run.sh --node1 -- \
  'kubectl apply -f /opt/kubercon/kubercon-installer-v22.6.0.yaml && kubectl -n kubercon-system rollout status deploy/kubercon-installer --timeout=10m'

# 修改并预览 CC；用户回复「确认 D8C」后才能执行
./scripts/ssh-run.sh --node1 -- \
  'kubectl diff -f /opt/kubercon/cluster-configuration-minimal.yaml; rc=$?; test $rc -eq 0 -o $rc -eq 1'
./scripts/ssh-run.sh --node1 -- \
  'kubectl apply -f /opt/kubercon/cluster-configuration-minimal.yaml'
```

跟踪（apply 之后，只读）：

```bash
kubectl -n kubercon-system get deploy,pod
kubectl -n kubercon-system logs -l app=kubercon-installer --tail=100
```

已有集群**不要**再跑 `create cluster`。

## 7. 验收标准

```bash
# 默认 SSH 到 node1，不要用本机另一个 kubeconfig
./scripts/accept-check.sh
```

通过条件：

1. 约定节点全部 `Ready`
2. 无持续的 `ImagePullBackOff` / `CrashLoopBackOff`
3. `kubercon-system` 中 `kubercon-apiserver`、`kubercon-controller-manager`、`kubercon-ui`、`kubercon-installer` 就绪（**不要猜成 ks-***）
4. 浏览器可打开 `http://<入口IP>:30880`，默认账号以离线包说明为准，首次登录后改密
5. 上传已签名 License 后，才能稳定做创建企业空间等写操作

向用户说明：单节点不是 HA；多节点只有 D11 通过才能声明控制面 HA，`external-prod` 还依赖客户外部 LB/Harbor/共享存储 SLA；未签 License 不代表平台写功能可用。

### 7.1 License 上传

平台装完是**未授权**状态，创建企业空间这类写操作会被拦。License 存放在 Secret `kubercon-system/kubercon-license`（类型 `kubercloud.com/license`，键 `license` / `license.file` / `license.history`），**没有 License CRD**。

**首选让用户在控制台页面上传**（平台设置 → 许可证）。原因有两个：签名校验、`license.history` 的追加逻辑都在 apiserver 里，手工改 Secret 容易写出一个格式对但验签不过的值，排查起来比重新上传贵得多。

Agent 在这一步只做三件事：

```bash
# 1. 看当前有没有 License（只读）
./scripts/ssh-run.sh --node1 -- \
  'kubectl -n kubercon-system get secret kubercon-license -o jsonpath="{.type}{\"\n\"}" 2>/dev/null || echo "无 license secret"'

# 2. 用户在打开控制台的本机浏览器选择本机 .lic 上传。
#    不需要先 scp 到 node1；不要 cat 文件内容或贴进聊天记录。

# 3. 上传后复验（只读，只看三个 key 是否齐全、不解码）
./scripts/ssh-run.sh --node1 -- \
  'for jp in "{.data.license}" "{.data.license\\.file}" "{.data.license\\.history}"; do test -n "$(kubectl -n kubercon-system get secret kubercon-license -o jsonpath="$jp")" || exit 1; done; echo "license 三个 key 齐全"'
```

**禁止** Agent 自己 `kubectl create secret` / `patch` 去塞 License，也禁止把 `kubercon-private`（存密钥材料）的内容打印出来。用户明确要求绕过控制台手工写入时，先说明验签和历史记录风险，并按 `确认 D10` 处理。

## 8. 失败处理原则

1. 保留完整日志；说明卡在哪一步。
2. 对照 `references/TROUBLESHOOTING.md`。
3. 有残留或半装集群：停 + 收日志 + 转人，不要自动重装。
4. **不要**自动 `delete cluster`。
5. 平台已部分起来时，改用 `kubercon-kubectl` 做只读巡检。

## 9. 禁止事项

- 禁止手装 Docker / kubeadm 旁路安装器
- 禁止把 Kubernetes 版本改成客户随口说的版本
- 禁止在 8C16G POC 上默认开启 DevOps + Istio + 全量日志 + DeepFlow 200Gi
- 禁止把客户密码、License 私钥贴进可外传日志
- 禁止未确认就重装、删集群、或对半装集群再跑 `create cluster`
- 禁止在 node2/node3 重复执行安装
- 禁止把 `etcd.type` 写成 `kubercon`
- 禁止用本机随便一份 kubeconfig 做验收

## 10. 配套文件

| 路径 | 用途 |
| --- | --- |
| `references/SUCCESS-CRITERIA.md` | **安装成功保证口径**（审计必读） |
| `scripts/prepare-single-node-config.sh` | D4 确定性生成单节点 config（四角色同机） |
| `scripts/patch-cluster-config.sh` | 旧/三节点配置字段补丁；不能替代拓扑门禁 |
| `references/TROUBLESHOOTING.md` | 按现象排障 |
| `templates/config-single.yaml` | 单节点样例（etcd.type=kubekey） |
| `templates/config-three-node.yaml` | 三节点样例 |
| `templates/inventory-multinode.json` | v1.6 多节点唯一配置事实源样例 |
| `templates/cluster-configuration-minimal.yaml` | 模式 C 轻量 cc（DeepFlow 默认关） |
| `templates/kubercon-installer-v22.6.0.yaml` | 模式 C installer CRD/RBAC/Deployment |
| `scripts/preflight-ssh.sh` | 预检门禁 |
| `scripts/inventory.py` | 多节点 inventory 校验、规范化、指纹与 config 渲染 |
| `scripts/preflight-multinode.sh` | 全节点硬件/磁盘/SSH/DNS/registry 门禁 |
| `scripts/probe-multinode-network.sh` | D3 临时监听并验证 TCP 6443/2379/2380/10250 与 UDP 4789 全互通 |
| `scripts/prepare-multinode-system.sh` | D2/D3 全节点系统与 hosts 幂等准备 |
| `scripts/bootstrap-multinode-ssh.sh` | D9 密钥/跳板/peer 引导（含 D9H） |
| `scripts/resume-from-status.sh` | 按远端 status 诊断/续跑下一阶段 |
| `scripts/precreate-sanitize.sh` | D6 前净化空 kubernetes/etcd 骨架与 hosts 抢解析 |
| `scripts/prepare-multinode-config.sh` | D4 确定性生成 3CP+N worker config |
| `scripts/start-init-os.sh` | D5 全节点 init os screen 状态机 |
| `scripts/detect-installer-local.sh` | **传大包前**本机探测 PROFILE |
| `scripts/detect-installer.sh` | 远端 kc / kk 探测复核 |
| `scripts/print-bootstrap-pubkey.sh` | 云控制台粘贴公钥文案 |
| `scripts/rsync-offline.sh` | light/heavy 分相传输 + sha256 |
| `scripts/ssh-run.sh` | 批量远程执行 |
| `scripts/accept-check.sh` | 安装验收（含控制台 HTTP + admin 真实登录） |
| `scripts/start-init-registry.sh` | separate registry 一次性后台启动（D6R；检查 tar） |
| `scripts/validate-cluster-config.sh` | D6R/D6 前校验 namespaceOverride / insecureRegistries 等 |
| `scripts/fix-registry-containerd.sh` | 修正 HTTPS / config_path / pause（D6 默认不改 config） |
| `scripts/watch-containerd-registry.sh` | D6 期间对抗 kk 重写 containerd |
| `scripts/stop-containerd-watch.sh` | D6 启动异常或恢复前停止遗留 watchdog |
| `scripts/reset-registry-attempt.sh` | 仅归档并重置 FAILED 的 D6R 状态 |
| `scripts/recover-failed-create.sh` | 确认 D7 后清理半装（含 etcd 存在判定物） |
| `scripts/start-create-cluster.sh` | create cluster（separate+kk-artifact 自动 fix + watchdog） |
| `scripts/apply-platform-after-k8s.sh` | PROFILE=`kk-artifact-then-cc`：装平台 |
| `scripts/ha-failover-check.sh` | D11 逐控制面 HA 故障切换演练 |
| `scripts/render-platform-config.py` | 可测试的 V22.6 CC 结构化渲染器 |
| `scripts/existing-k8s-preflight.sh` | 模式 C 只读门禁 |
| `scripts/validate-mode-c-manifests.sh` | 模式 C apply 前占位符/结构门禁 |
| `CHANGELOG.md` | 版本变更 |

模式 A/B：参数确认 → hardware 预检 → **本机 detect** → light 传 → D1/D2/D3 → heavy 传 → full 预检 → 远端 detect → D4…D6 →（kk-artifact 则平台 apply）。
模式 C：参数确认 → `existing-k8s-preflight.sh` → D8I → 等 installer Available → D8C。
两套门禁禁止混用。
