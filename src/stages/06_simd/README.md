# Stage 6 — SIMD vectorization (claim the layout's throughput reward)

> *Vectorize the hot loop — but SoA first. SIMD is a reward for layout.*

Stage 6 is the **payoff stage** — where the SoA layout from stage 3 finally
pays off in time. Stage 3 laid the per-component `[]f32` streams but, on Zig
0.17-dev (which doesn't autovectorize), the scalar loops were slower than
stage 2. Stage 6 adds explicit `@Vector(4, f32)` — 128-bit NEON — to the math
passes, claiming the throughput reward the layout unlocked. **This is the
first stage to beat stage 2 on time**, the win stage 3 deferred.

- **Checkpoint:** C7 (stage 6 of 6 within C7) — PASS.
- **DOD principles illustrated:** P4 (AoS → SoA), P7 (SIMD is a reward for layout).
- **The transformation:** scalar per-component math passes → `@Vector(4, f32)`
  vectorized math passes. Each NEON `fma` retires 4× the math of a scalar `fma`.

---

## 1. The problem it poses

Stage 3 laid out the SoA streams correctly for SIMD — `pos_x`, `vel_x` are
contiguous `[]f32` arrays, perfect for `@Vector` loads. But on Zig 0.17-dev,
the scalar loops don't autovectorize (confirmed in assembly — scalar `s0`/`s1`
registers, no `q`-register lanes). So stage 3 was compute-bound at ~17 GB/s
(32% of the ~54 GB/s ceiling) — the FPU was the bottleneck, doing one `fma`
per cycle when it could do four. The layout was correct; the throughput reward
was unclaimed.

**P7's thesis:** SIMD is a *reward* for layout, not a substitute. You can't
vectorize an AoS loop efficiently (you'd need 3 separate pos streams); you need
the SoA layout first. Stage 3 paid the layout's overhead (on this toolchain,
without SIMD, it lost to stage 2). Stage 6 collects the reward that makes the
layout pay.

---

## 2. The DOD transformation

### Builds on stage 3 (not stage 5)

Stages 4 (branchless compaction) and 5 (sort-by-kind) were honest detours —
they demonstrated techniques but added O(n) overhead that can't be vectorized
away. Stage 6 goes back to stage 3's clean SoA layout + branchy kill (respawn
in place) and vectorizes the math passes. The compaction and sort techniques
will be recomposed in stage 9's synthesis (where stage 8's double-buffer
allocator makes compaction cheap enough to be worth composing).

### Vectorized math passes

```zig
const W: usize = 4;          // native NEON width: 128-bit = 4×f32
const V = @Vector(W, f32);

fn mathPassVec(pos: []f32, vel: []f32, n: usize, dt: f32, g: f32) void {
    const vdt: V = @splat(dt);
    const vdrag: V = @splat(config.drag);
    const vg: V = @splat(g);

    const main = n - (n % W);
    var i: usize = 0;
    while (i < main) : (i += W) {
        const pos_w: *[W]f32 = @ptrCast(&pos[i]);
        const vel_w: *[W]f32 = @ptrCast(&vel[i]);
        const o: V = vel_w.*;     // load 4 vel values (1 vector load)
        const p: V = pos_w.*;     // load 4 pos values
        pos_w.* = p + o * vdt;            // integrate: pos += vel * dt (4 at once)
        vel_w.* = o + (vg + vdrag * o) * vdt; // forces: vel += (g+drag*vel)*dt
    }
    // scalar tail (n % W)
    while (i < n) : (i += 1) { ... }
}
```

The integrate + forces are fused per component so `vel` is loaded once (as a
vector) and used for both — same single-load profile as stage 3's scalar version.
Each NEON `fma` retires 4× the math of a scalar `fma`. The tail (n % 4) falls
back to scalar.

### Width sweep — the minimum is at W=4 (native NEON)

|   width | ns/particle @1M | NEON ops/step | observation                                                                 |
|--------:|----------------:|:--------------|:----------------------------------------------------------------------------|
| **W=4** |       **0.846** | 1             | **minimum** — native 128-bit NEON lane count                                |
|     W=8 |           0.898 | 2             | no benefit — backend can't retire >128 bits/cycle; more register pressure   |
|    W=16 |           0.871 | 4             | slightly better than W=8 (amortizes loop overhead) but still worse than W=4 |

The minimum at W=4 is the roofline prediction: the M4's NEON backend retires
128 bits/cycle. Wider vectors (`@Vector(8)` = 256 bits, `@Vector(16)` = 512 bits)
must be split into multiple 128-bit ops, which doesn't increase throughput — it
just adds register pressure and loop overhead. **W=4 is the native lane count,
and the width sweep confirms it.**

---

## 3. The honest outcome — stage 6 finally beats stage 2

### Stage 6 vs stage 2 (the champion) vs stage 3 (the layout)

|          N | stage 2 | stage 3 | **stage 6** | S6/S2 | S6/S3 | GB/s eff (S6) |
|-----------:|--------:|--------:|------------:|------:|------:|--------------:|
|      65000 |   1.695 |   1.634 |       0.952 | 0.56× | 0.58× |     30.5      |
|     262000 |   1.107 |   1.633 |       0.807 | 0.73× | 0.49× |     35.9      |
|    1000000 |   1.102 |   1.670 |       0.846 | 0.77× | 0.51× |     34.3      |
|    4000000 |   1.106 |   1.720 |       0.993 | 0.90× | 0.58× |     29.2      |
|   16000000 |   1.114 |   1.724 |       1.058 | 0.95× | 0.61× |     27.4      |
|   64000000 |   1.137 |   1.727 |       1.077 | 0.95× | 0.62× |     26.9      |

**Stage 6 beats stage 2 at every N≥65K** — the time win stage 3 deferred is
finally claimed (criterion 5 ✅). At 1M: 0.846 vs 1.102 (1.30× faster). At 65K:
0.952 vs 1.695 (1.78× faster). At 64M: 1.077 vs 1.137 (1.06× — the bandwidth
ceiling narrows the gap).

### The roofline, visible in the curve

- **At cache-resident N (65K–262K):** `GB/s eff` jumps to ~31–36 (from stage 3's
  ~18). The SIMD got the compute out of the way — the loop is now closer to
  bandwidth-bound. Stage 3 was compute-bound at 17 GB/s (32% of ceiling); stage 6
  at 262K hits 36 GB/s (67% of ceiling). The FPU is no longer the bottleneck.
- **At large N (4M–64M):** `GB/s eff` drops to ~27–29. The bandwidth ceiling
  bites — the compute is now fast enough that memory is the limit. This is the
  **roofline model in miniature**: stage 3 was compute-bound (below the roofline);
  stage 6 lifted the compute ceiling and hit the bandwidth roof. The speedup
  narrows from 1.78× (65K) to 1.06× (64M) — exactly the diminishing-returns
  pattern the plan predicted for bandwidth-bound regimes.

---

## 4. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=6 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N | bytes/p |   mem(MB) | ns/particle(min) |  ns/frame(min) |  frames/sec | GB/s eff | runtime(ms)
        4000 |      29 |       0.1 |          2.301 |         9202.5 |    108666.1 |    12.61 |         5.8
       16000 |      29 |       0.4 |          1.971 |        31530.6 |     31715.2 |    14.72 |        19.3
       65000 |      29 |       1.8 |          0.952 |        61854.4 |     16167.0 |    30.47 |        46.5
      262000 |      29 |       7.2 |          0.807 |       211503.1 |      4728.1 |    35.92 |       129.1
     1000000 |      29 |      27.7 |          0.846 |       846285.8 |      1181.6 |    34.27 |       511.6
     4000000 |      29 |     110.6 |          0.993 |      3970568.3 |       251.9 |    29.21 |      2396.3
    16000000 |      29 |     442.5 |          1.058 |     16923391.7 |        59.1 |    27.42 |     10216.8
    64000000 |      29 |    1770.0 |          1.077 |     68933229.4 |        14.5 |    26.92 |     41617.1
```

---

## 5. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=6 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

Same 8 streams as stage 3 (same layout — `@Vector` doesn't change the data, only
how the FPU processes it). MEAN density = **0.722** (identical to stage 3).

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
     pos.x |       4096 |       3866 |     0.944 |      7.55
     pos.y |       4096 |       3760 |     0.918 |      7.34
     pos.z |       4096 |       1138 |     0.278 |      2.22
     vel.x |       4096 |       3825 |     0.934 |      7.47
     vel.y |       4096 |       3841 |     0.938 |      7.50
     vel.z |       4096 |       1077 |     0.263 |      2.10
       age |       4096 |       3600 |     0.879 |      7.03
      kind |       1024 |        325 |     0.317 |      2.54
  ---------+------------+------------+-----------+----------
      MEAN |      29696 |      21432 |     0.722 |      5.77
```

The audit fingerprint matches stage 3 because stage 6 builds on stage 3's
layout — the transformation is *how* the FPU processes the data (vectorized),
not *what* the data is. The density story is the same: `pos.x/y`, `vel.x/y`,
`age` are real signal (0.88–0.94); `pos.z`/`vel.z` are low (near-constant z);
`kind` is the 3-value dispatch (stage 5's target, recomposed in stage 9).

---

## 6. PMC cycle-saturation — the SIMD reward, measured

```sh
scripts/pmc_collect.sh 6 1000000 100 1
```

```
stage |     N |   cycles | %useful | %proc | %deliv | %disc
------+-------+----------+---------+-------+--------+------
  3   |    1M |   5.71M  |   69.5% | 19.3% |   4.8% |  6.4%
  6   |    4K |    219K  |   57.4% |  8.2% |  21.1% | 13.2%
  6   |   65K |    885K  |   56.6% | 13.2% |  17.3% | 12.9%
  6   |  262K |   1.46M  |   56.5% | 15.1% |  15.9% | 12.5%
  6   |    1M |   3.12M  |   53.4% | 21.7% |  13.6% | 11.4%
  6   |    4M |   8.15M  |   45.2% | 35.9% |   9.8% |  9.0%
  6   |   64M |  49.26M  |   41.3% | 46.0% |   6.3% |  6.5%
```

**The SIMD reward, measured on the cycle side:**

- **Total cycles dropped from 5.71M to 3.12M at 1M** — the SIMD retires 4× the
  math per cycle, so the same work needs roughly half the cycles. This is the
  throughput reward P7 promised, measured directly.
- **% Useful dropped from 69.5% to 53.4%** — surprising, but the *absolute*
  useful cycles are fewer (1.67M vs 3.97M). The % dropped because the
  *bottleneck shifted*: the SIMD got the compute out of the way, exposing the
  next bottlenecks.
  - **% Delivery rose to 13.6% (from 4.8%)** — the vectorized loop has more
    frontend pressure (vector loads/stores, wider instructions, tail handling).
    The frontend must feed wider instructions; this is the delivery cost of SIMD.
  - **% Discarded rose to 11.4% (from 6.4%)** — the per-particle `switch(kind)`
    (still present, same as stage 3) is now a bigger fraction of the tighter
    loop. The *absolute* discarded cycles are almost identical (356K vs 365K) —
    the switch costs the same, but the total shrank, so its percentage grew.
    Same pattern as stage 2 (15.8% Discarded — its switch was a bigger fraction
    of its tighter loop).
- **At large N (64M): % Processing rises to 46%** — the bandwidth ceiling bites.
  The SIMD got the compute out of the way, so now the backend stalls on memory.
  Stage 3 was compute-bound (50% Useful); stage 6 at 64M is bandwidth-bound
  (41% Useful, 46% Processing). This is the **roofline model in PMC form**:
  stage 6 lifted the compute ceiling and hit the bandwidth roof.

**The cross-stage PMC pattern (stages 3 → 6):**

| metric | stage 3 (scalar SoA) | stage 6 (SIMD SoA) | what changed |
|---|---|---|---|
| cycles @1M | 5.71M | 3.12M | 4× math/cycle → ~half the cycles |
| % Useful | 69.5% | 53.4% | dropped — but absolute useful is lower; bottleneck shifted |
| % Delivery | 4.8% | 13.6% | vectorized loop has more frontend pressure |
| % Discarded | 6.4% | 11.4% | switch is a bigger fraction of the tighter loop |
| % Processing | 19.3% | 21.7% | similar at 1M; rises to 46% at 64M (bandwidth roof) |

The PMC confirms P7: the SIMD reward is real (fewer cycles), but it *exposes*
the next bottlenecks (delivery = frontend pressure of wider instructions;
discarded = the switch is now relatively more expensive; processing = bandwidth
ceiling at large N). Stage 7 (alignment/padding) will reduce the delivery
bottleneck (aligned loads, no tail branch); stage 5's sort-by-kind (recomposed
in stage 9) would remove the switch. The layout journey continues.

---

## 7. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

The vectorized math is bit-identical to the scalar math: each particle's FP ops
are the same (same order: `pos` uses old `vel`, then `vel` is updated). The
vectorized pass processes particles in the same index order, just W=4 at a
time — no reordering, no precision difference (NEON `fma` is IEEE 754 compliant).
The RNG sequence is identical (stage 3's branchy kill, same draw order). Golden
passes with max delta = 0.00.

---

## 8. What the next stage must beat (acceptance gate for stage 7)

Stage 7 (alignment, padding, sizing to the cache line) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4`.
4. **Stage 7 < stage 6 ns/particle** — the alignment/padding should reduce the
   % Delivery bottleneck (aligned vector loads, no tail branch, padded lengths).
5. The alignment sweep shows a visible minimum at "one hot tile = one line."
6. Audit runs; clear git diff from `06_simd/sim.zig`.

Stage 6's residual cost: the % Delivery bottleneck (13.6% at 1M — the vectorized
loop's frontend pressure from unaligned loads and the tail branch) and the
% Discarded from the switch (11.4% — a bigger fraction of the tighter loop).
Stage 7 attacks the delivery bottleneck (align streams to 128 B, pad lengths to
a multiple of W so there's no tail branch). The switch is stage 5's lesson,
recomposed in stage 9.
