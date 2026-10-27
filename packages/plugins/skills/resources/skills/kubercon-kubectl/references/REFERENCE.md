# 常青云容器云 kubectl 命令参考

面向常青云容器云（KuberCon，KubeSphere v3.4.1 商业发行）的 kubectl / kc 命令全集。示例中 `<项目>`、`<企业空间>`、`<组件>` 等占位符须替换为现场实际值。

**通用原则：** 组件名与命名空间先探测再使用；写操作先 `--dry-run`；生产变更走变更单。

---

## 1. 平台探测（接手集群第一步）

```bash
# 命名空间全貌
kubectl get ns
kubectl get ns --show-labels

# 是否常青云安装器部署
kubectl -n kubercon-system get deploy kubercon-installer
kubectl get crd | grep kubercloud.com

# 平台版本
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.metadata.labels.version}{"\n"}'
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.kubercon_tag}{"\n"}'

# 平台专有 API 资源全表
kubectl api-resources --api-group=installer.kubercloud.com
kubectl api-resources --api-group=tenant.kubercloud.com
kubectl api-resources --api-group=iam.kubercloud.com
kubectl api-resources --api-group=devops.kubercloud.com
kubectl api-resources --api-group=network.kubercloud.com
kubectl api-resources --api-group=quota.kubercloud.com
kubectl api-resources --api-group=cluster.kubercloud.com

# K8s 与节点
kubectl version
kubectl get nodes -o wide
kubectl cluster-info
```

### 真实组件名清单（禁止硬编码）

```bash
# 控制面所有工作负载
kubectl -n kubercon-system get deploy,sts,ds -o wide

# 仅名字，便于脚本循环
kubectl -n kubercon-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'

# kc 视角的组件清单
kc component list -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,ENABLED:.spec.enabled,REPLICAS:.status.replicas
```

---

## 2. ClusterConfiguration（平台总配置）

`cc` = `clusterconfigurations.installer.kubercloud.com`，实例固定为 `kubercon-system/kubercon-installer`。

```bash
# 全量配置
kubectl -n kubercon-system get cc kubercon-installer -o yaml

# 组件开关一览
kubectl -n kubercon-system get cc kubercon-installer -o yaml | grep -B2 'enabled:'

# 单项查询
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.devops.enabled}{"\n"}'
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.monitoring.storageClass}{"\n"}'

# status 内容很少（实测只有 clusterId），不要指望从这里读组件调谐状态
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.status}' | python3 -m json.tool

# 判断调谐结果要看安装器日志与各组件实际就绪情况
kubectl -n kubercon-system logs deploy/kubercon-installer --tail=100
kubectl -n kubercon-system get deploy
```

**installer hook 是周期性全量调谐，不是只在 cc 变更时触发**（约 80 分钟一轮，每轮 idempotent 重放完整安装 playbook）。因此 cc 的任何一次变更都会启动一轮完整安装流程，排查 cc 类问题第一动作是看 installer 日志；同时**绝不要 apply 旧 cc 文件**，见下方「修改配置」的回滚警告。

实测 v22 环境的 `spec` 顶层键：v22.5.0 共 23 个（即下述清单去掉 `deepflow`），**v22.6.0 为 24 个，新增 `deepflow`**：`persistence`、`authentication`、`local_registry`、`kubercon_registry`、`hub_registry`、`pull_policy`、`kubercon_tag`、`etcd`、`common`、`alerting`、`auditing`、`devops`、`events`、`logging`、`metrics_server`、`monitoring`、`multicluster`、`network`、`openpitrix`、`servicemesh`、`edgeruntime`、`gatekeeper`、`terminal`、`deepflow`。`common` 下有 `core`、`redis`、`openldap`、`minio`、`monitoring`、`es`、`opensearch`、`gpu`。

CRD 定义了 `x-kubernetes-preserve-unknown-fields: true`，所以 `cc` 没有严格的字段校验——写错字段名不会报错，只是不生效。patch 后务必确认实际效果。

### spec 主要字段

| 路径 | 含义 |
| --- | --- |
| `spec.persistence.storageClass` | 平台组件默认 StorageClass，空则用集群默认 |
| `spec.authentication.adminPassword` | admin 初始密码（默认 `KuberC0n#2025`，字段为空则随机生成） |
| `spec.authentication.jwtSecret` | 多集群纳管时须与 Host 集群一致 |
| `spec.local_registry` | 私有仓库地址（离线部署必填） |
| `spec.kubercon_registry` | 平台镜像仓库，默认 `docker.changqingyun.cn/` |
| `spec.hub_registry` | 第三方镜像镜像源，v22.6.0 起默认 `docker.changqingyun.cn/kubercon/`（此前为 `.../mirror/`） |
| `spec.kubercon_tag` | 平台镜像 tag，即平台版本 |
| `spec.pull_policy` | 镜像拉取策略 |
| `spec.etcd.monitoring` / `endpointIps` / `port` / `tlsEnable` | etcd 监控接入 |
| `spec.common.core.console.port` / `type` | 控制台端口（默认 NodePort 30880） |
| `spec.common.core.console.enableMultiLogin` | 是否允许同账号多处登录 |
| `spec.common.redis` / `openldap` / `minio` | 平台中间件开关与卷大小 |
| `spec.common.monitoring.endpoint` | Prometheus 查询地址 |
| `spec.common.es.*` | Elasticsearch 日志后端（旧版默认） |
| `spec.common.opensearch.*` | OpenSearch 日志后端（新版默认，索引前缀 `whizard`） |
| `spec.common.gpu.kinds` | GPU 资源类型注册 |

### 可插拔组件开关

| 开关 | 组件 |
| --- | --- |
| `spec.alerting.enabled` | 告警策略系统 |
| `spec.auditing.enabled` | 审计日志 |
| `spec.devops.enabled` | DevOps（Jenkins + S2I/B2I） |
| `spec.events.enabled` | 事件系统 |
| `spec.logging.enabled` | 日志系统 |
| `spec.metrics_server.enabled` | metrics-server（HPA 依赖） |
| `spec.monitoring.*` | 监控栈参数（Prometheus 副本、卷、GPU exporter） |
| `spec.multicluster.clusterRole` | `host` / `member` / `none` |
| `spec.network.networkpolicy.enabled` | 网络策略 |
| `spec.network.ippool.type` | Pod IP 池（`calico` / `none`） |
| `spec.network.topology.type` | 服务拓扑（`weave-scope` / `none`） |
| `spec.openpitrix.store.enabled` | 应用商店 |
| `spec.servicemesh.enabled` | 服务网格（Istio） |
| `spec.edgeruntime.enabled` / `kubeedge` | 边缘计算 |
| `spec.gatekeeper.enabled` | OPA 准入策略 |
| `spec.terminal.timeout` | Web 终端超时（秒） |
| `spec.deepflow.enabled` | 链路追踪与 eBPF 可观测（**v22.6.0 新增，默认 `true`**） |
| `spec.deepflow.storageClass` | DeepFlow 存储类，空则用集群默认 SC |
| `spec.deepflow.clickhouse.volumeSize` | ClickHouse 卷，默认 `200Gi`（最小值） |
| `spec.deepflow.retentionDays` | `l7_flow_log` 保留天数，默认 30，需与 BFF `ttl.max_days` 同步 |
| `spec.deepflow.server.replicas` / `clickhouse.replicas` | 副本数，all-in-one 默认各 1 |
| `spec.deepflow.agent.resources` / `otel.resources` | agent 与 OTel collector 资源限额 |

### 修改配置（写操作，需变更单）

```bash
# 演练
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"logging":{"enabled":true}}}' --dry-run=server

# 执行
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"logging":{"enabled":true}}}'

# 观察安装器调谐
kubectl -n kubercon-system logs -l app=kubercon-installer -f --tail=100
kubectl -n kubercon-system get pod -w

# 备份当前配置（改前必做）
kubectl -n kubercon-system get cc kubercon-installer -o yaml > cc-backup-$(date +%Y%m%d-%H%M).yaml
```

**回滚 = 只 patch 需要恢复的字段，绝对不要** `kubectl apply` **完整旧备份。** cc 是平台总配置，`spec.kubercon_tag` 决定全部组件镜像版本；apply 一份旧备份（升级前的备份、旧仓库模板、其他环境的定制文件都算）等于把整平台按旧版本重装一遍——installer hook 是周期性全量调谐，cc 一变就重放完整安装 playbook。2026-09-09 某环境 apply 了升级前的 cc 备份，直接导致 apiserver / controller-manager / ui 全量回退到旧版本，就是这个机制。

```bash
# 正确的回滚：只回退目标字段（先 --dry-run=server 演练）
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"<字段路径>":<旧值>}}'

# 备份文件只能用来核对差异，不能 apply；每条差异都要人工确认：
kubectl diff -f cc-backup-<时间戳>.yaml
```

---

## 3. 多租户资源

### 企业空间（Workspace）

```bash
kubectl get workspaces
kubectl get workspaces -o wide
kubectl get workspace <企业空间> -o yaml
kubectl describe workspace <企业空间>

# 多集群模板
kubectl get workspacetemplates
kubectl get workspacetemplate <企业空间> -o yaml
```

### 项目（Project = Namespace）

```bash
# 某企业空间下的项目
kubectl get ns -l kubercloud.com/workspace=<企业空间>

# 标签键不确定时先看实际标签
kubectl get ns --show-labels | head

# 项目归属反查
kubectl get ns <项目> -o jsonpath='{.metadata.labels}' | tr ',' '\n'

# 项目内资源总览
kubectl -n <项目> get all
kubectl -n <项目> get deploy,sts,ds,job,cronjob
kubectl -n <项目> get pvc,cm,secret
```

### 配额与限制

```bash
# 企业空间级配额（常青云 CRD）
kubectl get resourcequotas.quota.kubercloud.com
kubectl get resourcequotas.quota.kubercloud.com <名称> -o yaml

# 项目级配额（K8s 原生）
kubectl -n <项目> get resourcequota -o yaml
kubectl -n <项目> describe resourcequota
kubectl -n <项目> get limitrange -o yaml

# 配额是否打满（Pending 排障必查）
kubectl -n <项目> describe resourcequota | grep -E 'Resource|used|hard'
```

### 用户与权限

```bash
kubectl get users
kubectl get user <用户名> -o yaml
kubectl get globalroles
kubectl get globalrolebindings
kubectl get workspaceroles -A
kubectl get workspacerolebindings -A
kubectl get groups
kubectl get groupbindings
kubectl get loginrecords            # 登录审计

# 某用户的绑定关系
kubectl get globalrolebindings -o json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); [print(i['metadata']['name'], i.get('roleRef',{}).get('name'), [s.get('name') for s in i.get('subjects',[])]) for i in d['items']]"

# 权限自检
kubectl auth can-i --list
kubectl auth can-i create deployments -n <项目>
kubectl auth can-i '*' '*' --all-namespaces
```

### 多集群

```bash
kubectl get clusters
kubectl get cluster <集群名> -o yaml
kubectl get cluster <集群名> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

---

## 4. 组件运维

### 状态与日志

```bash
# 控制面
kubectl -n kubercon-system get pod -o wide
kubectl -n kubercon-system get deploy
kubectl -n kubercon-system logs deploy/<组件> --tail=200
kubectl -n kubercon-system logs deploy/<组件> --since=10m | grep -iE 'error|fatal|panic'
kubectl -n kubercon-system logs deploy/<组件> --previous     # 上次崩溃

# 多容器
kubectl -n kubercon-system logs <pod> -c <容器> --tail=100
kubectl -n kubercon-system logs <pod> --all-containers=true --timestamps=true

# 事件
kubectl -n kubercon-system get events --sort-by='.lastTimestamp' | tail -30
kubectl -n kubercon-system describe pod <pod> | sed -n '/Events/,$p'
```

### 批量扫组件错误日志

```bash
# 以真实组件名循环，不写死 ks-* 或 kubercon-*
for comp in $(kubectl -n kubercon-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  echo "===== $comp ====="
  kubectl -n kubercon-system logs deploy/"$comp" --since=10m --tail=50 2>/dev/null \
    | grep -iE 'fatal|error|panic' || echo OK
done
```

### 重启与重置（写操作）

```bash
# 滚动重启（先演练）
kubectl -n kubercon-system rollout restart deploy/<组件> --dry-run=server
kubectl -n kubercon-system rollout restart deploy/<组件>
kubectl -n kubercon-system rollout status deploy/<组件> -w

# 重置为安装器默认配置（kc）
kc com reset --name <组件>

# 镜像热更新（临时，务必回写 cc）
kc com watch --name <组件> --image <私有仓库>/<镜像>:<标签>
```

### kc 完整命令树

```bash
kc component|com
  list      # 组件清单
  edit      # 编辑组件
  enable    # 启用/禁用组件
  exec      # 在组件容器内执行命令
  kill      # 杀 Pod 触发重建
  log       # 输出组件日志
  reset     # 重置组件配置
  watch     # 更新 apiserver/controller-manager/ui 镜像

kc pipeline|pip
  create    # 由 java/go 等模板创建流水线
  delete    # 删除流水线
  edit      # 编辑流水线
  view      # 输出流水线 YAML

kc user
  create           # 创建平台用户
  reset-password   # 重置用户密码

kc install
  kind      # 用 kind 装平台（测试）
  kk        # 用 kubekey 装平台
```

作为 kubectl 插件调用：`kubectl kc com list`。操作 k3s 时设 `kubernetes_type=k3s`。

---

## 5. 工作负载与应用

```bash
# 查询
kubectl -n <项目> get deploy,sts,ds -o wide
kubectl -n <项目> get pod -o wide
kubectl -n <项目> get pod --field-selector=status.phase!=Running
kubectl -n <项目> get pod --sort-by='.status.containerStatuses[0].restartCount'
kubectl -n <项目> describe deploy <名称>

# 伸缩与回滚（写操作）
kubectl -n <项目> scale deploy/<名称> --replicas=3 --dry-run=client
kubectl -n <项目> rollout history deploy/<名称>
kubectl -n <项目> rollout undo deploy/<名称>
kubectl -n <项目> rollout undo deploy/<名称> --to-revision=2
kubectl -n <项目> set image deploy/<名称> <容器>=<镜像>:<标签> --dry-run=server

# Job / CronJob
kubectl -n <项目> get job,cronjob
kubectl -n <项目> logs job/<名称>
kubectl -n <项目> get cronjob <名称> -o jsonpath='{.status.lastScheduleTime}{"\n"}'
```

### Pod 排障

```bash
kubectl -n <项目> describe pod <pod>
kubectl -n <项目> logs <pod> --previous --all-containers=true
kubectl -n <项目> get events --field-selector involvedObject.name=<pod> --sort-by='.lastTimestamp'
kubectl -n <项目> exec -it <pod> -- sh
kubectl -n <项目> get pod <pod> -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl -n <项目> get pod <pod> -o jsonpath='{.spec.containers[*].resources}' | python3 -m json.tool

# 镜像拉取失败排查
kubectl -n <项目> get pod <pod> -o jsonpath='{.spec.containers[*].image}{"\n"}'
kubectl -n <项目> get pod <pod> -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
kubectl -n <项目> get secret <拉取密钥> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

# 端口转发本地验证
kubectl -n <项目> port-forward <pod> 8080:8080

# 临时调试容器（K8s ≥1.23）
kubectl -n <项目> debug <pod> -it --image=busybox --target=<容器>
```

---

## 6. DevOps

```bash
kubectl get devopsprojects
kubectl get devopsproject <名称> -o yaml
kubectl get pipelines -A
kubectl -n <devops项目> get pipelines
kubectl -n <devops项目> get pipeline <名称> -o yaml

# Jenkins
kubectl -n kubercon-devops-system get deploy,sts        # 先确认实际部署了什么
kubectl -n kubercon-devops-system get sts kubercon-jenkins
kubectl -n kubercon-devops-system describe sts kubercon-jenkins
kubectl -n kubercon-devops-system logs sts/kubercon-jenkins --tail=200
kubectl -n kubercon-devops-system get pvc

# 构建 Agent Pod（跨项目）
kubectl get pod -A -l jenkins/label -o wide
kubectl get pod -A -l jenkins/label --field-selector=status.phase=Pending

# S2I / B2I
kubectl -n <项目> get s2ibuilder,s2irun
kubectl -n <项目> describe s2irun <名称>
```

---

## 7. 监控与告警

实测组件：`prometheus-k8s`(STS)、`alertmanager-main`(STS)、`thanos-ruler-kubercon`(STS)、`prometheus-operator`、`kube-state-metrics`、`notification-manager-deployment`、`notification-manager-operator`、`node-exporter`(DS)。**Grafana 未必装在此命名空间**（实测该环境只有 `deepflow` 下的 `deepflow-grafana`），用 `kubectl get deploy -A | grep -i grafana` 定位。

```bash
kubectl -n kubercon-monitoring-system get pod -o wide
kubectl -n kubercon-monitoring-system get deploy,sts,ds
kubectl -n kubercon-monitoring-system get pvc

# Prometheus
kubectl -n kubercon-monitoring-system logs prometheus-k8s-0 -c prometheus --tail=100
kubectl -n kubercon-monitoring-system describe pod prometheus-k8s-0 | sed -n '/Events/,$p'
kubectl -n kubercon-monitoring-system port-forward svc/prometheus-operated 9090:9090

# 告警规则与 Alertmanager
kubectl -n kubercon-monitoring-system get prometheusrules
kubectl -n kubercon-monitoring-system get secret alertmanager-main -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
kubectl -n kubercon-monitoring-system port-forward svc/alertmanager-main 9093:9093

# 通知
kubectl -n kubercon-monitoring-system get deploy notification-manager-deployment
kubectl get notificationmanagers -A
kubectl get receivers -A

# 资源用量（需 metrics-server）
kubectl top nodes
kubectl top pod -A --sort-by=memory
kubectl -n <项目> top pod
```

---

## 8. 日志与审计

先确认后端是 ES 还是 OpenSearch：

```bash
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='opensearch={.spec.common.opensearch.enabled}{" es="}{.spec.common.es.enabled}{"\n"}'
```

```bash
kubectl -n kubercon-logging-system get pod -o wide
kubectl -n kubercon-logging-system get deploy,sts,ds

# 实测组件：opensearch-cluster-master/data(STS)、fluent-operator、
#           kube-auditing-operator、kube-auditing-webhook-deploy、logsidecar-injector-deploy
kubectl -n kubercon-logging-system get sts opensearch-cluster-master opensearch-cluster-data
kubectl -n kubercon-logging-system logs sts/opensearch-cluster-master --tail=100

# 采集器由 fluent-operator 管理（未必存在 fluent-bit DaemonSet，先看 ds 有没有）
kubectl -n kubercon-logging-system get deploy fluent-operator
kubectl get clusterfilters,clusteroutputs,clusterinputs 2>/dev/null   # fluent-operator CRD

# 后端健康（port-forward 到 OpenSearch）
kubectl -n kubercon-logging-system port-forward svc/opensearch-cluster-data 9200:9200
# 另一终端：curl http://localhost:9200/_cluster/health?pretty
# status=red → 分片分配失败，查 disk watermark 与 PV 余量

# 索引前缀：kc-<opensearchPrefix|elkPrefix>-logging
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.spec.common.opensearch.opensearchPrefix}{"\n"}'

# 审计
kubectl -n kubercon-logging-system get pod | grep -i auditing
kubectl get clusterauditingrules 2>/dev/null
```

---

## 9. 存储

```bash
kubectl get sc
kubectl get sc -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class",PROVISIONER:.provisioner
kubectl get pv --sort-by=.spec.capacity.storage
kubectl get pvc -A
kubectl get pvc -A --field-selector=status.phase=Pending      # 绑定失败
kubectl -n <项目> describe pvc <名称>

# CSI
kubectl -n kube-system get pod | grep -i csi
kubectl get csidrivers
kubectl get volumesnapshotclasses 2>/dev/null
kubectl get volumesnapshots -A 2>/dev/null

# 本地路径存储供给者（v22.6.0 默认带）
kubectl -n openebs get pod
```

### 默认 StorageClass `local-path`（同名两种实现）

POC 与单节点环境的默认 SC 都叫 `local-path`，但底层供给者可能是两套之一，**排障前先看 provisioner**：

```bash
kubectl get sc local-path -o jsonpath='{.provisioner}{"\n"}'
```

| provisioner | 出处 | 供给者位置 |
| --- | --- | --- |
| `rancher.io/local-path` | 现场部署 / 旧版本（v22.5.0 实测环境即此） | `kube-system/local-path-provisioner` |
| `openebs.io/local` | v22.6.0 安装器方案，`deploy/local-path-storage.yaml`（OpenEBS LocalPV-Hostpath 3.3.0） | `openebs/openebs-localpv-provisioner` |

宿主机路径两套来源不同，都以现场实测为准：rancher 实现看 `kube-system/local-path-config` 的 nodePathMap（v22.5.0 实测为 `/mnt/localfs`）；openebs 实现（`deploy/local-path-storage.yaml`）模板配的是 `/opt/local-path-provisioner`（OpenEBS 默认本为 `/var/openebs/local`，安装器改成了前者以对齐），实际值看 `openebs` 命名空间的 `localpv-hostpath-config`。SC 名相同，`kubectl get sc` 区分不出来，只能看 provisioner 字段与供给者 Pod 所在命名空间。

老集群升级到 v22.6.0 时留意：若 rancher 实现仍在运行，两个供给者会争抢同名 SC，需确认只保留一套。

**不论哪种实现都仅供单机与测试。** PV 绑定在具体节点目录上，节点故障即数据丢失，不支持跨节点迁移与快照。生产方案须换 Ceph 或企业级共享存储，并在 `cc` 里为 monitoring、logging、deepflow 等组件显式指定 `storageClass`。

PVC 长期 Pending 时的排查顺序：有无默认 SC → `cc` 里指定的 SC 是否真实存在 → 宿主机分区余量 → 对应命名空间里的 provisioner Pod 日志。

---

## 10. 网络

```bash
# 平台网络策略（常青云 CRD）
kubectl get namespacenetworkpolicies -A
kubectl -n <项目> get namespacenetworkpolicies -o yaml

# K8s 原生网络策略
kubectl -n <项目> get networkpolicies -o yaml

# IP 池
kubectl get ippools
kubectl get ipamblocks
kubectl get ipamhandles

# 服务与路由
kubectl -n <项目> get svc,ep
kubectl -n <项目> get ingress
kubectl -n <项目> describe ingress <名称>
kubectl -n kubercon-controls-system get pod -o wide
kubectl -n kubercon-controls-system logs deploy/nginx-ingress-controller --tail=100

# CNI 与 DNS
kubectl -n kube-system get ds | grep -iE 'calico|flannel'
kubectl -n kube-system logs ds/calico-node --tail=100
kubectl -n kube-system get pod -l k8s-app=kube-dns
kubectl -n kube-system get cm coredns -o yaml

# 集群内连通性测试（一次性 Pod）
kubectl -n <项目> run nettest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w "%{http_code}\n" --connect-timeout 3 http://<服务>.<项目>.svc:<端口>/

# DNS 解析测试
kubectl -n <项目> run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup <服务>.<项目>.svc.cluster.local
```

---

## 11. 可观测链路追踪（v22.06+）

**v22.6.0 起由安装器默认部署**（`spec.deepflow.enabled` 默认 `true`，playbook 为 `playbooks/deepflow.yaml`）。旧版本才需现场单独部署。跨三个命名空间：

```bash
# 是否启用与关键参数
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.spec.deepflow.enabled}{" sc="}{.spec.deepflow.storageClass}{" ttl="}{.spec.deepflow.retentionDays}{"\n"}'

# DeepFlow 采集与存储（命名空间以现场为准）
kubectl get ns | grep -i deepflow
kubectl -n deepflow get pod -o wide
kubectl -n deepflow get svc

# v7.1 中 deepflow-server 为 Deployment，controller+querier+ingester 一体，无独立 querier Pod
kubectl -n deepflow get deploy,ds

# ClickHouse 是最常见故障点（默认申请 200Gi）
kubectl -n deepflow get pvc
kubectl -n deepflow logs sts/deepflow-clickhouse --tail=100

# OTel 接入（otel-agent 为 DaemonSet，监听 4317/gRPC、4318/HTTP）
kubectl -n open-telemetry get ds,pod,svc
kubectl -n open-telemetry logs -l component=otel-agent --tail=100

# 平台查询 BFF（控制台链路追踪页面走它）
kubectl -n kubercon-system get deploy deepflow-trace-bff
kubectl -n kubercon-system logs deploy/deepflow-trace-bff --tail=100
```

排障按数据流顺序：**应用埋点 → `otel-agent` → `deepflow-server` → ClickHouse → BFF → 控制台**。

### 版本与参数基线（v22.6.0 实测）

| 项 | 值 |
| --- | --- |
| chart | `deepflow` umbrella 7.1.002（含 server / app / agent / ClickHouse / MySQL / Grafana） |
| 镜像 tag | `v7.1`；ClickHouse 23.10、MySQL 8.0.39、Grafana 10.4.3 |
| ClickHouse 卷 | 200Gi（`l7_flow_log` 主存储，最小值）；MySQL 20Gi |
| 保留期 | `retentionDays: 30`，需与 BFF 的 `ttl.max_days` 同步 |
| BFF 镜像 | `deepflow-trace-bff:v1.0.0`，部署在 `kubercon-system` |
| OTel collector | `opentelemetry-collector-contrib:0.62.0`（含 k8sattributesprocessor + otlphttp） |

硬约束与坑：

- **agent 镜像 tag 必须 ≤ server 的 tag**，倒挂会连不上。
- `storageClass` 留空 = 用集群默认 SC（v22.6.0 实测为 `local-path`）。生产必须显式指定可靠 SC。
- `all_in_one_local_storage` 开发环境可能为 `true`（hostPath），**生产必须 `false`**，用 PVC。
- chart 自带 `deepflow-grafana`，`kubectl get deploy -A | grep -i grafana` 会匹配到它，别与监控栈 Grafana 混淆。
- 单节点或小规格环境资源紧张时，`patch cc` 关掉 `deepflow` 比硬扛稳妥（属变更操作）。

自检脚本：`scripts/kubercon-deepflow-check.sh`。详细接入步骤见 `docs/常青云容器云-链路追踪接入OTel-部署手册.md`。

---

## 12. 节点与集群维护

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
kubectl describe node <节点> | sed -n '/Allocated resources/,/Events/p'
kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion

# 污点与标签
kubectl describe node <节点> | grep -A3 Taints
kubectl label node <节点> <键>=<值> --dry-run=client
kubectl taint node <节点> <键>=<值>:NoSchedule --dry-run=client

# 维护（P1 变更，需变更单）
kubectl cordon <节点>                                  # 停止新调度
kubectl drain <节点> --ignore-daemonsets --dry-run=client   # 先演练
kubectl drain <节点> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <节点>

# etcd 形态判定：kk 部署时为 systemd 二进制，此处查不到 Pod
kubectl -n kube-system get pod | grep etcd

# 无 etcd Pod 时，经 apiserver 侧面确认健康度
kubectl get --raw='/livez/etcd'
kubectl get --raw='/readyz?verbose' | grep -i etcd
```

etcd 备份恢复见第 18 节。注意运维手册第 11 章的恢复流程基于 kubeadm 静态 Pod 布局，在 `kk` 部署的集群上不适用。

---

## 13. 输出格式与批量操作

```bash
# jsonpath
kubectl get pod -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# custom-columns
kubectl get pod -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount

# 排序
kubectl get pod -A --sort-by='.status.containerStatuses[0].restartCount'
kubectl get events -A --sort-by='.lastTimestamp'

# 全平台异常 Pod
kubectl get pod -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 重启次数 Top
kubectl get pod -A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[]
for i in d['items']:
    r=sum(c.get('restartCount',0) for c in i.get('status',{}).get('containerStatuses',[]) or [])
    if r: rows.append((r,i['metadata']['namespace'],i['metadata']['name']))
for r,ns,n in sorted(rows,reverse=True)[:20]: print(r,ns,n)
"

# 导出备份
kubectl -n <项目> get deploy <名称> -o yaml > deploy-backup.yaml
kubectl -n kubercon-system get cc kubercon-installer -o yaml > cc-backup.yaml

# 差异比对
kubectl diff -f <清单>.yaml
```

---

## 14. 端口速查

| 端口 | 用途 |
| --- | --- |
| 6443 | Kubernetes API Server |
| 2379 / 2380 | etcd 客户端 / Raft Peer |
| 10250 | Kubelet API |
| 30880 | 常青云控制台默认 NodePort |
| 80 / 443 | Ingress |
| 30000-32767 | NodePort 范围 |
| 9090 / 9093 / 3000 | Prometheus / Alertmanager / Grafana |
| 9200 / 9300 | ES/OpenSearch REST / 内部传输 |
| 8080 | Jenkins Web（ClusterIP） |
| 4789 UDP / 179 | Calico VXLAN / BGP |
| 53 | CoreDNS |
| 38086 | deepflow-agent 外部数据接收（v22.06+） |

完整端口矩阵见运维手册附录 A。

---

## 15. 版本约束

| 常青云版本 | KubeSphere 基线 | 支持 K8s | Jenkins | JDK |
| --- | --- | --- | --- | --- |
| v3.4.0 | v3.4.0 | 1.22–1.24 | 2.346.3（已废弃） | 11（废弃） |
| v3.4.1 | v3.4.1 | 1.23 / 1.24.17 / 1.25.16 / 1.26.11 | 2.480 | 21 LTS |
| v22.06 | v3.4.1 | 配套 K8s 1.28.15 | 2.480 | 21 LTS |
| v22.6.0 | v3.4.1 | 安装器清单已含 1.29.x / 1.30.x（最高 1.30.3） | 2.480 | 21 LTS |

版本口径在不同材料中存在差异（运维手册以 v3.4.1 + K8s ≤1.26.11 为基线，v22.06 产品线配套 1.28.15，v22.6.0 的 `kc-installer/version/components.json` 已支持到 1.30.3）。**以现场 `kubectl version` 与 `cc` 的 `kubercon_tag` 为准**，不要用文档数字反推现场；「安装器支持」也不等于「该局点已验证」。

硬约束：Jenkins ≥2.480 必须 JDK ≥17；`kubernetes-cd` 插件在所有版本中必须移除（存在 RCE）。

### v22.6.0 相对 v22.5.0 的运维影响

| 变化 | 影响 |
| --- | --- |
| 移除试用 License，新增 RSA 验签 | 无正式授权则写操作全部被拒，交付流程必须先申请授权 |
| DeepFlow 默认开启 | 新增三个命名空间的负载，ClickHouse 占 200Gi |
| `local-path` 供给者由 rancher 改为 OpenEBS LocalPV | SC 名不变，供给者从 `kube-system` 挪到 `openebs`；升级时注意两套并存争抢同名 SC |
| `hub_registry` 前缀 `/mirror/` → `/kubercon/` | 仅影响第三方镜像（minio/redis/openldap 等）；平台镜像走 `kubercon_registry`，路径本就是 `/kubercon/`。离线仓库同步路径要跟着改。**升级集群的 cc 保留旧值 `/mirror/`，该前缀只对全新安装可靠** |
| 新增 `branding.kubercloud.com` | 品牌定制接口，kapis 无 CRD |
| 审计跳过流式请求响应体 | follow / watch / exec 类请求不再记录响应内容 |

---

## 16. 安全与合规

```bash
# RBAC 审计
kubectl get clusterrolebindings -o wide | grep cluster-admin
kubectl get globalrolebindings -o wide
kubectl auth can-i --list --as=<用户>

# 特权容器排查
kubectl get pod -A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d['items']:
    for c in i['spec'].get('containers',[]):
        sc=c.get('securityContext') or {}
        if sc.get('privileged'):
            print(i['metadata']['namespace'], i['metadata']['name'], c['name'])
"

# 敏感信息（勿输出到工单）
kubectl -n kubercon-system get cm kubercon-config -o yaml       # 含 jwtSecret
kubectl -n kubercon-system get secret | grep -i -E 'license|account'
```

`kubercon-config`、`alertmanager-main`、镜像拉取密钥等内容含凭据，排障时只看必要字段，不要整份复制外发。

### License 查询

**没有 License CRD**，授权存在 Secret 中。涉及两个 Secret，职责不同：

```bash
# 授权本体：type 为 kubercloud.com/license，实测含 3 个 key
kubectl -n kubercon-system get secret kubercon-license -o jsonpath='{.type}{"\n"}'
kubectl -n kubercon-system get secret kubercon-license -o json | \
  python3 -c "import json,sys; print(list(json.load(sys.stdin).get('data',{}).keys()))"
#   license          解析缓存（可读）
#   license.file     原始授权文件，真相源
#   license.history  历史授权记录

kubectl -n kubercon-system get secret kubercon-license \
  -o jsonpath='{.data.license}' | base64 -d

# 密钥材料：确认存在即可，不要打印内容
kubectl -n kubercon-system get secret kubercon-private
#   private.pem         客户端 RSA-2048 私钥（解密授权文件、签名请求）
#   public.pem          客户端公钥（写入 LicenseRequest.pubKey）
#   server_public.json  服务端公钥元数据
```

生效状态不在 CR status 里，由平台 API 提供（`license.kubercloud.com/v1alpha1` 的 kapis 接口，经 `kubercon-apiserver`）：

| 接口 | 用途 |
| --- | --- |
| `GET /license` | 查授权状态与有效期 |
| `GET /license/request` | 生成授权申请文件（含集群公钥） |
| `POST /license` | 上传签发后的 `.lic` |
| `DELETE /license` | 删除当前授权 |

**v22.6.0 起没有试用授权兜底。** 旧版本无授权时会自动创建试用 License（`EnsureTrialLicense`），v22.6.0 删除了 `pkg/models/license/trial.go` 并新增 RSA 验签，现在无正式授权时**平台可登录但所有写操作被拒**。

申请顺序不能颠倒：先装平台 → 安装器生成 `kubercon-private` → `GET /license/request` 拿申请文件 → 厂商签发 → 上传。签发依赖集群自己生成的公钥，**没法提前准备一份通用 `.lic` 带到现场**。

`kubercon-private` **不可删除或重建**。授权文件用其中的私钥解密，密钥一换，已签发的 License 全部失效。安装器 `roles/kubercon-core/license` 检测到该 Secret 已存在就跳过，正是为此。

验签失败的典型报错与处理：

```text
license signature verification failed: signature is empty (forged or unsigned license rejected)
```

`signature is empty` = 授权文件签名字段为空，通常是用了未签发的模板或手工改过内容。只能换厂商正式签发的文件，**不要手工编辑授权文件**。校验逻辑见 `kubercon-backend/pkg/models/license/license.go`，请求拦截见 `pkg/apiserver/filters/license.go`。

---

## 17. 与上游命名对照

| 上游 KubeSphere | 常青云 KuberCon |
| --- | --- |
| `kubesphere-system` | `kubercon-system` |
| `kubesphere-monitoring-system` | `kubercon-monitoring-system` |
| `kubesphere-logging-system` | `kubercon-logging-system` |
| `kubesphere-devops-system` | `kubercon-devops-system` |
| `kubesphere-controls-system` | `kubercon-controls-system` |
| `ks-installer` | `kubercon-installer` |
| `ks-apiserver` | `kubercon-apiserver` |
| `ks-console` | `kubercon-ui`（注意不是 kubercon-console） |
| `ks-controller-manager` | `kubercon-controller-manager` |
| `ks-jenkins` | `kubercon-jenkins` |
| `kubesphere.io/v1alpha*` | `*.kubercloud.com/v1alpha*` |
| `tenant.kubesphere.io` | `tenant.kubercloud.com` |
| `iam.kubesphere.io` | `iam.kubercloud.com` |
| `devops.kubesphere.io` | `devops.kubercloud.com` |
| `installer.kubesphere.io` | `installer.kubercloud.com` |
| `kubesphere.io/workspace`（标签） | `kubercloud.com/workspace`（实测无兼容标签；另有 `kubercloud.com/namespace`） |

实测集群（v22 线，K8s 1.28.15）中控制面工作负载**全部为 `kubercon-*`，未出现任何 `ks-*`**。部分内部文档仍写 `ks-apiserver`/`ks-console`，那是上游习惯名，照抄查不到资源。仍建议操作前用 `kubectl -n kubercon-system get deploy` 确认。

---

## 18. 备份与恢复

### 18.1 etcd 部署形态判定（做任何操作前的第一步）

形态由部署时的 `spec.etcd.type` 决定，共三种，**直接决定有没有自动备份**：

| `etcd.type` | 形态 | 自动备份 | 依据 |
| --- | --- | --- | --- |
| `kubekey`（默认） | 宿主机 systemd 二进制 | 有 | `default.go:342`，type 为空时置为 `KubeKey` |
| `kubeadm` | kube-system 静态 Pod | **无** | `create_cluster.go:77`，`BackupModule{Skip: Type != KubeKey}` |
| `external` | 集群外 etcd | **无** | 同上 |

`kubeadm` 与 `external` 形态下 `PreCheckModule`、`InstallETCDBinaryModule`、`ConfigureModule`、`BackupModule` 四个模块全部跳过——**不会有任何备份脚本或 timer**。接手集群先确认形态，不要假设备份存在。

以下为 `kubekey`（默认）形态与 kubeadm 形态的路径对照：

| 项目 | KubeKey 部署（常青云默认，v22.5.0 实测） | kubeadm 部署 |
| --- | --- | --- |
| 进程管理 | `systemctl {status,stop,start} etcd` | 移走 `/etc/kubernetes/manifests/etcd.yaml` |
| 二进制 | `/usr/local/bin/etcd`、`/usr/local/bin/etcdctl` | 容器内 |
| 证书目录 | `/etc/ssl/etcd/ssl/` | `/etc/kubernetes/pki/etcd/` |
| 客户端证书 | `admin-<主机名>.pem`、`admin-<主机名>-key.pem`、`ca.pem` | `server.crt`、`server.key`、`ca.crt` |
| 成员证书 | `member-<主机名>.pem`、`member-<主机名>-key.pem` | `peer.crt`、`peer.key` |
| 环境变量 | `/etc/etcd.env` | 静态 Pod 清单内 |
| 数据目录 | `/var/lib/etcd` | `/var/lib/etcd` |

判定方法：

```bash
kubectl -n kube-system get pod | grep etcd    # 无输出 → systemd 形态
```

证书文件名含主机名，多节点集群上每台的命令都不同。

### 18.2 自动定时备份（仅 `type: kubekey` 形态）

事实来源：`kc-installer/cmd/kk/pkg/etcd/templates/{backup_script.go,backup_service.go}`、`cmd/kk/apis/kubekey/v1alpha2/default.go`。

| 项目 | 默认值 | 代码常量 |
| --- | --- | --- |
| 备份脚本 | `/usr/local/bin/kube-scripts/etcd-backup.sh` | `DefaultEtcdBackupScriptDir` |
| systemd 单元 | `backup-etcd.service`（oneshot）+ `backup-etcd.timer` | — |
| 执行时间 | 每天 `02:00`（`OnCalendar=*-*-* 02:00:00`） | `DefaultEtcdBackupPeriod = 1440`（分钟） |
| 备份目录 | `/var/backups/kube_etcd/etcd-<年-月-日-时-分-秒>/` | `DefaultEtcdBackupDir` |
| 保留份数 | 5 | `DefaultKeepBackNumber = 5` |

每次产出 v2 格式 `backup` 与 v3 格式 `snapshot.db` 两份，**恢复只用 `snapshot.db`**。

**`backupPeriod` 换算规则（`BackupTimeOnCalendar()`），非线性且有陷阱：**

| 配置值（分钟） | 渲染的 `OnCalendar` | 实际行为 |
| --- | --- | --- |
| ≤ 0 | `*-*-* *:00/30:00` | 每 30 分钟 |
| < 60 | `*-*-* *:00/N:00` | 每 N 分钟 |
| 60 的整数倍且 < 1440 | `*-*-* 00/H:00:00` | 每 H 小时（符合直觉） |
| 非 60 整数倍且 < 1440 | `*-*-* 00/H:M:00` | **每 H 小时的第 M 分**，不是每 (H*60+M) 分钟 |
| ≥ 1440 | `*-*-* 02:00:00` | **一律每天 02:00**，更大的值被静默忽略 |

例：填 90 得到 `00/1:30:00`（每小时第 30 分，频率翻倍）；填 2880 仍是每天一次。**改完必须 `systemctl list-timers` 核对实际触发时间。**

**v2 备份步骤的静默失败风险：** 脚本首行含 `set -o errexit`，第一步执行 `ETCDCTL_API=2 etcdctl backup`（etcd v2 遗留命令，v3.5 起废弃；打包版本 v3.4.13 / v3.5.13 尚可用）。该步失败则脚本立即退出，**`snapshot.db` 不会生成**。timer 为 oneshot，失败仅记录在 `systemctl status` 中。

因此巡检的判据是**备份目录的实际产出时间**，而非 timer 是否 active：

```bash
ls -lt /var/backups/kube_etcd/ | head -5      # 最新目录时间是否为昨天 02:00
ls -l  /var/backups/kube_etcd/*/snapshot.db   # snapshot.db 是否真的存在且非空
```

现场核查（需登录节点，`kubectl` 查不到 systemd 状态）：

```bash
systemctl list-timers | grep backup-etcd
systemctl status backup-etcd.service
ls -lt /var/backups/kube_etcd/
du -sh /var/backups/kube_etcd/
```

### 18.3 与运维手册的四处冲突

| 项目 | 运维手册第 11 章 | 代码实际 |
| --- | --- | --- |
| 备份频率 | 每 6 小时 | 每天 02:00 一次 |
| 保留策略 | 至少 7 天 | 5 份（约 5 天） |
| 恢复流程 | 移走 `/etc/kubernetes/manifests/etcd.yaml` | 该文件不存在，须用 `systemctl stop etcd` |
| 证书路径 | `/etc/kubernetes/pki/etcd/*` | `/etc/ssl/etcd/ssl/*` |

**对客户承诺 RPO 前以现场 `systemctl list-timers` 实测值为准**，不要引用手册数字。

### 18.4 手工快照（变更窗口前必做）

```bash
export ETCDCTL_API=3
HOST=$(hostname)
SNAP=/var/backups/etcd-manual-$(date +%F-%H%M).db

/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 snapshot save $SNAP \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-$HOST.pem \
  --key=/etc/ssl/etcd/ssl/admin-$HOST-key.pem

/usr/local/bin/etcdctl snapshot status $SNAP --write-out=table   # totalKey 为 0 即无效
```

未经 `snapshot status` 校验的文件不算备份。校验后必须外传到集群之外。

### 18.5 恢复纪律

**不在本 skill 自动执行范围内。** 判断依据：

- 单成员故障 → 走成员替换（`etcdctl member remove` + 加新成员），数据自动同步，**不要做快照恢复**
- 全部成员数据不可用 → 才走快照恢复，且需先在同版本测试环境跑通
- 清理数据目录一律 `mv /var/lib/etcd/member /var/lib/etcd/member.bak.$(date +%s)`，**禁止 `rm -rf`**
- 多节点 restore 时 `--name` 与 `--initial-advertise-peer-urls` 逐台不同，不可复制同一条命令
- 恢复后需 `endpoint health` 全 healthy、`endpoint status` 存在唯一 Leader，才能恢复 apiserver

### 18.6 备份的两个盲区（第三个见 18.8）

**本地盘单点。** `/var/backups/kube_etcd` 在节点本地磁盘，节点损坏则备份同时丢失。单节点 POC 下数据与备份同盘，不具备任何容灾能力。外传需自行配置，安装器不覆盖。

**无应用级备份。** `kubercon-installer/roles/` 下无 Velero 或任何备份组件，`kc` 无 backup 子命令。手册第 11.2 章的 Velero 属外部自建方案。准确表述：**平台自带 etcd 控制面元数据的自动备份，应用数据与 PV 需另配方案。**

### 18.7 etcd 监控与告警

```bash
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.etcd}{"\n"}'
# {"endpointIps":"localhost","monitoring":false,"port":2379,"tlsEnable":true}
```

`monitoring: false` 为默认值。平台自带完整的 etcd 监控资产（`kubercon-installer/roles/kubercon-monitor/files/prometheus/etcd/`）：ServiceMonitor、Service、Endpoints、证书 Secret，以及 11 条告警规则（对齐上游 etcd-mixin）：

| 类别 | 告警 |
| --- | --- |
| 成员存活 | `etcdMembersDown`、`etcdInsufficientMembers` |
| Leader | `etcdNoLeader`、`etcdHighNumberOfLeaderChanges` |
| 请求失败 | `etcdHighNumberOfFailedProposals`、`etcdHighNumberOfFailedGRPCRequests` |
| 延迟 | `etcdGRPCRequestsSlow`、`etcdHighCommitDurations`、`etcdHighFsyncDurations`、`etcdMemberCommunicationSlow` |
| 容量 | `etcdExcessiveDatabaseGrowth` |

覆盖行业标准关注的全部核心 SLI。**但开关关闭时这 11 条均不生效**，集群处于控制面存储无告警状态。生产交付应置为 `true`；多节点需把 `endpointIps` 由 `localhost` 改为实际 IP 列表（逗号分隔），否则只采集本机成员。属配置变更，走变更单。

### 18.8 快照的密级要求

**etcd 快照含全部 Secret 明文。** `kk` 未配置 Kubernetes 静态加密（代码中无 `EncryptionConfiguration` / `--encryption-provider-config` 相关实现），Secret 在 etcd 中为 base64 编码而非密文。持有 `snapshot.db` 等同持有集群全部凭据。

处置要求：

- 外传的传输与落盘均需加密（`gpg -c` 或对象存储服务端加密），禁止明文存放于共享 NAS
- 备份存储访问权限按集群管理员同级管控
- 等保 / 密评场景需明确说明：**平台默认不启用静态加密，须交付时单独配置 `EncryptionConfiguration`**

### 18.9 行业标准要求但平台未自动化的项

| 运维项 | 平台现状 | 需人工执行的动作 |
| --- | --- | --- |
| 自动压缩 | **已启用**，`ETCD_AUTO_COMPACTION_RETENTION` 默认 8 小时 | 无需处理（合规） |
| 碎片整理 | 无自动化 | 定期 `etcdctl defrag`。压缩只回收逻辑版本，物理空间需 defrag 才归还。defrag 会短暂阻塞成员，多节点必须逐台滚动 |
| DB 配额 | `ETCD_QUOTA_BACKEND_BYTES` 无默认，回落到 etcd 内置 2GiB | 大规模集群显式上调（常见 8GiB）。达配额后进入 `NOSPACE` 只读告警，压缩后**不会自动恢复**，须手工 `etcdctl alarm disarm` |
| 恢复演练 | 无 | 至少半年一次同版本环境完整恢复演练并留存记录。`snapshot status` 校验不足以证明可恢复 |
| 备份外传 | 无 | 自行配置（NAS / 对象存储 / 异机房），见 18.6 |
| 静态加密 | 未配置 | 见 18.8 |

DB 体积可经 apiserver 指标查看，无需登录节点：

```bash
kubectl get --raw '/metrics' | grep apiserver_storage_db_total_size_in_bytes
# v22.5.0 单节点实测约 4.2e+07（42MB），距 2GiB 配额尚远
```

### 18.10 etcd 可调参数全集

`spec.etcd` 下可配置项（`kc-installer/cmd/kk/apis/kubekey/v1alpha2/etcd_types.go`）：

`type`、`external`、`port`、`peerPort`、`extraArgs`、`backupDir`、`backupPeriod`、`keepBackupNumber`、`backupScript`、`dataDir`、`heartbeatInterval`、`electionTimeout`、`snapshotCount`、`autoCompactionRetention`、`metrics`、`quotaBackendBytes`、`maxRequestBytes`、`maxSnapshots`、`maxWals`、`logLevel`

有代码兜底默认值的：`autoCompactionRetention`=8、`snapshotCount`=10000、`backupDir`=`/var/backups/kube_etcd`、`backupPeriod`=1440、`keepBackupNumber`=5、`backupScript`=`/usr/local/bin/kube-scripts`。其余未配置时不渲染对应环境变量，回落到 etcd 自身默认值。

**注意：这些参数在部署时的 `config.yaml` 里配置，不在 `cc` 里。** 已建成集群修改需重新执行 `kk` 相关流程，属高危变更。
