#!/usr/bin/env bash
# 校验 node1 上 config.yaml 是否满足 V22.6 separate registry 首过条件。
# 须在 D6R / D6 之前通过；失败则禁止继续（避免白跑 1～2 小时）。
set -euo pipefail

SSH_USER="${KC_SSH_USER:-root}"
SSH_KEY="${KC_SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${KC_SSH_PORT:-22}"
REMOTE_DIR="${KC_REMOTE_DIR:-/opt/kubercon}"
PROFILE="${KC_PROFILE:-}"
EXPECTED_NODES="${KC_EXPECT_NODES:-1}"
EXPECTED_REGISTRY="${KC_LOCAL_REGISTRY:-docker.kubercon.local}"
INVENTORY="${KC_INVENTORY_FILE:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$SSH_PORT")
[[ "$SSH_KEY" == "~/"* ]] && SSH_KEY="$HOME/${SSH_KEY#\~/}"
[[ -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

die() { echo "错误: $*" >&2; exit 1; }
[[ -n "${KC_NODE1:-}" ]] || die "请设置 KC_NODE1"
[[ -n "$PROFILE" ]] || die "请设置 KC_PROFILE（native-kubercon 或 kk-artifact-then-cc）"
if [[ -n "$INVENTORY" ]]; then
  [[ -f "$INVENTORY" ]] || die "KC_INVENTORY_FILE 不存在"
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" validate
  EXPECTED_NODES=$("$SCRIPT_DIR/inventory.py" --inventory "$INVENTORY" count)
  EXPECTED_REGISTRY=""
fi
[[ "$EXPECTED_NODES" =~ ^[1-9][0-9]*$ ]] || die "KC_EXPECT_NODES 必须是正整数"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${KC_NODE1}" \
  "bash -s -- $(printf '%q ' "$REMOTE_DIR" "$PROFILE" "$EXPECTED_NODES" "$EXPECTED_REGISTRY" "${INVENTORY:+1}")" <<'EOS'
set -euo pipefail
dir="$1"; profile="$2"; expected_nodes="$3"; expected_registry="$4"; use_inventory="$5"
cd "$dir"
[[ -f config.yaml ]] || { echo "错误: 缺少 config.yaml"; exit 1; }
[[ "$use_inventory" != "1" || -f inventory.json ]] ||
  { echo "错误: 多节点模式缺远端 inventory.json；请重跑 prepare-multinode-config.sh"; exit 1; }
command -v python3 >/dev/null || { echo "错误: 缺 python3"; exit 1; }

EXPECTED_NODES="$expected_nodes" EXPECTED_REGISTRY="$expected_registry" PROFILE="$profile" USE_INVENTORY="$use_inventory" python3 - <<'PY'
import ipaddress
import json
import os
import re
import sys
from pathlib import Path

text = Path("config.yaml").read_text()
problems = []
warnings = []

def bad(message):
    problems.append(message)

def scalar(key):
    m = re.search(rf"^\s*{re.escape(key)}:\s*([^#\n]+)", text, re.M)
    return m.group(1).strip().strip("\"'") if m else ""

if "User@dev123" in text or re.search(r"^\s*password\s*:", text, re.M):
    bad("禁止使用 kk 默认明文 password；必须使用 privateKeyPath")
for placeholder in ("172.16.0.2", "172.16.0.3"):
    if placeholder in text:
        bad(f"仍含 kk 模板占位 IP: {placeholder}")

# 解析 kk 生成格式的 inline host map。
hosts = []
for raw in re.findall(r"^\s*-\s*\{([^{}]+)\}\s*$", text, re.M):
    item = {}
    for part in raw.split(","):
        if ":" in part:
            k, v = part.split(":", 1)
            item[k.strip()] = v.strip().strip("\"'")
    if "name" in item:
        hosts.append(item)

expected_nodes = int(os.environ["EXPECTED_NODES"])
if len(hosts) != expected_nodes:
    bad(f"hosts 数量必须为 {expected_nodes}，当前 {len(hosts)}")
names = [h.get("name", "") for h in hosts]
if len(set(names)) != len(names) or any(not n for n in names):
    bad("hosts 名称为空或重复")
for h in hosts:
    for key in ("address", "internalAddress", "privateKeyPath"):
        if not h.get(key):
            bad(f"host {h.get('name','?')} 缺 {key}")
    for key in ("address", "internalAddress"):
        try:
            ipaddress.ip_address(h.get(key, ""))
        except ValueError:
            bad(f"host {h.get('name','?')} 的 {key} 不是合法 IP")
    if h.get("privateKeyPath") and not Path(h["privateKeyPath"]).is_file():
        bad(f"node1 私钥不存在: {h['privateKeyPath']}")

# 解析 roleGroups（只接受标准块状列表，避免误判）。
roles = {}
m = re.search(r"^\s{2}roleGroups:\s*(?:#.*)?$", text, re.M)
if not m:
    bad("缺 spec.roleGroups")
else:
    tail = text[m.end():].splitlines()
    current = None
    for line in tail:
        if line.strip() and len(line) - len(line.lstrip()) <= 2:
            break
        km = re.match(r"^\s{4}([A-Za-z0-9_-]+):\s*(?:#.*)?$", line)
        if km:
            current = km.group(1)
            roles[current] = []
            continue
        vm = re.match(r"^\s{4}-\s*([A-Za-z0-9_.-]+)\s*(?:#.*)?$", line)
        if vm and current:
            roles[current].append(vm.group(1))

required_roles = ("etcd", "control-plane", "worker")
for role in required_roles:
    members = roles.get(role, [])
    if not members:
        bad(f"roleGroups.{role} 不能为空")
    unknown = sorted(set(members) - set(names))
    if unknown:
        bad(f"roleGroups.{role} 引用了未声明 host: {','.join(unknown)}")
if expected_nodes == 1:
    for role in ("etcd", "control-plane", "worker", "registry"):
        if roles.get(role) != names:
            bad(f"单节点 roleGroups.{role} 必须且只能是 {names}")

if scalar("namespaceOverride") != "kubercon":
    bad("namespaceOverride 必须是 kubercon")
if os.environ["EXPECTED_REGISTRY"] and scalar("privateRegistry") != os.environ["EXPECTED_REGISTRY"]:
    bad(f"privateRegistry 必须是 {os.environ['EXPECTED_REGISTRY']}")
if not re.search(r"^\s*insecureRegistries:\s*\[\]\s*(?:#.*)?$", text, re.M):
    bad("insecureRegistries 必须严格为 []")

etcd = re.search(r"^\s{2}etcd:\s*(?:#.*)?$\n(?P<body>(?:^\s{4,}.*$\n?)*)", text, re.M)
if not etcd or not re.search(r"^\s{4}type:\s*kubekey\s*(?:#.*)?$", etcd.group("body"), re.M):
    bad("etcd.type 必须是 kubekey")

for key in ("kubePodsCIDR", "kubeServiceCIDR"):
    value = scalar(key)
    try:
        ipaddress.ip_network(value, strict=False)
    except ValueError:
        bad(f"{key} 不是合法 CIDR: {value or '空'}")
if scalar("domain") == "":
    bad("controlPlaneEndpoint.domain 不能为空")
if scalar("port") != "6443":
    bad("controlPlaneEndpoint.port 必须是 6443")

if os.environ["USE_INVENTORY"] == "1":
    inv = json.loads(Path("inventory.json").read_text())
    expected_names = [node["name"] for node in inv["nodes"]]
    expected_hosts = {node["name"]: node for node in inv["nodes"]}
    expected_roles = {
        role: [node["name"] for node in inv["nodes"] if role in node["roles"]]
        for role in ("etcd", "control-plane", "worker", "registry")
    }
    if names != expected_names:
        bad(f"config hosts 顺序/集合与 inventory 不一致: {names} != {expected_names}")
    for host in hosts:
        expected = expected_hosts.get(host.get("name"))
        if expected:
            if host.get("arch") != expected.get("arch"):
                bad(f"host {host.get('name')} 的 arch 与 inventory 不一致")
            # kk hosts.address 必须用 internalAddress（避免公网 hairpin）；inventory.address 仅供本机 SSH
            if host.get("address") != expected.get("internalAddress"):
                bad(
                    f"host {host.get('name')} 的 address 必须等于 inventory.internalAddress"
                    f"（当前 {host.get('address')!r}，期望 {expected.get('internalAddress')!r}）"
                )
            if host.get("internalAddress") != expected.get("internalAddress"):
                bad(f"host {host.get('name')} 的 internalAddress 与 inventory 不一致")
            if host.get("privateKeyPath") != expected.get("privateKeyPath") and expected.get("privateKeyPath"):
                # inventory 规范化后的私钥路径以 config 内写入为准；仅在两者都有时弱提示
                pass
    for role, expected in expected_roles.items():
        if roles.get(role, []) != expected:
            bad(f"roleGroups.{role} 与 inventory 不一致: {roles.get(role, [])} != {expected}")
    cp = expected_roles["control-plane"]
    if len(cp) != 3 or expected_roles["etcd"] != cp:
        bad("inventory/config 必须是 3 control-plane 且 etcd 与其一致")
    profile = inv["profile"]
    endpoint = re.search(
        r"^\s{2}controlPlaneEndpoint:\s*(?:#.*)?$\n(?P<body>(?:^\s{4,}.*$\n?)*)",
        text,
        re.M,
    )
    body = endpoint.group("body") if endpoint else ""
    lb_match = re.search(r"^\s{4}internalLoadbalancer:\s*([^#\n]+)", body, re.M)
    lb = lb_match.group(1).strip().strip("\"'") if lb_match else ""
    address_match = re.search(r"^\s{4}address:\s*([^#\n]*)", body, re.M)
    endpoint_address = address_match.group(1).strip().strip("\"'") if address_match else ""
    expected_lb = {"local-haproxy": "haproxy", "local-kube-vip": "kube-vip", "external-prod": ""}[profile]
    if lb != expected_lb:
        bad(f"internalLoadbalancer 与 profile 不一致: {lb!r} != {expected_lb!r}")
    if endpoint_address != inv["cluster"]["apiAddress"]:
        bad("controlPlaneEndpoint.address 与 inventory 不一致")
    if scalar("domain") != inv["cluster"]["apiDomain"]:
        bad("controlPlaneEndpoint.domain 与 inventory 不一致")
    if scalar("privateRegistry") != inv["cluster"]["privateRegistry"]:
        bad("privateRegistry 与 inventory 不一致")

if os.environ["PROFILE"] == "kk-artifact-then-cc":
    required_files = ["kubercon-installer.yaml", "cluster-configuration.yaml"]
    if os.environ["USE_INVENTORY"] != "1":
        required_files.append("local-path-storage.yaml")
    elif json.loads(Path("inventory.json").read_text())["profile"] == "external-prod":
        required_files.append(
            json.loads(Path("inventory.json").read_text())["cluster"]["storageBootstrapManifest"]
        )
    for f in required_files:
        if not Path(f).is_file():
            bad(f"缺少平台离线必需文件: {f}")

for p in problems:
    print(f"BAD {p}")
if problems:
    print(f"CONFIG_VALIDATE_FAILED count={len(problems)}")
    print("单节点请运行 scripts/prepare-single-node-config.sh 重新生成确定性配置")
    sys.exit(1)
for h in hosts:
    # 多节点渲染故意让 address==internalAddress（公网 EIP 只留在 inventory.address 供 SSH）
    if h["address"] == h["internalAddress"] and not Path("inventory.json").is_file():
        warnings.append(f"address==internalAddress ({h['address']})；仅单网卡环境可接受")
for w in warnings:
    print(f"WARN {w}")
print(f"CONFIG_VALIDATE_OK hosts={len(hosts)} roles=etcd,control-plane,worker,registry")
PY
EOS
