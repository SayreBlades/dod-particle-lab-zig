# Stage 2 — Hot/cold split (first real DOD move)

> *Group data by how it's used (frame cadence), not what it is.*

Stage 1 was the strawman: one 80 B `Particle` struct, every field dragged
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
nothing. The math *needs* ~28 B/frame; the loop *walks* ~80 B.

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

|        N | stage 1 ns/p | stage 2 ns/p |                            speedup |
|---------:|-------------:|-------------:|-----------------------------------:|
|     4000 |         3.87 |         2.41 | —  (small N: fixed costs, no gate) |
|    16000 |         2.36 |         1.91 |                                  — |
|    65000 |         2.21 |         1.70 |                          **1.30×** |
|   262000 |         1.25 |         1.11 |                          **1.13×** |
|  1000000 |         1.40 |         1.10 |                          **1.27×** |
|  4000000 |         1.59 |         1.11 |                          **1.44×** |
| 16000000 |         1.62 |         1.11 |                          **1.45×** |
| 64000000 |         1.63 |         1.14 |                          **1.44×** |

**Stage 2 wins at every N≥65K.** ✅ (criterion 5)

*(Run-to-run variance ~±10% at small N; numbers above are a single
back-to-back run of stage 1 then stage 2 under the same conditions.)*

### How to read the curve

- **Small N (≤16K):** stage 2 ≈ stage 1 or slightly worse. The working set fits
  in L1 either way; the split's byte-reduction is noise against fixed per-frame
  costs. Expected — DOD pays off at scale, not in L1.
- **65K:** the hot array (36 B × 65K ≈ 2.3 MB) is now L2/SLC-resident while
  stage 1's 80 B × 65K ≈ 5.2 MB spills L2. First clean win.
- **262K→4M:** stage 2's hot working set is 2.2× smaller, so it stays
  cache-resident to larger N and the bandwidth floor lifts. At 4M, stage 1 walks
  ~320 MB/frame (past L2, into DRAM) while stage 2 walks ~137 MB.
- **≥1M (bandwidth-bound):** the floor drops from ~1.6 → ~1.1 ns/particle. That
  ~33% lift at ~half the bytes/particle is the hot/cold split's headline. The
  remaining ~1.1 ns/particle is the compute floor (math the layout can't remove);
  stage 3 (SoA) attacks the *byte-reduction* further, stage 6 (SIMD) attacks
  the *compute floor*.

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
  bytes dragged through L1 by the update dropped from ~80 → ~36 B/particle.
- Two low-density fields remain in the hot loop, predicting later stages:
  - **`life` (0.013)** — a constant dragged through L1 every frame. Stage 4
    (compact) removes it: it shouldn't be per-particle data at all.
  - **`kind` (0.317)** — 3 distinct values, used for the per-particle dispatch.
    Stage 5 (sort-by-kind) restructures data so dispatch is hoisted out of the
    loop; `color` (currently in cold) becomes a lookup on `kind`, not a field.
- Only `pos`/`vel`/`age` are real signal (0.73–0.88). The math *needs* ~28 B;
  the hot loop now *walks* ~36 B — the gap closed from 80→28 (52 wasted) to
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
