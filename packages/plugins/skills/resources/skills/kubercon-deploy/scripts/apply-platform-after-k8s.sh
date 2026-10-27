#!/usr/bin/env bash
# PROFILE=kk-artifact-then-cc 时：在 K8s Ready 后 apply 平台安装器与 ClusterConfiguration。
# 依赖 node1 上已有 kubectl（kk 装完后通常有），以及同目录：
#   kubercon-installer.yaml / cluster-configuration.yaml / local-path-storage.yaml(可选)
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
  -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOYMENT_PROFILE=single
STORAGE_CLASS_EXPECTED=""
STORAGE_MANIFEST=""
if [[ -n "$INVENTORY" ]]; then
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  DEPLOYMENT_PROFILE=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ inv_address _ inv_user inv_port _ <<<"$first"
  KC_NODE1="${KC_NODE1:-$inv_address}"
  SSH_USER="$inv_user"; SSH_PORT="$inv_port"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
    -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -p "$SSH_PORT")
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
  LOCAL_REGISTRY=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["privateRegistry"])' "$INVENTORY")
  if [[ "$DEPLOYMENT_PROFILE" == external-prod ]]; then
    STORAGE_CLASS_EXPECTED=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["storageClass"])' "$INVENTORY")
    STORAGE_MANIFEST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["storageBootstrapManifest"])' "$INVENTORY")
  fi
fi
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ "${KC_CONFIRMED_D8I:-}" == "确认 D8I" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D8I='确认 D8I' 或 KC_AUTONOMOUS=1"
[[ "${KC_CONFIRMED_D8C:-}" == "确认 D8C" || "${KC_AUTONOMOUS:-}" == "1" ]] ||
  die "需要 KC_CONFIRMED_D8C='确认 D8C' 或 KC_AUTONOMOUS=1"

LOCAL_REGISTRY="${LOCAL_REGISTRY:-${KC_LOCAL_REGISTRY:-docker.kubercon.local}}"
ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-KuberC0n#2025}"
KUBERCON_TAG="${KC_KUBERCON_TAG:-v22.6.0}"
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "KC_REMOTE_DIR 含不安全字符"
[[ "$LOCAL_REGISTRY" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "KC_LOCAL_REGISTRY 格式错误"
[[ "$KUBERCON_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "KC_KUBERCON_TAG 格式错误"
[[ ${#ADMIN_PASSWORD} -ge 8 && ${#ADMIN_PASSWORD} -le 64 &&
   "$ADMIN_PASSWORD" =~ [a-z] && "$ADMIN_PASSWORD" =~ [A-Z] && "$ADMIN_PASSWORD" =~ [0-9] ]] ||
  die "KC_ADMIN_PASSWORD 必须 8~64 位，且至少含一个大写字母、一个小写字母和一个数字"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "umask 077; mkdir -p $(printf '%q' "$REMOTE_DIR"); cat > $(printf '%q' "$REMOTE_DIR/.render-platform-config.py")" \
  < "$SCRIPT_DIR/render-platform-config.py" ||
  die "上传 ClusterConfiguration 渲染器失败"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$LOCAL_REGISTRY" "$ADMIN_PASSWORD" "$KUBERCON_TAG" "$DEPLOYMENT_PROFILE" "$STORAGE_CLASS_EXPECTED" "$STORAGE_MANIFEST")" <<'EOS'
set -euo pipefail
dir="$1"; local_registry="$2"; admin_password="$3"; tag="$4"; deployment_profile="$5"
expected_sc="$6"; storage_manifest="$7"
cd "$dir"

export KUBECONFIG=/root/.kube/config
command -v kubectl >/dev/null || { echo "错误: 无 kubectl"; exit 1; }
command -v python3 >/dev/null || { echo "错误: 无 python3"; exit 1; }
command -v curl >/dev/null || { echo "错误: 无 curl"; exit 1; }
grep -q '^SUCCESS ' /tmp/kubercon-create.status 2>/dev/null ||
  { echo "错误: create cluster 状态不是 SUCCESS，禁止安装平台"; exit 1; }
nodes=$(kubectl get nodes --no-headers)
if [[ -z "$nodes" ]] || ! echo "$nodes" | awk '$2 != "Ready" {bad=1} END {exit bad}'; then
  echo "错误: 节点未全部 Ready"; echo "$nodes"; exit 1
fi
echo "$nodes"
kubectl get ns

# 所有镜像改写必须早于任何 kubectl apply。
[ -f kubercon-installer.yaml ] || { echo "缺少 kubercon-installer.yaml"; exit 1; }
[ -f cluster-configuration.yaml ] || { echo "缺少 cluster-configuration.yaml"; exit 1; }
for f in kubercon-installer.yaml local-path-storage.yaml "$storage_manifest"; do
  if [[ -f "$f" ]] && grep -q 'docker\.changqingyun\.cn' "$f"; then
    sed -i "s#docker\.changqingyun\.cn#${local_registry}#g" "$f"
    echo "rewrote $f image registry -> ${local_registry}"
  fi
done
if grep -R 'image: *docker\.changqingyun\.cn' kubercon-installer.yaml local-path-storage.yaml "$storage_manifest" 2>/dev/null; then
  echo "错误: apply 清单仍含公网镜像"
  exit 1
fi

default_sc() {
  kubectl get sc --no-headers 2>/dev/null | awk '/\(default\)/{print $1; exit}'
}

# 存储按交付 profile 分流；多节点严禁退化到单节点 local-path。
# kubectl 的 (default) 同时覆盖正式注解和 storageclass.beta.kubernetes.io/is-default-class。
if [[ "$deployment_profile" == external-prod ]]; then
  [[ -f "$storage_manifest" ]] || { echo "错误: 缺外部存储 bootstrap manifest"; exit 1; }
  kubectl apply -f "$storage_manifest"
  for _ in $(seq 1 60); do kubectl get sc "$expected_sc" >/dev/null 2>&1 && break; sleep 5; done
  kubectl get sc "$expected_sc" >/dev/null 2>&1 ||
    { echo "错误: 外部 StorageClass 未创建: $expected_sc"; exit 1; }
  while read -r current_default; do
    [[ -n "$current_default" && "$current_default" != "$expected_sc" ]] || continue
    kubectl annotate sc "$current_default" \
      storageclass.kubernetes.io/is-default-class- \
      storageclass.beta.kubernetes.io/is-default-class- --overwrite || true
  done < <(kubectl get sc --no-headers | awk '/\(default\)/{print $1}')
  kubectl annotate sc "$expected_sc" storageclass.kubernetes.io/is-default-class=true --overwrite
elif [[ "$deployment_profile" == local-haproxy || "$deployment_profile" == local-kube-vip ]]; then
  # kk --with-local-storage 若在 SaveKubeConfig 之后才部署 OpenEBS，公网 API timeout
  # 会导致集群 Ready 但无 SC。此时用交付介质里的 OpenEBS LocalPV 清单补装。
  if [[ -z "$(default_sc)" ]]; then
    [[ -f local-path-storage.yaml ]] ||
      { echo "错误: 多节点本地 profile 缺默认 OpenEBS StorageClass，且无 local-path-storage.yaml"; exit 1; }
    echo "NOTE: 缺省 OpenEBS SC，apply local-path-storage.yaml（OpenEBS LocalPV）"
    kubectl apply -f local-path-storage.yaml
    kubectl -n openebs rollout status deploy/openebs-localpv-provisioner --timeout=10m
    if kubectl get sc local-path >/dev/null 2>&1; then
      kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true --overwrite || true
    fi
  fi
  storage_class=$(default_sc)
  [[ -n "$storage_class" ]] || { echo "错误: 多节点本地 profile 缺默认 OpenEBS StorageClass"; exit 1; }
  provisioner=$(kubectl get sc "$storage_class" -o jsonpath='{.provisioner}')
  [[ "$provisioner" == *openebs* ]] ||
    { echo "错误: 多节点本地 profile 默认 SC 不是 OpenEBS: $provisioner"; exit 1; }
else
  if [[ -z "$(default_sc)" ]]; then
  if [ -f local-path-storage.yaml ]; then
    echo "apply local-path-storage.yaml"
    kubectl apply -f local-path-storage.yaml
    kubectl -n openebs rollout status deploy/openebs-localpv-provisioner --timeout=10m
    if kubectl get sc local-path >/dev/null 2>&1; then
      kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true --overwrite || true
    fi
  else
    echo "错误: 无默认 StorageClass 且缺少 local-path-storage.yaml"
    exit 1
  fi
  fi
fi

storage_class=$(default_sc)
[[ -n "$storage_class" ]] || { echo "错误: 无默认 StorageClass"; exit 1; }
if [[ -n "$expected_sc" && "$storage_class" != "$expected_sc" ]]; then
  echo "错误: 默认 StorageClass=$storage_class，期望 $expected_sc"
  exit 1
fi
echo "default StorageClass: $storage_class"

if [[ "$deployment_profile" != single ]]; then
  echo "=== multi-node PVC scheduling smoke ==="
  kubectl create namespace kubercon-storage-smoke --dry-run=client -o yaml | kubectl apply -f -
  trap 'kubectl delete namespace kubercon-storage-smoke --wait=false >/dev/null 2>&1 || true' EXIT
  while read -r worker; do
    safe=${worker//./-}
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${safe}
  namespace: kubercon-storage-smoke
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: mount-${safe}
  namespace: kubercon-storage-smoke
spec:
  nodeSelector:
    kubernetes.io/hostname: ${worker}
  tolerations:
  - operator: Exists
  containers:
  - name: write
    image: ${local_registry}/kubercon/alpine:3.14
    imagePullPolicy: IfNotPresent
    command: [sh, -c, "echo storage-ok > /data/probe && sleep 600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-${safe}
EOF
    kubectl -n kubercon-storage-smoke wait --for=condition=Ready "pod/mount-${safe}" --timeout=10m
    [[ "$(kubectl -n kubercon-storage-smoke exec "mount-${safe}" -- cat /data/probe)" == storage-ok ]] ||
      { echo "错误: $worker PVC 读写 smoke 失败"; exit 1; }
  done < <(python3 - <<'PY'
import json
for n in json.load(open("inventory.json"))["nodes"]:
    if "worker" in n["roles"]: print(n["name"])
PY
)
  kubectl delete namespace kubercon-storage-smoke --wait=true --timeout=5m
  trap - EXIT
  echo "MULTINODE_STORAGE_SMOKE_OK"
fi

# 生成现场 CC：按 YAML 缩进路径修改并回读断言，不能再用跨行正则猜结构。
python3 .render-platform-config.py \
  --input cluster-configuration.yaml \
  --output cluster-configuration.runtime.yaml \
  --storage-class "$storage_class" \
  --registry "$local_registry" \
  --tag "$tag" \
  --admin-password "$admin_password"

echo "=== apply installer ==="
kubectl apply -f kubercon-installer.yaml
kubectl -n kubercon-system rollout status deploy/kubercon-installer --timeout=10m

echo "=== apply ClusterConfiguration ==="
kubectl apply -f cluster-configuration.runtime.yaml

echo "=== wait core deployments (up to 30m) ==="
for i in $(seq 1 90); do
  ready=0
  total=0
  for d in kubercon-apiserver kubercon-controller-manager kubercon-ui kubercon-installer; do
    total=$((total+1))
    if kubectl -n kubercon-system get deploy "$d" >/dev/null 2>&1; then
      want=$(kubectl -n kubercon-system get deploy "$d" -o jsonpath='{.status.replicas}')
      have=$(kubectl -n kubercon-system get deploy "$d" -o jsonpath='{.status.readyReplicas}')
      want=${want:-0}; have=${have:-0}
      if [ "$have" = "$want" ] && [ "$want" != "0" ]; then ready=$((ready+1)); fi
    fi
  done
  echo "round $i: core ready $ready / need apiserver+cm+ui+installer"
  if kubectl -n kubercon-system get deploy kubercon-apiserver kubercon-controller-manager kubercon-ui kubercon-installer >/dev/null 2>&1; then
    ok=1
    for d in kubercon-apiserver kubercon-controller-manager kubercon-ui; do
      want=$(kubectl -n kubercon-system get deploy "$d" -o jsonpath='{.status.replicas}')
      have=$(kubectl -n kubercon-system get deploy "$d" -o jsonpath='{.status.readyReplicas}')
      want=${want:-0}; have=${have:-0}
      [ "$have" = "$want" ] && [ "$want" != "0" ] || ok=0
    done
    if [ "$ok" = 1 ]; then
      echo "PLATFORM_CORE_READY"
      kubectl -n kubercon-system get deploy,pods
      node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
      node_port=$(kubectl -n kubercon-system get svc kubercon-ui -o jsonpath='{.spec.ports[0].nodePort}')
      [[ -n "$node_ip" && "$node_port" =~ ^[0-9]+$ ]] ||
        { echo "错误: 无法取得控制台 InternalIP/NodePort"; exit 1; }
      ui_headers=$(mktemp)
      ui_code=$(curl -sS -D "$ui_headers" -o /dev/null --connect-timeout 5 --max-time 15 \
        -w '%{http_code}' "http://${node_ip}:${node_port}/" || true)
      if [[ "$ui_code" != "200" && "$ui_code" != "302" ]]; then
        echo "错误: 控制台 HTTP 不可达 http://${node_ip}:${node_port}/ code=$ui_code"
        rm -f "$ui_headers"
        exit 1
      fi
      if [[ "$ui_code" == "302" ]] && ! grep -qiE '^location: */login' "$ui_headers"; then
        echo "错误: 控制台 302 但未跳转 /login"
        rm -f "$ui_headers"
        exit 1
      fi
      rm -f "$ui_headers"
      echo "CONSOLE_HTTP_OK url=http://${node_ip}:${node_port}/ code=$ui_code"

      # —— 控制台可登录硬化（V22.6 现场）：——
      # 1) accessTokenMaxAge=0s → UI expire cookie 被清空 → 浏览器「会话已超时」死循环
      # 2) ui-config 指向不存在的 redis → 会话异常
      # 3) admin uninitialized 注解 → 首登状态机卡死
      # 4) OAuth client 名为 kubercloud（不是 kubercon）
      token_patch_out=$(python3 - <<'PY'
import json, subprocess
cm = json.loads(subprocess.check_output(
    ["kubectl", "-n", "kubercon-system", "get", "cm", "kubercon-config", "-o", "json"]))
text = cm["data"]["kubercon.yaml"]
orig = text
text = text.replace("accessTokenMaxAge: 0s", "accessTokenMaxAge: 2h")
text = text.replace("accessTokenInactivityTimeout: 0s", "accessTokenInactivityTimeout: 8h")
if "accessTokenMaxAge:" not in text:
    raise SystemExit("kubercon-config 缺少 accessTokenMaxAge")
if text != orig:
    cm["data"]["kubercon.yaml"] = text
    open("/tmp/kubercon-config.fixed.json", "w").write(json.dumps(cm))
    subprocess.check_call(["kubectl", "apply", "-f", "/tmp/kubercon-config.fixed.json"])
    print("PATCHED_TOKEN_MAX_AGE")
else:
    print("TOKEN_MAX_AGE_OK")
PY
)
      echo "$token_patch_out"
      ui_patched=0
      redis_up=0
      kubectl -n kubercon-system get svc redis >/dev/null 2>&1 && redis_up=1 || true
      if (( redis_up == 0 )); then
        kubectl -n kubercon-system create configmap kubercon-ui-config \
          --from-literal=local_config.yaml="$(cat <<'YAML'
server:
  http:
    hostname: localhost
    port: 8000
    static:
      production:
        /public: server/public
        /assets: dist/assets
        /dist: dist
  redisTimeout: 5000
  sessionTimeout: 7200000
  apiServer:
    clientID: kubercloud
    clientSecret: kubercloud
    url: http://kubercon-apiserver
    wsUrl: ws://kubercon-apiserver
client:
  version:
    kubercon: v22.6.0
    kubernetes: v1.28.15
  enableKubeConfig: true
defaultClusterName: default
YAML
)" -o yaml --dry-run=client | kubectl apply -f -
        echo "PATCHED_UI_CONFIG_NO_REDIS"
        ui_patched=1
        kubectl -n kubercon-system rollout restart deploy/kubercon-ui
      fi
      if kubectl get users.iam.kubercloud.com admin >/dev/null 2>&1; then
        kubectl annotate users.iam.kubercloud.com admin iam.kubercloud.com/uninitialized- --overwrite >/dev/null 2>&1 || true
      fi
      api_ip=$(kubectl -n kubercon-system get svc kubercon-apiserver -o jsonpath='{.spec.clusterIP}')
      probe=$(curl -sS -o /tmp/kc-tok-probe.json -w '%{http_code}' -X POST "http://${api_ip}/oauth/token" \
        --data-urlencode 'grant_type=password' \
        --data-urlencode 'client_id=kubercloud' \
        --data-urlencode 'client_secret=kubercloud' \
        --data-urlencode 'username=admin' \
        --data-urlencode "password=${admin_password}" || true)
      if [[ "$token_patch_out" == *PATCHED_TOKEN_MAX_AGE* || "$probe" != "200" ]] ||
         ! grep -q '"expires_in"' /tmp/kc-tok-probe.json 2>/dev/null; then
        echo "NOTE: 重启 kubercon-apiserver 以加载 accessTokenMaxAge"
        kubectl -n kubercon-system rollout restart deploy/kubercon-apiserver
        kubectl -n kubercon-system rollout status deploy/kubercon-apiserver --timeout=5m
        api_ip=$(kubectl -n kubercon-system get svc kubercon-apiserver -o jsonpath='{.spec.clusterIP}')
      fi
      if (( ui_patched == 1 )); then
        kubectl -n kubercon-system rollout status deploy/kubercon-ui --timeout=5m || true
      fi

      login_body=$(mktemp)
      login_code=$(curl -sS -o "$login_body" --connect-timeout 5 --max-time 20 -w '%{http_code}' \
        -X POST "http://${api_ip}/oauth/token" \
        --data-urlencode 'grant_type=password' \
        --data-urlencode 'client_id=kubercloud' \
        --data-urlencode 'client_secret=kubercloud' \
        --data-urlencode 'username=admin' \
        --data-urlencode "password=${admin_password}" || true)
      if [[ "$login_code" != "200" ]] || ! grep -q '"access_token"' "$login_body"; then
        echo "错误: admin 凭据登录验证失败（HTTP $login_code；响应不打印以免泄密）"
        rm -f "$login_body"
        exit 1
      fi
      grep -q '"expires_in"' "$login_body" ||
        { echo "错误: token 无 expires_in，浏览器会陷入会话超时；检查 accessTokenMaxAge"; rm -f "$login_body"; exit 1; }
      # 浏览器真实路径：POST /login + encrypt 字段，必须写入 expire cookie
      ui_login=$(curl -sS -D /tmp/kc-ui-login.hdr -o /tmp/kc-ui-login.body -w '%{http_code}' \
        -X POST "http://${node_ip}:${node_port}/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"encrypt\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$admin_password")}" || true)
      if [[ "$ui_login" != "302" && "$ui_login" != "200" ]]; then
        echo "错误: 控制台 POST /login 失败 code=$ui_login"
        exit 1
      fi
      grep -qi '^set-cookie:.*expire=[1-9]' /tmp/kc-ui-login.hdr ||
        { echo "错误: 控制台未写入有效 expire cookie（仍会提示会话超时）"; cat /tmp/kc-ui-login.hdr | grep -i set-cookie || true; exit 1; }
      rm -f "$login_body"
      echo "ADMIN_LOGIN_OK username=admin password_source=ClusterConfiguration oauth_client=kubercloud"
      echo "CONSOLE_SESSION_OK expire_cookie=set"
      echo "BROWSER_TIP: 若普通窗口闪退/必须无痕才能打开，请清除该站点 Cookie（同 IP 重装会残留坏 expire/token；无痕只是空 cookie）。"
      exit 0
    fi
  fi
  sleep 20
done
echo "超时：核心组件未全部 Ready，保留现场供排查"
kubectl -n kubercon-system get deploy,pods || true
exit 1
EOS
