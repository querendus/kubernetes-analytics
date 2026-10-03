#!/usr/bin/env python3
"""
Kubernetes Per-Namespace Resource Usage & Allocation Analyzer
Aggregates active CPU/Memory usage (from metrics-server / kubectl top pods)
and compares against total CPU/Memory requests and limits.
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
        description="Analyze Kubernetes resource usage and requests per namespace."
    )
    parser.add_argument(
        "--context",
        default=os.environ.get("CTX"),
        help="Kubectl context to target (defaults to $CTX or current context).",
    )
    args = parser.parse_args()

    ctx = args.context
    cmd_prefix = ["kubectl"]
    if ctx:
        cmd_prefix.extend(["--context", ctx])

    # 1. Fetch live metrics from top pods
    actual_ns = {}
    try:
        top_cmd = cmd_prefix + ["top", "pods", "-A", "--no-headers"]
        top_out = subprocess.check_output(top_cmd, stderr=subprocess.PIPE).decode()
        for line in top_out.strip().splitlines():
            parts = line.split()
            if len(parts) >= 4:
                ns, pod, c_str, m_str = parts[0], parts[1], parts[2], parts[3]
                cpu = parse_cpu(c_str)
                mem = parse_mem(m_str)
                actual_ns.setdefault(ns, {"cpu": 0, "mem": 0, "pods": 0})
                actual_ns[ns]["cpu"] += cpu
                actual_ns[ns]["mem"] += mem
                actual_ns[ns]["pods"] += 1
    except subprocess.CalledProcessError as e:
        print(f"[Warning] Could not fetch pod metrics (metrics-server might not be installed): {e}", file=sys.stderr)

    # 2. Fetch pod definitions and resource allocations
    try:
        pods_cmd = cmd_prefix + ["get", "pods", "-A", "-o", "json"]
        pods_raw = subprocess.check_output(pods_cmd).decode()
        pods_json = json.loads(pods_raw)
    except subprocess.CalledProcessError as e:
        print(f"[Error] Failed to fetch pods from cluster: {e}", file=sys.stderr)
        sys.exit(1)

    req_ns = {}
    for pod in pods_json.get("items", []):
        ns = pod["metadata"]["namespace"]
        status = pod["status"].get("phase", "Unknown")
        req_ns.setdefault(
            ns,
            {
                "req_cpu": 0,
                "req_mem": 0,
                "lim_cpu": 0,
                "lim_mem": 0,
                "pod_count": 0,
                "statuses": {},
            },
        )
        req_ns[ns]["pod_count"] += 1
        req_ns[ns]["statuses"][status] = req_ns[ns]["statuses"].get(status, 0) + 1

        if status in ["Running", "Pending"]:
            for c in pod.get("spec", {}).get("containers", []):
                res = c.get("resources", {})
                req = res.get("requests", {})
                lim = res.get("limits", {})
                req_ns[ns]["req_cpu"] += parse_cpu(req.get("cpu"))
                req_ns[ns]["req_mem"] += parse_mem(req.get("memory"))
                req_ns[ns]["lim_cpu"] += parse_cpu(lim.get("cpu"))
                req_ns[ns]["lim_mem"] += parse_mem(lim.get("memory"))

    # Print summary table
    print(f"\nCluster Context: {ctx or '<current>'}")
    print(
        f"{'Namespace':<24} | {'Pods':<5} | {'Status':<17} | "
        f"{'Actual CPU':<10} | {'Req CPU':<10} | {'Lim CPU':<10} | "
        f"{'Actual Mem':<10} | {'Req Mem':<10} | {'Lim Mem':<10}"
    )
    print("-" * 125)

    all_ns = sorted(set(list(actual_ns.keys()) + list(req_ns.keys())))
    tot_act_cpu, tot_req_cpu, tot_lim_cpu = 0, 0, 0
    tot_act_mem, tot_req_mem, tot_lim_mem = 0, 0, 0

    for ns in all_ns:
        act = actual_ns.get(ns, {"cpu": 0, "mem": 0, "pods": 0})
        req = req_ns.get(
            ns,
            {
                "req_cpu": 0,
                "req_mem": 0,
                "lim_cpu": 0,
                "lim_mem": 0,
                "pod_count": 0,
                "statuses": {},
            },
        )
        status_str = ",".join(f"{k}:{v}" for k, v in req["statuses"].items())

        print(
            f"{ns:<24} | {req['pod_count']:>5} | {status_str:<17} | "
            f"{act['cpu']:>7}m   | {req['req_cpu']:>7}m   | {req['lim_cpu']:>7}m   | "
            f"{act['mem']:>7}Mi  | {req['req_mem']:>7}Mi  | {req['lim_mem']:>7}Mi"
        )
        tot_act_cpu += act["cpu"]
        tot_req_cpu += req["req_cpu"]
        tot_lim_cpu += req["lim_cpu"]
        tot_act_mem += act["mem"]
        tot_req_mem += req["req_mem"]
        tot_lim_mem += req["lim_mem"]

    print("-" * 125)
    total_pods = sum(r["pod_count"] for r in req_ns.values())
    print(
        f"{'TOTAL':<24} | {total_pods:>5} | {'':<17} | "
        f"{tot_act_cpu:>7}m   | {tot_req_cpu:>7}m   | {tot_lim_cpu:>7}m   | "
        f"{tot_act_mem:>7}Mi  | {tot_req_mem:>7}Mi  | {tot_lim_mem:>7}Mi\n"
    )


if __name__ == "__main__":
    main()
