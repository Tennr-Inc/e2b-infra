#!/usr/bin/env python3
"""Mount the dedicated EC2 instance-store cache before Nomad starts.

Never format EBS, partitioned devices, foreign filesystems, or mounted disks.
On reboot retain the existing XFS filesystem. After stop/start EC2 supplies a
blank instance-store device; durable snapshots must already be in S3.
"""

import json
import os
from pathlib import Path
import re
import subprocess


TARGET = Path("/orchestrator")
LABEL = "e2b-cache"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def select_disk(disks):
    local = [disk for disk in disks
             if (disk.get("model") or "").strip() == "Amazon EC2 NVMe Instance Storage"
             and disk["type"] == "disk"]
    if len(local) != 1:
        raise RuntimeError("Expected exactly one EC2 instance-store disk; refusing cache setup")
    disk = local[0]
    if disk.get("children"):
        raise RuntimeError("Instance-store disk has partitions; refusing cache setup")
    return disk


def prepare(target=TARGET):
    disks = json.loads(run("lsblk", "--json", "--paths", "--output",
                           "NAME,MODEL,TYPE,FSTYPE,LABEL,MOUNTPOINTS"))["blockdevices"]
    disk = select_disk(disks)
    device = disk["name"]
    mounts = [path for path in disk.get("mountpoints", []) if path]
    mounted = subprocess.run(["mountpoint", "-q", str(target)], check=False).returncode == 0

    if mounted:
        source = run("findmnt", "-n", "-o", "SOURCE", "--mountpoint", str(target))
        if os.path.realpath(source) != os.path.realpath(device):
            raise RuntimeError("Orchestrator cache is mounted from a different device")
        if disk.get("fstype") != "xfs" or disk.get("label") != LABEL:
            raise RuntimeError("Mounted cache is not the managed XFS filesystem")
    else:
        if mounts:
            raise RuntimeError("Instance-store disk is mounted elsewhere; refusing cache setup")
        target.mkdir(parents=True, exist_ok=True)
        if any(target.iterdir()):
            raise RuntimeError("Unmounted cache directory is not empty; refusing to hide existing data")

        if disk.get("fstype") is None:
            signatures = json.loads(run("wipefs", "--no-act", "--json", device))["signatures"]
            if signatures:
                raise RuntimeError("Disk has existing signatures; refusing to format it")
            # No -f: even after the checks, mkfs must refuse an occupied disk.
            run("mkfs.xfs", "-m", "reflink=1", "-L", LABEL, device)
        elif disk["fstype"] != "xfs" or disk.get("label") != LABEL:
            raise RuntimeError("Foreign instance-store filesystem; refusing to overwrite it")

        run("mount", "-t", "xfs", "-o", "noatime", device, str(target))

    if not re.search(r"\breflink=1\b", run("xfs_info", str(target))):
        raise RuntimeError("Orchestrator cache requires XFS reflink support")
    for name in ("sandbox", "template", "build"):
        (target / name).mkdir(exist_ok=True)
    print(f"Orchestrator cache ready: {device} at {target}, XFS with reflink")


if __name__ == "__main__":
    prepare()
