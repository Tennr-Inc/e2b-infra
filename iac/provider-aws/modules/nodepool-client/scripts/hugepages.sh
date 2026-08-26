#!/usr/bin/env bash
set -euo pipefail

plan_hugepages() {
    local total_mib=$1 reserved_mib=$2 base_percentage=$3
    if [[ ! $total_mib =~ ^[0-9]+$ || ! $reserved_mib =~ ^[0-9]+$ || ! $base_percentage =~ ^[0-9]+$ ]] ||
        (( base_percentage > 100 )); then
        echo "Invalid hugepage configuration: expected integer memory sizes and a percentage from 0 through 100" >&2
        return 1
    fi

    # A zero override retains the build nodes' existing 16% host reserve,
    # bounded between 4 GiB and 42 GiB. Sandbox nodes explicitly reserve 4 GiB.
    if (( reserved_mib == 0 )); then
        reserved_mib=$((total_mib * 16 / 100))
        if (( reserved_mib < 4096 )); then reserved_mib=4096; fi
        if (( reserved_mib > 43008 )); then reserved_mib=43008; fi
    fi
    if (( reserved_mib >= total_mib )); then
        echo "Host memory reserve must be smaller than total RAM" >&2
        return 1
    fi

    local total_pages=$(((total_mib - reserved_mib) / 2))
    local base_pages=$((total_pages * base_percentage / 100))
    # Subtract after rounding so the base and surplus limits always sum to the
    # same 2 MiB page budget, including hosts with an odd number of pages.
    local surplus_pages=$((total_pages - base_pages))
    printf '%s %s %s\n' "$reserved_mib" "$base_pages" "$surplus_pages"
}

verify_hugepages() {
    local expected_base=$1 expected_surplus=$2 actual_base actual_surplus
    actual_base=$(sysctl -n vm.nr_hugepages)
    actual_surplus=$(sysctl -n vm.nr_overcommit_hugepages)
    printf 'Hugepage startup check: base requested=%s actual=%s; surplus limit requested=%s actual=%s (2 MiB pages)\n' \
        "$expected_base" "$actual_base" "$expected_surplus" "$actual_surplus"
    # A successful sysctl write can still leave a partially allocated pool.
    # Reject excess pages too, to preserve the host reserve and total budget.
    if [[ $actual_base != "$expected_base" || $actual_surplus != "$expected_surplus" ]]; then
        echo "Hugepage startup check failed; refusing to start Nomad on this node" >&2
        grep -E '^(MemTotal|MemAvailable|HugePages_|Hugepagesize)' /proc/meminfo >&2 || true
        return 1
    fi
}

case "${1:-}" in
    plan) plan_hugepages "$2" "$3" "$4" ;;
    verify) verify_hugepages "$2" "$3" ;;
    *) echo "Usage: $0 plan TOTAL_MIB RESERVED_MIB BASE_PERCENTAGE | verify BASE_PAGES SURPLUS_PAGES" >&2; exit 1 ;;
esac
