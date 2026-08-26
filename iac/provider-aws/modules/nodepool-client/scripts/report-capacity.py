#!/usr/bin/env python3
"""Publish reservations as well as resident memory; idle guests still need capacity."""

import argparse
import json
from pathlib import Path
import socket
import subprocess


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", required=True)
    parser.add_argument("--asg", required=True)
    args = parser.parse_args()

    # A booting node must not dilute the fleet metric before its orchestrator
    # can accept requests. Fail without publishing a misleading zero.
    with socket.create_connection(("127.0.0.1", 5008), timeout=3):
        pass
    utilization = memory_utilization(
        Path("/proc/meminfo").read_text(),
        int(Path("/proc/sys/vm/nr_hugepages").read_text()),
        int(Path("/proc/sys/vm/nr_overcommit_hugepages").read_text()),
    )
    metric = {
        "MetricName": "SandboxMemoryUtilization",
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
