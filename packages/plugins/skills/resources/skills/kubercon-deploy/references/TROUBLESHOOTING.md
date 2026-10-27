# 安装排障速查

原则：**先留日志，再改环境；未确认不 delete cluster。**

## 1. 按阶段

| 阶段 | 常见现象 | 处理方向 |
| --- | --- | --- |
| 介质 | sha256 失败 | 重新拷贝，禁止继续 |
| SSH | Permission denied / 超时 | 先 `print-bootstrap-pubkey.sh` 用云控制台粘贴公钥；密码 SSH 在公有云不可靠 |
| SSH | HOST IDENTIFICATION HAS CHANGED | 同 IP 重建；取得 `确认 D9H` 后 `ssh-keygen -R` |
| 介质 | 先传 11G 再发现 PROFILE=unsupported | **应用** `detect-installer-local.sh` 在传大包前探测 |
| 介质 | rsync: command not found（远端） | `rsync-offline.sh` 会尝试安装；无外网则离线补 rsync 或改 scp |
| 介质 | Broken pipe / Connection reset | 重跑 `rsync-offline.sh`（`--partial`）；预期公有云 1～3h |
| init registry | `tar: command not found` | D2 安装 `tar gzip`；`start-init-registry.sh` 现已启动前检查 |
| create cluster | ExistETCDHealthCheck / etcd exists | D7 须删 etcd binary/env/certs/unit，不只清 `/var/lib/etcd` |
| create cluster | CRI `Unimplemented` / mirrors+config_path | 只用 `config_path`+hosts.toml，删光 mirrors；靠 watchdog |
| 平台 | ImagePull `docker.changqingyun.cn` | `apply-platform-after-k8s.sh` 改写为本地仓 |
| init os | 缺 RPM/DEB | 离线包与 OS 不匹配；`init os` 无 `--with-packages`，按制品说明补依赖或跳过 |
| create cluster | 长时间无输出 | 先看 `/tmp/kubercon-create.status`，再看日志、CPU、磁盘；确认 screen 未断 |
| etcd | connection refused / raft 异常 | 时间同步、磁盘、2379/2380；单节点数据损坏时需专项恢复，勿盲目重装 |
| API | kubectl 连 localhost:8080 | apiserver 未起来或 kubeconfig 未导出 |
| 镜像 | ImagePullBackOff | `--with-registry`、hosts 中 `docker.kubercon.local`、私有仓认证 |
| 镜像 | `connection refused` 拉私有仓（:80） | separate registry 实际是 **HTTPS:443**；跑 `scripts/fix-registry-containerd.sh`，把 mirror 改为 `https://` 并挂 CA |
| 镜像 / sandbox | pause 拉取失败 / `kubesphere/pause` 不存在 | 仓库命名空间是 `kubercon/`；`namespaceOverride: "kubercon"` + sandbox=`.../kubercon/pause:3.9` |
| DNS | CoreDNS CrashLoop | 检查 `forward` 是否成环；可临时改为上游公共/内网 DNS |
| 控制台 | 30880 不通 | `ss -lntp`、客户防火墙、用节点 IP 而非错误 VIP |
| 授权 | 写操作 Forbidden / signature empty | 上传厂商已签名 License，禁止手改 lic |
| 资源 | 大量 Pending / OOM | 8C16G 勿开 DevOps/Istio/全量日志/DeepFlow 200Gi |
| 半装残留 | kubelet 已在跑、/etc/kubernetes 有清单 | 预检应失败；先排障，禁止再 create cluster |
| 半装残留 | etcd `INITIAL_CLUSTER_STATE=existing` + 控制面起不来 | 属 D7；确认后 `recover-failed-create.sh` → `fix-registry-containerd.sh` → 再 D6 |
| 多节点 D6 | 非 registry 节点报无 ca.pem | kk 同步证书时改名为 `ca.crt`；fix/watchdog/preflight 必须回退该路径 |
| 多节点平台 | 缺默认 OpenEBS SC | kk 用 beta 默认注解；用 `kubectl get sc` 的 `(default)` 列，不要只查非 beta 注解 |
| 多节点验收 | API 主机是 domain 不是 VIP/127.0.0.1 | kubeconfig `server` 字符串是 `controlPlaneEndpoint.domain` |
| 多节点 D4 | hosts 必须为 1、当前 3 | v1.5 旧路径；v1.6 必须设置 `KC_INVENTORY_FILE` 并运行 `prepare-multinode-config.sh` |
| 多节点 SSH | 本机三台都通，但 kk 连 node2/3 失败 | 跑 `KC_PREFLIGHT_PHASE=full preflight-multinode.sh`；它会从 node1 使用 inventory 私钥真连内网 IP |
| 多节点 registry | 只有 node2/3 ImagePull/CRI 失败 | 检查 aggregate 与各节点 watch status；v1.6 fix/watchdog 必须覆盖 inventory 全节点 |
| 多节点恢复 | aggregate=BLOCKED | 至少一台 D7 或残留复检失败；禁止重跑，逐节点查看状态 |
| external-prod 存储 | StorageClass 不出现/PVC smoke 超时 | 检查离线 CSI bootstrap manifest、控制器镜像、后端网络和指定 SC |
| HA 演练 | 隔离单控制面后 API 不可用 | LB/VIP 后端、健康检查或 HAProxy/kube-vip 配置不成立；不得 delivery-certified |
| 多节点网络 | probe TCP/UDP 失败（本机 SSH 却通） | **云安全组**未放通节点互访；关主机 firewalld≠SG 已通。至少 6443/2379-2380/10250/UDP 4789，或 VPC 网段全通 |
| 多节点 D6 | full 预检误报 kubernetes/etcd 残留 | init registry/os 留下**空**目录；D6 前跑 `precreate-sanitize.sh` |
| 多节点 D6 | hostname 解析到 `127.0.1.1` | cloud-init hosts；prepare + sanitize 去掉该行并把 managed 块置顶 |
| 多节点 D6 | create 末尾 SaveKubeConfig i/o timeout | inventory 把公网 EIP 写进了 kk `hosts.address`（hairpin）；v1.6.1 起强制 `internalAddress`；脚本有 Ready 自愈 |
| 多节点 D6 | fix/watchdog 报缺 containerd/crictl | 首次 create 前正常；应跳过硬校验，交给 create 中途 watchdog |
| 多节点平台 | OpenEBS SC 缺失 / PVC Pending | SaveKubeConfig 超时后 `--with-local-storage` 未执行；apply 补装 + smoke 用 nodeSelector |
| 控制台 | 浏览器「会话已超时」死循环 | `accessTokenMaxAge: 0s` 清空 expire cookie；改为 2h 并重启 apiserver；OAuth client 名是 **kubercloud** |
| 控制台 | **必须无痕才能开 / 普通窗口闪退** | 同 IP 留下坏 cookie：`expire=` 空 + 旧 `token` 时 GET `/` 会 **404**。清除该站点 Cookie。长任务中断用 `resume-from-status.sh`，勿盲重跑 |
| 多节点 SSH | 重置后 peer 不通 / 跳板 open failed | `bootstrap-multinode-ssh.sh`（D9/D9H）；prepare 打开 AllowTcpForwarding |
| 控制台 | UI 登录异常且无 redis | `redis.enabled=false` 时勿让 ui-config 指向 redis；apply 会改写无 redis 版 UI config |

## 2. 保留现场证据

```bash
# 安装节点（INSTALLER 为探测到的 ./kc 或 ./kk；优先看已有 screen 日志）
# 每次安装写一份带时间戳的日志，/tmp/kubercon-create.log 是指向最近一次的软链
ls -lt /tmp/kubercon-create.*.log
tail -n 200 /tmp/kubercon-create.log
cat /tmp/kubercon-create.status
# $INSTALLER create cluster ... 2>&1 | tee /tmp/kubercon-create.log   # 仅确认 D6 且无残留会话时

kubectl get nodes -o wide > /tmp/nodes.txt
kubectl get pods -A > /tmp/pods.txt
kubectl -n kubercon-system logs -l app=kubercon-installer --tail=500 > /tmp/installer.log
journalctl -u etcd -n 100 --no-pager > /tmp/etcd.log 2>/dev/null || true
journalctl -u kubelet -n 100 --no-pager > /tmp/kubelet.log
```

## 3. 配置类易错点

- 密码未加引号导致 YAML 被截断
- `apiVersion` 混用两套
- 三节点漏改 `hosts` 或 registry 写了三台
- 填了不存在的 VIP，或有 VIP 却留空 address
- `etcd.type` 写成 `kubercon`（会跳过 etcd）；只接受 `kubekey` / `kubeadm` / `external`
- 已有 Harbor 仍加 `--with-registry` 冲突
- 用运维用的 `kc`（没有 create cluster）去装集群
- 只有上游 `--with-kubesphere`、没有交付 `--with-kubercon`，却继续猜参数
- 本机 kubeconfig 指向另一个集群却当验收通过

## 4. 明确不要自动做的事

- `delete cluster`
- 对半装 / 失败现场重跑 `create cluster`
- 格式化未确认的磁盘
- 在 node2/node3 重跑安装
- apply 来路不明的整份旧 `ClusterConfiguration`
- 把客户密码贴到群聊

## 5. 半装现场怎么收场

`create cluster` 中断后最危险的动作是「再跑一遍」。安装器不是幂等的，二次执行可能在已有 etcd 数据上叠加操作，把可修复的现场变成必须重装的现场。按顺序判断：

**第一步：确认安装是否还在跑**（很多「卡住」其实是在导镜像）

```bash
./scripts/ssh-run.sh --node1 -- 'screen -ls; cat /tmp/kubercon-create.status; ls -lt /tmp/kubercon-create.*.log | head -3'
./scripts/ssh-run.sh --node1 -- 'tail -n 30 /tmp/kubercon-create.log; uptime; df -h /var/lib/containerd'
```

日志时间戳还在推进、或磁盘/CPU 在忙 → **继续等**，不要动。

**第二步：确认失败发生在哪一侧**

```bash
./scripts/ssh-run.sh --node1 -- 'grep -nE "Failed|error|fatal" /tmp/kubercon-create.log | tail -20'
```

| 日志最后停在 | 现场状态 | 处理 |
| --- | --- | --- |
| 介质校验 / 解包 | 系统基本未被改 | 修好介质，可从头开始 |
| `init os` 阶段 | 系统依赖已被改，K8s 未装 | 修掉具体报错后，可重跑 `init os`（相对安全） |
| etcd / kubeadm init | **已写入 etcd 数据** | **停**，收日志转人，禁止重跑 |
| 平台组件部署 | K8s 已就绪，只是平台没装完 | 不要重跑 `create cluster`；改用 `kubercon-kubectl` 查 installer 日志 |

**第三步：按状态选路**

- K8s 已起来（`kubectl get nodes` 有输出）→ 这已经不是部署问题，是平台组件问题，转 `kubercon-kubectl` 排障。
- etcd 有数据但集群不可用 → 收齐 `/tmp/*.log` + `journalctl -u etcd`。POC 且用户要求重装时走 `确认 D7`。
- 客户明确要求重装 / Agent 获 `确认 D7` 或 `KC_AUTONOMOUS=1` → 按序执行：
  1. `scripts/recover-failed-create.sh`（清 etcd/kubernetes 半装，**不**删 registry 与离线包）
  2. `scripts/fix-registry-containerd.sh`（HTTPS mirror + `kubercon/pause` + `namespaceOverride`）
  3. `scripts/start-create-cluster.sh`（D6）
  4. 成功后再 `apply-platform-after-k8s.sh`（PROFILE=`kk-artifact-then-cc`）

生产多节点现场：任何一条都不允许 Agent 自行决定重装；先转人。

## 6. 装完后只读巡检

若平台已部分起来，可改用独立安装的 `kubercon-kubectl` 技能（可选外部技能，不随本包提供）与：

```bash
kubercon-health-check.sh
kubercon-component.sh
```
