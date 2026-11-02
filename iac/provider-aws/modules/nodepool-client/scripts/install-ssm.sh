#!/usr/bin/env bash
# Management transport for the bounded retirement SSM document. This does not
# restart Nomad or the orchestrator and does not alter sandbox processes.
set -euo pipefail
if ! systemctl list-unit-files amazon-ssm-agent.service --no-legend | grep -q amazon-ssm-agent; then
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' EXIT
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo 'Unsupported SSM architecture' >&2; exit 1 ;;
  esac
  curl --fail --silent --show-error --location --retry 3 \
    "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_${arch}/amazon-ssm-agent.deb" \
    --output "$work_dir/amazon-ssm-agent.deb"
  dpkg -i "$work_dir/amazon-ssm-agent.deb"
fi
systemctl enable --now amazon-ssm-agent
