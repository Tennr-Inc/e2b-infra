#!/usr/bin/env bash
# Reuse Ubuntu's preinstalled Snap agent where present. Installing the Debian
# package alongside it fails and would abort worker bootstrap before Nomad starts.
set -euo pipefail
ssm_service=amazon-ssm-agent.service
if systemctl list-unit-files snap.amazon-ssm-agent.amazon-ssm-agent.service --no-legend | grep -q '^snap.amazon-ssm-agent.amazon-ssm-agent.service'; then
  ssm_service=snap.amazon-ssm-agent.amazon-ssm-agent.service
elif ! systemctl list-unit-files amazon-ssm-agent.service --no-legend | grep -q '^amazon-ssm-agent.service'; then
  ssm_work_dir=$(mktemp -d)
  trap 'rm -rf "$ssm_work_dir"' EXIT
  case "$(uname -m)" in
    x86_64) ssm_arch=amd64 ;;
    aarch64) ssm_arch=arm64 ;;
    *) echo 'Unsupported SSM architecture' >&2; exit 1 ;;
  esac
  curl --fail --silent --show-error --location --retry 3 \
    "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_${ssm_arch}/amazon-ssm-agent.deb" \
    --output "$ssm_work_dir/amazon-ssm-agent.deb"
  dpkg -i "$ssm_work_dir/amazon-ssm-agent.deb"
fi
systemctl enable --now "$ssm_service"
