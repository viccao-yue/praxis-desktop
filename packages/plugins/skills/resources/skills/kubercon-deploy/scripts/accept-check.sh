#!/usr/bin/env bash
# 安装验收（查询为主；多节点会执行一次幂等 CRI pull 主动探测）。默认 SSH 到 KC_NODE1 执行 kubectl。
# 只有显式 KC_ACCEPT_LOCAL=1 才用本机 kubeconfig。
#
# 铁律：查询失败与「确实没有异常」必须区分。任何一条查不到都算验收不通过，
# 不能因为 stdout 为空就打印「无异常」——那会让半成品集群看起来像装好了。
set -uo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
if [[ -n "${KC_SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  echo "错误: KC_SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-ssh.sh
source "$SCRIPT_DIR/lib-ssh.sh"

REMOTE_KUBECONFIG="${KC_REMOTE_KUBECONFIG:-/root/.kube/config}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
INVENTORY="${KC_INVENTORY_FILE:-}"

if [[ -n "$INVENTORY" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate || exit 1
  first=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | awk 'NR==1')
  IFS=$'\t' read -r _ inv_address _ inv_user inv_port _ <<<"$first"
  KC_NODE1="${KC_NODE1:-$inv_address}"
  SSH_USER="$inv_user"; SSH_PORT="$inv_port"
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
  [[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
  KC_EXPECT_NODES=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" count)
  inv_profile=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" profile)
  api_domain=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["apiDomain"])' "$INVENTORY")
  KC_EXPECT_APISERVER_HOST="${KC_EXPECT_APISERVER_HOST:-$api_domain}"
  if [[ "$inv_profile" == external-prod ]]; then
    KC_EXPECT_STORAGE_CLASS="${KC_EXPECT_STORAGE_CLASS:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["storageClass"])' "$INVENTORY")}"
  fi
fi

MODE="remote"
if [[ "${KC_ACCEPT_LOCAL:-}" == "1" ]]; then
  MODE="local"
fi

if [[ "$MODE" == "remote" && -z "${KC_NODE1:-}" ]]; then
  echo "错误: 默认从 KC_NODE1 验收，请设置 KC_NODE1。"
  echo "      若确认要用本机 kubeconfig，才设置 KC_ACCEPT_LOCAL=1"
  exit 1
fi
if [[ "$MODE" == "remote" && ! "$REMOTE_KUBECONFIG" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "错误: KC_REMOTE_KUBECONFIG 必须是仅含安全字符的绝对路径"
  exit 1
fi

if [[ "$MODE" == "local" ]] && ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: KC_ACCEPT_LOCAL=1 但本机没有 kubectl"
  exit 1
fi

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

# stdout 原样返回，stderr 收进 $ERRF，退出码为 kubectl 的退出码
k() {
  : > "$ERRF"
  if [[ "$MODE" == "local" ]]; then
    kubectl "$@" 2>"$ERRF"
  else
    kubercon_ssh_opts "$KC_NODE1" "$SSH_PORT"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
      "export KUBECONFIG='$REMOTE_KUBECONFIG'; kubectl $(printf '%q ' "$@")" 2>"$ERRF"
  fi
}

show_err() { [[ -s "$ERRF" ]] && sed 's/^/    /' "$ERRF"; }

FAIL=0
declare -a PROBLEMS=()
fail() { FAIL=1; PROBLEMS+=("$1"); }

server_host() {
  local authority="${1#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" == \[* ]]; then
    authority="${authority#\[}"
    printf '%s\n' "${authority%%\]*}"
  else
    printf '%s\n' "${authority%%:*}"
  fi
}

echo "=============================================================="
echo "  KuberCon 安装验收（只读）"
echo "=============================================================="
if [[ "$MODE" == "local" ]]; then
  echo "模式: 本机 kubeconfig（KC_ACCEPT_LOCAL=1）"
  echo "KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
else
  echo "模式: SSH ${SSH_USER}@${KC_NODE1} 上的 ${REMOTE_KUBECONFIG}"
fi
echo

if [[ "$MODE" == "remote" ]]; then
  INSTALL_STATUS=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "cat /tmp/kubercon-create.status 2>/dev/null || true")
  if ! grep -q '^SUCCESS ' <<<"$INSTALL_STATUS"; then
    echo "失败: 安装器状态不是 SUCCESS"
    echo "${INSTALL_STATUS:-NO_STATUS}" | sed 's/^/  /'
    exit 1
  fi
fi

echo "--- API Server ---"
SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}'); rc=$?
if (( rc != 0 )) || [[ -z "$SERVER" ]]; then
  echo "  失败: 读不到 kubeconfig 里的 API server 地址"
  show_err
  echo "  连不上就无法验收，后续结果一律不可信。"
  fail "读不到 API server 地址"
  echo
  echo "=============================================================="
  echo "验收未通过：${PROBLEMS[*]}"
  exit 1
fi
echo "  server: $SERVER"

SERVER_HOST=$(server_host "$SERVER")
EXPECTED_API="${KC_EXPECT_APISERVER_HOST:-}"
EXPECTED_UID="${KC_EXPECT_CLUSTER_UID:-}"
if [[ "$MODE" == "remote" && -z "$EXPECTED_API" ]]; then
  EXPECTED_API=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    "awk '/^  controlPlaneEndpoint:/ {found=1; next} found && /^    domain:/ {gsub(/[\"'\"'[:space:]]/, \"\", \$2); print \$2; exit} found && /^  [^ ]/ {exit}' '$REMOTE_DIR/config.yaml'" 2>/dev/null)
fi
if [[ -z "$EXPECTED_API" ]]; then
  echo "  失败: 无法从部署 config.yaml 推导 API 身份；本机模式必须设置 KC_EXPECT_APISERVER_HOST"
  exit 1
fi
if [[ "$SERVER_HOST" != "$EXPECTED_API" ]]; then
  echo "  失败: API server 主机精确匹配失败"
  echo "        预期: $EXPECTED_API"
  echo "        实际: $SERVER_HOST"
  echo "        VIP/LB 场景请把第 1 节已确认的地址设为 KC_EXPECT_APISERVER_HOST 后重跑。"
  exit 1
fi
echo "  身份匹配: $SERVER_HOST"
CLUSTER_UID=$(k get ns kube-system -o jsonpath='{.metadata.uid}'); rc=$?
if (( rc != 0 )) || [[ -z "$CLUSTER_UID" ]]; then
  echo "  失败: 读不到 kube-system UID，无法建立集群身份指纹"
  exit 1
fi
if [[ -n "$EXPECTED_UID" && "$CLUSTER_UID" != "$EXPECTED_UID" ]]; then
  echo "  失败: 集群 UID 不符，预期 $EXPECTED_UID，实际 $CLUSTER_UID"
  exit 1
fi
if [[ "$SERVER_HOST" == "127.0.0.1" || "$SERVER_HOST" == "localhost" || "$SERVER_HOST" == "::1" ]]; then
  [[ -n "$INVENTORY" || -n "$EXPECTED_UID" ]] ||
    { echo "  失败: API 使用本地回环地址，必须另设 KC_EXPECT_CLUSTER_UID 精确确认目标集群"; exit 1; }
fi
echo "  集群 UID: $CLUSTER_UID"

echo
echo "--- 节点 ---"
NODES_OUT=$(k get nodes -o wide); rc=$?
if (( rc != 0 )) || [[ -z "$NODES_OUT" ]]; then
  echo "  失败: 取不到节点列表"
  show_err
  fail "取不到节点列表"
else
  echo "$NODES_OUT" | sed 's/^/  /'
  NOTREADY=$(echo "$NODES_OUT" | awk 'NR>1 && $2 !~ /^Ready/ {print "  " $1 " -> " $2}')
  if [[ -n "$NOTREADY" ]]; then
    echo "  失败: 有节点未 Ready"
    echo "$NOTREADY"
    fail "存在未 Ready 的节点"
  fi
  NODE_COUNT=$(echo "$NODES_OUT" | awk 'NR>1' | grep -c . || true)
  EXPECTED_NODES="${KC_EXPECT_NODES:-}"
  if [[ -z "$EXPECTED_NODES" && "$MODE" == "remote" ]]; then
    EXPECTED_NODES=0
    for var in KC_NODE1 KC_NODE2 KC_NODE3; do [[ -n "${!var:-}" ]] && EXPECTED_NODES=$((EXPECTED_NODES + 1)); done
  fi
  if [[ -z "$EXPECTED_NODES" ]]; then
    echo "  失败: 必须设置 KC_EXPECT_NODES，不能用未知节点数验收"
    fail "未设置预期节点数"
  elif [[ "$NODE_COUNT" != "$EXPECTED_NODES" ]]; then
    echo "  失败: 节点数 ${NODE_COUNT} 与预期 ${EXPECTED_NODES} 不一致"
    fail "节点数与预期不符"
  fi
fi

echo
echo "--- 异常状态或 READY 不完整的 Pod ---"
PODS_OUT=$(k get pods -A --no-headers); rc=$?
if (( rc != 0 )); then
  echo "  失败: 查询 Pod 失败（这不等于没有异常 Pod）"
  show_err
  fail "查询 Pod 失败"
elif [[ -z "$PODS_OUT" ]]; then
  echo "  失败: 全集群 0 个 Pod，正常集群不可能如此"
  fail "查不到任何 Pod"
else
  ABNORMAL=$(echo "$PODS_OUT" | awk '
    {
      split($3, r, "/")
      if ($4 != "Running" && $4 != "Completed") print
      else if ($4 == "Running" && (r[1] == "" || r[2] == "" || r[1] != r[2])) print
    }')
  if [[ -z "$ABNORMAL" ]]; then
    echo "  无（Running Pod 全部 Ready；Completed Pod 已忽略）"
  else
    echo "$ABNORMAL" | sed 's/^/  /'
    echo "  失败: 存在异常状态或 READY 不完整的 Pod"
    fail "存在异常 Pod"
  fi
fi

echo
echo "--- kubercon-system 核心组件 ---"
CORE_OUT=$(k -n kubercon-system get deploy -o wide); rc=$?
if (( rc != 0 )) || [[ -z "$CORE_OUT" ]]; then
  echo "  失败: kubercon-system 下没有 Deployment，平台没装上"
  show_err
  fail "kubercon-system 无工作负载"
else
  echo "$CORE_OUT" | sed 's/^/  /'
  # READY 列形如 1/1；desired 必须 >=1，ready 与 AVAILABLE 都必须等于 desired。
  UNREADY=$(echo "$CORE_OUT" | awk '
    NR>1 {
      split($2, r, "/")
      if (r[1] == "" || r[2] == "" || r[2] < 1 || r[1] != r[2] || $4 != r[2])
        print "  " $1 " READY=" $2 " AVAILABLE=" $4
    }')
  if [[ -n "$UNREADY" ]]; then
    echo "  失败: 有组件副本未全部就绪"
    echo "$UNREADY"
    fail "kubercon-system 有组件未就绪"
  fi
  for want in kubercon-apiserver kubercon-controller-manager kubercon-ui kubercon-installer; do
    if ! echo "$CORE_OUT" | awk 'NR>1 {print $1}' | grep -qx "$want"; then
      echo "  失败: 缺少 $want"
      fail "缺少 $want"
    fi
  done
fi

echo
echo "--- ClusterConfiguration ---"
CC_OUT=$(k -n kubercon-system get cc kubercon-installer); rc=$?
if (( rc != 0 )) || [[ -z "$CC_OUT" ]]; then
  echo "  失败: 找不到 cc（installer.kubercloud.com/v1alpha1），平台未安装或 CRD 未就绪"
  show_err
  fail "找不到 ClusterConfiguration"
else
  echo "$CC_OUT" | sed 's/^/  /'
fi

echo
echo "--- StorageClass ---"
SC_OUT=$(k get sc); rc=$?
if (( rc != 0 )) || [[ -z "$SC_OUT" ]]; then
  echo "  失败: 没有任何 StorageClass，所有 PVC 会卡在 Pending"
  show_err
  fail "无 StorageClass"
else
  echo "$SC_OUT" | sed 's/^/  /'
  if [[ -n "${KC_EXPECT_STORAGE_CLASS:-}" ]]; then
    if ! echo "$SC_OUT" | awk -v want="$KC_EXPECT_STORAGE_CLASS" 'NR>1 && $1==want {found=1} END {exit !found}'; then
      echo "  失败: 预期 StorageClass 不存在: $KC_EXPECT_STORAGE_CLASS"
      fail "预期 StorageClass 不存在"
    fi
  elif ! echo "$SC_OUT" | grep -q '(default)'; then
    echo "  失败: 没有默认 StorageClass；非默认场景须设置 KC_EXPECT_STORAGE_CLASS"
    fail "无默认 StorageClass"
  fi
fi

if [[ -n "$INVENTORY" && "$MODE" == remote ]]; then
  echo
  echo "--- 多节点角色、etcd、控制面与 registry ---"
  expected_names=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes | cut -f1 | sort)
  actual_names=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort); rc=$?
  if ((rc != 0)) || [[ "$actual_names" != "$expected_names" ]]; then
    echo "  失败: Kubernetes 节点集合与 inventory 不一致"
    fail "节点集合与 inventory 不一致"
  fi
  readyz=$(k get --raw=/readyz); rc=$?
  if ((rc != 0)) || [[ "$readyz" != ok ]]; then
    echo "  失败: LB/VIP API /readyz 不通过"
    fail "LB/VIP API 未就绪"
  fi
  registry=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cluster"]["privateRegistry"])' "$INVENTORY")
  while IFS=$'\t' read -r name address internal _ _ roles; do
    kubercon_ssh_opts "$address" "$SSH_PORT"
    if [[ ",$roles," == *,control-plane,* ]]; then
      if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${address}" \
        "kubectl --kubeconfig=/etc/kubernetes/admin.conf --server=https://127.0.0.1:6443 --insecure-skip-tls-verify get --raw=/readyz" |
        grep -qx ok; then
        echo "  失败: $name 本地 apiserver /readyz 不通过"
        fail "$name apiserver 未就绪"
      fi
    fi
    if [[ ",$roles," == *,etcd,* ]]; then
      if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${address}" \
        'set -a; source /etc/etcd.env; set +a; ETCDCTL_API=3 etcdctl endpoint health >/dev/null'; then
        echo "  失败: $name etcd endpoint health 不通过"
        fail "$name etcd 不健康"
      fi
    fi
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${address}" \
      "crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull $(printf '%q' "$registry/kubercon/pause:3.9") >/dev/null"; then
      echo "  失败: $name 无法从 registry 拉取 pause"
      fail "$name registry pull 失败"
    fi
  done < <("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" nodes)

  member_count=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
    'set -a; source /etc/etcd.env; set +a; ETCDCTL_API=3 etcdctl member list -w json' |
    python3 -c 'import json,sys; print(len(json.load(sys.stdin)["members"]))' 2>/dev/null); rc=$?
  if ((rc != 0)) || [[ "$member_count" != 3 ]]; then
    echo "  失败: etcd member 数不是 3（实际 ${member_count:-unknown}）"
    fail "etcd quorum 成员数错误"
  else
    echo "  PASS: 3 control-plane / 3 etcd + 全节点 registry pull"
  fi
fi

echo
echo "--- 控制台入口 ---"
SVC_OUT=$(k -n kubercon-system get svc kubercon-ui -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ "$SVC_OUT" =~ ^[0-9]+$ ]] && (( SVC_OUT >= 1 && SVC_OUT <= 65535 )); then
  echo "  NodePort: $SVC_OUT"
  echo "  浏览器访问: http://${KC_NODE1:-<节点IP>}:${SVC_OUT}"
  if [[ "$MODE" == "remote" ]]; then
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
      "bash -s -- $(printf '%q' "$SVC_OUT") $(printf '%q' "$REMOTE_KUBECONFIG")" <<'EOS'
set -euo pipefail
port="$1"; export KUBECONFIG="$2"
command -v curl >/dev/null || { echo "  失败: 远端缺 curl"; exit 1; }
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
headers=$(mktemp); body=$(mktemp)
trap 'rm -f "$headers" "$body"' EXIT
code=$(curl -sS -D "$headers" -o /dev/null --connect-timeout 5 --max-time 15 \
  -w '%{http_code}' "http://${node_ip}:${port}/" || true)
[[ "$code" == "200" || "$code" == "302" ]] ||
  { echo "  失败: 控制台 HTTP 不可达 http://${node_ip}:${port}/ code=$code"; exit 1; }
if [[ "$code" == "302" ]]; then
  grep -qiE '^location: */login' "$headers" ||
    { echo "  失败: 控制台 302 但未跳转 /login"; exit 1; }
fi

api_ip=$(kubectl -n kubercon-system get svc kubercon-apiserver -o jsonpath='{.spec.clusterIP}')
password=$(kubectl -n kubercon-system get clusterconfiguration kubercon-installer \
  -o jsonpath='{.spec.authentication.adminPassword}')
[[ -n "$password" ]] || { echo "  失败: 无法读取实际 adminPassword"; exit 1; }
login_code=$(curl -sS -o "$body" --connect-timeout 5 --max-time 20 -w '%{http_code}' \
  -X POST "http://${api_ip}/oauth/token" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=kubercloud' \
  --data-urlencode 'client_secret=kubercloud' \
  --data-urlencode 'username=admin' \
  --data-urlencode "password=${password}" || true)
[[ "$login_code" == "200" ]] && grep -q '"access_token"' "$body" ||
  { echo "  失败: admin 登录 API 验证失败 code=$login_code"; exit 1; }
grep -q '"expires_in"' "$body" ||
  { echo "  失败: token 无 expires_in（accessTokenMaxAge=0s 会导致浏览器会话超时）"; exit 1; }
# 浏览器路径：POST /login 必须写入有效 expire cookie（与 D8 硬化一致）
ui_login=$(curl -sS -D /tmp/kc-ui-login.hdr -o /tmp/kc-ui-login.body -w '%{http_code}' \
  -X POST "http://${node_ip}:${port}/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"encrypt\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$password")}" || true)
if [[ "$ui_login" != "302" && "$ui_login" != "200" ]]; then
  echo "  失败: 控制台 POST /login 失败 code=$ui_login"
  exit 1
fi
grep -qi '^set-cookie:.*expire=[1-9]' /tmp/kc-ui-login.hdr ||
  { echo "  失败: 控制台未写入有效 expire cookie（普通窗口会闪退/会话超时）"; exit 1; }
echo "  HTTP 探测通过: http://${node_ip}:${port}/ code=$code"
echo "  admin 实际登录通过（含 expire cookie）"
echo "  BROWSER_TIP: 同 IP 重装后若普通窗口闪退，请清除该站点 Cookie（无痕只是空 cookie）"
EOS
    then
      fail "控制台 HTTP 或 admin 登录失败"
    fi
  else
    echo "  警告: 本机模式不执行远端控制台/login 探测"
    fail "本机模式缺少控制台/login 验收"
  fi
else
  echo "  未取到 kubercon-ui 的 NodePort，默认约定为 30880"
  fail "缺少 kubercon-ui NodePort"
fi
echo "  License 上传仍属于外部授权步骤；本次已验证 admin 凭据"

echo
echo "=============================================================="
if (( FAIL )); then
  echo "验收未通过，共 ${#PROBLEMS[@]} 项："
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
  echo
  echo "先查 references/TROUBLESHOOTING.md。不要自动执行 delete cluster，"
  echo "也不要把本次输出当成安装成功交付给客户。"
  exit 1
fi
echo "验收通过：节点/Pod/平台核心/StorageClass 就绪，控制台 HTTP 与 admin 登录均通过。"
exit 0
