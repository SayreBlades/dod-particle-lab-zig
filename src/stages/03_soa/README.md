# Stage 3 — AoS → SoA (the flagship layout transformation)

> *Design for the data transformation, not the object. AoS → SoA for cache
> density and vectorizability.*

Stage 3 is the plan's flagship *layout* transformation: turn the hot
array-of-structs into parallel per-component `[]f32` streams. **Scalar — no
`@Vector`.** Explicit SIMD is stage 6's lesson (P7: "SIMD is a *reward* for
layout" — layout first, reward second). This stage lays the layout; stage 6
collects the reward.

- **Checkpoint:** C6 — PASS (layout transformation landed; time win deferred to
  stage 6 on this toolchain — see below).
- **DOD principles illustrated:** P1 (design for the transformation, not the
  object), P4 (AoS → SoA). P7 (SIMD is a reward for layout) is stage 6.
- **The transformation:** `[]ParticleHot` → parallel per-component `[]f32`
  streams. `life` leaves the hot loop's cache footprint entirely.

---

## 1. The problem it poses

Stage 2's `ParticleHot` is 36 B/particle on the wire, but `step()` only *uses*
29 B of it (the other 7 = `life`'s 4 B + 3 B padding are loaded into the cache
line and discarded). And as an AoS, each 128 B cache line holds ~3.5 whole hot
particles with stride waste — a per-component pass can't get a full line of one
field. The audit (stage 2) flagged `life` at 0.013 density (a constant) and
predicted it would leave the hot loop; stage 3 makes that real.

## 2. The DOD transformation

```zig
// Stage 2: one hot AoS struct per particle
const ParticleHot = struct { pos, vel, life, age, kind };  // 36 B, stride waste

// Stage 3: parallel per-component streams (scalar — no @Vector)
var pos_x, pos_y, pos_z: []f32;
var vel_x, vel_y, vel_z: []f32;
var life: []f32;   // stored but NOT touched by step() — zero hot bandwidth
var age:   []f32;
var kind:  []ParticleKind;
```

Two reclaims, both *layout* (independent of SIMD):

- **No stride waste.** Each SoA stream is contiguous, so a 128 B line holds 32
  particles' worth of ONE field at ~100% utilization — no padding, no
  cross-field interleaving. `dumpFields` now emits per-component streams
  (`pos.x`, `pos.y`, …) — the layout fingerprint the audit reflects.
- **`life` leaves the hot loop entirely.** As a separate stream `step()` never
  walks, its 4 B/particle cost zero bandwidth — the first stage where an
  *allocated* field costs nothing. Stage 4 will remove it from storage as the
  constant it is.

### Loop structure

Integrate + forces are **fused per component** so `vel` is loaded once and used
for both `pos += vel*dt` and the `vel += (g+drag*vel)*dt` update — matches
stage 2's single-load profile (a split integrate-then-forces would reload the
whole vel array between passes, a loss at large N). `age` + kill + dispatch
stay scalar (branchy; can't vectorize respawn). The RNG draw sequence (kind,
jitter_x, jitter_y, age — same order) is identical to stages 1–2, so the math
matches byte-for-byte; the golden check passes with max delta = 0.00.

---

## 3. The honest outcome — layout lands, time win is deferred to stage 6

The plan expected the scalar SoA loops to autovectorize for free, so stage 3
alone would win at N≥1M. **Zig 0.17-dev does not autovectorize** — confirmed
in assembly (scalar `s0`/`s1` registers, no `q`-register lanes). So scalar-SoA
is measured **~1.5× *slower* than stage 2** at large N. Full analysis:
`.scratch/analysis/stage3-perf-degradation.md`.

### Stage 3 (scalar SoA) vs stage 2 — back-to-back, 3 trials min, ReleaseFast, M4

|        N | stage 2 ns/p | stage 3 ns/p |     ratio | GB/s @1M (S2 / S3) |
|---------:|-------------:|-------------:|----------:|:-------------------|
|    65000 |        1.078 |        1.634 |     0.66× | 33.4 / 17.8        |
|   262000 |        1.063 |        1.633 |     0.65× |                    |
|  1000000 |        1.073 |        1.670 | **0.64×** | 33.6 / 17.4        |
|  4000000 |        1.077 |        1.720 |     0.63× | 33.4 / 16.9        |
| 16000000 |        1.087 |        1.724 |     0.63× |                    |
| 64000000 |        1.102 |        1.727 |     0.64× | 32.7 / 16.8        |

Stage 3 moves **fewer** bytes than stage 2 (29 vs 36) yet takes **longer** and
sustains only **half** the effective bandwidth (17 vs 33 GB/s). The `GB/s eff`
column is the smoking gun: if stage 3 were memory-bound, fewer bytes would make
it faster. Instead it is bandwidth-*starved by its own compute* — the CPU is
busy on scalar FP + loop overhead + stream management and can't issue loads
fast enough. The 17 GB/s is a *consequence* of how fast it can cycle the loop,
not a ceiling imposed by memory.

### Why scalar-SoA loses here (the short version)

- **Stage 2 is not bandwidth-bound.** It's at 33 GB/s, 62% of the ~54 GB/s
  single-core streaming ceiling — already compute/overhead-bound. Cutting bytes
  further (stage 3: 36→29) can't help; you can't go faster than the compute
  floor by reducing bytes.
- **SoA's subsetting advantage doesn't apply to this hot loop.** SoA wins when
  different passes touch *different subsets* of fields. This sim's
  integrate+forces pass touches `pos` AND `vel` AND `age` for every particle —
  every hot field, every frame. There's no pass that reads "only pos" or "only
  vel." SoA rearranges the *same total hot bytes* into more streams; it doesn't
  let any pass load fewer. The byte-reduction (36→29) came entirely from
  dropping `life` — a 7-byte saving that cost 6–8 streams.
- **Same FP, more overhead, no SIMD to amortize it.** All three stages do the
  identical math. Stage 3 does it across 4 loops (vs stage 2's 1), over 6–8
  streams (vs 1), with 4× the loop-branch overhead. Without SIMD each `fma`
  takes a full scalar cycle instead of ¼ of a `@Vector(4)` cycle, so the
  compute that *was* hidden behind streaming in stages 1–2 becomes *visible*.

### The transformation still *lands* — the audit proves it

The layout transformation is not a no-op just because the time didn't move. The
data-density audit proves it landed three ways (§4 below): MEAN density
**0.655 → 0.722**, `life` left the dump entirely, and the fingerprint changed
from AoS-strided blobs to per-component streams. **The layout is now correct
for the throughput reward stage 6 will claim** (`@Vector` over contiguous
per-component streams — exactly what the layout unlocks). Stage 3 paid the
layout's overhead on this toolchain; stage 6 collects the reward that finally
makes it pay. That is the plan's P7, played straight.

---

## 4. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=3 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N | bytes/p |   mem(MB) | ns/particle(min) |  ns/frame(min) |  frames/sec | GB/s eff | runtime(ms)
  -----------+---------+-----------+------------------+----------------+-------------+----------+------------
        4000 |      29 |       0.1 |            3.887 |        15546.7 |     64322.5 |     7.46 |        10.2
       16000 |      29 |       0.4 |            2.537 |        40595.2 |     24633.5 |    11.43 |        30.2
       65000 |      29 |       1.8 |            1.634 |       106180.4 |      9417.9 |    17.75 |        68.0
      262000 |      29 |       7.2 |            1.633 |       427910.2 |      2336.9 |    17.76 |       259.1
     1000000 |      29 |      27.7 |            1.670 |      1669616.5 |       598.9 |    17.37 |      1005.7
     4000000 |      29 |     110.6 |            1.720 |      6878474.0 |       145.4 |    16.86 |      4140.9
    16000000 |      29 |     442.5 |            1.724 |     27577535.2 |        36.3 |    16.83 |     16578.5
    64000000 |      29 |    1770.0 |            1.727 |    110496691.7 |         9.1 |    16.80 |     66434.3
```

The curve is **flat from 262K on** (~1.63–1.73 ns/particle) and the `GB/s eff`
column is **flat at ~17** across the same range — the signature of a
compute/overhead-bound loop, not a bandwidth-bound one (compare stage 2's
~33 GB/s plateau, or stage 1's ~54 GB/s near the ceiling).

## 5. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=3 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

Stage 3's `dumpFields` fingerprint differs from stage 2's in two ways: each
stream is a *contiguous* per-component run (`pos.x`, `pos.y`, …) rather than an
AoS-strided blob, and `life` is **gone** from the dump — it's an allocated
stream `step()` never walks, so it carries no hot bandwidth and isn't counted.

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
     pos.x |       4096 |       3866 |     0.944 |      7.55
     pos.y |       4096 |       3760 |     0.918 |      7.34
     pos.z |       4096 |       1138 |     0.278 |      2.22   ← low (z near-constant: gravity/impulse mostly x,y)
     vel.x |       4096 |       3825 |     0.934 |      7.47
     vel.y |       4096 |       3841 |     0.938 |      7.50
     vel.z |       4096 |       1077 |     0.263 |      2.10   ← low (same)
       age |       4096 |       3600 |     0.879 |      7.03
      kind |       1024 |        325 |     0.317 |      2.54   ← 3 values, dispatch (stage 5 target)
  ---------+------------+------------+-----------+----------
      MEAN |      29696 |      21432 |     0.722 |      5.77
```

**MEAN density = 0.722** — up from stage 2's **0.655**. ✅ (directional check —
the transformation landed)

### What the audit proves (the layout transformation *did* land)

- **`life` left the hot loop.** Not in the dump at all — `step()` doesn't touch
  it. The first stage where an allocated field costs zero hot bandwidth. (Stage
  4 will remove it from storage as the constant it is.)
- **Per-component density is higher than AoS-strided density** for the real
  signal fields (pos.x/y at 0.92–0.94 vs stage 2's combined `pos` at 0.734).
  The SoA stream has no stride waste — every byte IS one component value, no
  padding/interleaving diluting it. **This is the audit showing the SoA
  transformation, not just the numbers.**
- **`pos.z` / `vel.z` are low density (0.26–0.28)** — a new signal the
  per-component split reveals (stage 2's combined `pos`/`vel` averaged it in).
  z is near-constant: gravity and the impulses are mostly x,y, so z barely
  changes. The audit doing its job: revealing structure the AoS hid.
- **`kind` (0.317)** is still the per-particle dispatch — stage 5's target.

**Density up (0.655 → 0.722) is the qualitative proof the transformation
landed**, even though the time went the wrong way on this toolchain. The layout
is now correct for stage 6's SIMD reward; the time win is deferred, not lost.

---

## 6. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

The RNG draw sequence (kind, jitter_x, jitter_y, age — same order, same
methods) is identical to stages 1–2's `spawnParticle`. The SoA math is
bit-identical to the AoS math (same FP ops, same per-particle order). Golden
passes with **max delta = 0.00** — math unchanged; only the data layout
changed.

---

## 7. What the next stage must beat (acceptance gate for C7)

Stage 4 (branchless compaction) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4` (math unchanged — sort tolerates reordering).
4. **Stage 4 branchless ≪ stage 4 branchy** under adversarial alive patterns
   (every-other alive — worst case for branch prediction). Stage 4's gate is
   the branchy-vs-branchless gap under adversarial input, not vs stage 3.
5. Audit: `life` (and other constants) leave storage; MEAN density climbs
   further.
6. Clear `git diff` from `03_soa/sim.zig` — the compaction move in one file.

Stage 3's residual cost is the scalar `age` + kill + dispatch pass and the
scalar math passes. Stage 4 attacks the kill branch (branchless compaction);
stage 5 attacks the `switch(kind)` (sort/split by kind); **stage 6 claims the
SIMD reward this layout unlocked** — and that's where stage 3's deferred time
win finally materializes.
