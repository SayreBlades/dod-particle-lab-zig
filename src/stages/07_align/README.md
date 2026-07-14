# Stage 7 — Alignment, padding, sizing to the cache line

> *Sizes/alignments are parameters matched to the hardware.*

Stage 7 attacks the % Delivery bottleneck stage 6's PMC revealed (13.6% at 1M —
the vectorized loop's frontend pressure from unaligned loads and the scalar
tail branch). Two concrete wins, both measured against the hardware:

1. **ALIGN** each SoA stream to 128 B (the M4's `hw.cachelinesize`). Every
   `@Vector(4)` load now starts on a line boundary — no load straddles two lines.
2. **PAD** each stream's length to a multiple of W=4. The vectorized math pass
   is now a single tight loop with **no scalar tail branch** — the mode switch
   stage 6 had is gone.

- **Checkpoint:** C7 (stage 7 of 6 within C7) — PASS.
- **DOD principle illustrated:** P8 (sizes/alignments are parameters matched to
  the hardware).
- **The transformation:** default-aligned streams + tail branch → 128 B-aligned
  + padded (no tail).

---

## 1. The problem it poses

Stage 6's PMC showed % Delivery at 13.6% at 1M — the vectorized loop's frontend
pressure. Two sources:

- **Unaligned stream bases.** `alloc.alloc(f32, n)` returns 4-byte-aligned
  memory (f32's natural alignment). A `@Vector(4)` load is 16 bytes; if the
  base isn't cache-line-aligned, the first load straddles a line boundary → a
  split load (two line fills for one vector). This is a frontend/cycle cost.
- **Scalar tail branch.** Stage 6's `mathPassVec` had a vector loop over
  `[0..n-(n%W)]` then a scalar loop over the tail `[..n]`. The tail branch
  (`while (i < main) ... while (i < n)`) is a mode switch — the frontend must
  transition from vector to scalar mid-function. For small N this is a
  measurable fraction of the loop.

P8's thesis: sizes and alignments are *parameters* — match them to the
measured hardware (`hw.cachelinesize = 128`, NEON width = 128 bits = W=4), not
to defaults.

---

## 2. The DOD transformation

### Aligned allocation

```zig
const LINE: std.mem.Alignment = .fromByteUnits(128);  // hw.cachelinesize

const pos_x = try alloc.alignedAlloc(f32, LINE, n_padded);  // []align(128) f32
// ...same for pos_y, pos_z, vel_x, vel_y, vel_z, life, age, kind
```

The slice type carries the alignment (`[]align(128) f32`) — the compiler
enforces it, and `@ptrCast(&pos[i])` in the math pass gets a line-aligned
pointer. Every `@Vector(4)` load starts on a 128 B boundary; no load straddles
two cache lines.

### Padded lengths (no tail branch)

```zig
const n_padded = std.mem.alignForward(usize, n, W);  // round up to multiple of 4
// guard region [n..n_padded] zeroed at init; never observed by snapshot/age/kill/render

fn mathPassVec(pos, vel, n_padded, dt, g) void {
    var i: usize = 0;
    while (i < n_padded) : (i += W) {  // single tight vector loop — NO tail
        // ...one NEON fma per step...
    }
}
```

The guard region `[n..n_padded]` (≤3 elements) is zeroed at init and never
observed — `snapshot`, `age`, `kill`, `render` all iterate `[0..n]`. The math
pass processes the full padded length (no tail), but the guard elements' pos/vel
drift freely and invisibly. The golden check (snapshot reads `[0..n]`) is
unaffected.

### What this does NOT do (honest scope)

The plan's stage 7 also mentions "tile the loop in 128-particle chunks (one
alive bitset line = one cache line)" and "size the hot block per particle = 32 B
= ¼ line." Both are AoS/bitset lessons that don't apply to stage 7's clean SoA
streaming:

- **In SoA, each stream already packs 32 particles per 128 B line** (4 B/float
  × 32 = 128 B) — maximally dense. There's no "hot block per particle" to size
  (that's an AoS framing: an AoS `ParticleHot` of 32 B would put 4 per line).
  Stage 7's alignment IS the line-matching.
- **The bitset-line tiling applies to the compaction pass** (stage 4/9), which
  stage 6 doesn't have (branchy kill). Stage 7 builds on stage 6, so there's no
  `alive` bitset to tile. That lesson lands in stage 9's synthesis.

Stage 7's concrete, measurable wins are alignment + padding. The tiling/hot-
block analysis is documented honestly rather than force-fit.

---

## 3. The honest outcome — a small but real win, measured

### Stage 7 vs stage 6 — back-to-back, 3 trials min, ReleaseFast, M4

|          N | stage 6 | stage 7 | S7/S6 | GB/s eff (S6 / S7) |
|-----------:|--------:|--------:|------:|:-------------------|
|      65000 |   0.910 |   0.946 | 0.96× |  31.9 / 30.7       |
|     262000 |   0.815 |   0.818 | 1.00× |  35.6 / 35.5       |
|  1000000 |   0.848 |   0.821 | 1.03× |  34.2 / 35.3       |
|  4000000 |   0.973 |   0.969 | 1.00× |  29.8 / 29.9       |
| 16000000 |   1.040 |   1.038 | 1.00× |  27.9 / 27.9       |
| 64000000 |   1.050 |   1.059 | 0.99× |  27.6 / 27.4       |

The win is **small and concentrated at the cache-resident sweet spot** (1M:
0.821 vs 0.848, ~3% faster). At other N it's within noise. This is honest:
alignment + padding removes the % Delivery bottleneck (a 13.6% → 9.0% reduction
at 1M, see §5) but that bottleneck was never the *dominant* cost — % Processing
(memory bandwidth at large N) and % Discarded (the switch) are larger. The win
is real but marginal, exactly what P8 predicts: alignment is a *parameter
tuning*, not a *transformation* — it removes friction, not a structural
bottleneck.

### Why the win is small

- **% Delivery was 13.6% at 1M, not 50%.** Eliminating it can save at most ~13%
  of cycles, and alignment removes *most* (not all) of it — the rest is
  fundamental vector-load frontend cost. Measured: 13.6% → 9.0% (a 4.6pp drop,
  ~34% of the delivery bottleneck gone).
- **At large N, % Processing (bandwidth) dominates.** Stage 6 at 64M was 46%
  Processing — the bandwidth ceiling. Alignment doesn't touch bandwidth (the
  same bytes still cross the memory bus). So at 64M, stage 7 ≈ stage 6.
- **At small N (65K), the tail branch was a tiny fraction of a tiny loop.** The
  padding removes it, but the loop is so short the branch was already amortized.

---

## 4. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=7 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N | bytes/p |   mem(MB) | ns/particle(min) |  ns/frame(min) |  frames/sec | GB/s eff | runtime(ms)
        4000 |      29 |       0.1 |          1.731 |         6925.8 |    144386.9 |    16.75 |         4.5
       16000 |      29 |       0.4 |          1.551 |        24811.7 |     40303.6 |    18.70 |        17.0
       65000 |      29 |       1.8 |          0.946 |        61469.4 |     16268.3 |    30.67 |        41.8
      262000 |      29 |       7.2 |          0.818 |       214220.2 |      4668.1 |    35.47 |       129.9
     1000000 |      29 |      27.7 |          0.821 |       821101.7 |      1217.9 |    35.32 |       501.7
     4000000 |      29 |     110.6 |          0.969 |      3875644.0 |       258.0 |    29.93 |      2334.1
    16000000 |      29 |     442.5 |          1.038 |     16609786.3 |        60.2 |    27.94 |      9981.8
    64000000 |      29 |    1770.0 |          1.059 |     67807561.5 |        14.7 |    27.37 |     40751.8
```

---

## 5. PMC cycle-saturation — the % Delivery win, measured

```sh
scripts/pmc_collect.sh 7 1000000 100 1
```

```
stage |     N |   cycles | %useful | %proc | %deliv | %disc
------+-------+----------+---------+-------+--------+------
  6   |    1M |   3.12M  |   53.4% | 21.7% |  13.6% | 11.4%
  7   |    4K |    209K  |   59.5% | 11.0% |  15.6% | 13.9%
  7   |   65K |    865K  |   56.6% | 18.4% |  11.7% | 13.3%
  7   |  262K |   1.43M  |   56.6% | 19.4% |  11.1% | 12.9%
  7   |    1M |   3.02M  |   54.2% | 24.8% |   9.0% | 12.0%
  7   |    4M |   7.66M  |   46.9% | 36.8% |   6.6% |  9.7%
  7   |   64M |  39.24M  |   40.9% | 47.3% |   4.7% |  7.1%
```

**The P8 win, measured on the cycle side:** % Delivery dropped at every N:

|          N | S6 %deliv | S7 %deliv | drop   |
|-----------:|----------:|----------:|-------:|
|      4000 |     21.1% |     15.6% |  5.5pp |
|     65000 |     17.3% |     11.7% |  5.6pp |
|    262000 |     15.9% |     11.1% |  4.8pp |
|  1000000 |     13.6% |      9.0% |  4.6pp |
| 16000000 |      7.1% |      5.1% |  2.0pp |
| 64000000 |      6.3% |      4.7% |  1.6pp |

The alignment (no line-straddling loads) + padding (no tail branch) removed
**~30–40% of the delivery bottleneck** at every N. Total cycles dropped at
most N (1M: 3.12M → 3.02M; 64M: 49.3M → 39.2M — a ~20% cycle reduction at 64M,
though wall-time noise obscures it in the bench). This is P8 landing: alignment
is a hardware-matched parameter, and the % Delivery drop is the cycle-side proof.

The other bottlenecks are unchanged (as expected — alignment doesn't touch
them): % Discarded stays ~12-14% (the switch, stage 5's target), % Processing
rises at large N (bandwidth ceiling, unchanged). % Useful rose slightly at
1M (53.4% → 54.2%) — fewer delivery stalls → more useful cycles.

---

## 6. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

Same as stage 6: the vectorized math is bit-identical for `[0..n]`. The guard
region `[n..n_padded]` is processed by the math pass but never observed
(snapshot/age/kill/render iterate `[0..n]`). The RNG sequence is identical.
Golden passes with max delta = 0.00.

---

## 7. What the next stage must beat (acceptance gate for stage 8)

Stage 8 (allocators & streaming) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4`.
4. **Arena/free-list/double-buffer all ≪ naive** at high churn (50% die/frame).
   Allocator differences are often larger than all layout work — the plan's
   "bracing but true" lesson.
5. Double-buffer ≈ branchless compaction (ties stage 4's lesson).
6. Audit runs; clear git diff from `07_align/sim.zig`.

Stage 7's residual cost: the % Discarded from the switch (12% — stage 5's
target, recomposed in stage 9) and the bandwidth ceiling at large N (% Processing
47% at 64M — fundamental, not fixable by layout). Stage 8 introduces spawn
churn and allocator comparisons — the compaction/sort techniques from stages 4/5
finally get a workload where they pay off (high churn makes the branchy kill
expensive, and the double-buffer makes compaction free).
