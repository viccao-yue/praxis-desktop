# kubercon-deploy 命令与参数参考

配合 `SKILL.md` 使用。IP、密码、版本均为占位符。

## 1. 开场参数表（复制给用户填）

| 项 | 示例 | 现场值 |
| --- | --- | --- |
| 模式 | A 单节点 / B 3CP+N worker / C 已有 K8s | |
| node1 IP / 主机名 | 10.10.10.11 / node1 | |
| node2 / node3 | （B 必填） | |
| SSH 用户 / 端口 / 密钥或 Host 别名 | root / 22 / ~/.ssh/id_rsa | |
| 控制面入口 | 无 VIP / VIP+kube-vip / 外部 LB | |
| OS 与架构 | openEuler 22.03 / x86_64 | |
| 安装器（探测后填写） | ./kc 或 ./kk | |
| 离线包文件名 | kubercon-offline-….tar.gz | |
| K8s 版本 | v1.28.15 | |
| Pod CIDR / Service CIDR | 10.233.64.0/18 / 10.233.0.0/18 | |
| 是否允许关防火墙/SELinux | 是/否 | |
| 镜像仓库策略 | --with-registry 本机 / 已有 Harbor | |
| License | 有已签名 .lic / 稍后上传 | |
| 规格实测 | `nproc` / `free -b` / `df`（不以控制台口头值为准） | |

## 1.1 模式 A 最小介质清单

| 文件 | 必需 |
| --- | --- |
| `kk*` / `kc*` 安装器 | 是 |
| `kubercon-offline-*.tar.gz` + `.sha256` | 是 |
| `kubercon-installer.yaml` + `cluster-configuration.yaml` | 无 `--with-kubercon` 时是 |
| `local-path-storage.yaml` | 单节点首过保证必需（裸集群默认无 SC） |

**禁止**照抄下载中心 `config-sample.yaml` 的他人 IP / Harbor 密码。

## 2. 本机 SSH 约定

```bash
export KC_SSH_USER=root
export KC_SSH_PORT=22
export KC_SSH_KEY=~/.ssh/id_rsa
export KC_NODE1=<ip>
export KC_NODE2=<ip>   # 可选
export KC_NODE3=<ip>   # 可选
export KC_REMOTE_DIR=/opt/kubercon
export KC_MEDIA_DIR=/path/to/media
```

多节点 v1.6 不再使用 `KC_NODE2/KC_NODE3` 作为事实源：

```bash
cp templates/inventory-multinode.json ./inventory.json
export KC_INVENTORY_FILE=$PWD/inventory.json
./scripts/inventory.py --inventory "$KC_INVENTORY_FILE" validate
```

`external-prod` 还必须在 inventory 中填写外部 LB `apiAddress`、匿名只读 Harbor、各节点已有的 `registryCAPath`、目标 `storageClass` 和离线 `storageBootstrapManifest`。

```bash
# 单节点探测
ssh -i "$KC_SSH_KEY" "${KC_SSH_USER}@${KC_NODE1}" 'uname -m; cat /etc/os-release | head -5; nproc; free -h; df -h /'

# 公钥引导（密码 SSH 不可靠时）
./scripts/print-bootstrap-pubkey.sh

# 传大包前本机探测 PROFILE（强烈推荐）
./scripts/detect-installer-local.sh

# 分相传输：light=kk+yaml；heavy=离线大包（可续传；公有云 1～3h）
KC_TRANSFER_PHASE=light ./scripts/rsync-offline.sh
KC_TRANSFER_PHASE=heavy ./scripts/rsync-offline.sh
```

同 IP 重建虚机若 `HOST IDENTIFICATION HAS CHANGED`：取得用户 `确认 D9H` 后再 `ssh-keygen -R <IP>`（禁止静默）。

三节点：在 node1 上配置到 node2/node3 的免密（须用户回复 `确认 D9`）：

```bash
# 仅当 /root/.ssh/id_rsa 不存在时生成
ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa
ssh-copy-id root@<node2>
ssh-copy-id root@<node3>
ssh root@<node2> hostname
ssh root@<node3> hostname
```

## 3. 系统准备（每台节点；需确认 D2/D3）

### 3.1 依赖

```bash
# RHEL 系 / 麒麟 / openEuler（包名是 conntrack-tools，命令名才是 conntrack）
# tar/gzip/unzip/which 为硬性依赖：缺 tar 会导致 init registry 中途失败
yum install -y socat conntrack-tools ebtables ipset chrony screen tar gzip unzip which rsync python3 curl
# Debian 系
apt-get install -y socat conntrack ebtables ipset chrony screen tar gzip unzip rsync python3 curl
```

`python3` / `curl` 为硬性依赖：`fix-registry-containerd`、watchdog、`apply-platform-after-k8s` 都需要。
无外网时，只有制品明确包含匹配该 OS 的 artifact 仓库才运行 `init os --artifact`。  
`init os` 没有 `--with-packages` 参数；该参数只属于部分 `create cluster` 实现。麒麟制品没有匹配 ISO 时按现场制品说明人工补依赖，并跳过 `init os`。

### 3.2 POC 常用系统调整

```bash
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config 2>/dev/null || true
systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true
systemctl stop ufw 2>/dev/null || true; systemctl disable ufw 2>/dev/null || true
swapoff -a
# 只注释 swap 挂载行，不要 sed '/swap/d' 误删注释
# 云厂商独立 SWAP 盘（lsblk 类型 SWAP）也要 swapoff；fstab 注释后复查 lsblk
sed -i.bak '/^[^#].*swap/s/^/#/' /etc/fstab
```

hosts（单节点示例；三节点写全三台 IP，**三台文件内容一致**）。  
公有云双地址：hosts / `docker.kubercon.local` 用**内网 IP**；config 里 `address` 可为公网，`internalAddress` 必须内网。

```text
172.31.0.2 node1
172.31.0.2 docker.kubercon.local
# 三节点再加 node2/node3；docker.kubercon.local 指向 registry 所在节点（通常 node1）
```

```bash
cat >> /etc/sysctl.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF
sysctl -p
modprobe br_netfilter; modprobe overlay
systemctl enable chronyd --now 2>/dev/null || systemctl enable chrony --now 2>/dev/null || true
```

### 3.3 多节点数据盘（full 门禁硬性要求，D1）

常见挂载（盘符以 `lsblk` 为准，**禁止猜盘**）：

| 挂载点 | 用途 |
| --- | --- |
| `/var/lib/containerd` | 容器镜像 |
| `/var/lib/etcd` | etcd |
| `/var/openebs/local` | 本地存储 |

格式化前必须与用户确认盘符无系统盘。

## 4. 生成与改写 config.yaml

```bash
cd /opt/kubercon
# PROFILE=native-kubercon:
$INSTALLER create config --filename config.yaml --with-kubernetes v1.28.15 --with-kubercon
# PROFILE=kk-artifact-then-cc（V22.6 下载中心真实路径，无 --with-kubercon）:
$INSTALLER create config --filename config.yaml --with-kubernetes v1.28.15
# 必须显式 --filename；源码默认会写到二进制目录的 config-sample.yaml
```

规则：

- 先 `detect-installer-local.sh` / `detect-installer.sh`，记录 `INSTALLER`、`PROFILE`、`REGISTRY_MODE`
- **`PROFILE=native-kubercon` 或 `kk-artifact-then-cc` 均可继续**；禁止用 `--with-kubesphere` 冒充平台
- D4 后必须通过：`KC_PROFILE=... ./scripts/validate-cluster-config.sh`
- V22.6 separate 必改：`namespaceOverride: "kubercon"`、`insecureRegistries: []`、公网/内网分栏
- `apiVersion` / 角色字段名（`control-plane` vs `master`）**以生成结果为准**
- **`etcd.type` 必须是 `kubekey`**。写成 `kubercon` 会跳过 etcd 安装
- 密码含特殊字符必须用双引号
- 缩进空格、不用 Tab
- 网段不与业务网、IPMI 冲突
- 多节点禁止人工改 config 开装；以 inventory + `prepare-multinode-config.sh` 为准

多节点固定 3 control-plane/etcd，worker 可扩展：

| 项 | 单节点 | 多节点 v1.6 |
| --- | --- | --- |
| hosts | 1 | 3CP + 0..N 纯 worker |
| etcd / control-plane | node1 | 必须且只能是同一组 3 节点 |
| worker | node1 | 至少 1 个；控制面可兼任 |
| registry | node1 | local profile 仅首个 CP；external-prod 无 registry role |
| VIP / LB | address 空 | `local-haproxy` / `local-kube-vip` / `external-prod` |
| etcd.type | `kubekey` | `kubekey` |
| namespaceOverride | `kubercon` | `kubercon` |
| insecureRegistries | `[]` | `[]` |

## 5. 安装命令（仅安装节点）

```bash
cd /opt/kubercon
export INSTALLER=./kk     # detect-installer.sh 的探测结果
export OFFLINE=kubercon-offline-<版本>-amd64.tar.gz
export KC_PROFILE=kk-artifact-then-cc   # V22.6 下载中心；有 --with-kubercon 则用 native-kubercon
export KC_REGISTRY_MODE=separate        # V22.6 本机仓；勿抄旧文档的 inline
sha256sum -c "${OFFLINE}.sha256sum"   # 或同名 .sha256sum 文件

# 模式 A D5：仅制品支持该 OS 时
$INSTALLER init os --filename config.yaml --artifact "$OFFLINE"

# D4 后 / D6R 前：
KC_PROFILE="$KC_PROFILE" ./scripts/validate-cluster-config.sh

# REGISTRY_MODE=separate 时，确认 D6R 后：
KC_INSTALLER="$INSTALLER" KC_OFFLINE="$OFFLINE" \
KC_CONFIRMED_D6R='确认 D6R' ./scripts/start-init-registry.sh

# D6：须显式 PROFILE + REGISTRY_MODE；脚本会 validate + fix(containerd) + watchdog
KC_INSTALLER="$INSTALLER" KC_OFFLINE="$OFFLINE" \
KC_PROFILE=kk-artifact-then-cc KC_REGISTRY_MODE=separate \
KC_CONFIRMED_D6='确认 D6' ./scripts/start-create-cluster.sh

# 轮询状态与日志
./scripts/ssh-run.sh --node1 -- \
  'cat /tmp/kubercon-create.status; tail -n 30 /tmp/kubercon-create.log'

# PROFILE=kk-artifact-then-cc 且 K8s Ready 后：
KC_AUTONOMOUS=1 ./scripts/apply-platform-after-k8s.sh   # 或确认 D8I+D8C
```

脚本会用已探测的 `--yes` 跳过安装器内部交互，但前提是外层已取得编号确认。  
成功标志必须精确为：`Pipeline[CreateClusterPipeline] execute successfully`（`Pipeline` 后没有空格），且状态文件为 `SUCCESS`。

**已有独立 Harbor、不要本机 registry 时**：`KC_REGISTRY_MODE=external`，并在 config / 镜像侧指向客户仓库（需用户确认）。

模式 B 不直接执行上述裸命令；必须依次使用：
`prepare-multinode-system.sh` → `prepare-multinode-config.sh` → `preflight-multinode.sh` →
`start-init-os.sh` → local profile 的 `start-init-registry.sh` → `start-create-cluster.sh`。
## 6. 已有 K8s 只装平台（模式 C）

```bash
kubectl cluster-info    # 先确认这就是目标集群
kubectl get nodes
kubectl version
kubectl get sc
kubectl get ns | grep -E 'kubercon|kubesphere' && echo '已有平台命名空间，停止并人工评估'
```

先设置精确的 `KC_EXPECT_APISERVER_HOST`、`KC_EXPECT_NODES` 并运行 `scripts/existing-k8s-preflight.sh`。  
然后核对 `templates/kubercon-installer-v22.6.0.yaml` 的镜像，确认 D8I 后 apply；等待 installer Available。  
最后修改 `templates/cluster-configuration-minimal.yaml`，确认 D8C 后 apply。  
两份修改后的文件在复制/apply 前必须通过 `scripts/validate-mode-c-manifests.sh <installer> <cc>`，禁止遗留 `REPLACE_*`。  
这两个文件随 standalone 技能包交付；只 apply CC 不会创建 installer。  
v22.06 产品默认开 DeepFlow（ClickHouse 200Gi）；轻量样例显式为 `false`。  
**不要**对已有平台集群再执行 `create cluster`。

## 7. 端口（POC 最低集）

| 端口 | 用途 |
| --- | --- |
| 22 | SSH |
| 6443 | K8s API |
| 2379-2380 | etcd |
| 10250 | kubelet |
| 4789/UDP | Calico VXLAN（本技能三节点样例） |
| 8472/UDP | Flannel VXLAN（仅选择 Flannel 时） |
| 30880 | 控制台 NodePort |
| 30000-32767 | 其他 NodePort |

三节点另需节点间互通上述端口；给客户网工的完整矩阵见运维手册附录。

## 8. 验收命令

```bash
export KUBECONFIG=/root/.kube/config
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n kubercon-system get deploy,sts
kubectl get cc -n kubercon-system
kubectl get sc
```

浏览器：`http://<node1或入口IP>:30880`  
默认账号以制品说明为准。上传已签名 `.lic` 后再演示创建企业空间。

## 9. 与生产的边界（须告知用户）

- 单节点 / 售前三节点不是生产 HA（无独立 etcd、无企业级共享存储承诺）
- 数据在本地盘；无备份方案不得按生产承诺
- 版本以当日离线包为准
