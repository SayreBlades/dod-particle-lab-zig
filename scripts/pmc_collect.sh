#!/usr/bin/env bash
# scripts/pmc_collect.sh — PMC (performance monitor counter) collection wrapper.
#
# Runs the bench under xctrace's "CPU Counters" template (CPU Bottlenecks guided
# mode) and exports per-process cycle-saturation data to CSV. This is the
# cycle-side context instrument that complements the bench's bandwidth-side
# `GB/s eff` column: together they tell you whether a stage is bandwidth-bound
# (near the ~54 GB/s streaming ceiling) or compute/overhead-bound (well below
# it, and *why* — frontend stalls, backend stalls, or branch mispredictions).
#
# The bench's --n/--iters runtime args run a single (N, iters) combo in "PMC
# mode" (no golden check, no sweep) so the whole process is a clean step()
# region — one xctrace launch = one (stage, N, trial) counter row.
#
# Usage:
#   scripts/pmc_collect.sh <stage> <N> <iters> <trial>
#   scripts/pmc_collect.sh 2 1000000 500 1
#
# Output: .scratch/pmc/s{stage}_n{N}_t{trial}.csv (one row: stage,N,trial,
#         cycles,delivery_bottleneck,discarded_bottleneck,processing_bottleneck)
#
# Prerequisites:
#   - Xcode installed (xctrace at /Applications/Xcode.app/Contents/Developer/usr/bin/xctrace)
#   - The bench built: zig build -Dstage=N -Dmode=bench -Doptimize=ReleaseFast
#
# See plan.md §2.2-2.3 for the full PMC collection design.

set -euo pipefail

STAGE="${1:?usage: pmc_collect.sh <stage> <N> <iters> <trial>}"
N="${2:?}"
ITERS="${3:?}"
TRIAL="${4:?}"

XCTRACE=""
for candidate in \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace" \
    "$(command -v xctrace 2>/dev/null || true)"; do
    if [ -x "$candidate" ]; then XCTRACE="$candidate"; break; fi
done

if [ -z "$XCTRACE" ]; then
    echo "error: xctrace not found. Install Xcode or set XCTRACE path." >&2
    echo "  fallback: powermetrics --show-process-ipc (sudo, IPC only)" >&2
    exit 1
fi

# Resolve binary to absolute path before cd-ing to temp dir.
BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/dod-particles"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found. Build first:" >&2
    echo "  zig build -Dstage=$STAGE -Dmode=bench -Doptimize=ReleaseFast" >&2
    exit 1
fi

OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/.scratch/pmc"
mkdir -p "$OUTDIR"
TRACE="$OUTDIR/s${STAGE}_n${N}_t${TRIAL}.trace"
CSV="$OUTDIR/s${STAGE}_n${N}_t${TRIAL}.csv"

# Build the stage if needed (silent if up-to-date).
echo "building stage $STAGE..." >&2
zig build -Dstage="$STAGE" -Dmode=bench -Doptimize=ReleaseFast >&2 2>&1 || true

# xctrace ignores --output when launching a process (known quirk); it writes
# to Launch_<name>_<timestamp>.trace in CWD. We launch from a temp dir and
# move the result.
TMPDIR_PMC="$(mktemp -d /tmp/pmc_XXXXXX)"
trap 'rm -rf "$TMPDIR_PMC"' EXIT

echo "recording: xctrace CPU Counters over stage=$STAGE N=$N iters=$ITERS trial=$TRIAL" >&2
PROJDIR="$(pwd)"
cd "$TMPDIR_PMC"
"$XCTRACE" record --template "CPU Counters" \
    --launch -- "$BIN" --n "$N" --iters "$ITERS" \
    --time-limit 60s >&2 2>&1

# Find the auto-named trace file and move it.
TRACE_FILE="$(ls -d Launch_*.trace 2>/dev/null | head -1)"
if [ -z "$TRACE_FILE" ]; then
    echo "error: xctrace did not produce a trace file" >&2
    exit 1
fi
mv "$TRACE_FILE" "$TRACE"

# Export the per-process aggregated counter table.
# The CPU Bottlenecks guided mode classifies cycles into:
#   [0] Cycles, [1] Instruction Delivery Bottleneck,
#   [2] Discarded Bottleneck, [3] Instruction Processing Bottleneck
# (Useful = Cycles - sum of bottlenecks, computed downstream.)
cd "$PROJDIR"
"$XCTRACE" export --input "$TRACE" \
    --xpath '//trace-toc/run[@number=1]/data/table[@schema="CounterMetricAggregatedForProcess"]' \
    > "$TRACE.xml" 2>&1

# Parse the XML and sum counters into one CSV row.
python3 - "$TRACE.xml" "$CSV" "$STAGE" "$N" "$ITERS" "$TRIAL" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

trace_xml, csv_path, stage, n, iters, trial = sys.argv[1:7]
tree = ET.parse(trace_xml)
root = tree.getroot()

# Each <row> has a <uint64-array> with 4 values. The CPU Bottlenecks guided
# mode classifies every cycle into exactly one of 4 categories; Cycles = sum.
# Array ordering (decoded from areaGraphSepcIndexTometricIndex [4:0,1:2,2:3,3:1]):
#   [0] Useful, [1] Instruction Processing Bottleneck,
#   [2] Instruction Delivery Bottleneck, [3] Discarded Bottleneck
# Cycles = Useful + Processing + Delivery + Discarded.
#
# Refs: many rows reference a previous element's id via ref="N" instead of
# repeating the value. Build an id→text map first, then resolve.

# Pass 1: collect id→text for all <boolean> elements that define an id.
bool_by_id = {}
for el in root.iter('boolean'):
    if 'id' in el.attrib and el.text is not None:
        bool_by_id[el.attrib['id']] = el.text.strip()

# Array indices: 0=useful, 1=processing, 2=delivery, 3=discarded
totals = [0, 0, 0, 0]
for row in root.iter('row'):
    # Resolve is-precise: direct text or ref lookup. Sum only precise (1ms)
    # rows; imprecise (10ms) rows aggregate 10 precise rows → double-counts.
    is_precise_el = row.find('boolean')
    if is_precise_el is None: continue
    if is_precise_el.text is not None:
        val = is_precise_el.text.strip()
    elif 'ref' in is_precise_el.attrib:
        val = bool_by_id.get(is_precise_el.attrib['ref'], '')
    else:
        continue
    if val != '1': continue
    arr = row.find('uint64-array')
    if arr is None or arr.text is None: continue
    vals = arr.text.split()
    if len(vals) != 4: continue
    for i, v in enumerate(vals):
        totals[i] += int(v, 0)

useful, processing, delivery, discarded = totals
cycles = useful + processing + delivery + discarded
with open(csv_path, 'w') as f:
    f.write("stage,N,iters,trial,cycles,useful,processing_bottleneck,delivery_bottleneck,discarded_bottleneck\n")
    f.write(f"{stage},{n},{iters},{trial},{cycles},{useful},{processing},{delivery},{discarded}\n")

pct = lambda x: 100.0 * x / cycles if cycles else 0
print(f"  cycles={cycles} useful={useful} ({pct(useful):.1f}%) "
      f"processing={processing} ({pct(processing):.1f}%) "
      f"delivery={delivery} ({pct(delivery):.1f}%) "
      f"discarded={discarded} ({pct(discarded):.1f}%)",
      file=sys.stderr)
PYEOF

echo "wrote $CSV" >&2
