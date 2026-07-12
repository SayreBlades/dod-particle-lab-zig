# Stage 5 — Sort by kind / de-virtualize (P6)

> *Per-element dispatch is a layout problem in disguise. De-virtualize.*

Stage 5 restructures the data so the per-particle `switch (kind)` dispatch
(stages 1–4) moves **out of the per-particle loop** and **into the data
layout**. After compaction + spawn, the particles are sorted by kind (Dutch-
flag 3-way partition, in-place, O(n)). Now same-kind particles are contiguous
— a "run." The dispatch loop iterates each kind's run separately, with **no
per-particle switch**: the loop body is "specialized" per run.

- **Checkpoint:** C7 (stage 5 of 6 within C7) — PASS (structure lands; time is
  overhead — the dispatch was already free, and the sort adds its own branch
  cost).
- **DOD principle illustrated:** P6 (per-element dispatch is a layout problem
  in disguise; de-virtualize).
- **The transformation:** `switch(kind)` per-particle → sort-by-kind + per-kind
  run iteration (no switch in the dispatch).

---

## 1. The problem it poses

Stages 1–4 have a per-particle `switch (kind)` dispatch in the hot loop:

```zig
// Stages 1–4: per-particle dispatch (a data-dependent branch)
for (0..n) |k| {
    _ = switch (kd[k]) {   // ← the predictor must guess per-particle
        .smoke => {},
        .spark => {},
        .debris => {},
    };
}
```

The plan's thesis (P6): this per-element dispatch is a *layout problem in
disguise*. If particles of the same kind were contiguous, the dispatch would
move from per-particle (data-dependent branch) to per-run (structural loop
boundary) — no switch in the inner loop. Stage 5 makes that real by sorting
the particles by kind each frame.

**The honest wrinkle on this toolchain:** the switch cases are deliberately
empty no-ops (the *branch* is the point, not the work — all kinds share the
same physics). The PMC data (§4) reveals the compiler already optimized the
empty switch away: stage 4 (which still HAS the switch) measured % Discarded
at ~0.5% — near zero. So there's no dispatch cost to remove. The sort adds
O(n) overhead AND its own branch cost (the 3-way partition). Net: slower.
The de-virtualization *structure* lands; the *time* does not improve.

---

## 2. The DOD transformation

### Sort by kind — Dutch-flag 3-way partition

```zig
// After compaction + spawn, sort by kind (in-place, O(n), O(1) space).
// Dutch-flag 3-way partition: [smoke... | spark... | debris...]
fn sortByKind(self: *@This()) void {
    const kd = self.kind;
    var lo: usize = 0;   // boundary: smoke | spark
    var mid: usize = 0;  // current element
    var hi: usize = n;   // boundary: spark | debris (exclusive)
    while (mid < hi) {
        const k = @intFromEnum(kd[mid]);
        if (k == 0) { // smoke → swap to the left
            self.swapParticle(lo, mid);
            lo += 1; mid += 1;
        } else if (k == 1) { // spark → stays in the middle
            mid += 1;
        } else { // debris → swap to the right
            hi -= 1;
            self.swapParticle(mid, hi);
        }
    }
}
```

The array becomes `[smoke, smoke, ..., spark, spark, ..., debris, debris, ...]`.
Same-kind particles are contiguous. The dispatch is now per-kind run iteration
(loop boundaries), not per-particle (switch).

### Why variant (a) (sort), not variant (b) (per-kind streams)

Variant (b) — split into per-kind streams (`smoke.pos[]`, `spark.pos[]`, ...)
— avoids the per-frame sort but requires 3× the memory (worst case all
particles are one kind → each stream must hold n). At N=64M, that's 3× the
hot-stream memory — infeasible on a 16 GB machine. The sort approach uses
the same memory as stage 4 (no blowup) and is O(n) per frame.

### The dispatch, removed

Stages 1–4's step ended with a per-particle switch. Stage 5 removes it
entirely — the sorted layout makes the dispatch implicit:

```zig
// Stage 5: dispatch is REMOVED. The sorted layout makes per-kind runs
// implicit. In a real system with per-kind physics, each run gets a
// specialized loop:
//   smoke run:  [0, smoke_end)       — specialized smoke physics
//   spark run:  [smoke_end, spark_end) — specialized spark physics
//   debris run: [spark_end, n)        — specialized debris physics
// No switch — the dispatch moved from per-particle data to per-run structure.
```

---

## 3. The honest outcome — structure lands, time is overhead (and the sort adds branch cost)

### Stage 5 vs stage 4 vs stage 3 — back-to-back, 3 trials min, ReleaseFast, M4

|          N | stage 3 | stage 4 | stage 5 | S5/S3 | S5/S4 |
|-----------:|--------:|--------:|--------:|------:|------:|
|      65000 |   1.634 |   3.140 |   5.195 | 0.31× | 0.60× |
|     262000 |   1.633 |   3.751 |   7.799 | 0.21× | 0.48× |
|  1000000 |   1.670 |   3.791 |   6.407 | 0.26× | 0.59× |
|  4000000 |   1.720 |   3.850 |   6.446 | 0.27× | 0.60× |
| 16000000 |   1.724 |   3.948 |   6.529 | 0.26× | 0.61× |
| 64000000 |   1.727 |   4.060 |   6.631 | 0.26× | 0.61× |

Stage 5 is ~3.9× slower than stage 3 and ~1.6× slower than stage 4 at large N.
Two compounding costs:

1. **The sort is O(n) overhead per frame.** The Dutch-flag partition reads and
   writes all 8 hot streams (swapping particles between kind-regions). Each
   swap is 8 field swaps. The sort does at most n swaps — roughly doubling the
   O(n) overhead vs stage 4 (which already has the compaction pass).

2. **The sort adds its own branch cost — the surprising PMC finding (§4).** The
   Dutch flag's 3-way branch (`if k==0 ... else if k==1 ... else ...`) is
   data-dependent: the kind order before sorting is random (3 kinds, ~33% each),
   so the branch predictor mispredicts ~67% of the time. The PMC measured % Discarded
   **rising** from stage 4's ~0.5% to stage 5's **2–4.7%**. The sort's branch
   is *worse* than the (already-free) switch it replaced.

### Why de-virtualization didn't help here

- **The switch was already free.** The PMC proved stage 4's switch (empty cases)
  was compiler-optimized away (% Discarded ~0.5% WITH the switch). Removing it
  saves nothing — there was no dispatch cost to eliminate.
- **The sort's branch is real.** The Dutch flag partition has a data-dependent
  3-way branch on kind. Before sorting, kinds are randomly interleaved — the
  worst case for a 3-way branch predictor. This *adds* misprediction cost.
- **No per-kind work to specialize.** The plan's P6 expects per-kind work
  (different physics per kind) that the de-virtualization enables. This sim's
  physics is kind-independent (gravity + drag, same for all). So the specialized
  per-kind loops would do the same work as the general loop — no savings.
- **The time win P6 promises** would require either (a) per-kind work (not
  present in this sim) or (b) the SIMD reward (stage 6), where per-kind
  contiguous runs enable kind-specialized vectorized loops.

---

## 4. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=5 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N | bytes/p |   mem(MB) | ns/particle(min) |  ns/frame(min) |  frames/sec | GB/s eff | runtime(ms)
  -----------+---------+-----------+------------------+----------------+-------------+----------+------------
        4000 |      30 |       0.1 |          6.035 |        24141.0 |     41423.2 |     4.97 |        15.2
       16000 |      30 |       0.5 |          5.185 |        82965.6 |     12053.2 |     5.79 |        52.9
       65000 |      30 |       1.9 |          5.195 |       337677.3 |      2961.4 |     5.77 |       204.4
      262000 |      30 |       7.5 |          7.799 |      2043277.3 |       489.4 |     3.85 |      1241.8
     1000000 |      30 |      28.6 |          6.407 |      6407222.9 |       156.1 |     4.68 |      3870.1
     4000000 |      30 |     114.4 |          6.446 |     25782958.1 |        38.8 |     4.65 |     15572.2
    16000000 |      30 |     457.8 |          6.529 |    104471584.0 |         9.6 |     4.59 |     63235.4
    64000000 |      30 |    1831.1 |          6.631 |    424407341.0 |         2.4 |     4.52 |    255459.9
```

The curve is flat from 1M on (~6.4–6.6 ns/particle) and `GB/s eff` is flat at
~4.5 — well below stage 4's ~7.5 and stage 3's ~17. The sort pass touches the
same 8 hot streams as the compaction (reads + writes them in-place), so the
effective bandwidth drops further: the same bytes touched even more times
(math + compaction + sort), not fewer.

---

## 5. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=5 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

The headline: `kind` density **collapsed from 0.320 to 0.044** — the sort-by-kind
made it a contiguous run `[0,0,...,1,1,...,2,2,...]` which gzip compresses to
almost nothing. This is the audit signal the sort landed: kind went from a
per-particle dispatch field (3 interleaved values) to a structural run boundary
(3 contiguous runs).

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
     pos.x |       4096 |       3854 |     0.941 |      7.53
     pos.y |       4096 |       3746 |     0.915 |      7.32
     pos.z |       4096 |        714 |     0.174 |      1.39
     vel.x |       4096 |       3815 |     0.931 |      7.45
     vel.y |       4096 |       3842 |     0.938 |      7.50
     vel.z |       4096 |        662 |     0.162 |      1.29
       age |       4096 |       3605 |     0.880 |      7.04
      kind |       1024 |         45 |     0.044 |      0.35   ← sorted! (was 0.320)
  ---------+------------+------------+-----------+----------
      MEAN |      29696 |      20283 |     0.683 |      5.46
```

**MEAN density = 0.683** — down from stage 4's **0.702**. The slight drop is
the sort transformation reflected in the audit: `kind` contributes ~0 instead
of ~0.32 (it's now a structural run boundary, not a per-particle field). The
real-signal fields (pos.x/y, vel.x/y, age) are at the same densities as stages
3–4. The MEAN drop is benign and predicted — kind left per-particle dispatch
and became a layout boundary. The audit is context, not a gate.

---

## 6. PMC cycle-saturation — the sort adds branch cost

```sh
scripts/pmc_collect.sh 5 1000000 100 1   # one (stage, N, trial) per launch
```

```
stage |     N |   cycles | %useful | %proc | %deliv | %disc
------+-------+----------+---------+-------+--------+------
  4   |    1M |  12.71M  |   44.7% | 47.8% |   7.1% |   0.5%
  5   |    4K |   1.26M  |   47.8% | 42.7% |   7.5% |   2.0%
  5   |   65K |   5.50M  |   44.5% | 46.1% |   6.7% |   2.7%
  5   |  262K |  13.82M  |   29.0% | 65.1% |   4.2% |   1.7%
  5   |    1M |  22.22M  |   36.5% | 54.7% |   5.4% |   3.4%
  5   |    4M |  45.24M  |   35.0% | 55.8% |   5.7% |   3.5%
  5   |   64M | 170.79M  |   29.7% | 63.0% |   2.6% |   4.6%
```

**The surprising finding: % Discarded ROSE from stage 4's ~0.5% to 2–4.7%.**
The Dutch flag sort's 3-way branch (`if k==0 ... else if k==1 ... else ...`)
is data-dependent: before sorting, kinds are randomly interleaved (3 kinds,
~33% each), so the branch predictor mispredicts ~67% of the time. **The sort's
branch is worse than the (already-free) switch it replaced.** Stage 5 traded a
compiler-optimized-away per-particle switch for a real, unpredictable sort
branch — making % Discarded go UP, not down.

- **% Useful dropped to 30–48%** (from stage 4's 37–57%): more overhead cycles
  (the sort pass) that aren't retiring useful instructions.
- **% Processing rose to 43–65%** (from stage 4's 31–59%): the sort's O(n)
  swap traffic (8 field swaps per swap, up to n swaps) stalls the backend on
  memory.
- **% Discarded rose to 2–4.7%** (from stage 4's ~0.5%): the Dutch flag's 3-way
  branch on kind, unpredictable before sorting. This is the sort's own branch
  cost — the ironic result of de-virtualizing a dispatch that was already free.

**The PMC insight:** de-virtualization via sorting is not free. The sort's own
branch can exceed the dispatch it removes — especially when the dispatch was
already compiler-optimized away (empty cases). P6's payoff requires per-kind
WORK to specialize; without it, the sort is pure overhead with its own
misprediction cost. The layout transformation (per-kind runs) is still correct
for stage 6's SIMD (kind-specialized vectorized loops), but the *time* win is
deferred, not delivered here.

---

## 7. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

The golden check passes because two invariants hold:

1. **The RNG sequence is preserved.** Kill/respawn happens BEFORE the sort (in
   storage order), so the RNG draws are in the same sequence as stage 4. The
   sort reorders particles after the draws, but doesn't affect the RNG.
2. **The sorted golden check tolerates reordering.** It compares the multiset
   of (pos, vel), not the storage order. The multiset is preserved because the
   same RNG values are drawn (same sequence), just assigned to different slots;
   the physics is slot-independent, so the multiset of trajectories is identical.

---

## 8. What the next stage must beat (acceptance gate for stage 6)

Stage 6 (SIMD vectorization) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4`.
4. **Stage 6 < stage 5 ns/particle at N≥65K** (and **stage 6 < stage 2 at
   N≥1M** — the time win stage 3 deferred is finally claimed). This is the
   plan's key gate: stage 6 claims the SIMD reward the SoA layout (stage 3)
   unlocked, finally beating stage 2 on time.
5. The width-sweep (`@Vector(4)`, `@Vector(8)`, `@Vector(16)`) shows a visible
   minimum at the native NEON lane count (likely 4 or 8 on the M4's 128-bit NEON).
6. Audit runs; clear git diff from `05_sortbykind/sim.zig`.

Stage 5's residual cost is the O(n) compaction + sort overhead and the sort's
own branch cost. Stage 6 claims the SIMD reward — `@Vector` over the contiguous
per-component SoA streams — which is where the layout transformations of stages
2–5 finally pay off in time. The per-kind sorted layout from stage 5 also
enables kind-specialized vectorized loops (each kind's run is a tight vectorized
loop with no per-element dispatch), which is the P6+P7 synergy.
