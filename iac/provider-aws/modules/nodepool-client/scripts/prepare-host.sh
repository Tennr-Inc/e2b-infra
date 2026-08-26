#!/usr/bin/env bash
set -euo pipefail

# Nomad restarts must restore the devices and mounts cloud-init made on first
# boot. Consul starts separately under Supervisor, so retry while DNS comes up.
modprobe nbd nbds_max=4096
for target in /fc-envd /fc-kernels /fc-versions /fc-busybox /mnt/hugepages; do
    for attempt in {1..30}; do
        if mountpoint -q "$target" || mount "$target"; then
            break
        fi
        sleep 2
    done
    if ! mountpoint -q "$target"; then
        echo "Required mount $target is unavailable; refusing to start Nomad" >&2
        exit 1
    fi
done
