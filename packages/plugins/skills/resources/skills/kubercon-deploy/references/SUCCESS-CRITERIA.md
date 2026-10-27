# 部署成功保证口径（给审计模型 / 交付）

技能版本：**1.7.0**

## 一句话

在**明确前置条件全部满足**时，本技能对 **V22.6.0 下载中心介质**支持两类条件性首过目标：单节点离线 POC，以及 **3 control-plane/etcd + 任意 worker** 多节点交付。多节点必须使用 inventory 与三个受支持 profile 之一。
**没有任何技能能对「任意环境、任意介质、任意网络」做绝对数学 100%**；能做的是把已知失败模式全部变成**启动前门禁失败**或**脚本内自愈**，而不是跑了两小时再炸。

现场状态（2026-09-16）：青云 `local-haproxy` 3 节点**重置后首装 + 平台验收**已通过 → 发布态 **field-validated**。完整 **delivery-certified** 仍须 D7 恢复演练 + D11 HA。

## 成功定义（安装成功 = 这些全绿）

1. `/tmp/kubercon-create.status` → `SUCCESS`
2. `kubectl get nodes` → node Ready
3. `kubercon-system` 中 apiserver / controller-manager / ui Ready
4. 节点上 `kubercon-ui` NodePort（默认 30880）本机/内网 HTTP 可达（302→/login）
5. 可用 `admin` + CC 中 `adminPassword` 登录；token 含 `expires_in`；UI `expire` cookie 有效

## 不纳入「安装成功」的外部条件

| 项 | 说明 |
| --- | --- |
| 正式 License 写操作 | 无 `.lic` 时登录可读，写操作会被拒；**不是安装失败** |
| 云安全组放通 22/30880/6443 | 节点上服务起来 ≠ 公网浏览器一定通 |
| 浏览器旧 Cookie | 同 EIP 重装后须清站点 Cookie；无痕能开 ≠ 服务端坏 |
| 密码 SSH | 技能只保证密钥 `BatchMode`；可用 `bootstrap-multinode-ssh` 一次性密码写公钥 |
| 规格不足（&lt;8C/16G/足够盘） | 预检应失败并停 |
| 介质缺 installer+cc / 离线包损坏 | detect / sha256 应失败并停（坏包会删） |
| 5 个或更多 control-plane/etcd、IPv6、混合架构 | v1.7 门禁拒绝；worker 数量不受此限制 |
| 外部 LB/Harbor/存储后端本身故障 | `external-prod` 仅验证并消费预置设施，不负责创建 |
| 模式 C | 已有 Kubernetes 的状态不可由裸机首过口径覆盖 |

## 单节点前置条件（缺一则拒绝声称首过）

1. 本机已 `detect-installer-local` → `PROFILE=kk-artifact-then-cc`（或真有 `--with-kubercon` 的 native）
2. 介质：`kk*` + `offline*.tar.gz`+sha256 + `kubercon-installer.yaml` + `cluster-configuration.yaml` + `local-path-storage.yaml`
3. SSH 密钥可达；D2 含：`tar gzip unzip which screen rsync python3 curl`
4. D4：`prepare-single-node-config.sh`；**kk hosts.address = internalAddress**（`KC_NODE_ADDRESS` 仅 SSH）
5. D6R SUCCESS 且 installer/offline **内容指纹**一致
6. D6：`KC_PROFILE` + `KC_REGISTRY_MODE=separate`；containerd CRI/watchdog；单节点 sanitize
7. 平台阶段：清单镜像改写早于 apply；默认 SC；accessTokenMaxAge；admin 登录 + expire cookie
8. 最终验收 HTTP + OAuth + expire cookie

## 多节点前置条件（v1.7）

1. inventory 通过 `inventory.py validate`：恰好 3 control-plane/etcd、至少 1 worker、节点/IP 唯一、同架构、IPv4。
2. profile 是 `local-haproxy`、`local-kube-vip` 或 `external-prod`；VIP/LB/registry/storage 字段与 profile 完全一致。
3. `bootstrap-multinode-ssh.sh`（或等价）完成 node1/peer BatchMode 与跳板 forwarding。
4. hardware/full/post-registry 三阶段 `preflight-multinode.sh` 全绿；node1 使用 inventory 私钥能真实登录所有内网节点。
5. etcd 节点独立盘（正式）；测试可用 `KC_ALLOW_SHARED_ROOT=1`（禁止交付）。
6. D5 / local profile D6R / D6 SUCCESS；长任务中断用 `resume-from-status.sh`。
7. local profile 默认 OpenEBS；平台 PVC smoke；登录硬化。
8. `accept-check.sh` 含 etcd/CP/registry/控制台/expire cookie。
9. 正式 HA：D11。未跑 D11 不得标记 delivery-certified。

## 1.7.0 相对 1.6.x 关闭的缺口

| 杀手 | 状态 |
| --- | --- |
| heavy 双 glob 传同一文件致坏包 | **1.7：basename 去重 + 字节数/sha256，失败删包** |
| 无外网 peer + `command -v chrony` | **1.7/1.6.1：chronyd + rpms-min** |
| 跳板 AllowTcpForwarding 默认关 | **1.7：prepare + bootstrap-ssh** |
| 本机流水线中断不知从哪续 | **1.7：resume-from-status.sh** |
| 单节点公网写入 kk hosts.address | **1.7：与多节点同样只用 internalAddress** |
| accept 不验 expire cookie | **1.7：与 D8 对齐** |
| 多节点公网 hairpin / sanitize / 登录 0s | **1.6.1 已修，1.7 收口** |

## 给下一任审计模型的提问清单

1. `fix-registry-containerd.sh` 在 `KC_SKIP_CONFIG_PATCH=1` 时，远端是否**真的**不改 config？
2. `start-create-cluster.sh` 是否在启动 watchdog **之前**拒绝已有 status / etcd 残留？
3. `rsync-offline` heavy 是否去重且 sha256 失败删坏包？
4. 单节点 config 的 `hosts.address` 是否等于 `internalAddress`？
5. `resume-from-status` 在 create SUCCESS 时是否导向 D8 而非重跑 create？
6. 成功口径是否把 License / 云 SG / 浏览器旧 Cookie 错误算进「安装失败」？
