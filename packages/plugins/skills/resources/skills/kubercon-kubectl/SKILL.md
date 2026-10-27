---
name: kubercon-kubectl
description: 通过 kubectl 与 kc 运维常青云容器云平台（KuberCon，基于 KubeSphere 商业发行版）。查询平台组件、启停可插拔组件、排查 Pod 与流水线故障、盘点多租户资源（企业空间/项目/DevOps 项目）、核对监控日志栈、处理 License 授权与验签失败、排查 DeepFlow 链路追踪、核对 etcd 备份与容灾能力。当用户提到常青云、KuberCon、kubercon-system、kc 命令、企业空间、ClusterConfiguration、授权文件、链路追踪、etcd 备份，或在常青云集群上做容器云运维时使用。Operate the Changqingyun KuberCon container platform via kubectl and kc.
license: 内部使用
metadata:
  author: 常青云交付与运维
  version: "1.5.0"
  keywords: "常青云,KuberCon,KubeSphere,kubectl,kc,kubernetes,容器云,企业空间,ClusterConfiguration,多租户,License,授权,DeepFlow,链路追踪,OpenTelemetry,etcd,备份,容灾,快照"
  compatibility: 需要 kubectl 与可用的 kubeconfig（平台管理员或等价 RBAC 权限）。目标平台为常青云容器云 v22.x，内容以 v22.6.0 为基线（KubeSphere v3.4.1 商业发行）。kc 为可选增强工具，缺失时全部操作均有 kubectl 等价写法。
---

# 常青云容器云 kubectl 运维技能

在常青云容器云（KuberCon）集群上执行查询、排障与组件运维。常青云是基于 KubeSphere 的商业发行版，**API group、命名空间、组件名都与上游不同**，直接套用 KubeSphere 或原生 Kubernetes 的命令会失败。

## 三条硬性纪律（先读，违反会误判或误操作）

**1. 组件名是** `kubercon-`***，不是上游的** `ks-`***。** 上游 KubeSphere 的 `ks-apiserver` / `ks-console` / `ks-controller-manager` 在常青云里分别叫 `kubercon-apiserver` / `kubercon-ui` / `kubercon-controller-manager`（注意 console 改名为 ui，不是简单换前缀）。部分内部文档仍沿用 `ks-`* 写法，那是上游习惯名，照抄会查不到资源。仍然建议先取真实清单再操作：

```bash
kubectl -n kubercon-system get deploy -o name
# 或（kc 可用时）
kc component list
```

**2. 不要假设 API group 是** `kubesphere.io`**。** 常青云全部改为 `*.kubercloud.com`（见下方 CRD 表）。写命令前用 `kubectl api-resources` 核实。

**3. 生产集群默认只读。** 未经确认不要执行 `delete`、`drain`、`scale`、`rollout restart`、改 `ClusterConfiguration`。这些操作在常青云交付规范里属于 P0/P1 变更，需要变更单与窗口期。写操作前一律先 `--dry-run=client` 或 `--dry-run=server`。

## 平台身份确认

上手一个陌生集群时，先确认它到底是不是常青云，以及版本：

```bash
# 1. 是否存在常青云命名空间与安装器
kubectl get ns | grep -E 'kubercon|kubesphere'
kubectl -n kubercon-system get deploy kubercon-installer

# 2. 平台版本（ClusterConfiguration 的 label 与 tag 字段）
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.metadata.labels.version}{"\n"}'
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.spec.kubercon_tag}{"\n"}'

# 3. Kubernetes 版本与节点
kubectl version --short 2>/dev/null || kubectl version
kubectl get nodes -o wide

# 4. 平台配置（含 jwtSecret 等，注意脱敏）
kubectl -n kubercon-system get cm kubercon-config -o yaml
```

`cc` 是 `clusterconfigurations.installer.kubercloud.com` 的内置简称。若 `kubectl get cc` 报 `NotFound`，说明该集群不是常青云安装器部署的。

**版本要读两个字段，且它们可能不一致。** 实测环境里 `metadata.labels.version` 是 `v22.4.0`，而 `spec.kubercon_tag` 是 `v22.5.0`——前者是安装时写入的标记，后者是当前实际拉取的镜像 tag。判断跑的是哪个版本**以** `kubercon_tag` **和 Pod 实际镜像为准**：

```bash
kubectl -n kubercon-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

镜像 tag 为 `dev` 是常见情况（测试环境或滚动补丁），此时版本只能靠 `kubercon_tag` 与交付记录确认。

**判断是否 v22.6.0 及以后**，看这几个特征比看版本号可靠（现场版本号经常对不上）：

```bash
# 1. cc 里有没有 deepflow 开关（v22.6.0 新增）
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.deepflow.enabled}{"\n"}'

# 2. 第三方镜像仓库前缀（v22.6.0 从 .../mirror/ 改为 .../kubercon/）
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.hub_registry}{"\n"}'

# 3. 本地存储供给者用的是哪套实现（v22.6.0 安装器改用 openebs）
kubectl get sc local-path -o jsonpath='{.provisioner}{"\n"}'
```

**注意：判据 2、3 只对全新安装成立。** 从旧版本升级到 v22.6.0 的集群，cc 保留站点旧值、存储供给者也不会被替换（实测某升级集群 `hub_registry` 仍为 `.../mirror/`、`local-path` 供给者仍为 rancher 实现），此时只有判据 1（deepflow 开关）可靠。

这三处的差别直接影响运维动作：v22.6.0 起 **没有试用 License 兜底**（见 License 章节），且 DeepFlow 默认开启并占 200Gi 存储。接手集群时先确认这两件事，能省掉大半排障时间。

## 命名空间地图

常青云把上游的 `kubesphere-*` 系列命名空间改成了 `kubercon-*`：


| 命名空间                            | 关键工作负载                                                                                                                                                                 | 说明                                                                                                     |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `kubercon-system`               | `kubercon-apiserver`、`kubercon-controller-manager`、`kubercon-ui`、`kubercon-installer`、`redis`、`minio`、`openldap`(STS)、`deepflow-trace-bff`                             | 平台控制面与安装器。BFF 是链路追踪查询层，现场部署与 v22.6.0 安装器部署都会有                                                          |
| `kubercon-monitoring-system`    | `prometheus-k8s`(STS)、`alertmanager-main`(STS)、`thanos-ruler-*`(STS)、`prometheus-operator`、`kube-state-metrics`、`notification-manager-deployment`、`node-exporter`(DS)  | 监控告警与通知。**Grafana 不一定装在这里**                                                                            |
| `kubercon-logging-system`       | `opensearch-cluster-master`(STS)、`opensearch-cluster-data`(STS)、`fluent-operator`、`kube-auditing-operator`、`kube-auditing-webhook-deploy`、`logsidecar-injector-deploy` | 日志、事件、审计。新版是 OpenSearch，不是 ES                                                                          |
| `kubercon-devops-system`        | `kubercon-jenkins`、`devops-apiserver`、`devops-controller`、`s2ioperator`(STS)                                                                                           | DevOps。**未启用 devops 时该命名空间可能只有业务/demo 负载**                                                             |
| `kubercon-controls-system`      | `default-http-backend`、`kubectl-admin`、网关类负载                                                                                                                           | 平台控制类负载。Ingress Controller 是否在此依部署方式而定                                                                 |
| `kubercon-monitoring-federated` | 联邦监控相关                                                                                                                                                                 | 安装器固定创建                                                                                                |
| `kube-federation-system`        | `kubefed-controller-manager`、`kubefed-admission-webhook`                                                                                                               | 多集群（`clusterRole=host` 时）                                                                              |
| `istio-system`                  | Istio 组件                                                                                                                                                               | 启用 servicemesh 后                                                                                       |
| `gatekeeper-system`             | Gatekeeper                                                                                                                                                             | 启用 gatekeeper 后                                                                                        |
| `kube-system`                   | etcd、CoreDNS、CNI、kube-proxy                                                                                                                                            | Kubernetes 自身                                                                                          |
| `deepflow`                      | `deepflow-server`(Deploy)、`deepflow-agent`(DS)、`deepflow-app`、`deepflow-clickhouse`(STS)、`deepflow-mysql`、`deepflow-grafana`                                           | 可观测链路追踪。**v22.6.0 起由安装器自动创建**（旧版本才需现场单独部署）                                                             |
| `open-telemetry`                | `otel-agent`(DS)                                                                                                                                                       | OTel 接入层，与 DeepFlow 分开放。监听 4317(gRPC)/4318(HTTP)                                                       |
| `openebs`                       | `openebs-localpv-provisioner`                                                                                                                                          | 本地路径存储供给者（v22.6.0 安装器方案）。旧版本与现场部署常见的是 `kube-system` 里的 `local-path-provisioner`，两者提供同名 SC `local-path` |


不要照抄本表，用 `kubectl get ns` 核实。实测发现的差异：`openpitrix-system` 与 `kubercon-alerting-system` **可能不存在**（即使 `openpitrix.store.enabled=true`、`alerting.enabled=true`），前者应用商店组件位置随版本变化，后者只在部分任务流程中出现。

## 平台专有 CRD

全部使用 `*.kubercloud.com` group ：


| Kind                                           | apiVersion                            | 复数（kubectl 用）                    | 作用                     |
| ---------------------------------------------- | ------------------------------------- | -------------------------------- | ---------------------- |
| ClusterConfiguration                           | `installer.kubercloud.com/v1alpha1`   | `clusterconfigurations` / `cc`   | 平台总配置，组件启停开关           |
| Workspace                                      | `tenant.kubercloud.com/v1alpha1`      | `workspaces`                     | 企业空间（一级租户）             |
| WorkspaceTemplate                              | `tenant.kubercloud.com/v1alpha2`      | `workspacetemplates`             | 多集群企业空间模板              |
| DevOpsProject                                  | `devops.kubercloud.com/v1alpha3`      | `devopsprojects`                 | DevOps 项目              |
| Pipeline                                       | `devops.kubercloud.com/v1alpha3`      | `pipelines`                      | 流水线                    |
| User                                           | `iam.kubercloud.com/v1alpha2`         | `users`                          | 平台用户                   |
| GlobalRole / WorkspaceRole                     | `iam.kubercloud.com/v1alpha2`         | `globalroles` / `workspaceroles` | 平台级 / 企业空间级角色          |
| Group / GroupBinding                           | `iam.kubercloud.com/v1alpha2`         | `groups` / `groupbindings`       | 用户组                    |
| ResourceQuota                                  | `quota.kubercloud.com/v1alpha2`       | `resourcequotas`                 | 企业空间配额（区别于 K8s 原生同名资源） |
| NamespaceNetworkPolicy                         | `network.kubercloud.com/v1alpha1`     | `namespacenetworkpolicies`       | 项目网络隔离                 |
| IPPool                                         | `network.kubercloud.com/v1alpha1`     | `ippools`                        | Pod IP 池               |
| Cluster                                        | `cluster.kubercloud.com/v1alpha1`     | `clusters`                       | 纳管的成员集群（多集群）           |
| PipelineRun                                    | `devops.kubercloud.com/v1alpha3`      | `pipelineruns`                   | 流水线运行记录                |
| HelmApplication / HelmRelease / HelmRepo       | `application.kubercloud.com/v1alpha1` | `helmapplications` 等             | 应用商店与 Helm 应用          |
| Receiver / NotificationManager / Config        | `notification.kubercloud.com/v2beta2` | `receivers` 等                    | 告警通知渠道                 |
| RuleGroup / ClusterRuleGroup / GlobalRuleGroup | `alerting.kubercloud.com/v2beta1`     | `rulegroups` 等                   | 告警规则                   |
| Dashboard / ClusterDashboard                   | `monitoring.kubercloud.com`           | `dashboards`                     | 自定义监控面板                |
| Rule / Webhook                                 | `auditing.kubercloud.com/v1alpha1`    | `rules` / `webhooks`             | 审计规则                   |
| Gateway / Nginx / Router                       | `gateway.kubercloud.com/v1alpha1`     | `gateways` 等                     | 平台网关                   |


`quota.kubercloud.com` 的 `ResourceQuota` 与 K8s 原生 `ResourceQuota` **同名不同物**，有歧义时写全名：`kubectl get resourcequotas.quota.kubercloud.com`。

平台共有 17 个 `*.kubercloud.com` group，完整清单用 `kubectl api-resources | grep kubercloud.com` 取。

**有些 group 只有 HTTP 接口，没有 CRD，**`kubectl` **查不到。** 它们由 `kubercon-apiserver` 以 kapis 形式提供，用 `kubectl get` 一定报 `NotFound`，别据此判断功能没装：


| Group                              | 用途                                 | 怎么查                                         |
| ---------------------------------- | ---------------------------------- | ------------------------------------------- |
| `license.kubercloud.com/v1alpha1`  | 授权状态、上传、生成申请文件                     | 见下方 License 章节，或看 `kubercon-license` Secret |
| `branding.kubercloud.com/v1alpha1` | 平台品牌定制（Logo、favicon、名称），v22.6.0 新增 | 控制台设置页，或 `kubercon-apiserver` 接口            |


另有一处仓库内不一致值得知道：`ks/kubectl-plugin/install/installer/cluster-configuration.yaml` 里写的是 `installer.kubercloud.io`（`.io` 结尾），而正式 CRD 与集群实际都是 `installer.kubercloud.com`。以 `.com` 为准。

完整字段与更多命令见 [references/REFERENCE.md](references/REFERENCE.md)。

## 三级租户模型

常青云是「平台 → 企业空间（Workspace） → 项目（Project）」三级结构。项目就是 Kubernetes Namespace，通过标签归属企业空间：

```bash
# 列出所有企业空间
kubectl get workspaces

# 某企业空间下的项目（项目即 namespace）
kubectl get ns -l kubercloud.com/workspace=<企业空间名>

# 反查某项目属于哪个企业空间
kubectl get ns <项目名> -o jsonpath='{.metadata.labels}' | tr ',' '\n'

# 企业空间配额与项目配额
kubectl get resourcequotas.quota.kubercloud.com
kubectl -n <项目名> get resourcequota,limitrange
```

归属标签实测为 `kubercloud.com/workspace`（另有 `kubercloud.com/namespace` 标注项目自身名）。系统组件所在的项目归属内置企业空间 `system-workspace`。查不到时用 `kubectl get ns --show-labels` 看实际标签键。

## 组件启停：改 ClusterConfiguration

可插拔组件不是用 `kubectl scale` 开关的，而是改 `ClusterConfiguration` 的 `spec.<组件>.enabled`，由 `kubercon-installer` 调谐生效。

**installer hook 是周期性全量调谐，不是只在变更时触发**（约 80 分钟一轮，每轮 idempotent 重放完整安装 playbook）。这意味着：cc 的任何一次变更都会启动一轮完整安装流程；且**绝不能 `kubectl apply` 一份旧格式的 cc 文件**——`spec.kubercon_tag` 决定全平台组件镜像版本，apply 旧 cc（升级前的备份、旧仓库模板、其他环境的定制文件）等于把整平台按旧版本重装（2026-09-09 有环境因 apply 旧备份导致整平台回退的实证）。版本变更与组件开关一律用 patch 单字段实现；需要对照旧文件时先 `kubectl diff -f <旧文件>` 逐条确认差异，不要直接 apply。

```bash
# 查看当前所有组件开关
kubectl -n kubercon-system get cc kubercon-installer -o yaml | grep -A1 -E '^  [a-z_]+:$' | grep -B1 enabled

# 可用开关：alerting / auditing / devops / events / logging / metrics_server /
#           monitoring / openpitrix.store / servicemesh / network.networkpolicy /
#           edgeruntime / gatekeeper / multicluster / deepflow(v22.6.0+)
```

启停必须用 patch（可审计），不要交互式 `edit`：

```bash
# 先演练
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"auditing":{"enabled":true}}}' --dry-run=server

# 确认后执行
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"auditing":{"enabled":true}}}'

# 跟踪调谐进度（安装器 Job 日志）
kubectl -n kubercon-system logs -l app=kubercon-installer -f --tail=100
```

开启重组件（devops、logging、monitoring、deepflow）会拉起大量 Pod 并申请 PVC，**先确认 StorageClass 与节点余量**。这属于变更窗口内的操作。其中 `deepflow` 的 ClickHouse 默认申请 200Gi，单节点或小规格环境开启前务必先看磁盘。

## 两套命令行工具：kc 与 kk

**别把这两个搞混**，它们职责完全不同：


| 工具   | 职责                                                    | 典型命令                                            |
| ---- | ----------------------------------------------------- | ----------------------------------------------- |
| `kc` | 平台日常运维（组件、流水线、用户、令牌）                                  | `kc com log`、`kc pip run`                       |
| `kk` | 集群安装与节点管理（KubeKey 衍生，源码在 `kc-installer/` 但二进制名是 `kk`） | `kk create cluster`、`kk init os`、`kk add nodes` |


装集群的命令是 `kk create cluster` **/** `kk init os`，不是 `kc create cluster`——`kc` 没有这些子命令。

### kc（平台运维）

可独立执行也可作为 kubectl 插件（`kubectl kc ...`）。非必需，本技能所有操作都有 kubectl 等价写法。

```bash
# 组件（别名 com）
kc component list
kc com log --name <组件> --follow=false
kc com enable devops              # 启停组件，也支持 kc com enable all
kc com kill --name <组件>          # 杀 Pod 触发重建
kc com reset --name <组件>         # 重置为安装器默认配置
kc com scale --name <组件>         # 调整副本
kc com describe --name <组件>      # kubectl describe 包装
kc com exec --name <组件> -- <命令>
kc com edit --name <组件>
kc com watch --name <组件> --image <镜像:标签>   # 镜像热更新

# 流水线（别名 pip）
kc pip create|delete|edit|view|run|dashboard|gc

# 其他
kc user <用户名>                   # 重置密码为与用户名相同的默认值
kc token                          # 打印平台 kubectl token
kc auth add                       # 配置认证
kc option cluster|migrate         # 平台配置
kc s2i create                     # 创建镜像构建器
kc registry                       # 本地起一个 registry
kc tool                           # 安装 kk、ke 等家族工具
kc install kind|kk|installer|k3d  # 装平台（测试用；installer 是装到已有集群）
```

`kc com` 接受**简称**并自动映射到真实工作负载，省去记全名：`apiserver` → `kubercon-apiserver`、`controller`/`controller-manager` → `kubercon-controller-manager`、`console` → `kubercon-ui`、`installer` → `kubercon-installer`、`jenkins` → `kubercon-jenkins`（在 `kubercon-devops-system`）。

`kc com enable` 支持的组件：`devops`、`alerting`、`auditing`、`events`、`logging`、`metrics_server`、`networkpolicy`、`notification`、`openpitrix`、`servicemesh`。它实际就是 patch `kubercon-system/kubercon-installer` 这个 `cc`。

还有一批内置 kubectl 快捷别名，如 `kc pod`（等价于 `-n kubercon-system get pod -w`）、`kc api-log`、`kc console-log`、`kc install-log`、`kc j-log`、`kc devops-enable`。

`kc com watch` 的镜像热更新**不会写回 ClusterConfiguration**，下次安装器调谐会被覆盖。验证通过后必须把镜像版本同步写回 `cc` 对应组件的 image 字段。

`kubernetes_type=k3s` 环境变量下 `kc` 会改走 `k3s kubectl`，且**不加载组件类子命令**。

## 常用排障流程



### 通用三步（任何故障先做）

```bash
kubectl get nodes -o wide
kubectl get pod -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get events -A --sort-by='.lastTimestamp' | tail -50
```

`kubercon-health-check.sh` 脚本把这三步连同平台组件、存储、证书一起跑完。

### 「突然什么都创建不了」——先查准入 Webhook

报错形如 `failed calling webhook "xxx": ... connection refused` / `context deadline exceeded`，或某类资源写操作全部 `Forbidden`，**十有八九是准入 Webhook 的后端服务不可用**，而不是 RBAC 或配额问题。这是本平台最容易被误判的故障类型。

原因是平台注册了大量 Webhook：v22.5.0 实测有 **23 个配置对象、38 条 Webhook 条目，其中 26 条为 `failurePolicy: Fail`**（其余 12 条为 `Ignore`）。`Fail` 的那些后端一旦不可达，匹配到的写操作直接被拒，而不是放行。排查时只需关注 `Fail` 的部分，`Ignore` 的后端挂了只会跳过校验。

```bash
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# 逐条列出失败策略与后端服务，Fail 的才有阻塞风险
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json \
  | python3 -c "
import json,sys
for c in json.load(sys.stdin)['items']:
    for w in c.get('webhooks',[]):
        svc=w.get('clientConfig',{}).get('service',{})
        print('%-50s %-6s -> %s/%s' % (c['metadata']['name'], w.get('failurePolicy'),
              svc.get('namespace','?'), svc.get('name','?')))
"
```

阻塞面对照（v22.5.0 实测），按爆炸半径排序：

| Webhook | 后端服务 | 挂掉后什么写不了 |
| --- | --- | --- |
| `users.iam.kubercloud.com`、`cluster.kubercloud.com`、`network.kubercloud.com` | `kubercon-system/kubercon-controller-manager` | **用户、集群、网络策略全部无法创建或更新**——平台核心功能瘫痪 |
| `validating-webhook-configuration`、`mutating-webhook-configuration` | `kubercon-devops-system/webhook-server-service` | DevOps 项目与流水线相关资源 |
| `kubercon-events-admission-validate` / `-mutate` | `kubercon-logging-system/kubercon-events-admission` | 事件规则 |
| `logsidecar-injector-admission-mutate` | `kubercon-logging-system/logsidecar-injector-admission` | **仅**带 `logging.kubercloud.com/logsidecar-injection=enabled` 标签的命名空间内**建 Pod**（有 `namespaceSelector` 兜底，未开启日志侧车的项目不受影响） |
| `rulegroups.alerting.kubercloud.com` | 告警组件 | 告警规则 |
| `gatekeeper-*`、`istio-*`、`cert-manager-webhook`、`jaeger-operator-*`、`notification-manager-*` | 各自组件 | 对应功能域 |

**注意 `kubercon-controller-manager` 是三个核心 Webhook 的共同后端**，它单点故障的影响远超「控制器不干活」——会直接让平台写操作报 Forbidden。之前现场遇到的 `users.iam.kubercloud.com is forbidden: license signature verification failed` 就是这条链路：请求到了 Webhook，Webhook 里的 License 校验拒绝了它。

定位后端是否健康：

```bash
kubectl -n kubercon-system get deploy,pod -l app=kubercon-controller-manager
kubectl -n kubercon-system get endpoints kubercon-controller-manager
kubectl -n kubercon-system logs deploy/kubercon-controller-manager --tail=100
```

**判断「写操作是否真的被阻塞」用 server 端演练，不要靠间接信号推断：**

```bash
kubectl -n default create configmap wh-probe --from-literal=k=v --dry-run=server
```

`--dry-run=server` 会真实走完准入链但不落盘。返回 `created (server dry run)` 说明准入链通畅；报 `failed calling webhook` 则直接指出是哪条 Webhook。用 `get endpoints` 拼 jsonpath 反推容易因路径写错得到空值、误判成「后端全挂」，server 演练是最少假设的验证手段。

### 平台登录失败（5xx / 超时）

按「前端 → API 网关 → K8s API → Ingress」顺序定位：

```bash
kubectl -n kubercon-system get pod -l app=kubercon-ui          # 前端（上游 ks-console）
kubectl -n kubercon-system get pod -l app=kubercon-apiserver   # API 网关
kubectl -n kubercon-system logs deploy/kubercon-apiserver --tail=100
curl -k https://<VIP>:6443/livez?verbose

# Ingress Controller 位置依部署方式而定，先定位再看日志
kubectl get pod -A | grep -i ingress
```

实测的 selector 是 `app=kubercon-apiserver,tier=backend` 与 `app=kubercon-ui,tier=frontend`，只用 `app=` 部分即可匹配。查不到就退回 `kubectl -n kubercon-system get pod` 全量看。

### 工作负载一直 Pending

常青云多租户下最常见的根因是**项目配额用尽**，而不是节点资源不足：

```bash
kubectl -n <项目名> get resourcequota -o yaml     # 配额是否打满
kubectl -n <项目名> describe pod <pod名>          # 事件里的调度失败原因
kubectl describe node <节点名> | grep -A5 'Allocated resources'
kubectl top node                                  # metrics-server 默认部署，可用
```

**控制面组件的日志不能用 `kubectl logs` 取。** `kk` 部署的集群里 kube-apiserver / kube-scheduler / kube-controller-manager 和 etcd 一样是宿主机 systemd 二进制，既不是 Deployment 也不是静态 Pod：

```bash
kubectl -n kube-system get deploy kube-scheduler   # Error: NotFound（实测）
kubectl -n kube-system get pod | grep scheduler    # 无输出（实测）
```

要看调度器日志必须登录节点：

```bash
journalctl -u kube-scheduler --since '30 min ago' | grep <pod名>
journalctl -u kube-apiserver -n 200
journalctl -u kube-controller-manager -n 200
```

`kube-system` 下只有 `coredns`、`calico-kube-controllers`、`metrics-server`、`local-path-provisioner` 这几个真正的工作负载。



### 流水线全部失败

**Jenkins 的名字有三种，且是 Deployment 不是 StatefulSet，必须先探测。** 不要硬编码：

```bash
kubectl -n kubercon-devops-system get deploy,sts     # 第一步永远是这个
```

代码库里三种命名并存，对应不同部署路径：

| 名称 | 出处 | 类型 |
| --- | --- | --- |
| `devops-jenkins` | `devops/kubercon-devops`、`kubesphere/kubercon-upgrade` 模块 | Deployment（**v22.5.0 实测集群即此**，同命名空间还有 `devops-apiserver`、`devops-controller`、`s2ioperator`） |
| `kubercon-jenkins` | `kubercon-installer/roles/kubercon-devops`、`kc` 内置快捷方式 | Deployment |
| `ks-jenkins` | 上游 KubeSphere 遗留 | Deployment |

探测到实际名字后再取日志（把 `<jenkins>` 换成实际名）：

```bash
kubectl -n kubercon-devops-system describe deploy <jenkins>
kubectl -n kubercon-devops-system logs deploy/<jenkins> --tail=200
kubectl get pod -A -l jenkins/label --field-selector=status.phase=Pending -o wide
```

Jenkins ≥ 2.480 必须跑在 JDK 21 上，日志里 `java -version` 不对就是环境问题。

**`kc` 的 Jenkins 快捷方式硬编码了名字，不一定能用。** `ks/default.go` 里 `j-on` / `j-off` / `j-log` 三条都写死 `deploy/kubercon-jenkins`：

```
j-on   →  -n kubercon-devops-system scale deploy/kubercon-jenkins --replicas=1
j-off  →  -n kubercon-devops-system scale deploy/kubercon-jenkins --replicas=0
j-log  →  -n kubercon-devops-system logs deploy/kubercon-jenkins --tail=50 -f
```

在 Jenkins 实际叫 `devops-jenkins` 的集群上这三条会报 NotFound（v22.5.0 实测环境就是这种情况）。报错不代表 Jenkins 没装，退回上面探测出的真实名字用 `kubectl` 操作即可。

### 监控无数据 / 日志查不出

```bash
# 监控
kubectl -n kubercon-monitoring-system get sts prometheus-k8s
kubectl -n kubercon-monitoring-system describe pod prometheus-k8s-0 | grep -A5 Events
kubectl -n kubercon-monitoring-system logs prometheus-k8s-0 -c prometheus --tail=100 | grep -i corrupt

# 日志（新版后端是 OpenSearch，不是 Elasticsearch）
kubectl -n kubercon-logging-system get pod
kubectl -n kubercon-logging-system get sts opensearch-cluster-master opensearch-cluster-data
kubectl -n kubercon-logging-system logs sts/opensearch-cluster-master --tail=100
kubectl -n kubercon-logging-system get deploy fluent-operator
```

日志后端在 `cc` 里由 `spec.common.opensearch.enabled` 与 `spec.common.es.enabled` 决定，较新版本默认 OpenSearch。索引名格式为 `kc-<前缀>-logging`。查之前先确认用的是哪个后端：

```bash
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.spec.common.opensearch.enabled}{" / "}{.spec.common.es.enabled}{"\n"}'
```

**v22.6.0 起，流式请求不再记录审计响应体。** `logs --follow`、`watch`、`exec`、`attach`、`port-forward`、`proxy` 这几类请求会跳过响应捕获层——捕获层没实现 `http.Flusher`，会把分块响应缓冲住，导致 follow 日志和 watch 事件流推不出去。所以「为什么 follow 日志在审计里查不到完整内容」不是缺陷，是有意为之，与 K8s 原生审计对流式响应的处理一致。请求本身仍会被审计，只是不含响应体。

### Pod 级排障

用 `kubercon-pod-debug.sh` 一次性收集描述、状态、事件、日志、上一次崩溃日志与资源配置。常见状态含义：


| 状态                           | 排查方向                                                                              |
| ---------------------------- | --------------------------------------------------------------------------------- |
| `ImagePullBackOff`           | 镜像地址、`imagePullSecrets`、私有仓库（常青云默认 `docker.changqingyun.cn`，离线环境应替换为客户 Harbor）连通性 |
| `CrashLoopBackOff`           | `kubectl logs --previous` 看崩溃前输出；**同时必须查 `lastState.terminated.reason` 区分 OOMKilled 与应用自身退出**，两者处置完全不同 |
| `Pending`                    | 项目配额、节点选择器、污点容忍、PVC 是否绑定                                                          |
| `CreateContainerConfigError` | 引用的 ConfigMap / Secret 不存在                                                        |
| `Terminating` 卡住不消失          | finalizer 未被清理，见下文                                                                |
| `Error` / `Init:Error`       | Init 容器失败会阻塞主容器，`kubectl logs <pod> -c <init容器名>` 单独看                             |

**OOMKilled 与应用退出必须分清。** 前者要调 limits 或查内存泄漏，后者要看应用日志，只看 `CrashLoopBackOff` 无法区分：

```bash
kubectl get pod -A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    for cs in p['status'].get('containerStatuses',[]):
        t=cs.get('lastState',{}).get('terminated')
        if t and t.get('reason') in ('OOMKilled','Error'):
            print('%-26s %-46s %-22s %-10s restarts=%s' % (
                p['metadata']['namespace'], p['metadata']['name'],
                cs['name'], t['reason'], cs.get('restartCount',0)))
"
```

**容器里没有 shell 时用临时容器，不要放弃排障。** 平台组件多为精简镜像，`kubectl exec` 会报 `executable file not found`。K8s 1.28 的临时容器已 GA（实测集群 server v1.28.15，`kubectl debug` 可用）：

```bash
# 挂一个带工具的临时容器进目标 Pod，共享进程命名空间
kubectl -n <项目> debug -it <pod名> --image=busybox:1.36 --target=<容器名>

# 节点级排障：在节点上起特权容器，可看宿主机文件系统
kubectl debug node/<节点名> -it --image=busybox:1.36
```

临时容器不会重启原 Pod，也不改 spec，是只读排障的安全手段。注意离线环境要把 `--image` 换成客户 Harbor 里的地址。

**资源卡 `Terminating`（多租户平台高频问题）。** 删项目或删企业空间时卡住不动，根因通常是 finalizer 等待的控制器已不可用：

```bash
# 看卡在哪个 finalizer 上
kubectl get ns <项目名> -o jsonpath='{.spec.finalizers}{"\n"}{.status.conditions}{"\n"}'
kubectl get <资源类型> <名称> -n <项目> -o jsonpath='{.metadata.finalizers}{"\n"}'
```

**先修控制器，不要直接摘 finalizer。** 平台 finalizer 多由 `kubercon-controller-manager` 处理，它不健康时删除请求会一直挂着——恢复控制器后往往会自动清理完成。强行 patch 掉 finalizer 会留下孤儿资源（企业空间已删但项目、RoleBinding、配额残留），后续重建同名对象时冲突，属高危操作，需变更单。

**DNS 与 Service 连通性。** 应用报「连不上某服务」时按这个顺序排，不要一上来就怀疑 NetworkPolicy：

```bash
# 1. Service 是否真的选中了 Pod——endpoints 为空说明 selector 与标签不匹配
kubectl -n <项目> get endpoints <服务名>

# 2. CoreDNS 是否健康（kube-system 下的真实工作负载）
kubectl -n kube-system get deploy coredns
kubectl -n kube-system logs deploy/coredns --tail=50

# 3. 从业务 Pod 内部实测解析与连通（无 shell 时配合上面的 debug）
kubectl -n <项目> exec <pod名> -- nslookup <服务名>.<项目>.svc.cluster.local

# 4. 前三步都正常再查网络策略（平台开启 networkpolicy 时才有）
kubectl -n <项目> get networkpolicy
```




### 时间同步（偏移会同时打击 etcd 与证书校验）

**平台不默认配置时间同步。** `kk` 支持 `spec.system.ntpServers` 与 `spec.system.timezone`，但**只有显式配置了 `ntpServers`，kk 才会去动时间同步**；不配就完全不管，节点时钟随机器 BIOS 漂。离线环境尤其常见——没有公网 NTP 源，客户又没自建，装完就是各节点各走各的。

配置了的话，`kk` 用 chrony 实现（`bootstrap/os/tasks.go` 的 `NodeConfigureNtpServer`）：改写 `/etc/chrony.conf`（Debian 系为 `/etc/chrony/chrony.conf`）里的 `server` 行、注释掉 `pool`，服务名 `chronyd.service`（Debian 系 `chrony.service`）。若把某台节点指定为 NTP 服务端，还会追加 `allow 0.0.0.0/0` 和 `local stratum 10`。

**不登录节点也能测出偏移**，用 node lease——它由 kubelet 每 10 秒续期一次，写的是节点自己的时钟：

```bash
NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-node-lease get lease "$NODE" -o json | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
t=datetime.datetime.fromisoformat(d['spec']['renewTime'].replace('Z','+00:00'))
now=datetime.datetime.now(datetime.timezone.utc)
print('偏移 %+.1f 秒（正=节点时钟超前本机）' % (t-now).total_seconds())
"
```

多节点集群要逐个节点跑，节点之间的相互偏移比与本机的偏移更重要。

**判读时注意这测的是「节点 vs 你本机」的相对偏移**，超过 60 秒就该查，但不能直接断定是节点错——也可能是你本机没同步。要定性必须登录节点：

```bash
timedatectl status                    # 看 NTP synchronized 是否为 yes
chronyc tracking                      # 看 System time 偏移量与 Stratum
chronyc sources -v                    # 看是否真有可用时间源
```

时间偏移的危害不止「日志时间戳乱」，它会同时打击几个地方：

- **证书校验**。签发时用签发方的时钟写 `notBefore`，校验时用校验方的时钟比对。节点时钟落后于签发方时，刚签好的证书会被判成 `x509: certificate has expired or is not yet valid`，症状看起来像证书坏了，实际是时钟问题。本平台的 Webhook 证书是**重新部署时现签**的（实测某条 Webhook CA 的 `notBefore` 就是当天），刚装完或刚重启组件时最容易踩到
- **etcd**。Raft 的选举与租约、`lastHeartbeatTime` 的判定都依赖时钟，节点间偏移大会引发莫名的 Leader 切换
- **审计与链路追踪**。跨节点的审计日志和 DeepFlow / OTel 的 span 无法正确排序，排障时会得出错误的因果结论
- **令牌有效期**。带 `exp` 的 ServiceAccount token、OIDC token 会被判成已过期或尚未生效

### 证书有效期

`kk` 签的证书期限差异很大，别一概而论。实测本集群：

| 证书 | 有效期 | 风险 |
| --- | --- | --- |
| apiserver 服务证书 | 2026-07-07 → **2076-06-24**（50 年） | 基本不用管 |
| Webhook CA（如 `users.iam.kubercloud.com`） | 签发日 → **+10 年**，重新部署时重签 | 不用管，但注意 `notBefore` 是当天，见上文时钟问题 |
| **admin kubeconfig 客户端证书** | 2026-07-08 → **2027-07-08（1 年）** | **这才是真正会到期的那个** |

所以「证书到期」在本平台的实际含义,多数情况是**管理员 kubeconfig 过期**,而不是集群证书过期。表现为突然所有 `kubectl` 报 `Unauthorized`,而平台 Web 控制台仍能正常登录。

```bash
# 查自己手里这份 kubeconfig 还能用多久
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -dates -subject

# 查 apiserver 服务证书
echo | openssl s_client -connect <apiserver地址>:6443 2>/dev/null \
  | openssl x509 -noout -dates
```

### 节点磁盘与 inode 耗尽

**第一步是读出运行中 kubelet 的实际驱逐阈值，不要凭默认值推断。** 这一步不能省，因为代码模板与现场实际不一致：

```bash
NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/$NODE/proxy/configz" | python3 -c "
import json,sys
k=json.load(sys.stdin)['kubeletconfig']
for f in ['evictionHard','evictionSoft','evictionPressureTransitionPeriod',
          'imageGCHighThresholdPercent','imageGCLowThresholdPercent']:
    print('%-34s %s' % (f, json.dumps(k.get(f),ensure_ascii=False)))
"
```

v22.5.0 实测集群返回的是：

```
evictionHard   {"memory.available":"300Mi","nodefs.available":"10%",
                "imagefs.available":"15%","nodefs.inodesFree":"5%"}
evictionSoft   null
imageGC        高水位 85% / 低水位 80%
```

磁盘与 inode 的驱逐保护是**在的**。但 v22.6.0 的 `kk` 模板（`kc-installer/cmd/kk/pkg/kubernetes/templates/kubeadm_config.go`）里 `evictionHard` 只写了 `memory.available: 5%` 与 `pid.available: 10%`——**`evictionHard` 是整体替换而非逐键合并**，按该模板渲染出来的 kubelet 会丢掉 `nodefs.available`、`imagefs.available`、`nodefs.inodesFree` 三项。那种集群上磁盘写满和 inode 耗尽**不会触发 DiskPressure、也不会驱逐任何 Pod**，节点会直接硬崩(containerd 无法写层、etcd 无法写 WAL)。现场实际用的是哪套,只有 `configz` 说得准,所以这一步必查。

`kk` 的预检查模块**不检查磁盘空间**（`bootstrap/precheck/` 下无相关实现），所以安装阶段不会因为磁盘不足而告警。

集群侧能看的信号：

```bash
kubectl describe node <节点> | grep -A5 Conditions      # DiskPressure 是否 True
kubectl get node -o custom-columns=\
NAME:.metadata.name,EPHEMERAL:.status.capacity.ephemeral-storage
kubectl get events -A --field-selector reason=Evicted --sort-by='.lastTimestamp'
kubectl get events -A | grep -iE 'FreeDiskSpaceFailed|ImageGCFailed|EvictionThresholdMet'
```

**inode 耗尽 `kubectl` 查不出来，必须登录节点。** 表现很有迷惑性：`df -h` 显示磁盘还有大量剩余，但创建文件报 `no space left on device`：

```bash
df -i                              # Inodes / IUse% 才是要看的列
df -h /var/lib /mnt/localfs        # 对照块空间
# 找 inode 大户（小文件多的目录）
for d in /var/lib/containerd /var/lib/etcd /mnt/localfs /var/log /var/backups; do
  echo -n "$d: "; find "$d" -xdev 2>/dev/null | wc -l
done
```

**本平台的磁盘消耗集中在这几处，排查按此顺序：**

| 路径 | 内容 | 增长特征 |
| --- | --- | --- |
| `/mnt/localfs` | **local-path 的 PV 数据**（实测值，以 `kube-system/local-path-config` 的 ConfigMap 为准，不同集群可能不同） | 监控、日志、ClickHouse 的 PVC 全落在这里，是最大且最容易失控的一处 |
| `/var/lib/containerd` | 镜像与容器层 | 受 imageGC 约束（85%/80%），但 imagefs 与 nodefs 同盘时会互相挤占 |
| `/var/lib/etcd` | etcd 数据与 WAL | 受 `quotaBackendBytes` 约束（默认 2GiB） |
| `/var/backups/kube_etcd` | etcd 备份，保留 5 份 | 随集群规模线性增长 |
| `/var/log` | 容器日志与 journal | 日志量大且未配轮转时增长很快 |

**最需要警惕的链条是:local-path 的 PV 数据和系统盘同在一块盘上。** monitoring、logging、DeepFlow 的 ClickHouse(建议 200Gi)这些组件的 PVC 都落在 `/mnt/localfs`,它们涨起来会挤占宿主机根分区,进而触发 DiskPressure、驱逐业务 Pod——而根因在平台自身的可观测组件,不在业务。单节点 POC 环境这个风险最高,因为所有数据都在同一块盘上。

查 PVC 实际占了多少：

```bash
kubectl get pvc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SIZE:.spec.resources.requests.storage,SC:.spec.storageClassName
```

注意 `local-path` 这类本地存储**不强制执行容量限制**——PVC 申请 10Gi 不代表只会用 10Gi，实际可以写满整块盘。所以 PVC 的 requests 只能当参考，真实占用必须登录节点 `du -sh /mnt/localfs/*` 看。

## 可观测链路追踪（DeepFlow，v22.6.0+）

v22.6.0 把 DeepFlow 收进了安装器，`cc` 里 `spec.deepflow.enabled` **默认为** `true`，全新安装会自动带上。它横跨三个命名空间，排障时别只盯着一个：


| 命名空间              | 负载                                                                                  | 职责                                |
| ----------------- | ----------------------------------------------------------------------------------- | --------------------------------- |
| `deepflow`        | `deepflow-server`、`deepflow-app`、`deepflow-agent`(DS)、ClickHouse(STS)、MySQL、Grafana | 采集与存储，helm umbrella chart 一次装出来   |
| `open-telemetry`  | `otel-agent`(DS)                                                                    | OTel 接入，收 4317/4318 后转发给 DeepFlow |
| `kubercon-system` | `deepflow-trace-bff`                                                                | 平台侧查询聚合层，控制台链路追踪页面走它              |


```bash
# 是否启用
kubectl -n kubercon-system get cc kubercon-installer \
  -o jsonpath='{.spec.deepflow.enabled}{"\n"}'

# 三处一起看
kubectl -n deepflow get pod -o wide
kubectl -n open-telemetry get ds,pod
kubectl -n kubercon-system get deploy deepflow-trace-bff

# ClickHouse 是最容易出问题的一环（默认 200Gi）
kubectl -n deepflow get pvc
kubectl -n deepflow logs sts/deepflow-clickhouse --tail=100
```

排障顺序按数据流走：**应用埋点 →** `otel-agent` **→** `deepflow-server` **→ ClickHouse → BFF → 控制台**。控制台没数据时先确认哪一段断了，不要一上来重启 server。

几个实测约束，踩过才知道：

- **agent 的镜像 tag 必须小于等于 server 的 tag**，版本倒挂会连不上。当前基线 chart `7.1.002`、镜像 `v7.1`。
- `deepflow.storageClass` 留空表示用集群默认 SC（v22.6.0 环境实测是 `local-path`）。**生产环境必须显式指定可靠 SC**，本地路径存储节点一挂数据就没了。
- ClickHouse `volumeSize` 最小 200Gi，存的是 `l7_flow_log`，默认保留 `retentionDays: 30` 天。保留天数要和 BFF 的 `ttl.max_days` 一起改，只改一边会对不上。
- chart 自带 Grafana（`deepflow-grafana`），所以 `kubectl get deploy -A | grep -i grafana` 可能匹配到它，别误判成监控栈的 Grafana。
- 开发环境可能开了 `all_in_one_local_storage`（hostPath），**生产环境必须关**，要用 PVC。

单节点 POC 若资源紧张，关掉它比硬扛更稳妥（属于变更操作，需确认）：

```bash
kubectl -n kubercon-system patch cc kubercon-installer --type=merge \
  -p '{"spec":{"deepflow":{"enabled":false}}}' --dry-run=server
```



## 存储

POC 与单节点环境的 PVC 基本都落在一个名为 `local-path` 的默认 StorageClass 上。**同一个 SC 名字对应两种实现，先看 provisioner 再判断**：

```bash
kubectl get sc
kubectl get sc local-path -o jsonpath='{.provisioner}{"\n"}'
```


| provisioner             | 出处                                              | 供给者位置                                 | 宿主机路径                                         |
| ----------------------- | ----------------------------------------------- | ------------------------------------- | --------------------------------------------- |
| `rancher.io/local-path` | 现场/旧版本常见（v22.5.0 实测）                            | `kube-system/local-path-provisioner`  | **`/mnt/localfs`**（v22.5.0 实测值）               |
| `openebs.io/local`      | v22.6.0 安装器方案（`deploy/local-path-storage.yaml`） | `openebs/openebs-localpv-provisioner` | 见该 YAML 内的 `basePath`                         |

**宿主机路径必须现场查，不要照抄任何文档的默认值。** 常见的 `/opt/local-path-provisioner` 在实测集群上并不成立：

```bash
kubectl -n kube-system get cm local-path-config -o jsonpath='{.data.config\.json}'
# 实测返回 nodePathMap 中 paths=["/mnt/localfs"]
```

这个路径决定排查磁盘占用时该 `du` 哪个目录，查错会得出「磁盘没被平台占用」的错误结论。


两者 SC 同名，`kubectl get sc` 看不出区别，但供给者所在命名空间不同——排查 PVC 不绑定时**先确认该找哪个 Pod 看日志**：

```bash
kubectl -n kube-system get pod | grep local-path     # rancher 实现
kubectl -n openebs get pod                           # openebs 实现（v22.6.0）
```

老集群升级到 v22.6.0 时留意：若原有 rancher 实现仍在运行，两个供给者会争抢同名 SC。以现场实际存在的为准，不要两套并存。

**不论哪种实现，都是单机/测试用的本地存储**，PV 绑在具体节点目录上，节点故障即数据丢失，也不支持跨节点迁移。给客户做生产方案时不能沿用，要换成 Ceph 或企业级共享存储，并在 `cc` 里为 monitoring、logging、deepflow 等组件显式指定 `storageClass`。

排查 PVC 一直 Pending 时先看是不是没有默认 SC，或者宿主机分区满了：

```bash
kubectl get pvc -A --field-selector=status.phase=Pending
kubectl describe pvc <名称> -n <项目>
```



## 备份与 etcd 运维

**先判断 etcd 的部署形态，这决定了后面所有命令的写法，也决定了到底有没有自动备份。** `kk` 支持三种形态，由部署时的 `spec.etcd.type` 决定：


| `etcd.type`                 | 形态                 | 自动备份         |
| --------------------------- | ------------------ | ------------ |
| `kubekey`（**默认**，未显式配置时即此值） | 宿主机 systemd 二进制服务  | **有**，安装时自动配 |
| `kubeadm`                   | kube-system 静态 Pod | **无**        |
| `external`                  | 集群外已有 etcd         | **无**        |


`kk` 的 `create_cluster` 流水线里 `BackupModule` 带 `Skip: etcd.Type != kubekey`——`kubeadm` **和** `external` **两种形态下备份模块直接跳过，一份备份都不会有**。接手集群先确认形态，不要假设备份存在。

```bash
kubectl -n kube-system get pod | grep etcd
```

查不到 etcd Pod 即为 `kubekey` 形态（v22.5.0 现场实测如此，且集群内无 `kubeadm-config` ConfigMap 可交叉印证）。这时候网上和通用手册里那套 kubeadm 流程**全部不适用**，路径对照如下：


| 项目    | KubeKey 部署（常青云默认）                                    | kubeadm 部署（通用文档假设）                       |
| ----- | ---------------------------------------------------- | ---------------------------------------- |
| 进程管理  | `systemctl {status,stop,start} etcd`                 | 移走 `/etc/kubernetes/manifests/etcd.yaml` |
| 二进制   | `/usr/local/bin/etcd`、`/usr/local/bin/etcdctl`       | 容器内                                      |
| 证书目录  | `/etc/ssl/etcd/ssl/`                                 | `/etc/kubernetes/pki/etcd/`              |
| 客户端证书 | `admin-<主机名>.pem` / `admin-<主机名>-key.pem` / `ca.pem` | `server.crt` / `server.key` / `ca.crt`   |
| 环境变量  | `/etc/etcd.env`                                      | 静态 Pod 清单内                               |
| 数据目录  | `/var/lib/etcd`                                      | `/var/lib/etcd`                          |


证书文件名里带**当前主机名**，所以三节点上的命令各不相同，不能复制粘贴同一条。

### 定时备份（仅 `type: kubekey` 形态自动配置）

`kk` 装 etcd 时会顺带装一套备份机制，不需要额外配置，但**必须现场确认它真的在跑**：

```bash
# 需登录节点执行（kubectl 查不到 systemd 状态）
systemctl list-timers | grep backup-etcd     # 定时器是否 active
systemctl status backup-etcd.service         # 上次执行结果
ls -lt /var/backups/kube_etcd/               # 备份是否真在产出
```

代码里的默认值（`kc-installer/cmd/kk/apis/kubekey/v1alpha2/default.go`）：


| 项目         | 默认值                                                 |
| ---------- | --------------------------------------------------- |
| 备份脚本       | `/usr/local/bin/kube-scripts/etcd-backup.sh`        |
| systemd 单元 | `backup-etcd.service`（oneshot）+ `backup-etcd.timer` |
| 执行时间       | 每天 `02:00`（由 `BackupPeriod` 1440 分钟换算）              |
| 备份目录       | `/var/backups/kube_etcd/etcd-<年-月-日-时-分-秒>/`        |
| 保留份数       | **5 份**                                             |


每次备份产出两份东西：v2 格式的 `backup`（`ETCDCTL_API=2 etcdctl backup`）和 v3 格式的 `snapshot.db`（`etcdctl snapshot save`）。**恢复只用** `snapshot.db`**。**

### 五个必须知道的坑

**运维手册第 11 章的备份频率和保留策略与代码不符。** 手册写「每 6 小时快照、保留至少 7 天」，实际代码是**每天 02:00 一次、只保留 5 份**（约 5 天）。给客户承诺 RPO 之前按现场 `systemctl list-timers` 的实际值核对，别引用手册数字。

`backupPeriod` **的换算不是线性的，改了不一定生效。** `BackupTimeOnCalendar()` 的换算规则有两个陷阱：

- **≥ 1440 一律变成每天 02:00**。想配「每两天一次」填 2880，结果还是每天，值被静默忽略
- **非整小时的值会被错误换算**。填 90（想要 90 分钟一次）会渲染成 `*-*-* 00/1:30:00`，实际是**每小时的第 30 分**执行，频率翻了一倍

只有 60 的整数倍且小于 1440 的值符合直觉（如 360 → 每 6 小时）。改完必须用 `systemctl list-timers` 核对实际触发时间，不能只看配置。

**v2 备份那步已弃用，且失败会让整个备份静默中止。** 脚本开头是 `set -o errexit`，第一步跑 `ETCDCTL_API=2 etcdctl backup`——这是 etcd v2 时代的命令，v3.5 起已废弃（打包版本为 v3.4.13 / v3.5.13，尚可运行，但后续升级到更高版本会失效）。一旦这步失败，脚本立即退出，**后面真正有用的** `snapshot.db` **根本不会生成**。而 timer 是 oneshot 服务，失败只体现在 `systemctl status` 里，没人看就发现不了。这是「以为有备份、实际没有」最可能的成因，所以巡检必须看 `ls -lt /var/backups/kube_etcd/` 的实际产出时间，而不是看 timer 是否 active。

**轮转靠** `rm -rf` **裸删。** 脚本末尾是 `ls -lt | awk '{if(NR > 5) print "rm -rf "$9}' | sh`，作用在备份目录的父目录上。把 `keepBackupNumber` 配成 0 或改动 `backupDir` 指向非专用目录，都有删掉无关数据的风险。

**备份落在本机磁盘，不是容灾。** `/var/backups/kube_etcd` 就在节点本地盘上，节点整机损坏备份一起没。单节点 POC 环境更是数据和备份同盘，等于没有备份。**必须额外做外传**（NAS / 对象存储 / 异机房），这一步安装器不管。

### 快照是密级材料，必须按 Secret 对待

**etcd 快照里的所有 Secret 都是明文。** `kk` 没有配置 Kubernetes 静态加密（`EncryptionConfiguration` / `--encryption-provider-config`，代码中无相关实现），意味着 Secret 在 etcd 里以 base64 而非密文存储。拿到 `snapshot.db` 就等于拿到集群全部凭据——镜像仓库密码、数据库连接串、TLS 私钥、License 私钥。

因此外传备份时：

- 传输和落盘都要加密（`gpg` 或对象存储服务端加密），**不能明文丢在共享 NAS 上**
- 备份存储的访问权限要按最高密级管，与集群管理员权限同级
- 客户有等保或密评要求时，这是必答项：**平台默认不启用静态加密，需在交付时单独配置**



### 行业标准要求但平台未覆盖的运维项

以下都是 etcd 标准运维动作，安装器不做、也没有自动化，需要纳入运维手册人工执行：

**碎片整理（defrag）。** `ETCD_AUTO_COMPACTION_RETENTION` 默认为 8（小时），自动压缩是开启的——但**压缩只回收逻辑版本，不归还物理磁盘空间**。长期运行后 DB 文件持续膨胀，需定期 `etcdctl defrag` 才能真正收缩。defrag 期间成员短暂阻塞，多节点要逐台滚动做，不能并发。

**DB 配额与告警解除。** `ETCD_QUOTA_BACKEND_BYTES` 无默认值（不配置则用 etcd 内置的 2GiB）。达到配额后 etcd 进入只读的 `NOSPACE` 告警状态，整个集群无法写入，**且压缩后不会自动恢复**，必须手工 `etcdctl alarm disarm`。大规模集群应显式上调（常见 8GiB）。

当前 DB 体积可以不登录节点查看：

```bash
kubectl get --raw '/metrics' | grep apiserver_storage_db_total_size_in_bytes
# 实测 v22.5.0 单节点环境约 42MB，距 2GiB 配额尚远
```

**恢复演练。** 备份的有效性只能靠恢复验证。行业惯例是至少半年一次在同版本测试环境做完整恢复演练，并留存记录。仅有 `snapshot status` 校验不足以证明可恢复。

### 变更窗口前的手工快照

任何升级、扩缩容、改 `cc` 之前先手工打一份，这是唯一的回滚保障。在 etcd 节点上执行（注意主机名替换）：

```bash
export ETCDCTL_API=3
HOST=$(hostname)
SNAP=/var/backups/etcd-manual-$(date +%F-%H%M).db

/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 snapshot save $SNAP \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-$HOST.pem \
  --key=/etc/ssl/etcd/ssl/admin-$HOST-key.pem

# 校验，totalKey 为 0 说明快照无效
/usr/local/bin/etcdctl snapshot status $SNAP --write-out=table
```

**校验通过再动手，并把快照传出集群。** 未经 `snapshot status` 校验的备份不能算备份。

### 恢复

恢复是 P1 高危操作，**不属于本 skill 的自动执行范围**——需要停 apiserver、停 etcd、三节点分别 restore、重建集群 token，任一步错都会加重故障。这里只给判断依据和纪律：

- 单个 etcd 成员故障，**不要恢复**，走成员替换（移除坏成员 + 加新成员），数据从健康节点同步
- 只有全部成员数据都不可用时才走快照恢复
- 清理数据目录一律用带时间戳的 `mv` 备份，**禁止** `rm -rf /var/lib/etcd/member`，保留回滚后路
- 三节点的 restore 命令中 `--name` 与 `--initial-advertise-peer-urls` 各不相同，必须逐台改写

集群整体健康度可以不登录节点、经 apiserver 侧面确认：

```bash
kubectl get --raw='/livez/etcd'      # 返回 ok 表示 apiserver 到 etcd 链路正常
kubectl get --raw='/readyz?verbose' | grep -i etcd
```



### etcd 监控默认关闭，但规则是齐的

```bash
kubectl -n kubercon-system get cc kubercon-installer -o jsonpath='{.spec.etcd}{"\n"}'
# {"endpointIps":"localhost","monitoring":false,"port":2379,"tlsEnable":true}
```

`monitoring: false` 是默认值。**平台其实自带了一整套标准 etcd 告警规则**（`kubercon-installer/roles/kubercon-monitor/files/prometheus/etcd/`，对齐上游 etcd-mixin，共 11 条）：

`etcdMembersDown`、`etcdInsufficientMembers`、`etcdNoLeader`、`etcdHighNumberOfLeaderChanges`、`etcdHighNumberOfFailedProposals`、`etcdHighNumberOfFailedGRPCRequests`、`etcdGRPCRequestsSlow`、`etcdHighCommitDurations`、`etcdHighFsyncDurations`、`etcdMemberCommunicationSlow`、`etcdExcessiveDatabaseGrowth`

覆盖了行业标准关注的全部核心 SLI（成员存活、Leader 稳定性、WAL fsync 与 backend commit 延迟、DB 增长）。**但开关关着，这 11 条全部不生效**——集群实际处于「控制面存储无任何告警」的状态，etcd 磁盘变慢、DB 异常增长都不会有人知道。

生产交付应打开。多节点还要把 `endpointIps` 从 `localhost` 改成实际 IP 列表（逗号分隔），否则只采到本机一个成员。属配置变更，走变更单。

### 应用级备份不在平台内

安装器和后端代码里**没有 Velero，也没有任何应用级备份组件**——`kubercon-installer/roles/` 下无相关角色，`kc` 也没有 backup 子命令。运维手册第 11.2 章提到的 Velero 属于需要自行安装的外部方案，不要以为装完平台就有了。客户问「平台自带备份吗」，准确回答是：**etcd 有自动定时备份（控制面元数据），应用数据和 PV 需要另配方案。**

## License

常青云是商业发行版，带 License 校验。**没有 License CRD**，别去找 `kubectl get licenses`——授权存在 Secret 里。

**v22.6.0 起没有试用授权兜底了。** 旧版本在无授权时会自动生成一份试用 License（`EnsureTrialLicense`），v22.6.0 把 `pkg/models/license/trial.go` 整个删除，并新增 RSA 验签（`vendor_key.go`、`sign/rsa_verify.go`）。现在**没有厂商签发的正式** `.lic`**，平台所有写操作都会被拒**，登录本身不受影响。交付现场按旧版经验「先装完再慢慢补授权」会直接卡住。

### 两个 Secret，别搞混


| Secret             | 内容                                                                                | 谁生成                            |
| ------------------ | --------------------------------------------------------------------------------- | ------------------------------ |
| `kubercon-private` | `private.pem`（客户端 RSA-2048 私钥）、`public.pem`（客户端公钥）、`server_public.json`（服务端公钥元数据） | 安装器自动生成（`openssl genrsa 2048`） |
| `kubercon-license` | `license`（解析缓存）、`license.file`（原始授权文件，真相源）、`license.history`（历史记录）                | 上传授权后由平台写入                     |


```bash
# 密钥材料：确认存在即可，不要打印内容
kubectl -n kubercon-system get secret kubercon-private

# 授权 Secret：type 为 kubercloud.com/license
kubectl -n kubercon-system get secret kubercon-license \
  -o jsonpath='{.type}{"\n"}'

# 看有哪些 key（不解码内容）
kubectl -n kubercon-system get secret kubercon-license -o json 2>/dev/null | \
  python3 -c "import json,sys; print(list(json.load(sys.stdin).get('data',{}).keys()))"

# 解析缓存内容（可读，用于确认到期时间与授权范围）
kubectl -n kubercon-system get secret kubercon-license \
  -o jsonpath='{.data.license}' | base64 -d
```

**绝对不要删除或重建** `kubercon-private`**。** 授权文件是用这把私钥解密的，密钥一换，已签发的 License 全部失效，只能找厂商重签。安装器的 `roles/kubercon-core/license` 也是这个逻辑——检测到 Secret 已存在就跳过，不覆盖。

### 授权申请流程（顺序不能颠倒）

签发依赖集群自己生成的公钥，所以**必须先把平台装起来，才能申请授权**，不能提前拿一份通用 `.lic` 带到现场。

1. 平台安装完成，安装器生成 `kubercon-private`
2. 调 `GET /license/request` 生成申请文件（内含 `pubKey`，取自 `public.pem`）
3. 把申请文件交厂商签发，拿回 `.lic`
4. 控制台授权页面上传，或调 `POST /license`

授权接口都在 `license.kubercloud.com/v1alpha1`（kapis HTTP，经 `kubercon-apiserver`，**不是 CRD**）：`GET /license` 查状态、`POST /license` 上传、`DELETE /license` 删除、`GET /license/request` 生成申请文件。生效状态不在任何 CR 的 status 里，只能通过这个接口查。

### 验签失败排障

写操作报这类错，是授权没通过验签，不是 RBAC 问题：

```text
users.iam.kubercloud.com is forbidden: state: invalid, reason: authorization file is invalid:
license signature verification failed: signature is empty (forged or unsigned license rejected)
```

`signature is empty` 说明拿到的授权文件签名字段为空——通常是用了未签发的模板文件，或手工改过内容导致签名失效。处理方式只有一条：换厂商正式签发的 `.lic`。**不要试图手工编辑授权文件**，改任何一个字节都会验签失败。校验逻辑在 `kubercon-backend/pkg/models/license/license.go`，配套过滤器是 `pkg/apiserver/filters/license.go`。

`kubercon-config` ConfigMap 含 `jwtSecret`，`kubercon-private` 含私钥，排障时只看必要字段，不要整份复制到工单或聊天里。

## 输出格式与安全用法

```bash
-n, --namespace=<项目>        # 常青云的「项目」即 namespace
-A, --all-namespaces
-o wide|json|yaml|name        # jsonpath / custom-columns 见 REFERENCE.md
-l, --selector=<标签>
--dry-run=client|server       # 写操作前必做
--show-labels                 # 查租户归属标签时很有用
```

删除或重启前一律先演练：

```bash
kubectl -n <项目> delete pod <pod名> --dry-run=client
kubectl -n kubercon-system rollout restart deploy/<组件> --dry-run=server
```



## 辅助脚本


| 脚本                                                                       | 用途                                            |
| ------------------------------------------------------------------------ | --------------------------------------------- |
| [scripts/kubercon-health-check.sh](scripts/kubercon-health-check.sh)     | 平台整体健康巡检（节点、控制面、组件、存储、证书、异常 Pod）              |
| [scripts/kubercon-pod-debug.sh](scripts/kubercon-pod-debug.sh)           | 单 Pod 排障信息一次性收集                               |
| [scripts/kubercon-component.sh](scripts/kubercon-component.sh)           | 平台组件清单、状态与日志（kc 缺失时自动退回 kubectl）              |
| [scripts/kubercon-tenant-inspect.sh](scripts/kubercon-tenant-inspect.sh) | 租户盘点：企业空间 → 项目 → 配额 → 工作负载                    |
| [scripts/kubercon-deepflow-check.sh](scripts/kubercon-deepflow-check.sh) | 链路追踪链路自检：开关 → DeepFlow → OTel → BFF → 存储      |
| [scripts/kubercon-backup-check.sh](scripts/kubercon-backup-check.sh)     | 备份能力自检：etcd 形态判定、健康度、监控开关、应用级备份缺口，并输出节点侧待核对清单 |


脚本全部只读，不含写操作。首次使用先 `chmod +x scripts/*.sh`。

## 参考

- [references/REFERENCE.md](references/REFERENCE.md) — 常青云 kubectl 命令全参考
- 平台内部文档：`docs/kubercon-ops-manual.md`（运维手册）、`docs/kubercon-user-manual.md`（用户手册）
- [kubectl 官方文档](https://kubernetes.io/docs/reference/kubectl/)

---

**版本：** 1.5.0　**适配：** 常青云容器云 v22.x，内容以 **v22.6.0** 为基线（KubeSphere v3.4.1）
**改编自：** SkillHub 社区 kubectl skill（MIT），已按常青云 API group、命名空间、组件命名与运维规范重写

**v1.5.0 的修正（2026-09-09，基于 20.44 cc 回退事故核查；此前页脚版本号停留在 1.1.0 与 frontmatter 不同步，已一并统一）：**

1. **删除「回滚 = `kubectl apply -f cc-backup.yaml`」配方**（REFERENCE.md）。apply 完整旧 cc 等于把整平台按旧版本重装（2026-09-09 实证：apply 升级前备份致 apiserver/controller-manager/ui 全量回退），改为只 patch 目标字段；备份文件仅用于 `kubectl diff` 逐条核对。
2. 新增 installer hook **周期性全量调谐**的说明（约 80 分钟一轮 idempotent 重放安装 playbook，非仅变更触发），SKILL.md「组件启停」与 REFERENCE.md §2 两处。
3. spec 顶层键清单补上 `deepflow`（v22.6.0 为 24 个），消除与 deepflow 开关表的自相矛盾。
4. v22.6.0 判定特征加升级集群警示：hub_registry 前缀与 local-path 供给者两判据**只对全新安装成立**，升级集群 cc 保留旧值（实测某升级集群仍为 `/mirror/` + rancher 实现），仅 deepflow 开关可靠。
5. 修正 REFERENCE.md 存储：rancher 与 openebs 两套实现的宿主机路径**来源不同**（rancher 实测 `/mnt/localfs`，openebs 模板 `/opt/local-path-provisioner`），替换"两者都配成 /opt"的错误表述。
6. kubercon-health-check.sh 组件开关清单补 `deepflow`（v22.6.0 核心开关）；修正"Webhook 全部为 Fail"的错误注释（实测 26/38 条为 Fail）。

**v1.1.0 相对 v1.0.0 的修正（均已对照 v22.6.0 源码核实）：**

1. License 章节重写。旧版称「无授权时平台会自动创建试用 License」，v22.6.0 已删除 `trial.go`，**无正式授权则所有写操作被拒**；补充了申请流程与 `signature is empty` 排障。
2. DeepFlow 由「现场单独部署」改为「安装器默认部署」，新增独立运维章节与 `spec.deepflow` 开关。
3. 新增存储章节：默认 SC `local-path` 的两种实现（`rancher.io/local-path` 与 v22.6.0 的 `openebs.io/local`），同名不同物，仅测试用。
4. 新增 kapis-only group 说明（`license.` / `branding.`），避免误以为 `kubectl get` 查不到就是没装。
5. 新增 v22.6.0 版本特征判定，以及流式请求不记录审计响应体的说明。
