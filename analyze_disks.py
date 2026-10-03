#!/usr/bin/env python3
"""
Kubernetes Cluster-Wide Node Disk & Container Runtime Analyzer
Queries the Kubelet Summary API (/api/v1/nodes/<node>/proxy/stats/summary)
to break down Root Filesystem usage into Container Runtime/Images vs OS/Logs/EmptyDir.
"""

import argparse
import json
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Query Kubelet Summary API across nodes for root disk vs. imageFs footprint."
    )
    parser.add_argument(
        "--context",
        default=os.environ.get("CTX"),
        help="Kubectl context to target (defaults to $CTX or current context).",
    )
    parser.add_argument(
        "--node",
        default=os.environ.get("NODE"),
        help="Target a specific node (defaults to all nodes).",
    )
    args = parser.parse_args()

    ctx = args.context
    target_node = args.node
    cmd_prefix = ["kubectl"]
    if ctx:
        cmd_prefix.extend(["--context", ctx])

    try:
        if target_node:
            nodes = [target_node]
        else:
            nodes_out = subprocess.check_output(
                cmd_prefix + ["get", "nodes", "-o", "jsonpath={.items[*].metadata.name}"]
            ).decode()
            nodes = nodes_out.strip().split()
    except subprocess.CalledProcessError as e:
        print(f"[Error] Failed to list cluster nodes: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"\nCluster Context: {ctx or '<current>'}")
    for n in nodes:
        raw_cmd = cmd_prefix + ["get", "--raw", f"/api/v1/nodes/{n}/proxy/stats/summary"]
        try:
            raw = subprocess.check_output(raw_cmd, stderr=subprocess.PIPE)
            data = json.loads(raw)
            fs = data.get("node", {}).get("fs", {})
            img = data.get("node", {}).get("runtime", {}).get("imageFs", {})

            cap_gb = fs.get("capacityBytes", 0) / 1e9
            used_gb = fs.get("usedBytes", 0) / 1e9
            avail_gb = fs.get("availableBytes", 0) / 1e9
            pct = (used_gb / cap_gb * 100) if cap_gb > 0 else 0
            img_gb = img.get("usedBytes", 0) / 1e9
            sys_logs_gb = max(0, used_gb - img_gb)

            print(f"=== NODE: {n} ===")
            print(f"  Root Disk (node.fs):     {cap_gb:.2f} GB | Used: {used_gb:.2f} GB ({pct:.1f}%) | Avail: {avail_gb:.2f} GB")
            print(f"  Container Images/Runtime: {img_gb:.2f} GB")
            print(f"  OS, Logs & EmptyDir:      {sys_logs_gb:.2f} GB\n")
        except subprocess.CalledProcessError as e:
            print(f"[Warning] Failed to query stats summary for node {n}: {e}", file=sys.stderr)
        except Exception as ex:
            print(f"[Warning] Error parsing stats for node {n}: {ex}", file=sys.stderr)


if __name__ == "__main__":
    main()
