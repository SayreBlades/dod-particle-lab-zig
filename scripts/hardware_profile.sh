#!/bin/bash
# hardware_profile.sh — print the cache/memory/SIMD profile of this machine.
#
# DOD only makes sense relative to concrete hardware facts. The framework's
# stage 7 (alignment/tile sizing) and the benchmark N-sweep interpretation
# both depend on these numbers. Run this on any machine to regenerate the
# profile for that machine.
#
# On macOS these come from sysctl. On Linux they come from sysfs, procfs,
# and getconf.
#
# Usage:  scripts/hardware_profile.sh

set -euo pipefail

print_header() {
    echo "=== Hardware profile ==="
    echo "date   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host   : $(hostname -s)"
    echo "os     : $(uname -s) $(uname -r) ($(uname -m))"
    echo
}

print_kv() {
    printf "  %-22s = %s\n" "$1" "$2"
}

size_to_bytes() {
    local size="$1"
    local number unit

    number="${size%[KkMmGg]}"
    unit="${size:${#number}:1}"

    case "$unit" in
        K|k) echo $((number * 1024)) ;;
        M|m) echo $((number * 1024 * 1024)) ;;
        G|g) echo $((number * 1024 * 1024 * 1024)) ;;
        *) echo "$size" ;;
    esac
}

sysctl_value() {
    sysctl -n "$1" 2>/dev/null || echo "n/a"
}

print_darwin_profile() {
    print_header

    echo "cpu    : $(sysctl_value machdep.cpu.brand_string)"
    echo "cores  : physical=$(sysctl_value hw.physicalcpu) logical=$(sysctl_value hw.logicalcpu)"
    echo

    echo "=== Cache / memory ==="
    for k in hw.cachelinesize hw.l1dcachesize hw.l1icachesize hw.l2cachesize hw.l3cachesize hw.pagesize hw.memsize; do
        print_kv "$k" "$(sysctl_value "$k")"
    done
    echo

    echo "=== SIMD / feature flags (subset) ==="
    sysctl -a 2>/dev/null \
        | grep -iE 'hw.optional.neon|hw.optional.AdvSIMD|hw.optional.armv8' \
        | sed 's/^/  /' \
        || echo "  (no NEON/ARM feature flags found; not an ARM host)"
}

linux_cpu_model() {
    local model
    model=$(awk -F: '/^(model name|Hardware|Processor)[[:space:]]*:/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
    }' /proc/cpuinfo 2>/dev/null || true)

    if [ -n "$model" ]; then
        echo "$model"
    else
        echo "unknown"
    fi
}

linux_logical_cores() {
    getconf _NPROCESSORS_ONLN 2>/dev/null \
        || nproc 2>/dev/null \
        || grep -c '^processor' /proc/cpuinfo 2>/dev/null \
        || echo "n/a"
}

linux_physical_cores() {
    local count

    count=$(
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            [ -d "$cpu" ] || continue
            if [ -f "$cpu/online" ] && [ "$(cat "$cpu/online")" != "1" ]; then
                continue
            fi

            local package_id core_id
            package_id=$(cat "$cpu/topology/physical_package_id" 2>/dev/null || echo 0)
            core_id=$(cat "$cpu/topology/core_id" 2>/dev/null || basename "$cpu" | tr -dc '0-9')
            printf '%s:%s\n' "$package_id" "$core_id"
        done | sort -u | wc -l | tr -d ' '
    )

    if [ -n "$count" ] && [ "$count" != "0" ]; then
        echo "$count"
    else
        echo "n/a"
    fi
}

linux_cache_dir() {
    local level="$1"
    local type="$2"
    local dir

    for dir in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ -d "$dir" ] || continue
        [ "$(cat "$dir/level" 2>/dev/null || true)" = "$level" ] || continue
        [ "$(cat "$dir/type" 2>/dev/null || true)" = "$type" ] || continue
        echo "$dir"
        return 0
    done

    return 1
}

linux_cache_size() {
    local level="$1"
    local type="$2"
    local dir size

    if dir=$(linux_cache_dir "$level" "$type"); then
        size=$(cat "$dir/size" 2>/dev/null || true)
        if [ -n "$size" ]; then
            size_to_bytes "$size"
            return 0
        fi
    fi

    echo "n/a"
}

linux_cache_line_size() {
    local dir

    if dir=$(linux_cache_dir 1 Data); then
        cat "$dir/coherency_line_size" 2>/dev/null && return 0
    fi

    for dir in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ -f "$dir/coherency_line_size" ] || continue
        cat "$dir/coherency_line_size"
        return 0
    done

    echo "n/a"
}

linux_mem_bytes() {
    local bytes
    bytes=$(awk '/^MemTotal:/ {
        printf "%.0f\n", $2 * 1024
        found = 1
        exit
    }
    END { if (!found) exit 1 }' /proc/meminfo 2>/dev/null || true)

    if [ -n "$bytes" ]; then
        echo "$bytes"
    else
        echo "n/a"
    fi
}

linux_simd_flags() {
    local flags printed
    printed=0
    flags=$(awk -F: '/^(flags|Features)[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)

    for flag in neon asimd sse4_1 sse4_2 avx avx2 avx512f; do
        case " $flags " in
            *" $flag "*)
                printf '  %s = 1\n' "$flag"
                printed=1
                ;;
        esac
    done

    if [ "$printed" != "1" ]; then
        echo "  (no common SIMD flags found)"
    fi
}

print_linux_profile() {
    print_header

    echo "cpu    : $(linux_cpu_model)"
    echo "cores  : physical=$(linux_physical_cores) logical=$(linux_logical_cores)"
    echo

    echo "=== Cache / memory ==="
    print_kv "hw.cachelinesize" "$(linux_cache_line_size)"
    print_kv "hw.l1dcachesize" "$(linux_cache_size 1 Data)"
    print_kv "hw.l1icachesize" "$(linux_cache_size 1 Instruction)"
    print_kv "hw.l2cachesize" "$(linux_cache_size 2 Unified)"
    print_kv "hw.l3cachesize" "$(linux_cache_size 3 Unified)"
    print_kv "hw.pagesize" "$(getconf PAGESIZE 2>/dev/null || echo "n/a")"
    print_kv "hw.memsize" "$(linux_mem_bytes)"
    echo

    echo "=== SIMD / feature flags (subset) ==="
    linux_simd_flags
}

print_unknown_profile() {
    print_header

    echo "cpu    : unknown"
    echo "cores  : physical=n/a logical=n/a"
    echo

    echo "=== Cache / memory ==="
    for k in hw.cachelinesize hw.l1dcachesize hw.l1icachesize hw.l2cachesize hw.l3cachesize hw.pagesize hw.memsize; do
        print_kv "$k" "n/a"
    done
    echo

    echo "=== SIMD / feature flags (subset) ==="
    echo "  (unsupported OS; add a profile backend for $(uname -s))"
}

case "$(uname -s)" in
    Darwin) print_darwin_profile ;;
    Linux) print_linux_profile ;;
    *) print_unknown_profile ;;
esac
