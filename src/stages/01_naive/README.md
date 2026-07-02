# Stage 1 — The naive baseline (the strawman)

> *"The object was a lie."* This is the lie, on purpose.

Stage 1 is the **reference every later stage is measured against** — the
"OOP brain" version built deliberately wrong so each transformation in stages
2–9 has a concrete before to beat. The math here is the math forever; only the
**data layout and access pattern** change in later stages.

- **Checkpoint:** C2 (renders+moves), C3 (bench+golden), C4 (full acceptance) — all PASS.
- **DOD principles illustrated:** none yet. This stage *sets up* all of them.
- **The line to beat:** every later stage must be faster than this one at large N,
  without changing the golden-file output.

---

## 1. The problem it poses

One big AoS array of `Particle`. `step()` touches **every field of every
particle every frame**, including cold fields (`mass`/`flags`/`seed`/`kind`)
the update doesn't use. Per-particle `switch (kind)` is a deliberate hot
branch. `if (age >= kill_age) respawn` is branchy in-place mutation.

```zig
const Particle = struct {
    pos: Vec3, vel: Vec3, life: f32, age: f32,   // hot every frame
    color: Vec4, size: f32, rotation: f32,        // render-only (cold to update)
    mass: f32, flags: u8, kind: u8, seed: u32,    // rare / spawn-time only
};
var particles: []Particle;  // one AoS array
// step: for (particles) |*p| { integrate; forces; age; if(kill) respawn; switch(kind){...} }
```

`sizeof(Particle)` ≈ 80 B (with padding). The math *needs* ~28 B/frame
(`pos`/`vel`/`age`); the loop *walks* ~80 B. That gap is the seed of the whole
lesson.

---

## 2. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=1 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
           N |     mem(MB) |    ns/particle |   frames/sec
        4000 |         0.3 |          3.316 |      75385.2
       16000 |         1.0 |          2.676 |      23354.5
       65000 |         4.2 |          1.387 |      11094.2
      262000 |        17.0 |          1.338 |       2851.8
     1000000 |        64.8 |          1.467 |        681.8
     4000000 |       259.4 |          1.667 |        150.0
    16000000 |      1037.6 |          1.681 |         37.2
    64000000 |      4150.4 |          1.902 |          8.2
```

*(Run-to-run variance ~±10% at small N from CPU frequency scaling; the curve
shape is the durable signal, not any single number.)*

**How to read the curve:**

- **4K→262K:** ns/particle *falls* (3.32 → 1.34). Fixed per-frame costs
  amortize; the working set is L1/L2/SLC-resident. The cache lessons live here.
- **262K:** the minimum. SLC-resident.
- **262K→1M:** gentle slope up (+9%). The L2→SLC transition — *not* a cliff,
  because SLC latency is only ~2–3× L2.
- **1M→64M:** **flat across a 64× working-set increase** (1.47 → 1.90). That
  plateau is the signature of **memory-bandwidth saturation**, not cache-miss
  latency. Stage 1 streams ~80 B/particle; at 4M that's ~190 GB/s effective
  throughput, ≈ the M4's DRAM ceiling.

**The honest takeaway:** stage 1 is **memory-bandwidth-bound from ~1M particles.**
The cache lessons (L1→L2→SLC residency) are most visible at small N; the big-N
region is a *bandwidth* lesson. This reframes what stages 2–3 target: reducing
bytes-per-particle (AoS→SoA, hot/cold split) directly lifts off the bandwidth
floor.

---

## 3. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=1 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

Mike Acton (~49:38, CppCon 2014): print a field's per-element values, zip them.
gzip is an entropy oracle — a lossless compressor cannot shrink a stream below
its information content, so `density = gz_bytes / raw_bytes` is a lower bound on
a field's information density.

- **low density** → redundant per-particle (constant / few distinct values) →
  candidate to drop from the hot loop, stop storing per-element, or become a lookup.
- **high density** → real signal → leave it alone.

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
        pos |      12288 |       9015 |     0.734 |      5.87   ← real signal
        vel |      12288 |       9136 |     0.743 |      5.95   ← real signal
       life |       4096 |         52 |     0.013 |      0.10   ← constant (kill_age)
        age |       4096 |       3600 |     0.879 |      7.03   ← real signal
      color |      16384 |        590 |     0.036 |      0.29   ← 3 values (fn of kind)
       size |       4096 |         52 |     0.013 |      0.10   ← constant (1.0)
   rotation |       4096 |         48 |     0.012 |      0.09   ← constant (0)
       mass |       4096 |         52 |     0.013 |      0.10   ← constant (1.0)
      flags |       1024 |         39 |     0.038 |      0.30   ← constant (0)
       kind |       1024 |        325 |     0.317 |      2.54   ← 3 values
       seed |       4096 |       1478 |     0.361 |      2.89   ← sequential ints
  ---------+------------+------------+-----------+----------
      MEAN |      67584 |      24387 |     0.361 |      2.89
```

**MEAN density = 0.361** — the headline number later stages must drive UP.

### What the audit proves

- **8 of 11 fields carry ~0 information** yet are touched every frame. The hot
  loop pays ~64 KB of cache bandwidth per 1K particles to read constants and a
  3-entry color table.
- Only **`pos`, `vel`, `age`** are real signal (0.73–0.88 density). The math
  *needs* ~28 B/particle; the loop *walks* ~80 B — the audit quantifies the
  waste the whole stage-2 transformation targets, by measuring the bytes rather
  than reasoning about usage cadence.

### The density ranking IS the stage roadmap

| Later stage | What the audit predicts |
|---|---|
| **2 hot/cold** | Drop `color/size/rotation/mass/flags/life` out of the update loop → hot-loop mean density jumps from 0.36 to ~0.85 (only `pos`/`vel`/`age` remain). |
| **4 compact** | `size/rotation/mass/flags/life` are *constants* (0.01 density) — they shouldn't be per-particle data at all. The audit predicted their removal before any layout work. |
| **5 sort-by-kind** | `color` at 0.036 is a pure function of `kind` (a 3-entry dictionary). De-virtualizing kind makes color a lookup, not a field. |

Watching **MEAN density rise** across stages is the qualitative twin of
**ns/particle fall** — two views of one transformation (reclaimed entropy ≈
reclaimed bandwidth).

---

## 4. Correctness — the golden file

Stage 1 *generates* `golden/stage1.bin` (the reference). Every later stage
verifies against it within `eps=1e-4`. Stage 1 self-checks after generating:

```
=== Correctness: generating golden file ===
  wrote golden/stage1.bin (n=1024, steps=600)
=== Correctness: PASS (max delta = 0.00) ===
```

This *proves* the central DOD claim ahead of time: every later stage reshapes
data, none change math. If a stage's layout transformation breaks the math, the
golden check catches it before the perf numbers do.

---

## 5. What the next stage must beat (acceptance gate for C5)

Stage 2 (hot/cold split) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4` (math unchanged).
4. **Stage 2 < stage 1 at N≥65K** — the directional perf gate. If it doesn't
   win, the split didn't land even if correctness passes.
5. Audit shows hot-loop mean density climb toward ~0.85 (cold fields out of the
   update loop).
6. Clear `git diff` from `01_naive/sim.zig` — readable as a single DOD lesson.

The 65K threshold sits in the small-N cache-resident region where the hot/cold
split's byte-reduction matters most — it should be a clean win. The *big* win
comes from lifting the bandwidth floor at large N (~1M+), which the audit's
density framing predicts directly.
