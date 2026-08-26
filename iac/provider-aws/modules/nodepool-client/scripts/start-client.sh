#!/usr/bin/env bash

# This script is meant to be run in the User Data of each EC2 Instance while it's booting. The script uses the
# run-nomad and run-consul scripts to configure and start Nomad and Consul in client mode. Note that this script
# assumes it's running in an AMI built from the Packer template in examples/nomad-consul-ami/nomad-consul.json.

set -euo pipefail

# Set timestamp format
PS4='[\D{%Y-%m-%d %H:%M:%S}] '
# Enable command tracing
set -x

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

mkdir -p /orchestrator
mkdir -p /orchestrator/sandbox
mkdir -p /orchestrator/template
mkdir -p /orchestrator/build

# Add swapfile
SWAPFILE="/swapfile"
fallocate -l 100G $SWAPFILE
chmod 600 $SWAPFILE
mkswap $SWAPFILE
swapon $SWAPFILE

# Make swapfile persistent
echo "$SWAPFILE none swap sw 0 0" | tee -a /etc/fstab

# Set swap settings
sysctl vm.swappiness=10
sysctl vm.vfs_cache_pressure=50

ulimit -n 1048576
export GOMAXPROCS=$(nproc)

tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535

# Increase the maximum number of memory map areas
vm.max_map_count=1048576

EOF
sysctl -p

echo "Disabling inotify for NBD devices"
# https://lore.kernel.org/lkml/20220422054224.19527-1-matthew.ruffell@canonical.com/
cat <<EOH >/etc/udev/rules.d/97-nbd-device.rules
# Disable inotify watching of change events for NBD devices
ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"
EOH

udevadm control --reload-rules
udevadm trigger

# Create the directory for the fc mounts
mkdir -p /fc-vm

# Persist mount definitions, but let Nomad's startup hook mount them after
# Consul can supply DNS. noauto avoids a boot dependency cycle with Supervisor.
# disable_noobj_cache prevents stale negative lookups for newly uploaded binaries.
mkdir -p /fc-envd /fc-kernels /fc-versions /fc-busybox /mnt/hugepages
cat >> /etc/fstab <<EOF
${FC_ENV_PIPELINE_BUCKET_NAME} /fc-envd fuse.s3fs noauto,_netdev,allow_other,umask=000,nonempty,iam_role=auto,disable_noobj_cache 0 0
${FC_KERNELS_BUCKET_NAME} /fc-kernels fuse.s3fs noauto,_netdev,allow_other,umask=000,nonempty,iam_role=auto,disable_noobj_cache 0 0
${FC_VERSIONS_BUCKET_NAME} /fc-versions fuse.s3fs noauto,_netdev,allow_other,umask=000,nonempty,iam_role=auto,disable_noobj_cache 0 0
${FC_BUSYBOX_BUCKET_NAME} /fc-busybox fuse.s3fs noauto,_netdev,allow_other,umask=000,nonempty,iam_role=auto,disable_noobj_cache 0 0
none /mnt/hugepages hugetlbfs noauto 0 0
EOF
printf '%s' '${PREPARE_HOST_SCRIPT_BASE64}' | base64 --decode > /opt/nomad/bin/prepare-host.sh
chmod 0755 /opt/nomad/bin/prepare-host.sh
/opt/nomad/bin/prepare-host.sh

# These variables are passed in via Terraform template interpolation
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

mkdir -p /root/docker
touch /root/docker/config.json
cat <<EOF >/root/docker/config.json
{
    "credHelpers": {
        "${AWS_ECR_ACCOUNT_REPOSITORY_DOMAIN}": "ecr-login"
    }
}
EOF

mkdir -p /etc/systemd/resolved.conf.d/
touch /etc/systemd/resolved.conf.d/consul.conf
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
DNSStubListener=yes
DNSStubListenerExtra=172.17.0.1
EOF
sync  # Ensure file is written to disk

# Allocate the shared hugepage pool before Nomad can accept sandboxes. Dynamic
# hugepages still use the rest of the existing budget; this is not per guest.
echo "[Setting up huge pages]"
install -d -m 0755 /opt/e2b/bin
printf '%s' '${HUGEPAGES_SCRIPT_BASE64}' | base64 --decode > /opt/e2b/bin/hugepages.sh
chmod 0755 /opt/e2b/bin/hugepages.sh

available_ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
hugepage_plan=$(/opt/e2b/bin/hugepages.sh plan "$available_ram" ${RESERVED_HOST_MEMORY_MIB} ${BASE_HUGEPAGES_PERCENTAGE})
read -r reserved_normal_ram base_hugepages overcommitment_hugepages <<< "$hugepage_plan"
echo "- Total memory: $available_ram MiB; host reserve: $reserved_normal_ram MiB"
echo "- Shared base pool: $base_hugepages pages; dynamic limit: $overcommitment_hugepages pages (2 MiB each)"

cat > /etc/sysctl.d/90-e2b-hugepages.conf <<EOF
vm.nr_overcommit_hugepages=$overcommitment_hugepages
vm.nr_hugepages=$base_hugepages
EOF

# Nomad is managed by Supervisor. Its pre-start check also protects reboots,
# when cloud-init user data does not run again and sysctl may allocate fewer
# pages than requested. Do not restart Supervisor or existing workloads here.
mkdir -p /etc/systemd/system/supervisor.service.d
cat > /etc/systemd/system/supervisor.service.d/hugepages.conf <<EOF
[Unit]
After=systemd-sysctl.service

[Service]
ExecStartPre=/opt/e2b/bin/hugepages.sh verify $base_hugepages $overcommitment_hugepages
EOF
systemctl daemon-reload

sysctl -w vm.nr_overcommit_hugepages="$overcommitment_hugepages"
sysctl -w vm.nr_hugepages="$base_hugepages"
# Supervisor is already running during first boot, so verify explicitly too.
/opt/e2b/bin/hugepages.sh verify "$base_hugepages" "$overcommitment_hugepages"

${CAPACITY_REPORTER_SETUP}

# Start Consul first (in background) with GCE DNS as recursor
# This allows Consul to handle both .consul queries AND forward internet queries
# These variables are passed in via Terraform template interpolation
/opt/consul/bin/run-consul.sh --client \
    --consul-token "${CONSUL_TOKEN}" \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --cluster-tag-value "${CLUSTER_TAG_VALUE}"  \
    --enable-gossip-encryption \
    --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "${CONSUL_DNS_REQUEST_TOKEN}" &

# Give Consul a moment to start its DNS server on port 8600
echo "- Waiting for Consul DNS to start on port 8600..."
for i in {1..60}; do
  if nc -z 127.0.0.1 8600 2>/dev/null; then
    echo "- Consul DNS is ready (attempt $i/60)"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "- ERROR: Consul DNS not responding after 60 seconds, exiting..."
    exit 1
  fi
  sleep 1
done

# Now restart systemd-resolved to apply Consul DNS configuration
# This must happen AFTER Consul starts, otherwise systemd-resolved marks 127.0.0.1:8600 as unreachable
# Consul DNS (127.0.0.1:8600) is the ONLY DNS server configured in systemd-resolved
# Consul handles ALL queries: .consul directly, everything else via recursor to GCE DNS
echo "[Configuring systemd-resolved for Consul DNS]"
echo "- Restarting systemd-resolved to apply Consul DNS config"
systemctl restart systemd-resolved
echo "- Waiting for systemd-resolved to settle"

# Give Consul a moment to start its DNS server on port 8600
echo "- Waiting for Systemd-resolved to start..."
for i in {1..60}; do
  if host google.com 2>/dev/null; then
    echo "- DNS resolving is ready (attempt $i/60)"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "- ERROR: Systemd-resolved not responding after 60 seconds, exiting..."
    exit 1
  fi
  sleep 1
done
echo "- Flushing DNS caches"
resolvectl flush-caches

/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" --node-pool "${NODE_POOL}" --node-labels "${NODE_LABELS}" &

# Add alias for ssh-ing to sbx
echo '_sbx_ssh() {
  local address=$(dig @127.0.0.4 $1. A +short 2>/dev/null)
  ssh -o StrictHostKeyChecking=accept-new "root@$address"
}

alias sbx-ssh=_sbx_ssh' >>/etc/profile
