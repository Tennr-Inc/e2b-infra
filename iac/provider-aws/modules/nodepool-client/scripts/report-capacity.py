#!/usr/bin/env python3
"""Publish committed guest capacity, with host/backing pressure as extra signals."""

import argparse
import json
from pathlib import Path
import socket
import subprocess
from urllib.request import urlopen


def memory_utilization(meminfo: str, base_pages: int, surplus_limit: int) -> float:
    values = {line.split(":", 1)[0]: int(line.split()[1]) for line in meminfo.splitlines()}
    total = values["MemTotal"]
    page_size = values["Hugepagesize"]
    used_pages = values["HugePages_Total"] - values["HugePages_Free"]
    reserved_pages = used_pages + values["HugePages_Rsvd"]
    capacity_pages = base_pages + surplus_limit
    if total <= 0 or page_size <= 0 or capacity_pages <= 0 or used_pages < 0:
        raise ValueError("Invalid host memory capacity")

    # MemAvailable excludes even unused preallocated huge pages. Remove only
    # unreserved pages to avoid reporting that idle pool as workload demand.
    unreserved = max(0, values["HugePages_Free"] - values["HugePages_Rsvd"]) * page_size
    physical_percent = 100 * max(0, total - values["MemAvailable"] - unreserved) / total
    reservation_percent = 100 * reserved_pages / capacity_pages
    return max(physical_percent, reservation_percent)


def capacity_utilization(meminfo: str, base_pages: int, capacity: dict) -> float:
    fields = ("memory_limit_mib", "sandbox_limit", "memory_committed_mib",
              "sandboxes_committed", "hugepage_headroom_mib")
    if any(type(capacity[field]) is not int or capacity[field] < 0 for field in fields):
        raise ValueError("Invalid orchestrator capacity counters")
    memory_limit = capacity["memory_limit_mib"]
    slots = capacity["sandbox_limit"]
    if memory_limit <= 0 or slots <= 0:
        raise ValueError("Orchestrator admission must be enabled")
    # The node gate and scaler use the same full-RAM and slot commitments,
    # including starts and teardown. Never assume lazy mappings reserved RAM.
    committed_percent = 100 * capacity["memory_committed_mib"] / memory_limit
    slots_percent = 100 * capacity["sandboxes_committed"] / slots
    backing_pages = base_pages - (capacity["hugepage_headroom_mib"] + 1) // 2
    if backing_pages <= 0:
        raise ValueError("Preallocated hugepage pool must exceed scaling headroom")
    # Backing pressure is measured against the persistent pool even when the
    # configured guest budget allows surplus. Scale before needing more pages.
    return max(committed_percent, slots_percent,
               memory_utilization(meminfo, backing_pages, 0))


def read_capacity() -> dict:
    # HTTP success requires admission enabled and an orchestrator accepting work.
    # Old binaries, booting/draining nodes, or invalid JSON fail without a zero.
    with urlopen("http://127.0.0.1:5008/capacity", timeout=3) as response:
        return json.load(response)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", required=True)
    parser.add_argument("--asg", required=True)
    parser.add_argument("--admission", action="store_true")
    args = parser.parse_args()

    meminfo = Path("/proc/meminfo").read_text()
    base_pages = int(Path("/proc/sys/vm/nr_hugepages").read_text())
    if args.admission:
        utilization = capacity_utilization(meminfo, base_pages, read_capacity())
        metric_name = "SandboxCapacityUtilization"
    else:
        # Preserve the legacy reporter for pools without an admission policy.
        with socket.create_connection(("127.0.0.1", 5008), timeout=3):
            pass
        utilization = memory_utilization(
            meminfo, base_pages,
            int(Path("/proc/sys/vm/nr_overcommit_hugepages").read_text()),
        )
        metric_name = "SandboxMemoryUtilization"
    metric = {
        "MetricName": metric_name,
        "Dimensions": [{"Name": "AutoScalingGroupName", "Value": args.asg}],
        "Unit": "Percent",
        "Value": utilization,
    }
    subprocess.run(
        ["aws", "--region", args.region, "--cli-connect-timeout", "5",
         "--cli-read-timeout", "15", "cloudwatch", "put-metric-data",
         "--namespace", "E2B/Capacity", "--metric-data", json.dumps([metric])],
        check=True, timeout=35,
    )
    print(json.dumps({"event": "capacity.published", "percent": utilization}))


if __name__ == "__main__":
    main()
