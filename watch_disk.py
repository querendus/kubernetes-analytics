#!/usr/bin/env python3
"""
Kubernetes Live Node Disk Growth Tracker
Polls the Kubelet Summary API for a specific node to track root disk usage,
available space, and capacity utilization during rollouts or image pulls.
"""

import argparse
import json
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Check live node disk usage percentage and available bytes."
    )
    parser.add_argument(
        "--context",
        default=os.environ.get("CTX"),
        help="Kubectl context to target (defaults to $CTX or current context).",
    )
    parser.add_argument(
        "--node",
        default=os.environ.get("NODE"),
        help="Node name to check (defaults to $NODE).",
    )
    args = parser.parse_args()

    ctx = args.context
    node = args.node

    if not node:
        print("[Error] Node name is required. Specify via --node=<name> or export NODE=<name>.", file=sys.stderr)
        sys.exit(1)

    cmd_prefix = ["kubectl"]
    if ctx:
        cmd_prefix.extend(["--context", ctx])

    raw_cmd = cmd_prefix + ["get", "--raw", f"/api/v1/nodes/{node}/proxy/stats/summary"]
    try:
        raw = subprocess.check_output(raw_cmd, stderr=subprocess.PIPE)
        data = json.loads(raw)
        fs = data.get("node", {}).get("fs", {})

        cap_gb = fs.get("capacityBytes", 0) / 1e9
        used_gb = fs.get("usedBytes", 0) / 1e9
        avail_gb = fs.get("availableBytes", 0) / 1e9
        pct = (used_gb / cap_gb * 100) if cap_gb > 0 else 0

        print(
            f"Node: {node} ({ctx or 'current-context'})\n"
            f"  Total: {cap_gb:.2f} GB | Used: {used_gb:.2f} GB ({pct:.1f}%) | Avail: {avail_gb:.2f} GB"
        )
    except subprocess.CalledProcessError as e:
        print(f"[Error] Failed to query stats summary for node {node}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
