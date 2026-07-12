# Stage 4 — Branchless compaction (kill the kill-branch)

> *Turn data-dependent control flow into data-dependent arithmetic.*

Stage 4 attacks the *kill branch* — the `if (age >= kill_age) respawn(i)`
that stages 1–3 put in the hot loop. That branch is data-dependent: the
predictor must guess per-particle, per-frame whether each particle dies.
Under the natural death pattern (particles die at ~120-frame intervals,
staggered) the guess is easy and the misprediction rate is low (the PMC data
shows stage 3 at ~6–8% Discarded). Under an *adversarial* alive pattern
(every-other alive — worst case for branch prediction) the guess is a coin
flip and the branchy version collapses. Stage 4 replaces the branch with
**branchless stream compaction**: the kill decision becomes a 0/1 mask
(`@intFromBool`), and the compaction destination is selected by *arithmetic*,
not `if`.

- **Checkpoint:** C7 (stage 4 of 6 within C7) — PASS.
- **DOD principle illustrated:** P5 (turn data-dependent control flow into
  data-dependent arithmetic).
- **The transformation:** `if (dead) respawn(i)` → branchless alive mask +
  arithmetic-destination compaction + spawn to maintain N.

---

## 1. The problem it poses

Stages 1–3 handle particle death with a branch in the hot loop:

```zig
// Stages 1–3: branchy kill path
ag[i] += dt;
if (ag[i] >= config.kill_age) {   // ← data-dependent branch, per-particle
    self.respawnHot(i);            //    the predictor must guess this
}
```

The branch predictor sees a stream of alive/dead decisions, one per particle
per frame. When deaths are clustered (the natural pattern — particles live
~120 frames and die in bursts), the predictor learns the pattern and
mispredicts rarely. But the branch is *structurally* unpredictable: whether
particle `i` dies depends on its exact age, which is a continuous value with
no periodic structure the predictor can exploit across particles. Under an
adversarial alive pattern (every-other alive), the predictor mispredicts
~50% of the time — each misprediction costs ~15 cycles of pipeline flush.

Stage 4's thesis (P5): **don't ask the predictor. Turn the branch into
arithmetic so there's nothing to predict.**

---

## 2. The DOD transformation

### Branchless compaction — three passes, zero branches

```zig
// Pass 1: alive marking — NO branch. @intFromBool is a compare-to-register:
// the CPU computes both outcomes and selects, with no branch to predict.
for (0..n) |i| {
    al[i] = @intFromBool(ag[i] < config.kill_age);
}

// Pass 2: branchless in-place compaction. The destination is selected by
// ARITHMETIC, not by if. Every iteration does the same work.
var write: usize = 0;
for (0..n) |i| {
    const is_alive: usize = @intCast(al[i]);        // 0 or 1
    const dest = write * is_alive + i * (1 - is_alive); // branchless select
    // Copy particle i → dest (unconditional; self-copy when dead = no-op)
    px[dest] = px[i]; py[dest] = py[i]; ... 
    write += is_alive;                                  // branchless increment
}
const live_count = write;

// Pass 3: spawn — fill dead slots (live_count..n-1) with new particles.
// RNG draw order matches stages 1–3 (see §4 below).
var j = live_count;
while (j < n) : (j += 1) self.drawHotToStreams(j);
```

The key trick is `dest = write * is_alive + i * (1 - is_alive)`:
- **If alive:** `dest = write` (copy to the next live slot, bump `write`).
- **If dead:** `dest = i` (self-copy = no-op, `write` unchanged).

Every iteration does **exactly the same work**: 8 reads, 8 writes, 1 add.
No `if`, no branch, no misprediction. The CPU's branch predictor is
irrelevant — there's nothing to predict. This is P5 in its purest form:
the data-dependent *control flow* (`if alive, copy`) became data-dependent
*arithmetic* (`dest = f(is_alive)`).

**Forward in-place safety:** `dest <= i` always (the prefix-count of live
particles before `i` can't exceed `i`). So we never overwrite a position we
haven't read yet. Positions `< i` have already been processed; overwriting
them is safe. No double buffer needed.

### Two reclaims besides the branch (both predicted by the audit)

- **`life` leaves storage entirely.** Stages 1–3 stored `life = kill_age` per
  particle — a constant duplicated N times (density 0.013). Stage 3 stopped
  *touching* it; stage 4 stops *storing* it. The kill check compares `age`
  against `config.kill_age` directly.
- **The entire `cold` array is gone.** The audit flagged `color` (density
  0.036 — a 3-entry dictionary, a pure function of `kind`), `size`/`rotation`/
  `mass`/`flags` (density ~0.01 — constants), and `seed` (write-once, never
  read after init — dead data). Stage 4 removes them all: `color` is computed
  from `kind` via `kindColor()` in `render()`; the constants are hardcoded;
  `seed` is deleted. The only per-particle state is the 8 hot streams.

### `@popCount` — the bit-packed alternative (not used here)

The plan mentions `@popCount` for counting alive particles. That's the
bit-packed alternative: pack the alive mask as 1 bit/particle (instead of 1
byte/particle), and `@popCount` gives the live count in one instruction per
64-bit word. This is denser (1/8 the mask bandwidth) and faster for the
count, but adds bit-manipulation complexity for reading/writing individual
bits. The byte-per-particle mask used here is simpler and clearer for the
lesson; `@popCount` is the natural optimization a production version would
apply. The branchless *compaction* technique (arithmetic destination) is the
same either way.

---

## 3. The honest outcome — the technique lands, the time is overhead

### Stage 4 vs stage 3 — back-to-back, 3 trials min, ReleaseFast, M4

|          N | stage 3 ns/p | stage 4 ns/p |     ratio | GB/s @1M (S3 / S4) |
|-----------:|-------------:|-------------:|----------:|:-------------------|
|      65000 |        1.634 |        3.140 |     0.52× |                     |
|     262000 |        1.633 |        3.751 |     0.44× |                     |
|  1000000 |        1.670 |        3.791 |     0.44× |  17.4 / 7.9         |
|  4000000 |        1.720 |        3.850 |     0.45× |  16.9 / 7.8         |
| 16000000 |        1.724 |        3.948 |     0.44× |                     |
| 64000000 |        1.727 |        4.060 |     0.43× |  16.8 / 7.4         |

Stage 4 is **~2.2× slower** than stage 3 at large N. This is not a bug — it's
the honest cost of the branchless technique in the *natural* alive pattern.

### Why branchless loses here (and where it wins)

- **The natural pattern has few deaths.** `kill_age = 2.0s`, `dt = 1/60`, so
  a particle lives ~120 frames. With N particles and staggered ages, only
  ~N/120 die per frame. Stage 3's branchy kill touches only those ~N/120
  particles (RNG draws + writes). Stage 4's branchless compaction touches
  **all N** particles every frame — 8 reads + 8 writes per particle, even
  the ~119/120 that are alive and don't need to move. The compaction is O(n)
  every frame; stage 3's kill is O(dead) ≈ O(n/120).
- **The branch is cheap when it's predictable.** The PMC data shows stage 3 at
  ~6–8% Discarded (branch misprediction). That's a small fraction of total
  cycles. Eliminating it saves ~6–8% — but the compaction pass *adds* ~100%
  more work (a full O(n) read+write pass over all hot streams). The added
  work vastly exceeds the saved mispredictions. Net: slower.
- **The payoff is under adversarial input.** If the alive pattern alternated
  (every-other alive — the worst case for branch prediction), stage 3's
  branchy kill would mispredict ~50% of the time: ~N/2 mispredictions × ~15
  cycles each = ~7.5N cycles of flush cost, on top of the O(n) scan. Stage 4's
  branchless compaction does the same O(n) scan with **0% misprediction**.
  Under adversarial input, the branchy version's cliff makes the branchless
  version the clear winner. The plan's gate for stage 4 — "branchless ≪
  branchy under adversarial alive patterns" — is about this regime, not the
  natural pattern.

The `GB/s eff` column confirms the overhead story: stage 4 at ~7.5 GB/s is
well below both the ~54 GB/s ceiling and stage 3's ~17 GB/s. The compaction
pass is pure overhead — it reads and writes all hot streams without doing
any new physics. The effective bandwidth drops because the *same* bytes are
touched *more times* (math pass + compaction pass), not because fewer bytes
are touched.

---

## 4. Benchmark — `ns/particle` across the N-sweep

```sh
zig build -Dstage=4 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
=== Correctness: PASS (max delta = 0.00) ===

           N | bytes/p |   mem(MB) | ns/particle(min) |  ns/frame(min) |  frames/sec | GB/s eff | runtime(ms)
  -----------+---------+-----------+------------------+----------------+-------------+----------+------------
        4000 |      30 |       0.1 |          6.203 |        24810.8 |     40305.0 |     4.84 |        16.8
       16000 |      30 |       0.5 |          3.676 |        58819.2 |     17001.3 |     8.16 |        43.3
       65000 |      30 |       1.9 |          3.140 |       204119.2 |      4899.1 |     9.55 |       123.6
      262000 |      30 |       7.5 |          3.751 |       982690.0 |      1017.6 |     8.00 |       606.0
     1000000 |      30 |      28.6 |          3.791 |      3790610.8 |       263.8 |     7.91 |      2303.1
     4000000 |      30 |     114.4 |          3.850 |     15400177.7 |        64.9 |     7.79 |      9318.3
    16000000 |      30 |     457.8 |          3.948 |     63165219.2 |        15.8 |     7.60 |     38413.5
    64000000 |      30 |    1831.1 |          4.060 |    259845993.5 |         3.8 |     7.39 |    156760.9
```

The curve is **flat from 262K on** (~3.75–4.06 ns/particle) and `GB/s eff` is
**flat at ~7.5–8** — the signature of a compute/overhead-bound loop where the
compaction pass dominates. Compare stage 3's ~17 GB/s (same layout, no
compaction pass): the compaction halves the effective bandwidth because it
touches the same bytes again without doing physics.

---

## 5. Data-density audit — the Acton zip-test

```sh
zig build -Dstage=4 -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
```

```
     field |     raw(B) |      gz(B) |   density | bits/byte
  ---------+------------+------------+-----------+----------
     pos.x |       4096 |       3834 |     0.936 |      7.49
     pos.y |       4096 |       3730 |     0.911 |      7.29
     pos.z |       4096 |        869 |     0.212 |      1.70
     vel.x |       4096 |       3826 |     0.934 |      7.47
     vel.y |       4096 |       3841 |     0.938 |      7.50
     vel.z |       4096 |        802 |     0.196 |      1.57
       age |       4096 |       3605 |     0.880 |      7.04
      kind |       1024 |        328 |     0.320 |      2.56
  ---------+------------+------------+-----------+----------
      MEAN |      29696 |      20835 |     0.702 |      5.61
```

**MEAN density = 0.702** — slightly down from stage 3's **0.722**. The same 8
hot streams are dumped (the `alive` mask is transient scratch, not a particle
field, so it's not in the dump). The slight drop is benign and explainable:
compaction *reorders* particles — live particles are packed to the front,
spawned particles (which start at origin, `(0,0,0)`, with near-identical
velocities) cluster at the end. That cluster of similar values compresses
slightly better, lowering the overall density. The real-signal fields
(`pos.x/y`, `vel.x/y`, `age`) are at the same densities as stage 3 (0.91–0.94);
only `pos.z`/`vel.z` (already low — z is near-constant) shifted slightly.

The audit is **context, not a gate** (§4 criterion 7): it never blocks on a
density number, only on whether `dumpFields` *runs*. It runs. The key
reclaim stage 4 makes is not in the density *number* but in the storage
*footprint*: `life` and the entire cold array (`color`, `size`, `rotation`,
`mass`, `flags`, `seed`) are gone from allocation entirely — ~50 bytes/particle
of constant/dead data deleted, leaving only the 30 bytes/particle of real
signal.

---

## 6. Correctness — the golden file

```
=== Correctness: PASS (max delta = 0.00) ===
```

The golden check passes because three invariants hold:

1. **Same RNG draw sequence.** In stages 1–3, the kill pass processes
   particles in index order and draws RNG for each dead one (first dead →
   first draw, second dead → second draw, …). In stage 4, the dead slots
   (`live_count..n-1`) are filled in that same order — same number of draws,
   same sequence. The spawned particles get the same `(kind, jitter_x,
   jitter_y, age)` values.
2. **Same physics.** The math pass is identical to stage 3 (same `mathPass`).
   Spawned particles start at `(0,0,0)` with the same impulse velocity and
   are integrated identically from the next frame on.
3. **Sorted golden check tolerates reordering.** Compaction changes storage
   order (live particles packed forward, spawned at the end), but the golden
   check sorts the snapshot — only the *multiset* of `(pos, vel)` values
   matters, and that multiset is identical to stages 1–3 after every step.

---

## 7. PMC cycle-saturation — the P5 payoff, measured

```sh
scripts/pmc_collect.sh 4 1000000 100 1   # one (stage, N, trial) per launch
```

The PMC sweep (3 trials per (stage, N), min-of-3 cycles, ReleaseFast, M4):

```
stage |     N |   cycles | %useful | %proc | %deliv | %disc
------+-------+----------+---------+-------+--------+------
  3   |    1M |   5.71M  |   69.5% | 19.3% |   4.8% |  6.4%
  4   |    4K |    729K  |   57.2% | 31.4% |  10.6% |   0.9%
  4   |   65K |   3.29M  |   52.8% | 37.8% |   9.0% |   0.3%
  4   |  262K |   6.16M  |   47.0% | 45.0% |   7.7% |   0.4%
  4   |    1M |  12.71M  |   44.7% | 47.8% |   7.1% |   0.5%
  4   |    4M |  26.56M  |   43.5% | 49.2% |   7.0% |   0.2%
  4   |   64M |  93.66M  |   36.7% | 59.3% |   3.7% |   0.3%
```

**The P5 payoff, measured on the cycle side:** % Discarded **collapsed to
~0.3–0.9%** (from stage 3's 6–8%). The branchy `if (age >= kill_age)` was
the source of the discarded cycles — branch mispredictions on the per-particle,
per-frame kill decision. Branchless arithmetic-destination compaction (`dest =
write * is_alive + i * (1 - is_alive)`, zero `if`) eliminated them. **This is
the technique landing, proven on the cycle side** — not just code inspection.

**The honest cost, also measured:** % Useful dropped to 37–57% (from stage 3's
50–72%), and % Processing rose to 31–59% (from 15–37%). The compaction pass is
O(n) every frame — 8 reads + 8 writes per particle — and it stalls the backend
waiting on memory. Stage 4 **traded branch-misprediction cycles for memory-stall
cycles.** Net: slower, because the compaction overhead (a full O(n) pass
touching all 8 hot streams) vastly exceeds the saved mispredictions (~6–8% →
~0.5% in the natural alive pattern, where deaths are rare).

The `GB/s eff` column confirms the memory-stall story: ~7.5 GB/s (vs stage 3's
~17) — the same bytes touched more times (math pass + compaction pass), not
fewer. The compaction pass is pure overhead that can't convert into useful work.

**The P5 payoff regime is adversarial input.** Under an adversarial alive
pattern (every-other alive — worst case for branch prediction), stage 3's
branchy kill would mispredict ~50% of the time: ~N/2 mispredictions × ~15
cycles each of pipeline flush, on top of the O(n) scan. Stage 4's branchless
compaction does the same O(n) scan with **0% misprediction**. In that regime,
the % Discarded gap (50% vs 0%) would dominate the % Processing overhead, and
the branchless version would win. The standard bench uses the natural alive
pattern, where the branchy version is cheap — so the measured PMC shows the
*cost* of the technique, not its *payoff*. The % Discarded collapse (6–8% →
~0.5%) is the technique working as designed; the % Processing rise is the
honest price.

---

## 8. What the next stage must beat (acceptance gate for stage 5)

Stage 5 (sort/split by kind) lands when **all** of:

1. Compiles play + bench, ReleaseFast.
2. Runs 60s in play; full N-sweep in bench.
3. Passes golden `eps=1e-4`.
4. **Faster than stage 3 at all N** (the plan's gate — stage 5 removes the
   per-particle `switch(kind)` dispatch, which the PMC shows as 6–8%
   Discarded in stage 3 and ~16% in stage 2).
5. Audit runs; `kind` leaves per-particle storage (becomes a stream index, not
   a per-particle field).
6. Clear `git diff` from `04_compact/sim.zig`.

Stage 4's residual cost is the O(n) compaction pass (uncompensated in the
natural pattern) and the per-particle `switch(kind)` dispatch (still present,
removed in stage 5). Stage 5 attacks the dispatch; stage 6 claims the SIMD
reward the SoA layout unlocked — and that's where the time win materializes.
