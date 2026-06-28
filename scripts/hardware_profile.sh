#!/bin/bash
# hardware_profile.sh — print the cache/memory/SIMD profile of this machine.
#
# DOD only makes sense relative to concrete hardware facts. The framework's
# stage 7 (alignment/tile sizing) and the benchmark N-sweep interpretation
# both depend on these numbers. Run this on any machine to regenerate the
# profile for that machine.
#
# On macOS these come from sysctl; on Linux you'd read /sys/devices/system/cpu/
# and /proc/meminfo instead (extend this script when porting).
#
# Usage:  scripts/hardware_profile.sh

set -euo pipefail

echo "=== Hardware profile ==="
echo "date   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host   : $(hostname -s)"
echo "os     : $(uname -s) $(uname -r) ($(uname -m))"
echo

echo "cpu    : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "cores  : physical=$(sysctl -n hw.physicalcpu) logical=$(sysctl -n hw.logicalcpu)"
echo

echo "=== Cache / memory ==="
for k in hw.cachelinesize hw.l1dcachesize hw.l1icachesize hw.l2cachesize hw.l3cachesize hw.pagesize hw.memsize; do
    v=$(sysctl -n "$k" 2>/dev/null || echo "n/a")
    printf "  %-22s = %s\n" "$k" "$v"
done
echo

echo "=== SIMD / feature flags (subset) ==="
sysctl -a 2>/dev/null \
    | grep -iE 'hw.optional.neon|hw.optional.AdvSIMD|hw.optional.armv8' \
    | sed 's/^/  /' \
    || echo "  (no NEON/ARM feature flags found; not an ARM host)"
