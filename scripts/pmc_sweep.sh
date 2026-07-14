#!/usr/bin/env bash
# scripts/pmc_sweep.sh — full PMC collection across all stages and N.
#
# Runs scripts/pmc_collect.sh for every (stage, N, trial) combo, producing
# one CSV per trial in .scratch/pmc/ and a rollup .scratch/pmc/pmc_rollup.csv
# (min per (stage, N) across trials + derived percentages).
#
# Iter counts are scaled by N so each trial runs ~1-3s of step() work (enough
# for stable counters, not so long the sweep takes hours).
#
# Usage: scripts/pmc_sweep.sh [trials]
#   trials defaults to 3

set -euo pipefail

TRIALS="${1:-3}"
STAGES="1 2 3 4 5 6 7"

# N → iters pairs (space-separated list of "N:iters"). Smaller N gets more
# iters (each step is cheap); larger N gets fewer (each step is already slow).
N_ITERS_LIST="
4000:2000
16000:1000
65000:500
262000:200
1000000:100
4000000:50
16000000:20
64000000:10
"

OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/.scratch/pmc"
mkdir -p "$OUTDIR"

# Count total launches for progress.
total=0
for entry in $N_ITERS_LIST; do
    for s in $STAGES; do
        total=$((total + TRIALS))
    done
done

echo "=== PMC sweep: stages=[$STAGES] trials=$TRIALS ===" >&2
echo "    Ns: $(echo "$N_ITERS_LIST" | tr -d ' ' | tr '\n' ' ' | sed 's/:[0-9]*//g')" >&2
echo "    ~$total xctrace launches (each ~2-5s + overhead)" >&2
echo

i=0
for s in $STAGES; do
    for entry in $N_ITERS_LIST; do
        n="${entry%%:*}"
        iters="${entry##*:}"
        for t in $(seq 1 "$TRIALS"); do
            i=$((i + 1))
            echo "[$i/$total] stage=$s N=$n iters=$iters trial=$t" >&2
            scripts/pmc_collect.sh "$s" "$n" "$iters" "$t" 2>&1 | grep "cycles=" | sed "s/^/      /" >&2 || {
                echo "      FAILED" >&2
            }
        done
    done
done

echo
echo "=== building rollup (min per stage/N across trials) ===" >&2
python3 - "$OUTDIR" << 'PYEOF'
import sys, csv, os, glob

outdir = sys.argv[1]

# Collect all trial CSVs.
rows = {}  # (stage, N) -> list of trial dicts
for path in sorted(glob.glob(os.path.join(outdir, "s*_n*_t*.csv"))):
    with open(path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            key = (int(r["stage"]), int(r["N"]))
            rows.setdefault(key, []).append({
                "cycles": int(r["cycles"]),
                "useful": int(r["useful"]),
                "processing": int(r["processing_bottleneck"]),
                "delivery": int(r["delivery_bottleneck"]),
                "discarded": int(r["discarded_bottleneck"]),
                "iters": int(r["iters"]),
                "trial": int(r["trial"]),
            })

# For each (stage, N), pick the trial with min cycles (cleanest sample).
rollup_path = os.path.join(outdir, "pmc_rollup.csv")
with open(rollup_path, "w") as f:
    w = csv.writer(f)
    w.writerow(["stage", "N", "iters", "trial",
                "cycles", "useful", "processing_bottleneck",
                "delivery_bottleneck", "discarded_bottleneck",
                "pct_useful", "pct_processing", "pct_delivery", "pct_discarded"])
    for key in sorted(rows.keys()):
        trials = rows[key]
        best = min(trials, key=lambda t: t["cycles"])
        c = best["cycles"]
        def pct(x): return f"{100.0*x/c:.1f}" if c else "0.0"
        w.writerow([key[0], key[1], best["iters"], best["trial"],
                    c, best["useful"], best["processing"],
                    best["delivery"], best["discarded"],
                    pct(best["useful"]), pct(best["processing"]),
                    pct(best["delivery"]), pct(best["discarded"])])

# Print a readable table.
print(f"\n  {'stage':>5} {'N':>10} {'cycles':>10} {'%useful':>8} {'%proc':>7} {'%deliv':>7} {'%disc':>7}")
print(f"  {'-----':>5} {'----------':>10} {'----------':>10} {'--------':>8} {'-------':>7} {'-------':>7} {'-------':>7}")
with open(rollup_path) as f:
    reader = csv.DictReader(f)
    for r in sorted(reader, key=lambda x: (int(x["stage"]), int(x["N"]))):
        print(f"  {r['stage']:>5} {r['N']:>10} {r['cycles']:>10} "
              f"{r['pct_useful']:>7}% {r['pct_processing']:>6}% "
              f"{r['pct_delivery']:>6}% {r['pct_discarded']:>6}%")
print(f"\n  wrote {rollup_path}", file=sys.stderr)
PYEOF
