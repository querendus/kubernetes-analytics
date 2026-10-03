#!/usr/bin/env python3
"""
Kubernetes Per-Node Resource Allocation & Headroom Analyzer
Calculates allocatable capacity vs. total scheduled requests per node,
and breaks down commitments by namespace to highlight bottleneck drivers.
"""

import argparse
import json
import os
import subprocess
import sys


def parse_cpu(val):
    if not val:
        return 0
    s = str(val).strip()
    if s.endswith("m"):
        return int(s[:-1])
    return int(float(s) * 1000)


def parse_mem(val):
    if not val:
        return 0
    s = str(val).strip()
    if s.endswith("Ki"):
        return int(s[:-2]) // 1024
    if s.endswith("Mi"):
        return int(s[:-2])
    if s.endswith("Gi"):
        return int(float(s[:-2]) * 1024)
    if s.endswith("Ti"):
        return int(float(s[:-2]) * 1024 * 1024)
    if s.endswith("k"):
        return int(s[:-1]) * 1000 // (1024 * 1024)
    if s.endswith("M"):
        return int(s[:-1]) * 1000000 // (1024 * 1024)
    if s.endswith("G"):
        return int(float(s[:-1]) * 1000000000) // (1024 * 1024)
    if s.isdigit():
        return int(s) // (1024 * 1024)
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Calculate node allocatable resources vs. requests and remaining headroom."
    )
    parser.add_argument(
        "--context",
        default=os.environ.get("CTX"),
        help="Kubectl context to target (defaults to $CTX or current context).",
    )
    parser.add_argument(
        "--node",
        default=os.environ.get("NODE"),
        help="Filter analysis to a specific node (defaults to all nodes).",
    )
    args = parser.parse_args()

    ctx = args.context
    target_node = args.node
    cmd_prefix = ["kubectl"]
    if ctx:
        cmd_prefix.extend(["--context", ctx])

    try:
        nodes_raw = subprocess.check_output(cmd_prefix + ["get", "nodes", "-o", "json"]).decode()
        nodes_json = json.loads(nodes_raw)

        pods_raw = subprocess.check_output(cmd_prefix + ["get", "pods", "-A", "-o", "json"]).decode()
        pods_json = json.loads(pods_raw)
    except subprocess.CalledProcessError as e:
        print(f"[Error] Failed to fetch nodes/pods: {e}", file=sys.stderr)
        sys.exit(1)

    nodes = nodes_json.get("items", [])
    if target_node:
        nodes = [n for n in nodes if n["metadata"]["name"] == target_node]
        if not nodes:
            print(f"[Error] Node '{target_node}' not found in cluster.", file=sys.stderr)
            sys.exit(1)

    print(f"\nCluster Context: {ctx or '<current>'}")
    for n in nodes:
        node_name = n["metadata"]["name"]
        alloc_cpu = parse_cpu(n["status"]["allocatable"]["cpu"])
        alloc_mem = parse_mem(n["status"]["allocatable"]["memory"])

        # Find non-terminated pods running on this node
        node_pods = [
            p
            for p in pods_json.get("items", [])
            if p.get("spec", {}).get("nodeName") == node_name
            and p.get("status", {}).get("phase") in ["Running", "Pending"]
        ]

        total_req_cpu = 0
        total_req_mem = 0
        ns_breakdown = {}

        for p in node_pods:
            ns = p["metadata"]["namespace"]
            ns_breakdown.setdefault(ns, {"cpu": 0, "mem": 0, "count": 0})
            ns_breakdown[ns]["count"] += 1
            for c in p.get("spec", {}).get("containers", []):
                req = c.get("resources", {}).get("requests", {})
                c_cpu = parse_cpu(req.get("cpu"))
                c_mem = parse_mem(req.get("memory"))
                total_req_cpu += c_cpu
                total_req_mem += c_mem
                ns_breakdown[ns]["cpu"] += c_cpu
                ns_breakdown[ns]["mem"] += c_mem

        cpu_pct = (total_req_cpu / alloc_cpu * 100) if alloc_cpu else 0
        mem_pct = (total_req_mem / alloc_mem * 100) if alloc_mem else 0
        free_cpu = alloc_cpu - total_req_cpu
        free_mem = alloc_mem - total_req_mem

        print(f"=== NODE: {node_name} ===")
        print(f"  Allocatable Capacity: CPU={alloc_cpu:>5}m | Mem={alloc_mem:>6}Mi")
        print(f"  Total Requested:      CPU={total_req_cpu:>5}m ({cpu_pct:>5.1f}%) | Mem={total_req_mem:>6}Mi ({mem_pct:>5.1f}%)")
        print(f"  Remaining Headroom:   CPU={free_cpu:>5}m ({100 - cpu_pct:>5.1f}%) | Mem={free_mem:>6}Mi ({100 - mem_pct:>5.1f}%)")
        print("  Workload breakdown by namespace:")
        for ns, data in sorted(ns_breakdown.items(), key=lambda x: x[1]["cpu"], reverse=True):
            ns_cpu_pct = (data["cpu"] / alloc_cpu * 100) if alloc_cpu else 0
            ns_mem_pct = (data["mem"] / alloc_mem * 100) if alloc_mem else 0
            print(
                f"    - {ns:<22}: {data['count']:>2} pods | "
                f"CPU Req: {data['cpu']:>5}m ({ns_cpu_pct:>4.1f}%) | "
                f"Mem Req: {data['mem']:>6}Mi ({ns_mem_pct:>4.1f}%)"
            )
        print()


if __name__ == "__main__":
    main()
