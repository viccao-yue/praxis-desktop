# kubercon-deploy 变更记录

## 1.7.0 — 2026-09-16

青云 3 节点重置复测验收通过后的交付硬化（在 1.6.1 现场修复上收口为正式版）：

- **断点续跑**：新增 `resume-from-status.sh`，按远端 init-os/registry/create 状态给出 NEXT，可选 `KC_RESUME_EXECUTE=1` 续 D6R/D6/D8
- **D9 SSH 引导**：新增 `bootstrap-multinode-ssh.sh`（跳板 AllowTcpForwarding、node1 自信任 id_rsa、peer 公钥、可选密码一次性写入、D9H 刷新 known_hosts）
- **单节点 hairpin 对齐**：`prepare-single-node-config` 的 kk `hosts.address` 改为 `internalAddress`；D6 前单节点同样净化空骨架与 `127.0.1.1`
- **heavy 传包**：glob basename 去重；`KC_RSYNC_RETRIES` 重试；远端字节数+sha256，失败删坏包并提示重跑
- **登录验收**：`accept-check` 强制 UI `expire` cookie + 浏览器 Cookie 提示（同 EIP 重装闪退）
- **D2**：prepare 打开 `AllowTcpForwarding`；chronyd/离线 `rpms-min`（承 1.6.1 现场）
- 文档：开场检查表、双地址约定统一；版本与 SUCCESS-CRITERIA 对齐 1.7.0
- 现场：`local-haproxy` 3 节点重置首装+验收已通过；**delivery-certified** 仍须补 D11 HA 演练

## 1.6.1 — 2026-09-15

青云 3 节点首装复盘：把「现场修完才过」变成「脚本前置，少报错」：

- **inventory**：`hosts.address` 一律渲染为 `internalAddress`；公网 EIP 只用于本机 SSH，避免 SaveKubeConfig 公网 hairpin 假失败
- **D6 前**：`precreate-sanitize.sh` 清空 kubernetes/etcd 骨架、hosts 置顶并去掉 `127.0.1.1`/`fe80` 抢解析；`start-create-cluster.sh` 重渲染 config + sanitize + full 门禁
- **first-create**：无 containerd 时 fix 直接跳过；watchdog 容忍缺 crictl；无 config.toml 时跳过 post-registry CRI 门禁
- **SaveKubeConfig healer**：日志命中公网 6443 超时且本机 API/三节点 Ready 时记 SUCCESS，不再整场 FAILED
- **OpenEBS**：`--with-local-storage` 未装上时用 `local-path-storage.yaml` 补装；PVC smoke 用 `nodeSelector`（兼容 WaitForFirstConsumer）
- **登录**：OAuth client=`kubercloud`；`accessTokenMaxAge 0s→2h`；无 redis 时改写 UI config；清 admin uninitialized；验收强制 `expires_in` + UI `expire` cookie
- **探针**：`probe-multinode-network` 失败时明确提示云安全组，避免误判「主机防火墙已关」
- 测试：多节点 render 断言不得把 `192.0.2.*` 写入 kk `hosts.address`

## 1.6.0 — 2026-09-15

多节点正式交付闭环（3 control-plane/etcd + 任意 worker）：

- 新增 JSON inventory 契约、规范化指纹和确定性 KubeKey config 渲染；支持 `local-haproxy`、`local-kube-vip`、`external-prod`
- 新增全节点 hardware/full/post-registry 门禁及 D3 临时端口探针：资源/分盘/时钟、node1 真实 SSH、hosts/DNS、TCP/UDP、TLS、CRI 镜像
- 新增 D2/D3 全节点系统准备和 D5 `init os` screen 状态机
- containerd fix/watchdog 扩展到全部节点，并由 node1 aggregate 监控；任一节点失败终止 D6
- D7 扩展为全节点恢复与残留复检，支持孤儿 RUNNING 状态并输出 aggregate BLOCKED/SUCCESS
- 平台存储按 profile 分流；多节点禁止 local-path 退化，对每个 worker 执行 PVC mount/write smoke
- 验收增加 3 etcd endpoint、3 apiserver `/readyz`、LB/VIP、全节点 registry pull
- 新增 D11 逐控制面 HA 故障切换演练
- 新增 3CP+0/2 worker、三 profile、拓扑反例、全节点脚本枚举测试
- 认证状态拆分：本地测试完成仅 `implementation-complete`；真实 3 VM 首装/恢复/HA 通过后才能 `delivery-certified`
- 复审修补：全节点 CA 兼容 kk 下发的 `ca.crt`；默认 SC 认 kubectl `(default)`（含 beta 注解）；验收 API 身份与 kubeconfig domain 对齐；HA 从存活控制面探测；`external-prod` 不再误走本机 registry fix/watchdog

## 1.5.0 — 2026-09-15

严格审计 v1.4.2 后的首过闭环：

- 新增 `prepare-single-node-config.sh`：V22.6 单节点确定性拓扑，`etcd/control-plane/worker/registry` 四角色都且仅指向 node1
- `validate-cluster-config.sh` 改为执行级 Python 语义门禁：节点数、角色引用、IP/CIDR、私钥、默认密码、平台清单均硬校验
- `apply-platform-after-k8s.sh` 先改写离线镜像再 apply；等待 local-path provisioner；按 YAML 路径关闭 DeepFlow/重组件并回读断言
- `fix-registry-containerd.sh` 把 containerd active、CRI RuntimeService、CRI pause pull 设为硬后置条件
- D6R 指纹改为 installer/offline 内容指纹，避免路径名或 D4 后非 registry 配置变化造成假失配
- watchdog 新增状态文件与 CRI 自检；D6 runner 监控 watchdog，异常立即停止安装器
- 新增 `stop-containerd-watch.sh` 与 `reset-registry-attempt.sh`，补齐失败状态机
- `accept-check.sh` 默认从部署 config 推导 API 身份，并实际验证控制台 HTTP 与 admin OAuth 登录
- 测试加入真实 config fixture 和登录失败路径，不再只检查脚本字符串存在

## 1.4.2 — 2026-09-15

自检发现并修复的 **P0**（否则不能对下一任模型声称接近首过）：

- **`KC_SKIP_CONFIG_PATCH` 未传入远端**：heredoc 单引号导致 D6 仍改 config、破坏 D6R fingerprint → 改为第 6 参数显式传递
- **D6 顺序**：先远端预检 status/etcd 残留/**etcd 存在判定物**/screen，再 validate → fix → watchdog → create
- **D6R 强制** `validate-cluster-config.sh`（需 `KC_PROFILE`）
- **新增** `scripts/patch-cluster-config.sh`：D4 后自动写入 namespaceOverride / insecureRegistries / privateRegistry
- **validate** 收紧 privateRegistry 非空；提示缺 local-path
- **新增** `references/SUCCESS-CRITERIA.md`：明确「安装成功」与外部不可保证项

## 1.4.1 — 2026-09-15

严格审计 v1.4.0 后的 **P0 修复**：

- 本机调用 `watch-containerd-registry.sh`；失败则 die
- 强制显式 `KC_PROFILE` / `KC_REGISTRY_MODE`
- `validate-cluster-config.sh`；D6 fix 默认不改 config（意图；1.4.2 才真正传到远端）
- REFERENCE 删除「只有 native」；D2 补 python3/curl

## 1.4.0 — 2026-09-15

基于青云 POC 笔记：detect-local、rsync light/heavy、kk-artifact-then-cc、recover/fix/apply 文档化。
（watchdog 接线在 1.4.0 不可靠，以 1.4.1+ 为准。）

## 1.3.0

- 初版技能包结构、两阶段预检、screen 后台安装、模式 C 门禁
