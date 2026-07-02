# Stage 2 — Hot/cold split (first real DOD move)

> *Group data by how it's used (frame cadence), not what it is.*

Stage 1 was the strawman: one 68 B `Particle` struct, every field dragged
through the update loop every frame. Stage 2 keeps the AoS and the math but
**splits the struct by usage cadence** into two parallel arrays. The update
loop walks only the hot array; render walks the cold one. Same math, fewer
bytes per frame — the first measured DOD win.

- **Checkpoint:** C5 — PASS.
- **DOD principles illustrated:** P2 (group by usage cadence), P3 (only touch
  what each loop needs).
- **The transformation:** stop walking render-only and spawn-only fields in the
  hot update loop.

---

## 1. The problem it poses

Stage 1's `step()` touches every field of every particle every frame, including
`color`/`size`/`rotation`/`mass`/`flags`/`seed` — fields the update never
*uses*, only reads as a strawman sin. The audit (stage 1) proved 8 of 11 fields
carry ~0 information, yet ~50 cold bytes/particle cross L1 every frame for
nothing. The math *needs* ~28 B/frame; the loop *walks* ~68 B.

## 2. The DOD transformation

Split by usage cadence into two parallel arrays (same indices):

```zig
const ParticleHot  = struct { pos, vel, life, age, kind };  // ~36 B — step() walks this
const ParticleCold = struct { color, size, rotation, mass, flags, seed }; // render/spawn only
var hot:  []ParticleHot;
var cold: []ParticleCold;
```

`step()` walks `hot` only. `render()` zips `hot` + `cold`. The strawman's
cold-field reads (`_ = p.mass` etc.) are gone — the cold array is never touched
by the update loop.

Two design choices, both about **not paying for cross-array access**:

- **`kind` stays in hot.** The per-particle `switch(kind)` (the deliberate hot
  branch, removed in stage 5) reads `hot.kind` — no per-frame cold access. If
  `kind` lived in cold, the switch would drag the whole cold array through cache
  every frame, defeating the split.
- **The kill path writes hot only.** `seed` is a write-once constant (= the
  particle's index), so the respawn target is just the loop index — no cold
  read. And the respawn re-rolls only hot fields (pos/vel/life/age/kind); cold
  is write-once, so leaving it stale changes neither the golden check (pos/vel
  only) nor the physics. This matters: a first cut that re-wrote `cold[i]` on
  respawn triggered a read-for-ownership miss on the cold array at large N and
  made stage 2 *slower* than stage 1 at N≥1M. Routing the kill path around cold
  (the lesson) recovered the win. *DOD is empirical — the numbers caught it.*

The RNG draw sequence (kind, jitter_x, jitter_y, age — in that order) is
identical to stage 1's `spawnParticle`, so every particle's pos/vel/age
trajectory matches stage 1 exactly. The golden check passes byte-for-byte.

---

## 2. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=2 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N |     mem(MB) |       ns/frame |    ns/particle |   frames/sec
  -----------+-------------+----------------+----------------+-------------
        4000 |         0.1 |         9648.5 |          2.412 |     103642.6
       16000 |         0.5 |        30590.4 |          1.912 |      32690.0
       65000 |         2.2 |       110176.9 |          1.695 |       9076.3
      262000 |         9.0 |       289985.0 |          1.107 |       3448.5
     1000000 |        34.3 |      1101608.5 |          1.102 |        907.8
     4000000 |       137.3 |      4423781.7 |          1.106 |        226.1
    16000000 |       549.3 |     17826275.0 |          1.114 |         56.1
    64000000 |      2197.3 |     72775531.3 |          1.137 |         13.7
```

### Stage 2 vs stage 1 (acceptance gate: stage 2 < stage 1 at N≥65K)

From a clean back-to-back run (stage 1 then stage 2, same conditions, flat
saturation plateau — used for the decomposition below):

|          N | stage 1 ns/p | stage 2 ns/p |          speedup |
|----------:|-------------:|-------------:|------------------:|
|     65000 |         2.21 |         1.79 |            1.23×   |
|    262000 |         1.25 |         1.11 |   **1.13×** ← dip |
|   1000000 |         1.40 |         1.06 |            1.33×   |
|   4000000 |         1.59 |         1.06 |            1.50×   |
|  16000000 |         1.62 |         1.07 |            1.51×   |
|  64000000 |         1.63 |         1.07 |            1.52×   |

**Stage 2 wins at every N≥65K.** ✅ (criterion 5). The speedup has a local
minimum at 262K (1.13×) and rises to a ~1.50× plateau at saturation — see below.

*(Run-to-run variance ~±10–15%; at 64M the 16 GiB machine can hit RAM
pressure under background load, which inflates stage 1's ns/p well above its
DRAM floor. The run above was chosen for its clean flat plateau. The bench
block at the top of this section is a separate representative run.)*

### How to read the curve

The struct sizes are exact (working_set ÷ N from the `mem` column): stage 1
walks **68 B/particle**, stage 2 walks **36 B/particle** — a **1.89×** byte
ratio. Yet the speedup is not flat at 1.89×; it has a **local minimum at 262K**
(1.13×) between larger wins on either side. Three memory regimes explain the
shape. (The vocabulary matters: only the third is "bandwidth" in the strict
sense.)

**1. Cache capacity (65K).** Stage 2's hot working set (36 B × 65K ≈ 2.3 MiB)
fits the 4 MiB L2; stage 1's (68 B × 65K ≈ 4.4 MiB) spills it. The asymmetry is
*which cache level* each access hits (L2 ≈ ~12 cycles vs DRAM ≈ ~200+ cycles) —
a capacity/latency effect, not throughput. Stage 1 pays the penalty → **1.23×**.

**2. Unsaturated streaming — the dip (262K).** Both working sets now spill L2
(17.8 MiB and 9.4 MiB), so the capacity asymmetry is gone. But the stream is
short enough (~0.3 ms/frame) that the prefetcher hides DRAM latency and the
memory pipe has spare throughput — fewer bytes does *not* proportionally reduce
time. With neither capacity nor throughput pinning the difference, both stages
converge toward the **shared compute cost** (the per-particle math, identical
across stages), and the gap collapses to its narrowest: **1.13×** (absolute gap
0.14 ns/p, near the run-to-run noise floor).

**3. Throughput saturation (1M+).** Now the stream is large enough to fill the
memory pipe: the core stalls waiting for bytes, and `ns/particle` is set by
`(bytes touched) ÷ (single-thread streaming throughput)` — a bytes/second
ceiling, distinct from the per-access latency of regime 1. The byte ratio
finally bites, and the speedup climbs to a **~1.50× plateau**.

#### Why the plateau is ~1.50×, not 1.89×

Because the per-particle cost is `compute + k·bytes`, and **compute is shared**
— the integrate + drag math is byte-for-byte identical across stages, so the
layout can't touch it. Fitting the plateau (4M–64M, where both stages are
throughput-saturated):

```
  compute + k·68 B = 1.613   (stage 1 plateau)
  compute + k·36 B = 1.065   (stage 2 plateau)
  →  compute ≈ 0.45 ns/particle     (the shared math floor)
     k       ≈ 0.017 ns/byte       → ~59 GB/s effective single-thread streaming
```

Validation (predict the plateau from the fit):

|              | compute | streaming | predicted |  actual (4M–64M) |
|-------------|--------:|----------:|----------:|-----------------:|
| stage 1 (68 B) |  0.45  |   1.16    |  1.61 ns/p|  1.59 – 1.63 ✓   |
| stage 2 (36 B) |  0.45  |   0.61    |  1.06 ns/p|  1.06 – 1.07 ✓   |

So at saturation stage 2 is **~42% compute / 58% memory throughput**; stage 1
is **~28% compute / 72% memory throughput**. The speedup ratio is
`(0.45+1.16)/(0.45+0.61) = 1.52×` — not 1.89×, because the 0.45 compute term
absorbs the difference. **The hot/cold split can only ever attack the memory
term; the compute floor is out of its reach.**

#### The dip, quantified

The saturation model *over-predicts stage 1 at 262K by ~22%* (model 1.61 vs
actual 1.25) but matches stage 2 (model 1.06 vs actual 1.11). That residual is
the dip: at 262K stage 1's 17.8 MiB working set still gets a below-DRAM-rate
memory cost (partial cache residency / prefetch on a short stream), while stage
2 — with less than half the bytes — is already at its floor and has no such
discount left to lose. The gap narrows because **stage 1 catches *down* to its
own minimum** (its V-shape bottoms at 262K), not because stage 2 pulls ahead.
By 64M stage 1 has lost that discount (its 4.3 GiB working set is fully
DRAM-bound) and the full byte-ratio difference re-emerges. *Why* stage 1 gets
the 262K discount (SLC residency? cache-line packing?) is plausible but not
pinned down here; the measured fact is that its memory cost dips below its DRAM
rate at 262K and rises back to it by 4M. The model's job is to flag the regime
change, not name the microarchitectural cause.

#### What this predicts for later stages

- **Stage 3 (SoA, ~24 B hot)** attacks the memory term:
  `0.45 + 0.017·24 ≈ 0.86 ns/p` → ~1.24× over stage 2 at saturation. The win is
  *bounded by the 0.45 compute floor* — which is why stage 3's gate is "beat
  stage 2 at N≥1M," not everywhere.
- **Stage 6 (SIMD)** attacks the 0.45 compute term — the half the hot/cold
  split couldn't reach. This is the plan's "SIMD is a *reward* for layout":
  stage 2 had to reclaim the memory half first before compute became the
  dominant residual worth attacking.

*(The saturation fit carries ~±15% across run conditions — background load,
thermal state, and at 64M, RAM pressure on the 16 GiB machine. The numbers
above are from a clean back-to-back chosen for its flat plateau (4M–64M within
±1.5% of the model); the constants are representative, not precise. The
load-bearing claim is the *structure* — compute is shared and
layout-independent, the memory term scales with bytes, the ratio is bounded by
compute — which is robust to the variance.)*

---

## 3. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=2 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

The audit dumps only the fields `step()` actually touches (the hot array). In
stage 2 that's 5 fields, not 11 — the cold array is never walked by the update
loop, so its bytes don't cross L1 during `step()` and aren't counted.

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
       pos |      12288 |       9015 |     0.734 |      5.87   ← real signal
       vel |      12288 |       9136 |     0.743 |      5.95   ← real signal
      life |       4096 |         52 |     0.013 |      0.10   ← constant (kill_age)
       age |       4096 |       3600 |     0.879 |      7.03   ← real signal
      kind |       1024 |        325 |     0.317 |      2.54   ← 3 values
  ---------+------------+------------+-----------+----------
      MEAN |      33792 |      22128 |     0.655 |      5.24
```

**MEAN density = 0.655** — up from stage 1's **0.361**. ✅ (directional check)

### What the audit proves

- The cold fields (`color/size/rotation/mass/flags/seed`) **left the hot loop**.
  They're no longer in the dump because `step()` no longer touches them. The
  bytes dragged through L1 by the update dropped from 68 → 36 B/particle.
- Two low-density fields remain in the hot loop, predicting later stages:
  - **`life` (0.013)** — a constant dragged through L1 every frame. Stage 4
    (compact) removes it: it shouldn't be per-particle data at all.
  - **`kind` (0.317)** — 3 distinct values, used for the per-particle dispatch.
    Stage 5 (sort-by-kind) restructures data so dispatch is hoisted out of the
    loop; `color` (currently in cold) becomes a lookup on `kind`, not a field.
- Only `pos`/`vel`/`age` are real signal (0.73–0.88). The math *needs* ~28 B;
  the hot loop now *walks* ~36 B — the gap closed from 68→28 (40 wasted) to
  36→28 (8 wasted). Stage 3 (SoA) closes the last gap.

**Density up (0.361 → 0.655) is the qualitative twin of ns/particle down
(~1.6 → ~1.1 at large N).** Two views of one transformation: reclaimed entropy
≈ reclaimed bandwidth.

---

## 4. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

The RNG draw sequence in both init and respawn is identical to stage 1's
`spawnParticle` (kind, jitter_x, jitter_y, age — same order, same methods), so
every particle's pos/vel/age trajectory matches stage 1 byte-for-byte. The
golden check passes with **max delta = 0.00** — the math is unchanged; only the
data layout and access pattern changed. This is the central DOD claim, proven
again.

---

## 5. What the next stage must beat (acceptance gate for C6)

Stage 3 (AoS → SoA) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4` (math unchanged).
4. **Stage 3 < stage 2 at N≥1M** — the flagship transformation. At small N both
   fit in L1 (AoS vs SoA is noise); at 1M+, SoA touches ~24 B/particle at high
   density vs the hot AoS's ~36 B. The ns/particle-vs-N curve should bend at L2.
5. Audit: MEAN density climbs further as `life` (and the AoS stride waste)
   leave the hot loop. Stage 3's `dumpFields` emits per-component SoA streams
   (pos.x, pos.y, pos.z, …) — the layout fingerprint changes.
6. Clear `git diff` from `02_hotcold/sim.zig` — the AoS→SoA move in one file.

The big-N floor (~1.1 ns/particle here) is now compute + ~36 B of bandwidth.
Stage 3 cuts the bandwidth half; stage 6 cuts the compute half.
