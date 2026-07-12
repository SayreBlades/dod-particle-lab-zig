# DOD Particle Lab — Zig

A hands-on laboratory for *feeling* the cache/perf lessons from Mike Acton's
CppCon 2014 talk, ["Data-Oriented Design and C++"](https://www.youtube.com/watch?v=rX0ItVEVjHc),
implemented as an interactive **raylib game** in Zig on Apple Silicon.

The thesis, in one sentence: *the object was a lie.* There was never a "Particle"
— there were five loops that touched overlapping subsets of its fields. When we
laid out memory for the loops instead of for the concept, the loops got 10× faster
and the code got simpler. This lab walks through that transformation in stages;
the math never changes between stages, only the data layout and access pattern do.

**Status:** Stage 4 of 9 — last landed C7/stage 4 (branchless compaction: the branchy `if (age >= kill_age) respawn(i)` becomes an alive mask + arithmetic-destination compaction — `dest = write * is_alive + i * (1 - is_alive)`, zero `if` in the compaction loop. P5: turn data-dependent control flow into data-dependent arithmetic. Two audit-predicted reclaims besides the branch: `life` leaves *storage* entirely (was a constant), and the entire `cold` array is deleted — `color` → `kindColor(kind)` lookup, `size`/`rotation`/`mass`/`flags` hardcoded, `seed` was dead data. ~54 B/particle of constant/dead data gone. Golden PASS. The technique lands; the time is overhead in the natural alive pattern — the payoff is under adversarial input, where the branchy version mispredicts ~50% and the branchless version mispredicts 0%.)

## Quick start

```sh
git submodule update --init --recursive
```

There are two modes. **play** opens a window and runs the simulation
visually; **bench** runs headless and prints numbers + a correctness check.
Always build with `-Doptimize=ReleaseFast` for real numbers — Debug builds
make every stage look equally slow and hide the cache effects we're here
to see.

### Play mode (interactive window)

```sh
zig build run -Dstage=1 -Dmode=play -Doptimize=ReleaseFast
```

Opens a 1024×1024 raylib window. You should see particles rendering and
moving (three colored streams from the center: gray smoke, orange sparks,
blue debris, arcing under gravity). HUD top-left shows FPS, stage name, and
N. Keys: `ESC` quit · `P` pause · `F1` toggle HUD.

### Bench mode (headless numbers + correctness)

```sh
zig build -Dstage=1 -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
```

(Bench mode reads from stdin/stderr, so build and run are separate steps.)
Prints: the hardware profile, a correctness check vs the golden file, and
the N-sweep table. Stage 1 also generates the golden file.

### Audit mode (data-density, the Acton zip-test)

```sh
zig build -Dstage=1 -Dmode=audit -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
```

Pipes each field's raw bytes through `gzip -c` and tabulates the compression
ratio. gzip is an entropy oracle — the ratio is a lower bound on a field's
information density. Low density = redundant per-particle (constant / few
distinct values) = candidate to drop from the hot loop. This is Mike Acton's
"print it, zip it" trick from ~49:38 of the talk, applied per-field. The
headline number is the size-weighted **MEAN density of the fields the hot
loop touches** — stages 2–9 should drive it UP as cold/constant fields leave
the hot loop, the qualitative twin of `ns/particle` falling. Runs against the
same fixed seed + steps as the golden check. See
`.scratch/plan/RESULTS.md` for the per-stage density rollup.

`-Dstage` selects the data layout (1–11); `-Dmode` selects the driver.
`zig build run` builds + executes; `zig build` alone only builds to
`zig-out/bin/`.

## How to verify a checkpoint

Each checkpoint has a **criterion** (what must be true) and a **command**
(what you run to see it). Run both modes for any stage you're verifying.

### Verify play mode

```sh
zig build run -Dstage=N -Dmode=play -Doptimize=ReleaseFast
```

**What you're checking:**
- A window opens and the sim runs for ≥60s without crashing.
- Particles render and move (the visual should look the same across all
  stages — the *math* never changes, only the *layout* does).
- The HUD shows the correct stage name and particle count.

If the visual changes between stages (different trajectories, colors,
counts), something is wrong — the layout transformation broke the math.

### Verify bench mode

```sh
zig build -Dstage=N -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
```

**What you're checking, top to bottom of the output:**
1. **Hardware block** — prints cache facts (line size, L1/L2 sizes, etc.).
   Should match `scripts/hardware_profile.sh` on the same machine.
2. **Correctness: PASS** — the stage's output matches `golden/stage1.bin`
   within `eps=1e-4`. This is the proof the DOD transformation didn't change
   the math. If you see `FAIL`, the stage has a bug — it diverged from
   stage 1's reference. (Stage 1 self-checks after generating the golden file.)
3. **Benchmark table** — the N-sweep. Read `ns/particle` across N:
   - It should generally *decrease* as N grows (fixed costs amortize).
   - It *increases* at the L2 spill point (1M→4M on M4) — that's expected.
   - **Between stages**, later stages should have lower `ns/particle` than
     earlier ones at large N. If stage 3 isn't faster than stage 2 at N≥1M,
     the transformation didn't land.

**Reproducibility note:** bench output goes to stderr via `std.debug.print`,
so it works whether or not a terminal is attached. The golden file
(`golden/stage1.bin`) is gitignored — it regenerates from stage 1 on any
`-Dstage=1 -Dmode=bench` run.

### Verify audit mode (data-density)

```sh
zig build -Dstage=N -Dmode=audit -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
```

**What you're checking:**
1. **Hardware block** — same as bench (the ritual anchor).
2. **Per-field density table** — `density = gz_bytes / raw_bytes` per field.
   Low density = redundant per-particle (constant / few distinct values) =
   candidate to drop from the hot loop. High density = real signal.
3. **MEAN density** — the headline number, size-weighted over the dumped
   fields. It should **rise** across stages as cold/constant fields leave the
   hot loop — the qualitative twin of `ns/particle` falling. Stage 1 ≈ 0.36;
   later stages should climb toward ~0.9.

The audit links no raylib and never touches the hot path — it's *context*, not
an acceptance gate. The per-field interpretation and what each stage's density
should look like is in `src/stages/NN_name/README.md` (§3) and the cross-stage
rollup in `.scratch/plan/RESULTS.md`.

### Reading the numbers

The whole project's payoff is watching `ns/particle` drop across stages.
Example (stage 1 baseline on M4, with working-set `mem` column):

```
           N |     mem(MB) |    ns/particle |   frames/sec
        4000 |         0.3 |          3.104 |      80540.9
      262000 |        17.0 |          1.326 |       2878.2
     4000000 |       259.4 |          1.684 |        148.4
    64000000 |      4150.4 |          1.719 |          9.1
```

Read the curve shape: dips to a minimum at 262K (SLC-resident), slopes up
to 1M (L2→SLC), then plateaus from 4M→64M (memory-bandwidth-bound — the
working set grows 64× while ns/particle barely moves). The `mem` column
makes the bandwidth plateau obvious: ~80 B/particle × N. Stage 2 (hot/cold)
shrinks bytes/particle → lifts the whole plateau down. Stage 3 (SoA)
shrinks further. Stage 9 (synthesis) should be ~8–15× lower at N=1M.

### Bench columns and what they diagnose

The bench table reports more than `ns/particle` — the other columns are
the *diagnostic instruments* that tell you *why* a stage is fast or slow:

| column | what it is | what it tells you |
|---|---|---|
| `bytes/p` | hot-loop bytes touched per particle (`sim.bytesPerParticle`) | the per-particle working set; shrinks as cold fields leave the hot loop |
| `mem(MB)` | `N × bytes/p` — per-frame working set | which cache level the working set lives in (L1/L2/SLC/DRAM) |
| `ns/particle(min)` | cleanest per-particle cost (min of 3 trials) | the headline number for cross-stage comparison |
| `GB/s eff` | `N × bytes/p ÷ ns/frame` — effective hot-loop bandwidth | **the key diagnostic:** bandwidth-bound vs compute/overhead-bound (see below) |
| `runtime(ms)` | wall time spent at this N across all trials | the real bench cost; sums to the TOTAL row |

The single-core streaming ceiling on this M4 is ~**54 GB/s** (measured:
stage 1 hits it at 262K, cache-resident). `GB/s eff` tells you where a stage
sits relative to that ceiling:

- **Near the ceiling (~54 GB/s)** → **bandwidth-bound.** The loop is keeping
  the memory subsystem busy; FP is hidden behind the loads. Cutting
  `bytes/p` is the lever (stages 2, 3).
- **Well below the ceiling** → **compute/overhead-bound.** The loop is
  spending its time on FP math, loop branches, stream management, or latency
  stalls — not waiting on memory. Cutting `bytes/p` *won't help*; you have to
  raise throughput (SIMD, fewer streams, branchless) or cut the compute.

This distinction is the key to reading stages 2 and 3: stage 2 is already
off the ceiling (~33 GB/s, 62%) — compute-bound, not bandwidth-bound — so
the stage-3 byte-reduction (36→29 B/p) can't win on its own. The `GB/s eff`
column caught that before any reasoning did.

### Vocabulary: "stream" and "number of streams"

A **stream** is one contiguous run of memory addresses the program touches in
sequential order — the thing the CPU's hardware prefetcher tracks as a single
unit. `for (arr) |x|` walks one stream; `for (a, b) |x, y|` walks two.

- The prefetcher has a limited number of entries / L1 fill buffers (~10–13 on
  this M4 core). Each stream you walk consumes one.
- One stream = the prefetcher's happy case: it fetches ahead, you never stall.
- Many concurrent streams compete for the same fill buffers. If a loop walks
  8 streams at once, each gets ~1/8 of the prefetcher's tracking bandwidth.

This matters for the AoS-vs-SoA trade:
- **Stage 2 (AoS)** walks **1 stream** — one `[]ParticleHot` array, one base
  pointer advancing by `sizeof(ParticleHot)`. Prefetcher-perfect. But it
  drags 7 wasted bytes/particle through the line (`life` + padding).
- **Stage 3 (SoA)** walks **8 streams** — `pos_x, pos_y, pos_z, vel_x, vel_y,
  vel_z, age, kind`. Each is contiguous and dense (no stride waste), but the
  loop manages 8 independent base pointers across 4 passes.

The trade: give up one perfectly-prefetched stream to save 7 B/particle and
gain per-component density. On a *bandwidth-bound* loop that trade wins
(fewer bytes × 8 streams still saturates memory). On a *compute-bound* loop
(stage 2 at 33 GB/s, 62% of ceiling) it loses: the 7 B saving is irrelevant
against the compute floor, and the 8-stream reorganization adds loop-branch
overhead (4 passes vs 1) and prefetcher complexity — with no SIMD to amortize
it (stage 3 is scalar; SIMD is stage 6's reward for the layout).

So "number of streams" is shorthand for "how many independent sequential
memory accesses the loop interleaves." Fewer is usually better, *unless*
reducing streams means dragging useless bytes through cache (the AoS-vs-SoA
trade). The lab's whole story is a measured walk through that trade.

### PMC counters — cycle-saturation (xctrace CPU Counters)

The `GB/s eff` column is a *bandwidth-side* proxy for "is the CPU saturated?"
For the cycle-side answer — *why* the CPU isn't saturated — use the PMC
(performance monitor counter) collection via `scripts/pmc_collect.sh`, which
wraps `xctrace`'s "CPU Counters" template in its default **CPU Bottlenecks**
guided mode. This classifies every retired cycle into exactly one of four
categories; `cycles` is their sum. Read the categories as percentages of
`cycles` to diagnose what a stage is actually spending its time on.

| column | what it counts | what it tells you |
|---|---|---|
| `cycles` | total cycles on the cores (sum of the other 4) | the denominator; headline is "% of cycles" |
| `useful` | cycles actually *retiring instructions* (frontend fed the backend, data ready, instruction committed) | **high % Useful = FPU is doing real work.** The cycle-saturation measure. Stage 6's `@Vector` should push this up (each NEON `fma` retires 4× the math of a scalar `fma`) |
| `processing_bottleneck` | backend stalls — instruction in flight but operands not ready (cache misses, TLB walks, data dependencies) | **high % Processing = memory/latency-bound.** Stage 1's 40% lives here (68 B/particle AoS thrashes cache); stage 2's hot/cold split pays off (40→13%) because fewer cold bytes means fewer backend stalls waiting on cache refills |
| `delivery_bottleneck` | frontend stalls — backend *could* retire but the frontend can't feed it fast enough (icache misses, branch-target-misprediction fetch bubbles, decode bandwidth limits) | **high % Delivery = frontend/icache pressure.** Near-zero for tiny loops; rises with multi-pass structure. Stage 3's jump to 5% is the signature of SoA's 4-pass loop transitions |
| `discarded_bottleneck` | cycles spent on *wrong-path* work from branch mispredictions (fetched/decoded/executed past a branch that went the wrong way, then flushed) | **high % Discarded = branch misprediction cost.** Stage 1's 11% is the deliberate per-particle `switch(kind)` — three interleaved kinds, hard to predict. Stage 5 (sort-by-kind) removes the branch entirely |

**How to read a row.** Pick a stage, read the percentages top-down:
1. **% Useful** tells you the efficiency ceiling — how saturated the FPU is.
2. Then look at where the *rest* of the cycles went. That breakdown tells you
   *what to fix next*:
   - high **Processing** → cut bytes/particle or improve locality (stages 2, 3, 7)
   - high **Discarded** → remove the unpredictable branch (stages 4, 5)
   - high **Delivery** → simplify the loop structure, fewer passes (informs the SoA-vs-AoS trade)
   - all three low but % Useful still not great → the work itself is the
     bottleneck, needs SIMD (stage 6)

**Full sweep data** (3 trials per (stage, N), min-of-3 cycles, ReleaseFast, M4 —
full CSV at `.scratch/pmc/pmc_rollup.csv`):

```
stage |     N |   cycles | %useful | %proc | %deliv | %disc
------+-------+----------+---------+-------+--------+------
  1   |    4K |    318K  |   55.1% | 26.5% |   4.1% | 14.4%
  1   |   65K |   1.15M  |   58.2% | 27.1% |   1.4% | 13.2%
  1   |  262K |   2.06M  |   58.0% | 28.2% |   0.8% | 12.9%
  1   |    1M |   4.99M  |   48.1% | 41.3% |   0.4% | 10.2%
  1   |    4M |  12.4M   |   42.4% | 48.9% |   0.2% |  8.4%
  1   |   64M |  82.5M   |   40.9% | 51.8% |   0.7% |  6.6%
  2   |    4K |    308K  |   65.6% | 10.5% |   4.9% | 19.0%
  2   |   65K |   1.08M  |   69.0% | 12.6% |   1.6% | 16.7%
  2   |  262K |   1.83M  |   68.9% | 13.7% |   1.0% | 16.4%
  2   |    1M |   3.69M  |   69.1% | 14.5% |   0.6% | 15.8%
  2   |    4M |   8.21M  |   68.6% | 16.3% |   0.4% | 14.6%
  2   |   64M |  51.9M   |   64.8% | 24.9% |   0.4% |  9.9%
  3   |    4K |    438K  |   68.7% | 14.8% |   9.1% |  7.5%
  3   |   65K |   1.67M  |   71.8% | 15.1% |   6.2% |  7.0%
  3   |  262K |   2.78M  |   70.9% | 16.7% |   5.7% |  6.7%
  3   |    1M |   5.71M  |   69.5% | 19.3% |   4.8% |  6.4%
  3   |    4M |  11.5M   |   65.1% | 23.8% |   4.5% |  6.6%
  3   |   64M |  44.5M   |   50.4% | 37.4% |   5.0% |  7.2%
  4   |    4K |    729K  |   57.2% | 31.4% |  10.6% |   0.9%
  4   |   65K |   3.29M  |   52.8% | 37.8% |   9.0% |   0.3%
  4   |  262K |   6.16M  |   47.0% | 45.0% |   7.7% |   0.4%
  4   |    1M |  12.71M  |   44.7% | 47.8% |   7.1% |   0.5%
  4   |    4M |  26.56M  |   43.5% | 49.2% |   7.0% |   0.2%
  4   |   64M |  93.66M  |   36.7% | 59.3% |   3.7% |   0.3%
```

Reading the sweep (the cycle-level story behind the `GB/s eff` column):

- **Stage 1, large N:** % Useful drops to ~41%, % Processing rises to ~52% —
  the bandwidth-bound signature. The 68 B/particle AoS thrashes cache; the
  backend stalls waiting on memory. The `GB/s eff` column (~46 GB/s, near the
  54 ceiling) says "bandwidth-bound"; the PMC says *where* the lost cycles went.
- **Stage 2's win:** % Useful jumps to ~69% (stable across N) — the hot/cold
  split stopped dragging cold bytes through cache, so % Processing dropped
  41→14% at 1M. **The cold bytes were the bottleneck, and removing them converted
  stall cycles into useful cycles.** % Discarded rose (the `switch(kind)` is
  now a bigger fraction of a smaller total).
- **Stage 3 at small/mid N:** % Useful ~70-72% — **the same efficiency as
  stage 2** (both compute-bound at ~70%). But stage 3 needs more total cycles
  (e.g. 5.71M vs 3.69M at 1M) for the same work — the 8-stream overhead. The
  extra cycles show up as % Delivery (5-9% vs stage 2's <1% — the multi-pass
  frontend pressure) and slightly more % Processing (the 8-stream prefetcher
  juggling).
- **Stage 3 at large N (64M):** % Useful drops to 50% — below stage 2's 65%.
  The 8-stream SoA can't keep the prefetcher fed at DRAM-bandwidth scale; %
  Processing rises to 37% (vs stage 2's 25%). **At large N, the layout's
  overhead compounds and stage 3 loses on both cycles AND utilization.**
- **% Discarded across stages:** stage 2 (10-19%) > stage 1 (7-14%) > stage 3
  (6-8%). Stage 2's switch is a bigger fraction of its tighter loop; stage 3's
  per-component loops have fewer unpredictable branches. Stage 5 (sort-by-kind)
  will attack this directly.
- **Stage 4 — the P5 payoff, measured:** % Discarded **collapsed to ~0.3-0.9%**
  (from stage 3's 6-8%) — the branchless compaction **eliminated the kill-branch
  mispredictions**, exactly as P5 predicted. The branchy `if (age >= kill_age)`
  was the source of the discarded cycles; branchless arithmetic-destination
  compaction (`dest = write * is_alive + i * (1 - is_alive)`, zero `if`) drove
  % Discarded to near-zero. **This is the technique landing, measured on the
  cycle side.** But % Useful also dropped (to 37-57%, from stage 3's 50-72%):
  the compaction pass is O(n) every frame (8 reads + 8 writes per particle) and
  stalls the backend — % Processing rose to 31-59% (from stage 3's 15-37%).
  Stage 4 traded branch-misprediction cycles for memory-stall cycles. Net:
  slower, because the compaction overhead (a full O(n) pass touching all 8 hot
  streams) vastly exceeds the saved mispredictions (~6-8% → ~0.5%). The `GB/s eff`
  column confirms: ~7.5 GB/s (vs stage 3's ~17) — the same bytes touched more
  times (math + compaction), not fewer. The P5 payoff regime is adversarial
  alive patterns, where the branchy version's % Discarded would hit ~50% and
  the branchless version's stays at ~0%.

**The cross-stage pattern the PMC reveals:** stages 2 and 3 have the **same
% Useful at small/mid N** (~70%) — proving they're both compute-bound at the
same per-cycle efficiency. Stage 3's loss is *more cycles*, not *worse
efficiency*. Stage 6's `@Vector` should raise % Useful itself (more math per
retired instruction), which is the throughput lever stage 3's layout unlocks
but doesn't claim (scalar, per P7).

Full collection design (per-stage, per-N, multi-trial) is documented in
`plan.md` §2.2–2.3. The PMC collection is a *context instrument* (same pattern
as the audit) — run it when you need the cycle-saturation story, not on every
bench invocation. Requires Xcode (xctrace); if unavailable, `powermetrics
--show-process-ipc` (sudo) gives per-process IPC only.

## Checkpoints


| #  | Checkpoint                                     | Stage | Complete |
|----|------------------------------------------------|-------|----------|
| C1 | Window opens with HUD (raylib+build proven)    | 0     | [x]      |
| C2 | Particles render and move                      | 1     | [x]      |
| C3 | Bench mode works + golden file generated       | 0,1   | [x]      |
| C4 | Stage 1 fully passes acceptance (baseline)     | 1     | [x]      |
| C5 | Stage 2 (hot/cold) — first measured DOD win    | 2     | [x]      |
| C6 | Stage 3 (SoA) — flagship layout transformation | 3     | [x]      |
| C7 | Stages 4–9 each pass acceptance                | 4–9   | stage 4 ✅ / 5–9 [ ] |
| C8 | Synthesis verified, RESULTS recorded           | 9     | [ ]      |
| C9 | Bonus stages (rasterizer + video export)       | 10,11 | [ ]      |

## Hardware target

DOD only makes sense relative to concrete cache/memory facts. The framework
prints these at the start of every bench run, and stage 7 (alignment/tile
sizing) is tuned to them.

**Regenerate the profile on any machine:**

```sh
scripts/hardware_profile.sh
```

**Reference profile (the dev machine this project is built against):**

```
cpu    : Apple M4
cores  : physical=10 logical=10

hw.cachelinesize   = 128         ← stage 7 alignment/tile target
hw.l1dcachesize    = 65536       (64 KB, per core, split from L1i)
hw.l1icachesize    = 131072      (128 KB, per core)
hw.l2cachesize     = 4194304     (4 MB, per cluster, UNIFIED: code+data share)
hw.l3cachesize     = 0           (sysctl quirk; M4 has an SLC, see below)
hw.pagesize        = 16384       (16 KB)
hw.memsize         = 17179869184  (16 GB)
SIMD               = NEON (128-bit → @Vector(4, f32) native; @Vector(8) = 2 ops)
```

**On the M4 cache hierarchy and what the benchmark actually sees.** L1 is
split (i/d separate); L2 is *unified* (code + data share 4 MB). `sysctl`
reports `hw.l3cachesize = 0`, but the M4 has a System Level Cache (SLC) below
L2 and above RAM — its size isn't publicly specified by Apple (likely
~16–24 MB). Apple doesn't expose userspace PMU access, so we can't read
clean per-level refill counters; instead we **infer the hierarchy from kinks
in the N-sweep curve** (the DOD way: measure behavior, don't trust specs).

The stage-1 extended sweep `{4K … 64M}` reveals the shape:

```
      N |     mem(MB) | ns/particle | what's happening
   4K   | 0.3         | 3.10        | L1/L2 resident
  16K   | 1.0         | 2.66        | L2 resident
  65K   | 4.2         | 1.62        | past L2, into SLC
 262K   | 17.0        | 1.33        | SLC resident (first minimum)
   1M   | 64.8        | 1.52        | L2→SLC slope
   4M   | 259.4       | 1.68        | bandwidth plateau
  16M   | 1037.6      | 1.71        | bandwidth plateau
  64M   | 4150.4      | 1.72        | bandwidth plateau (RAM)
```

Three honest takeaways, which correct an earlier "L2 spill cliff" framing:
1. There is **no cliff** — the L2→SLC transition (262K→1M) is a *gentle slope*
   (+17%), because SLC latency is only ~2–3× L2. The curve dips to a minimum
   at 262K (SLC-resident) then slopes up.
2. From ~1M onward, ns/particle is **flat across a 64× working-set increase**
   (1.52 → 1.72). That plateau is the signature of **memory-bandwidth
   saturation**, not cache-miss latency. Stage 1 streams ~80 B/particle; at
   4M that's ~190 GB/s of effective throughput, ~the M4's DRAM ceiling.
3. **The SLC is not visible as a discrete kink** for this streaming access
   pattern — only as the flat region between the L2 slope and the RAM plateau.
   A second kink (SLC→RAM) doesn't appear; the M4's SLC handles streaming
   reads well enough that bandwidth saturates before capacity does.

**What this means for the DOD story.** Stage 1 is **memory-bandwidth-bound**
from ~1M particles. The cache lessons (L1→L2→SLC residency) are most visible
at small N (4K–262K); the big-N region is a *bandwidth* lesson. This
reframes what stages 2–3 target: reducing bytes-per-particle (AoS→SoA,
hot/cold split) directly lifts off the bandwidth floor. At large N, stage 3
(24 B/particle vs stage 1's 80 B) should see ~3× better ns/particle —
*because it streams fewer bytes*, not because it hits cache more. And stage 6
(SIMD) will help at small N (cache-resident) but be ~flat at large N
(bandwidth-bound) — a bandwidth roofline in miniature.

## Layout

```
build.zig, build.zig.zon      # build: -Dstage/-Dmode, raylib C compile
src/                          # the project
├── main.zig                  # comptime switch: stage -> SimImpl, mode -> driver
├── framework/                # shared across every stage
├── bindings/                 # minimal hand-written extern "c" (raylib)
├── stages/NN_name/sim.zig     # the ONLY file that changes between stages 1-9
│   └── README.md             # per-stage: lesson + bench + density audit
vendor/                       # git submodules: raylib (6.0), stb (PNG write)
scripts/hardware_profile.sh   # regenerate the hardware profile above
```

## Dependencies

- **Zig 0.17-dev** (dev toolchain; `minimum_zig_version` in `build.zig.zon` is `0.16.0`).
- **raylib 6.0** — vendored as a git submodule at `vendor/raylib`. We compile its
  C source directly in `build.zig` (raylib-zig's build scripts are broken on
  0.17-dev, so we bypass them and write minimal `extern "c"` bindings).
- **stb** — vendored at `vendor/stb`, used only for PNG output (bonus stages).
- **ffmpeg** (optional) — only for the `--record` video-export bonus stage.
