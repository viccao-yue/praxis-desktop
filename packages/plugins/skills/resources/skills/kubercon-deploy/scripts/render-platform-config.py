#!/usr/bin/env python3
"""Render V22.6 ClusterConfiguration without a PyYAML dependency."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--storage-class", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--admin-password", required=True)
    args = parser.parse_args()

    password = args.admin_password
    if not (
        8 <= len(password) <= 64
        and re.search(r"[a-z]", password)
        and re.search(r"[A-Z]", password)
        and re.search(r"[0-9]", password)
    ):
        raise SystemExit("adminPassword 不满足 8~64 位且含大小写和数字")

    desired = {
        ("spec", "persistence", "storageClass"): json.dumps(args.storage_class),
        ("spec", "authentication", "adminPassword"): json.dumps(password),
        ("spec", "local_registry"): json.dumps(args.registry),
        ("spec", "kubercon_registry"): json.dumps(f"{args.registry}/"),
        ("spec", "hub_registry"): json.dumps(f"{args.registry}/kubercon/"),
        ("spec", "pull_policy"): "IfNotPresent",
        ("spec", "kubercon_tag"): json.dumps(args.tag),
        ("spec", "deepflow", "enabled"): "false",
        ("spec", "devops", "enabled"): "false",
        ("spec", "logging", "enabled"): "false",
        ("spec", "servicemesh", "enabled"): "false",
        ("spec", "auditing", "enabled"): "false",
        ("spec", "events", "enabled"): "false",
        ("spec", "alerting", "enabled"): "false",
    }

    lines = Path(args.input).read_text().splitlines()
    key_re = re.compile(r"^(\s*)([A-Za-z0-9_.-]+):(?:\s*)(.*)$")
    stack: list[tuple[int, str]] = []
    seen: dict[tuple[str, ...], str] = {}
    output: list[str] = []

    for line in lines:
        match = key_re.match(line)
        if not match or line.lstrip().startswith("#"):
            output.append(line)
            continue
        indent = len(match.group(1))
        key = match.group(2)
        value = match.group(3)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = tuple([item[1] for item in stack] + [key])
        if path in desired:
            value = desired[path]
            output.append(f"{match.group(1)}{key}: {value}")
            seen[path] = value.strip('"')
        else:
            output.append(line)
        if value.strip() == "" or value.lstrip().startswith("#"):
            stack.append((indent, key))

    missing = sorted(".".join(path) for path in desired if path not in seen)
    if missing:
        raise SystemExit("CC 缺少必需路径或改写未生效: " + ", ".join(missing))
    Path(args.output).write_text("\n".join(output) + "\n")
    print(
        "CC_RUNTIME_VALIDATED deepflow=false heavy-components=false "
        f"storageClass={args.storage_class}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
