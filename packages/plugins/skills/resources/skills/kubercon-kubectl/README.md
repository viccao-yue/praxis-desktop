# 常青云容器云 kubectl 运维技能包

给 AI Agent 用的技能包（Agent Skills 格式），让 Agent 能正确操作**常青云容器云（KuberCon）**集群，而不是把它当成原生 Kubernetes 或上游 KubeSphere。

## 内容

```
kubercon-kubectl/
├── SKILL.md                              # 主指令：纪律、命名空间地图、CRD 表、排障流程
├── README.md                             # 本文件
├── references/
│   └── REFERENCE.md                      # 命令全参考（18 节）
└── scripts/
    ├── kubercon-health-check.sh          # 平台健康巡检（含准入 Webhook 阻塞风险）
    ├── kubercon-pod-debug.sh             # 单 Pod 排障收集
    ├── kubercon-component.sh             # 组件清单/状态/日志
    ├── kubercon-tenant-inspect.sh        # 租户盘点
    ├── kubercon-deepflow-check.sh        # 链路追踪链路自检（v22.6.0+）
    └── kubercon-backup-check.sh          # 备份能力自检与容灾缺口核对
```



### 脚本全部只读

原包里的 `kubectl-deploy-update.sh`（改镜像）和 `kubectl-node-drain.sh`（驱逐节点）是写操作脚本。常青云交付规范把改镜像、节点下线列为 P0/P1 变更，需要变更单与窗口期，**不适合让 Agent 直接执行**，因此替换为两个只读诊断脚本（组件巡检、租户盘点）。

写操作的正确命令仍写在 `SKILL.md` 与 `REFERENCE.md` 里，但一律带 `--dry-run` 演练步骤和「需变更单」标注，由人决定是否执行。

## 安装

技能包放在 Agent 的 skills 目录下即可被发现。按你用的 Agent 选一处：

```bash
SRC=/Users/viccao/Documents/trae_projects/kubercon/skills/kubercon-kubectl

# Claude Code
cp -r "$SRC" ~/.claude/skills/

# Codex
cp -r "$SRC" ~/.codex/skills/

# Cursor
cp -r "$SRC" ~/.cursor/skills-cursor/
```

想让技能包跟着仓库更新走，用软链代替复制：

```bash
ln -sfn "$SRC" ~/.claude/skills/kubercon-kubectl
```

首次使用前给脚本执行权限：

```bash
chmod +x "$SRC"/scripts/*.sh
```



## 前置条件

- `kubectl`，且 kubeconfig 指向目标常青云集群
- 平台管理员或等价 RBAC 权限（Workspace、ClusterConfiguration 都是集群级资源）
- `python3`（脚本用它解析 JSON 输出）
- `kc` 可选。装了能用 `kc com` 系列命令，没装则全部退回 kubectl 等价写法



## 快速开始

```bash
cd scripts

# 1. 先确认这是常青云集群，以及版本、组件开关
./kubercon-health-check.sh

# 2. 看控制面组件（不硬编码组件名）
./kubercon-component.sh
./kubercon-component.sh --scan            # 扫近 10 分钟错误日志
./kubercon-component.sh kubercon-apiserver   # 单组件详情

# 3. 租户盘点
./kubercon-tenant-inspect.sh
./kubercon-tenant-inspect.sh <企业空间名>

# 4. Pod 排障
./kubercon-pod-debug.sh <Pod名> <项目名>

# 5. 链路追踪不出数据（v22.6.0+）
./kubercon-deepflow-check.sh

# 6. 备份与容灾能力核对（变更窗口前、客户问备份方案时）
./kubercon-backup-check.sh
```

命名空间不是默认的 `kubercon-system` 时，用环境变量覆盖：

```bash
KUBERCON_SYSTEM_NS=kubesphere-system ./kubercon-health-check.sh
```



## 事实来源

技能内容取自本仓库的实际代码与清单，不是照抄文档：


| 事实                                                               | 来源                                                                                                                                |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| API group `installer.kubercloud.com/v1alpha1`、`cc` 简称            | `kubercon-installer/deploy/kubercon-installer.yaml`                                                                               |
| ClusterConfiguration 完整字段与组件开关                                   | `kubercon-installer/deploy/cluster-configuration.yaml`                                                                            |
| `tenant`/`iam`/`devops`/`network`/`quota`/`cluster` group 与 kind | `api/*/v1alpha*/register.go`、`*_types.go`                                                                                         |
| 命名空间与工作负载名                                                       | `kubercon-installer/roles/`、`docs/kubercon-ops-manual.md` 第 1 章                                                                   |
| `kc` 命令树                                                         | `ks/README-zh.md`                                                                                                                 |
| 排障场景与红线                                                          | `docs/kubercon-ops-manual.md` 第 14、15 章、附录 A/B/C                                                                                  |
| DeepFlow 与 OTel 接入                                               | `docs/常青云容器云-链路追踪接入OTel-部署手册.md`、`kubercon-installer/roles/kubercon-deepflow/`（v22.6.0）                                           |
| License 验签、申请流程与密钥结构                                             | `kubercon-backend/pkg/models/license/`、`pkg/kapis/license/v1alpha1/register.go`、`kubercon-installer/roles/kubercon-core/license/` |
| 默认 StorageClass `local-path`                                     | `kubercon-installer/deploy/local-path-storage.yaml`                                                                               |
| 支持的 K8s 版本                                                       | `kc-installer/version/components.json`                                                                                            |
| etcd 备份脚本、systemd 单元与轮转逻辑                                        | `kc-installer/cmd/kk/pkg/etcd/templates/{backup_script.go,backup_service.go}`、`cmd/kk/pkg/etcd/module.go`                         |
| etcd 备份默认值（目录/周期/保留份数）                                           | `kc-installer/cmd/kk/apis/kubekey/v1alpha2/default.go`                                                                            |
| etcd 证书路径与 systemd 部署形态                                          | `kc-installer/cmd/kk/pkg/etcd/`，v22.5.0 实测确认 `kube-system` 下无 etcd Pod                                                            |


平台版本口径在不同材料间存在差异（运维手册基线为 v3.4.1 + K8s ≤1.26.11，v22.06 产品线配套 K8s 1.28.15，v22.6.0 安装器清单已到 1.30.3）。技能里统一要求**以现场** `kubectl version` **和** `cc` **的** `kubercon_tag` **为准**，不用文档数字反推现场。

## 维护

平台版本变更时，重点复核这几处：

1. `SKILL.md` 的命名空间地图与 CRD 表（组件改名、group 版本升级）
2. `REFERENCE.md` 第 2 节的 ClusterConfiguration 字段（新增组件开关）
3. `REFERENCE.md` 第 15 节的版本约束表与「运维影响」表
4. `kc` 命令树是否有新子命令
5. License 机制（v22.6.0 就动过一次：移除试用授权、新增 RSA 验签）
6. etcd 备份默认值（`default.go` 里的备份周期与保留份数直接决定能对客户承诺的 RPO）

复核方法：升级代码后在各模块 `git diff`，重点看 `kubercon-installer/deploy/cluster-configuration.yaml`（组件开关与默认值）、`kubercon-backend/pkg/models/license/`（授权逻辑）、`kc-installer/version/components.json`（版本矩阵）。

## 变更记录

**1.4.0** — 补齐时间同步、证书有效期、节点磁盘与 inode 三类基础设施层排障，在 v22.5.0 实测环境验证。

**时间同步：平台默认不配。** `kk` 支持 `spec.system.ntpServers` / `timezone`，但只有显式配置了 `ntpServers` 才会去动 chrony（`bootstrap/os/tasks.go` 的 `NodeConfigureNtpServer`，改写 `/etc/chrony.conf`），不配就完全不管。新增用 node lease 测偏移的方法——不用登录节点，`renewTime` 由 kubelet 每 10 秒按节点自己的时钟续期。**实测该集群偏移 +207 秒**，已超阈值。同时写明偏移的四类危害：证书 `notBefore` 校验（平台 Webhook 证书是重新部署时现签的，刚装完最容易踩）、etcd 选举与租约、跨节点审计与 span 时序、令牌 `exp` 判定。

**证书有效期：期限差异极大，不能一概而论。** 实测 apiserver 服务证书签到 **2076 年**（50 年），Webhook CA 是签发日 +10 年，而 **admin kubeconfig 的客户端证书只有 1 年**（2026-07-08 → 2027-07-08，剩 302 天）。所以本平台「证书到期」的实际含义多数是管理员 kubeconfig 过期，症状是 `kubectl` 全部 `Unauthorized` 但 Web 控制台仍能登录。

**磁盘与 inode：驱逐阈值必须从运行中的 kubelet 读。** 这一步不能省，因为代码与现场不一致——v22.6.0 的 `kk` 模板（`kubeadm_config.go`）里 `evictionHard` 只写了 `memory.available: 5%` 与 `pid.available: 10%`，而 `evictionHard` 是整体替换而非逐键合并，按该模板渲染的 kubelet 会丢掉 `nodefs.available` / `imagefs.available` / `nodefs.inodesFree`，磁盘写满与 inode 耗尽都不触发 DiskPressure、不驱逐 Pod，节点直接硬崩。但实测集群通过 `configz` 读到的是完整的四项阈值（`memory.available: 300Mi` + 三项磁盘/inode），保护是在的。两者不一致，所以规定一律以 `configz` 为准。另外 `kk` 的预检查模块不检查磁盘空间，安装阶段不会告警。

顺带修正一处存储路径错误：`local-path` 的 PV 宿主机路径实测是 **`/mnt/localfs`**，不是原文写的 `/opt/local-path-provisioner`。这个路径决定排查磁盘占用时该 `du` 哪个目录，查错会得出「磁盘没被平台占用」的错误结论。并写明本平台最危险的磁盘链条：monitoring、logging、DeepFlow ClickHouse 的 PVC 全落在这个目录、与系统盘同盘，涨起来会挤占根分区触发驱逐，而根因在平台自身的可观测组件、不在业务；单节点环境风险最高。

`kubercon-health-check.sh` 新增两节：「1c. 时间同步与证书有效期」和「6b. 节点磁盘、inode 与驱逐阈值」。后者会在 `evictionHard` 缺失磁盘/inode 项时明确报高危；`configz` 读不到时输出「无法确认，不要假设有保护」，不静默跳过。

**1.3.0** — 审核排障章节，在 v22.5.0 实测环境（192.168.20.44）逐条验证命令可用性。

修掉三条在实测集群上必然失败的命令：

1. **`kubectl -n kube-system logs deploy/kube-scheduler` 不存在。** 控制面与 etcd 一样是 systemd 二进制，既非 Deployment 也非静态 Pod，`kube-system` 下只有 `coredns`、`calico-kube-controllers`、`metrics-server`、`local-path-provisioner`。控制面日志改用 `journalctl -u kube-scheduler`。
2. **Jenkins 写成了 StatefulSet，实际是 Deployment，且有三种命名。** 代码库里 `devops-jenkins`（12 个文件）、`kubercon-jenkins`（18 个）、`ks-jenkins`（9 个）并存，实测集群跑的是 `deploy/devops-jenkins`。改为强制先探测再操作。
3. **`kc j-log` / `j-on` / `j-off` 不一定能用。** `ks/default.go` 里三条都硬编码 `deploy/kubercon-jenkins`，在 Jenkins 叫 `devops-jenkins` 的集群上直接 NotFound。原文当作可靠捷径推荐，已加警示。

新增行业标准要求但原先完全缺失的内容：

4. **准入 Webhook 排障（最大缺口）。** 实测集群有 23 个 Webhook 配置对象、38 条条目，其中 **26 条为 `failurePolicy: Fail`**（后端不可达即拒绝写操作，另 12 条为 `Ignore` 可忽略）。`users.iam.` / `cluster.` / `network.kubercloud.com` 三条共用 `kubercon-controller-manager` 作后端——它一挂，用户、集群、网络策略写操作全部 Forbidden。这是本平台「突然什么都创建不了」的头号成因，也解释了之前现场那个 `license signature verification failed` 报错的链路。新增爆炸半径对照表，并规定用 `--dry-run=server` 实测准入链，而非拼 jsonpath 反推（后者容易因路径写错得到空值、误判成后端全挂）。
5. **OOMKilled 与应用退出的区分。** 原文只说 `logs --previous`，未要求查 `lastState.terminated.reason`，而两者处置完全不同。
6. **临时容器（`kubectl debug`）。** 平台组件多为精简镜像，`exec` 会报 `executable file not found`。实测 server v1.28.15 临时容器已 GA、可用。
7. **资源卡 `Terminating` 的 finalizer 处理。** 多租户平台高频问题，并明确「先修控制器、不要直接摘 finalizer」的纪律。
8. **DNS 与 Service 连通性排查顺序。** 先看 endpoints 是否为空，再看 CoreDNS，最后才怀疑 NetworkPolicy。

`kubercon-health-check.sh` 相应新增「3b. 准入 Webhook」一节：按后端服务归组列出所有 `Fail` 策略 Webhook、标出无就绪端点的后端，并用 `--dry-run=server` 实测准入链是否通畅。凭据无 `default` 创建权限时会明确说明「无法判定」，不会误报成异常。

**1.2.0** — 补齐备份与 etcd 运维能力，在 v22.5.0 实测环境（192.168.20.44）验证。

新增 `SKILL.md`「备份与 etcd 运维」章节、`REFERENCE.md` 第 18 节，以及 `kubercon-backup-check.sh` 脚本。

核对代码后发现运维手册第 11 章有四处与实现不符，均以代码和实测为准写入技能：

1. **etcd 是 systemd 二进制服务，不是静态 Pod。** `kk` 部署的集群里 `kubectl -n kube-system get pod | grep etcd` 查不到东西，手册那套「移走 `/etc/kubernetes/manifests/etcd.yaml`」的恢复流程在现场根本执行不了。
2. **证书路径不同。** 实际在 `/etc/ssl/etcd/ssl/`，文件名带主机名（`admin-<主机名>.pem`），不是手册写的 `/etc/kubernetes/pki/etcd/server.crt`。多节点上每台命令都不一样，不能复制粘贴。
3. **备份频率与保留策略被高估。** 手册说「每 6 小时、保留 7 天」，代码默认是每天 02:00 一次、保留 5 份。这个差异直接影响能对客户承诺的 RPO。
4. **平台不含应用级备份。** 安装器 20 个角色里没有 Velero 或任何备份组件，`kc` 也无 backup 子命令。手册第 11.2 章的 Velero 是需自建的外部方案。

另修正 `REFERENCE.md` 第 12 节里「etcd（kube-system 静态 Pod 或独立部署）」的错误表述。

初稿写完后又做了一轮自查，补上三处漏写和两处过度断言：

1. **「systemd 二进制」只对默认形态成立。** `spec.etcd.type` 有 `kubekey` / `kubeadm` / `external` 三种，默认是 `kubekey`（`default.go:342`）。更要紧的是 `BackupModule` 带 `Skip: etcd.Type != kubekey`——**后两种形态下备份模块整个跳过，一份备份都没有**。原文按「一定有自动备份」写，会让人在 kubeadm 形态集群上误判。
2. `backupPeriod` **换算非线性，改了不一定生效。** `BackupTimeOnCalendar()` 对 ≥1440 的值一律返回每天 02:00（填 2880 想要两天一次，静默失败）；非 60 整数倍会被错算（填 90 得到「每小时第 30 分」，频率翻倍）。
3. **备份可能静默失败。** 脚本首行 `set -o errexit`，第一步却跑已废弃的 `ETCDCTL_API=2 etcdctl backup`。该步失败则脚本直接退出，`snapshot.db` 不生成，而 timer 是 oneshot、失败只进 `systemctl status`。所以巡检判据改成「看备份目录的实际产出时间和 `snapshot.db` 是否存在」，而不是看 timer 是否 active。
4. **快照含全部 Secret 明文。** `kk` 未配置 `EncryptionConfiguration`（代码中无相关实现）。原文只说「要外传」，没说外传的是一份等同集群全部凭据的材料——必须加密传输落盘、按管理员同级权限管控。等保/密评场景是必答项。
5. **行业标准项补齐。** 自动压缩已启用且合规（`ETCD_AUTO_COMPACTION_RETENTION` 默认 8 小时），但**碎片整理、DB 配额与** `NOSPACE` **告警解除、恢复演练**三项平台不做也没自动化，原文完全没提。另外发现平台其实自带 11 条标准 etcd 告警规则（对齐 etcd-mixin，覆盖成员存活/Leader/fsync 与 commit 延迟/DB 增长），只是被 `spec.etcd.monitoring: false` 关着——开关关闭时等于控制面存储无任何告警，这个信息比单说「监控默认关闭」有用得多。

**1.1.0** — 对齐 v22.6.0 代码，并在 v22.5.0 实测环境（192.168.20.44）验证。

修正已失效的事实：试用 License 自动创建机制已移除（`trial.go` 删除 + 新增 RSA 验签，无正式授权则写操作全部被拒）；DeepFlow 由现场单独部署改为安装器默认部署。

新增：DeepFlow 运维章节、存储章节、kapis-only group 说明（`license.` / `branding.`）、v22.6.0 版本特征判定、流式请求审计行为说明，以及 `kubercon-deepflow-check.sh` 脚本。

实跑后又修正三处（仅凭读代码会写错）：

1. `local-path` **不是** v22.6.0 新增的 SC，v22.5.0 就有，且 provisioner 是 `rancher.io/local-path`（Pod 在 `kube-system`）。v22.6.0 换成 OpenEBS LocalPV（Pod 在 `openebs`），**SC 同名但实现不同**，升级时可能两套并存争抢。
2. `deepflow-trace-bff` **不是** v22.6.0 独有，v22.5.0 现场部署环境已在运行。
3. 镜像仓库是两个独立配置：平台镜像走 `kubercon_registry`（路径本就是 `/kubercon/`），第三方镜像走 `hub_registry`（v22.6.0 才从 `/mirror/` 改为 `/kubercon/`）。原表述把两者混为一谈。

**1.0.0** — 首版，基于 v22.5.0 前后的代码与实测环境（192.168.20.44）。

---

**原作：** SkillHub `clawhub_ddevaal/kubectl` v1.0.0（MIT，作者 Dennis de Vaal）
