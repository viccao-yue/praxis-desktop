#!/usr/bin/env python3
"""Validate and render the KuberCon v1.6 multi-node inventory contract."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any

PROFILES = {"local-haproxy", "local-kube-vip", "external-prod"}
ROLE_ORDER = ("etcd", "control-plane", "worker", "registry")
DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
DNS_NAME = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")
REGISTRY = re.compile(r"^[A-Za-z0-9.-]+(?::[0-9]+)?$")


class InventoryError(ValueError):
    pass


def load(path: str) -> dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise InventoryError(f"无法读取 inventory JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise InventoryError("inventory 顶层必须是 JSON object")
    return data


def require_string(obj: dict[str, Any], key: str, where: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise InventoryError(f"{where}.{key} 必须是非空字符串")
    return value.strip()


def validate(data: dict[str, Any]) -> dict[str, Any]:
    if data.get("apiVersion") != "kubercon.io/v1alpha1":
        raise InventoryError("apiVersion 必须是 kubercon.io/v1alpha1")
    profile = require_string(data, "profile", "inventory")
    if profile not in PROFILES:
        raise InventoryError(f"profile 必须是 {sorted(PROFILES)} 之一")

    cluster = data.get("cluster")
    ssh = data.get("ssh")
    nodes = data.get("nodes")
    if not isinstance(cluster, dict):
        raise InventoryError("cluster 必须是 object")
    if not isinstance(ssh, dict):
        raise InventoryError("ssh 必须是 object")
    if not isinstance(nodes, list) or len(nodes) < 3:
        raise InventoryError("nodes 至少需要 3 个节点")

    user = require_string(ssh, "user", "ssh")
    if user != "root":
        raise InventoryError("v1.6 裸机安装只支持 ssh.user=root")
    port = ssh.get("port", 22)
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise InventoryError("ssh.port 必须是 1..65535")
    key = require_string(ssh, "privateKeyPath", "ssh")
    if not key.startswith("/") or not re.fullmatch(r"/[A-Za-z0-9._/-]+", key):
        raise InventoryError("ssh.privateKeyPath 必须是 node1 上的安全绝对路径")

    names: list[str] = []
    addresses: list[str] = []
    internal_addresses: list[str] = []
    arches: set[str] = set()
    role_members = {role: [] for role in ROLE_ORDER}
    normalized_nodes: list[dict[str, Any]] = []
    for index, raw in enumerate(nodes):
        where = f"nodes[{index}]"
        if not isinstance(raw, dict):
            raise InventoryError(f"{where} 必须是 object")
        name = require_string(raw, "name", where)
        if not DNS_LABEL.fullmatch(name):
            raise InventoryError(f"{where}.name 不是合法 DNS label: {name}")
        address = require_string(raw, "address", where)
        internal = require_string(raw, "internalAddress", where)
        try:
            if ipaddress.ip_address(address).version != 4 or ipaddress.ip_address(internal).version != 4:
                raise ValueError("v1.6 多节点保证范围只支持 IPv4")
        except ValueError as exc:
            raise InventoryError(f"{where} address/internalAddress 必须是 IP: {exc}") from exc
        arch = raw.get("arch", "amd64")
        if arch not in {"amd64", "arm64"}:
            raise InventoryError(f"{where}.arch 只支持 amd64/arm64")
        roles = raw.get("roles")
        if not isinstance(roles, list) or not roles:
            raise InventoryError(f"{where}.roles 必须是非空数组")
        if len(roles) != len(set(roles)) or any(role not in ROLE_ORDER for role in roles):
            raise InventoryError(f"{where}.roles 含重复或未知角色")
        names.append(name)
        addresses.append(address)
        internal_addresses.append(internal)
        arches.add(arch)
        for role in roles:
            role_members[role].append(name)
        normalized_nodes.append(
            {
                "name": name,
                "arch": arch,
                "address": address,
                "internalAddress": internal,
                "roles": [role for role in ROLE_ORDER if role in roles],
            }
        )

    if len(names) != len(set(names)):
        raise InventoryError("节点 name 必须唯一")
    if len(addresses) != len(set(addresses)):
        raise InventoryError("节点 address 必须唯一")
    if len(internal_addresses) != len(set(internal_addresses)):
        raise InventoryError("节点 internalAddress 必须唯一")
    if len(arches) != 1:
        raise InventoryError("所有节点架构必须一致")

    cp = role_members["control-plane"]
    etcd = role_members["etcd"]
    workers = role_members["worker"]
    registry_nodes = role_members["registry"]
    if len(cp) != 3:
        raise InventoryError(f"control-plane 必须恰好 3 个，当前 {len(cp)}")
    if set(etcd) != set(cp) or len(etcd) != 3:
        raise InventoryError("etcd 必须与 3 个 control-plane 完全一致")
    if not workers:
        raise InventoryError("至少需要一个 worker；控制面可同时承担 worker")

    private_registry = require_string(cluster, "privateRegistry", "cluster")
    if not REGISTRY.fullmatch(private_registry):
        raise InventoryError("cluster.privateRegistry 格式错误")
    registry_ca = cluster.get("registryCAPath", "/etc/ssl/registry/ssl/ca.pem")
    if not isinstance(registry_ca, str) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", registry_ca):
        raise InventoryError("cluster.registryCAPath 必须是所有节点上的安全绝对路径")
    api_domain = require_string(cluster, "apiDomain", "cluster")
    if not DNS_NAME.fullmatch(api_domain):
        raise InventoryError("cluster.apiDomain 格式错误")
    api_address = cluster.get("apiAddress", "")
    if not isinstance(api_address, str):
        raise InventoryError("cluster.apiAddress 必须是字符串")
    if api_address:
        try:
            ipaddress.ip_address(api_address)
        except ValueError as exc:
            raise InventoryError("cluster.apiAddress 必须是 IP") from exc

    if profile == "local-haproxy":
        if api_address:
            raise InventoryError("local-haproxy 必须令 cluster.apiAddress 为空")
        if registry_nodes != [cp[0]]:
            raise InventoryError(f"local-haproxy 的 registry 必须且只能是首个控制面 {cp[0]}")
    elif profile == "local-kube-vip":
        if not api_address:
            raise InventoryError("local-kube-vip 必须提供 cluster.apiAddress VIP")
        if api_address in addresses or api_address in internal_addresses:
            raise InventoryError("kube-vip 地址不能等于任何节点 IP")
        if registry_nodes != [cp[0]]:
            raise InventoryError(f"local-kube-vip 的 registry 必须且只能是首个控制面 {cp[0]}")
    else:
        if not api_address:
            raise InventoryError("external-prod 必须提供外部 LB 的 cluster.apiAddress")
        if registry_nodes:
            raise InventoryError("external-prod 禁止本地 registry role")
        storage_class = require_string(cluster, "storageClass", "cluster")
        storage_manifest = require_string(cluster, "storageBootstrapManifest", "cluster")
        if "/" in storage_class or not DNS_NAME.fullmatch(storage_class):
            raise InventoryError("cluster.storageClass 格式错误")
        if not storage_manifest.endswith((".yaml", ".yml")) or "/" in storage_manifest:
            raise InventoryError("storageBootstrapManifest 只能是远端目录中的 YAML 文件名")

    pod = require_string(cluster, "podCIDR", "cluster")
    service = require_string(cluster, "serviceCIDR", "cluster")
    try:
        pod_net = ipaddress.ip_network(pod, strict=False)
        service_net = ipaddress.ip_network(service, strict=False)
    except ValueError as exc:
        raise InventoryError(f"Pod/Service CIDR 错误: {exc}") from exc
    if pod_net.overlaps(service_net):
        raise InventoryError("Pod CIDR 与 Service CIDR 不能重叠")
    if api_address:
        api_ip = ipaddress.ip_address(api_address)
        if api_address in addresses or api_address in internal_addresses:
            raise InventoryError("apiAddress 不能等于任何节点 IP")
        if api_ip in pod_net or api_ip in service_net:
            raise InventoryError("apiAddress 与 Pod/Service CIDR 冲突")
    for value in internal_addresses:
        ip = ipaddress.ip_address(value)
        if ip in pod_net or ip in service_net:
            raise InventoryError(f"节点内网 IP {value} 与 Pod/Service CIDR 冲突")

    version = require_string(cluster, "kubernetesVersion", "cluster")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
        raise InventoryError("cluster.kubernetesVersion 格式错误")

    normalized_cluster: dict[str, Any] = {
        "kubernetesVersion": version,
        "podCIDR": str(pod_net),
        "serviceCIDR": str(service_net),
        "apiDomain": api_domain,
        "apiAddress": api_address,
        "privateRegistry": private_registry,
        "registryCAPath": registry_ca,
        "namespaceOverride": "kubercon",
    }
    if profile == "external-prod":
        normalized_cluster["storageClass"] = cluster["storageClass"].strip()
        normalized_cluster["storageBootstrapManifest"] = cluster[
            "storageBootstrapManifest"
        ].strip()

    return {
        "apiVersion": "kubercon.io/v1alpha1",
        "profile": profile,
        "cluster": normalized_cluster,
        "ssh": {"user": user, "port": port, "privateKeyPath": key},
        "nodes": normalized_nodes,
    }


def canonical(data: dict[str, Any]) -> str:
    return json.dumps(validate(data), sort_keys=True, separators=(",", ":"))


def render_config(data: dict[str, Any]) -> str:
    inv = validate(data)
    cluster = inv["cluster"]
    ssh = inv["ssh"]
    nodes = inv["nodes"]
    profile = inv["profile"]
    roles = {
        role: [node["name"] for node in nodes if role in node["roles"]]
        for role in ROLE_ORDER
    }
    load_balancer = {
        "local-haproxy": "haproxy",
        "local-kube-vip": "kube-vip",
        "external-prod": "",
    }[profile]

    lines = [
        "apiVersion: kubekey.kubesphere.io/v1alpha2",
        "kind: Cluster",
        "metadata:",
        "  name: kubercon",
        "spec:",
        "  hosts:",
    ]
    for node in nodes:
        # KubeKey 在 VPC 内执行。inventory.address 可写公网 EIP 供本机 SSH/跳板，
        # 但 config.yaml 的 hosts.address 必须用 internalAddress：否则 SaveKubeConfig
        # 会经公网 EIP:6443 回环（云上 hairpin）超时，整场 create 被误判失败。
        values = {
            "name": node["name"],
            "arch": node["arch"],
            "address": node["internalAddress"],
            "internalAddress": node["internalAddress"],
            "user": ssh["user"],
            "privateKeyPath": ssh["privateKeyPath"],
        }
        body = ", ".join(
            f"{key}: {json.dumps(value)}" for key, value in values.items()
        )
        lines.append(f"  - {{{body}}}")
    lines.extend(["  roleGroups:"])
    for role in ROLE_ORDER:
        if roles[role]:
            lines.append(f"    {role}:")
            lines.extend(f"    - {name}" for name in roles[role])
    lines.extend(["  controlPlaneEndpoint:"])
    if load_balancer:
        lines.append(f"    internalLoadbalancer: {load_balancer}")
    lines.extend(
        [
            f"    domain: {cluster['apiDomain']}",
            f"    address: {json.dumps(cluster['apiAddress'])}",
            "    port: 6443",
            "  kubernetes:",
            f"    version: {cluster['kubernetesVersion']}",
            "    clusterName: cluster.local",
            "    autoRenewCerts: true",
            "    containerManager: containerd",
            "  etcd:",
            "    type: kubekey",
            "    dataDir: /var/lib/etcd",
            "  network:",
            "    plugin: calico",
            f"    kubePodsCIDR: {cluster['podCIDR']}",
            f"    kubeServiceCIDR: {cluster['serviceCIDR']}",
            "    calico:",
            "      ipipMode: Never",
            "      vxlanMode: Always",
            "    multusCNI:",
            "      enabled: false",
        ]
    )
    if profile != "external-prod":
        lines.extend(
            [
                "  storage:",
                "    openebs:",
                "      basePath: /var/openebs/local",
                "  registry:",
                "    type: registry",
            ]
        )
    else:
        lines.extend(["  registry:"])
    lines.extend(
        [
            f"    privateRegistry: {json.dumps(cluster['privateRegistry'])}",
            '    namespaceOverride: "kubercon"',
            "    registryMirrors: []",
            "    insecureRegistries: []",
            "    auths: {}",
            "  addons: []",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("normalize")
    sub.add_parser("fingerprint")
    sub.add_parser("profile")
    sub.add_parser("count")
    sub.add_parser("nodes")
    render = sub.add_parser("render-config")
    render.add_argument("--output")
    args = parser.parse_args()
    try:
        data = load(args.inventory)
        inv = validate(data)
        if args.command == "validate":
            print(
                f"INVENTORY_OK profile={inv['profile']} nodes={len(inv['nodes'])} "
                "controlPlane=3"
            )
        elif args.command == "normalize":
            print(canonical(data))
        elif args.command == "fingerprint":
            print(hashlib.sha256(canonical(data).encode()).hexdigest())
        elif args.command == "profile":
            print(inv["profile"])
        elif args.command == "count":
            print(len(inv["nodes"]))
        elif args.command == "nodes":
            for node in inv["nodes"]:
                print(
                    "\t".join(
                        [
                            node["name"],
                            node["address"],
                            node["internalAddress"],
                            inv["ssh"]["user"],
                            str(inv["ssh"]["port"]),
                            ",".join(node["roles"]),
                        ]
                    )
                )
        elif args.command == "render-config":
            output = render_config(data)
            if args.output:
                Path(args.output).write_text(output)
            else:
                sys.stdout.write(output)
        return 0
    except InventoryError as exc:
        print(f"INVENTORY_BAD {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
