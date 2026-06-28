# Plan: Particle System — A Staged Data-Oriented Design Lab in Zig

A hands-on laboratory for *feeling* the cache/perf lessons from Mike Acton's
CppCon 2014 talk ["Data-Oriented Design and C++"](https://www.youtube.com/watch?v=rX0ItVEVjHc),
implemented as an interactive **raylib game** in Zig on Apple Silicon.

The thesis, in one sentence:

> The object was a lie. There was never a "Particle" — there were five loops that
> touched overlapping subsets of its fields. When we laid out memory for the loops
> instead of for the concept, the loops got 10× faster and the code got simpler.

Each stage is a *before/after* with measured numbers. The math never changes;
only the **data layout and access pattern** change.

---

## 1. The DOD principles this lab teaches

| #   | Principle                                                                                  | Stages |
|-----|--------------------------------------------------------------------------------------------|--------|
| P1  | **Design for the data transformation, not the object.**                                    | 3, 9   |
| P2  | **Group data by how it's used (frame cadence), not what it is.**                           | 2      |
| P3  | **Only touch what each loop needs.** Hot/cold split.                                       | 2, 9   |
| P4  | **AoS → SoA** for cache density and vectorizability.                                       | 3, 6   |
| P5  | **Turn data-dependent control flow into data-dependent arithmetic.** Branchless.           | 4      |
| P6  | **Per-element dispatch is a layout problem in disguise.** De-virtualize.                   | 5      |
| P7  | **Vectorize the hot loop — but SoA first.** SIMD is a *reward* for layout.                 | 6      |
| P8  | **Sizes/alignments are parameters matched to the hardware.**                               | 7      |
| P9  | **The allocator is part of the data pipeline.**                                            | 8      |
| P10 | **Synthesis:** every move is independent and measurable; the final ratio is their product. | 9      |
| P11 | **Bonus:** the renderer is data too.                                                       | 10     |
| P12 | **Bonus:** determinism enables headless replay and video export.                           | 11     |

---

## 2. Hardware target — "the platform is the hardware"

This project is built against a **specific machine**. DOD only makes sense relative
to concrete cache/memory facts. The framework prints these at the start of every
run (a deliberate ritual — never let the developer forget the x-axis).

**Measured on the dev machine (Apple M4):**

```
hw.cachelinesize   = 128        ← stage 7 alignment/tile target
hw.l1dcachesize    = 65536     (64 KB)   ← ~1.6K hot particles fit
hw.l1icachesize    = 131072    (128 KB)
hw.l2cachesize     = 4194304   (4 MB)    ← ~524K hot particles; the sweep kink lives here
hw.pagesize        = 16384     (16 KB)
hw.ncpu            = 10
hw.memsize         = 17179869184  (16 GB)
SIMD               = NEON (128-bit → @Vector(4, f32) native; @Vector(8) needs 2 ops)
```

The benchmark N-sweep `{4K, 16K, 65K, 262K, 1M, 4M}` is chosen so the L2 boundary
(~524K hot particles at 8 B/hot-field) falls between 262K and 1M — i.e. the cache
spill shows up as a visible kink in the curve. That's the whole point of the sweep.

`src/framework/hardware.zig` shells out to `sysctl` once at startup, parses, and
prints a formatted block. Stages 7+ consume these values to size their layouts.

---

## 3. Architecture

### 3.1 Directory layout

```
zig-test/
├── build.zig                  # ROOT build: -Dstage=N -Dmode={play|bench}
├── build.zig.zon
├── vendor/
│   ├── stb/                   # submodule (PNG write, used by stages 10/11)
│   └── raylib/                # submodule, pinned to tag 6.0
├── src/
│   ├── main.zig               # ~15 lines: comptime switch on stage -> SimImpl -> driver
│   ├── framework/             # SHARED across every stage (never edited per-stage)
│   │   ├── config.zig         # THE math contract: dt, gravity, drag, kill, seed, spawn
│   │   ├── sim.zig            # Sim interface types (Desc, Vec3, Vec4, ParticleKind...)
│   │   ├── hardware.zig       # sysctl cache facts, printed every run
│   │   ├── play.zig           # game driver: raylib window, update+render loop, infinite
│   │   ├── bench.zig          # headless driver: N-sweep, no render, ns/particle table
│   │   ├── render.zig         # software rasterizer: Sim -> RGBA framebuffer (used by 1-9)
│   │   ├── correctness.zig     # golden-file element-wise check vs stage 1 reference
│   │   └── vec.zig            # Vec3/Vec4 helpers
│   ├── bindings/
│   │   ├── raylib.zig          # minimal hand-written extern "c" (grown as stages need)
│   │   └── stb.zig             # extern "c" for stbi_write_png (stages 10/11 only)
│   ├── stb_impl.c             # STB_IMAGE_WRITE_IMPLEMENTATION
│   └── stages/
│       ├── 01_naive/sim.zig     # ← the ONLY file that changes between stages 1-9
│       ├── 02_hotcold/sim.zig
│       ├── 03_soa/sim.zig
│       ├── 04_compact/sim.zig
│       ├── 05_sortbykind/sim.zig
│       ├── 06_simd/sim.zig
│       ├── 07_align/sim.zig
│       ├── 08_alloc/sim.zig
│       ├── 09_synthesis/sim.zig
│       ├── 10_rasterizer/       # bonus: same sim as 09, optimized render
│       │   ├── sim.zig          # re-exports 09's Sim
│       │   └── render.zig       # stage 10's optimized rasterizer (overrides shared)
│       └── 11_record/          # bonus: headless PNG -> ffmpeg export
│           └── sim.zig          # re-exports 09's Sim; bench driver gains --record mode
```

**Invariant:** between stages 1 and 9, only `src/stages/NN_name/sim.zig` differs.
`git diff src/stages/02_hotcold/sim.zig src/stages/03_soa/sim.zig` *is* the
AoS→SoA lesson in one readable file. Everything else — driver, render, bench,
bindings, math constants — is shared and unchanged. This is what makes the
project pedagogically legible.

### 3.2 The `Sim` interface (comptime generics, no vtable)

```zig
// src/framework/sim.zig — the contract every stage implements.
// No vtable: the driver is generic over a concrete Sim type chosen at compile time.
// (This matters: stage 5 teaches that per-particle vtables are bad. We must not
//  use one ourselves at the per-frame boundary either — and per-frame dispatch
//  would be fine, but generics let us skip the question entirely.)

pub const ParticleKind = enum(u8) { smoke, spark, debris };

pub const Desc = struct {
    n: usize,
    seed: u64,
    // physics params are NOT here — they live in config.zig, shared, so every
    // stage's math is provably identical. Desc only describes population/seed.
};

// Each stage's sim.zig exposes a concrete struct with exactly these methods:
//
//   pub const Sim = struct {
//       <stage-specific fields — the layout IS the lesson>
//       pub fn init(alloc: Allocator, desc: Desc) anyerror!*@This();
//       pub fn step(self: *@This(), dt: f32) void;          // the hot loop — benchmarked
//       pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void;  // -> RGBA
//       pub fn deinit(self: *@This()) void;
//   };
```

### 3.3 The shared math contract (`src/framework/config.zig`)

```zig
// The single source of truth for physics. Imported by every stage's step().
// If two stages ever diverge on one of these, the golden-file test catches it.
pub const dt: f32           = 1.0 / 60.0;
pub const gravity: Vec3     = .{ .x = 0, .y = -9.81, .z = 0 };
pub const drag: f32         = 0.01;
pub const kill_age: f32     = 4.0;     // particle dies at age >= 4.0s
pub const spawn_seed: u64   = 0xC0FFEE;
pub const spawn_radius: f32 = 0.5;
// Per-kind impulse tables (lookup, not branch):
pub const impulse: [3]Vec3 = .{
    .{ .x = 0,   .y = 2.0, .z = 0 },   // smoke:  gentle up
    .{ .x = 3.0, .y = 4.0, .z = 0 },   // spark:   sharp diagonal
    .{ .x = 1.0, .y = 1.0, .z = 0.5 }, // debris:  slow scatter
};
```

Every stage's `step()` references `fw.config.gravity`, `fw.config.impulse[kind]`,
etc. — **never local literals.** This is enforced by the golden-file test, not
just convention: if stage 4 changes `gravity` to `-9.8`, its particle positions
diverge from stage 1's golden file and the test fails.

### 3.4 The driver flow

```
                 ┌─────────────────────────────────────────────────┐
                 │  src/main.zig  (comptime switch on opts.stage)  │
                 └────────────────────┬────────────────────────────┘
                                      │
                ┌─────────────────────┴────────────────────────┐
                │  opts.mode == .play   or   opts.mode == .bench
                ▼                                              ▼
  ┌────────────────────────────────┐           ┌──────────────────────────────┐
  │ framework/play.zig             │           │ framework/bench.zig          │
  │  - opens raylib window         │           │  - no window, no raylib      │
  │  - infinite loop:              │           │  - sweeps N over {4K…4M}     │
  │      dt = GetFrameTime()       │           │  - 200 iters each            │
  │      Sim.step(dt)              │           │  - calls Sim.step() only     │
  │      Sim.render(fb, w, h)      │           │  - times via Io.Timestamp    │
  │      UpdateTexture(tex, fb)    │           │  - tabulates ns/particle     │
  │      DrawTexture + HUD         │           │  - runs correctness check    │
  │      live keys: ←/→ grow N,    │           │    vs stage 1 golden file    │
  │      1-9 switch stage, P pause │           │  - prints PASS/FAIL          │
  └────────────────────────────────┘           └──────────────────────────────┘
```

**The firewall:** `bench` mode links no raylib, opens no window, calls no `render()`.
The benchmark measures `Sim.step()` and *nothing else*. `play` mode is for
visualization and never reports benchmark numbers. This is the same headless-vs-
play split real game engines use.

### 3.5 The render path (software rasterizer, firewalled from sim)

```
  Sim state  ──▶  framework/render.zig  ──▶  RGBA framebuffer  ──▶  raylib UpdateTexture  ──▶  GPU
   (CPU)          (CPU, writes []u8)         (W*H*4 bytes)         (one call)              screen
```

- The software rasterizer is **100% CPU, 100% ours.** raylib never draws particles;
  it only blits our framebuffer. This keeps rendering a *visible, measurable* DOD
  exercise (stage 10) rather than a GPU black box.
- `render.zig` is shared by stages 1–9 (so only `sim.zig` differs). Stage 10
  overrides it with its own `stages/10_rasterizer/render.zig`.
- Additive blending of N splats into an RGBA buffer is itself a branchless/SIMD-
  friendly problem — that's the stage 10 lesson.

### 3.6 raylib bindings (minimal, hand-written)

We compile raylib's C source directly (per the working spike — raylib-zig's build
scripts are broken on 0.17-dev). `src/bindings/raylib.zig` declares only what we
use as `extern "c"`, and grows as stages need more functions:

```zig
// Stage 1-9 use: InitWindow, CloseWindow, WindowShouldClose, SetTargetFPS,
// BeginDrawing, EndDrawing, DrawTexture, UpdateTexture, DrawText, DrawFPS,
// ClearBackground, IsKeyPressed, IsKeyDown, GetFrameTime, SetWindowSize,
// GenImageColor, ImageFormat, LoadTextureFromImage, UnloadImage, UnloadTexture.
// Stage 10/11 add: stbi_write_png (from stb.zig).
```

This minimal file is itself a small DOD lesson: *declare the exact data contract
you use, nothing more.*

### 3.7 Build system

One root `build.zig`. The developer UX is exactly:

```sh
zig build -Dstage=3 -Dmode=play        # open the game, stage 3
zig build -Dstage=3 -Dmode=bench       # headless benchmark stage 3
zig build -Dstage=9 -Dmode=play        # full synthesis, live
zig build -Dstage=10 -Dmode=play      # bonus: optimized rasterizer
zig build -Dstage=11 -Dmode=bench -- --record out/  # bonus: PNG -> ffmpeg
```

`build.zig`:
1. Reads `-Dstage=` (string → enum), `-Dmode=` (play|bench), `-Doptimize=`.
2. Compiles raylib C source (per spike: 6 files, `-DPLATFORM_DESKTOP`,
   `-DGRAPHICS_API_OPENGL_33`, `-ObjC`, link Cocoa/IOKit/CoreVideo/CoreFoundation/OpenGL).
3. Compiles `src/stb_impl.c` (stb image_write impl — only linked for stages 10/11).
4. Creates a `Step.Options` with `.stage` and `.mode`, injects as the `"options"`
   import into `src/main.zig`.
5. `main.zig` does the comptime switch on `opts.stage` → picks `SimImpl` →
   dispatches to `play.zig.run(SimImpl, ...)` or `bench.zig.run(SimImpl, ...)`.

### 3.8 The golden-file correctness check

`src/framework/correctness.zig`:
- **Generate** (bench mode, stage 1 only): after 600 fixed steps with a fixed
  seed and `Desc{n=1024, seed=0xC0FFEE}`, dump a sorted, lex-comparable snapshot
  of `(pos.x, pos.y, pos.z, vel.x, vel.y, vel.z)` to `golden/stage1.bin`.
  Sorting means storage-order changes (stage 4's compaction, stage 5's sort-by-kind)
  don't count as failures — only numeric drift does.
- **Verify** (bench mode, any stage): load `golden/stage1.bin`, run the same
  600-step sequence, sort, compare element-wise within `eps = 1e-4`.
- **Print**: `PASS: matches stage1 golden (max delta = 3.2e-6)` or
  `FAIL: 1847 particles diverge (max delta = 0.42, first at index 312)`.
- The check is part of `bench` mode, not `play` mode (play is unbounded; its
  determinism is for visualization, not correctness).

This *proves* the central DOD claim: every stage reshapes data, none change math.

---

## 4. Acceptance criteria — every stage must satisfy

A stage is "done" when all of:

1. **Compiles** at `zig build -Dstage=N -Dmode=play` and `-Dmode=bench`, `-Doptimize=ReleaseFast`.
2. **Runs in play mode** without crashing for ≥ 60 seconds; window opens, particles
   render, HUD shows FPS + stage name + N.
3. **Runs in bench mode** to completion across the full N-sweep
   `{4K, 16K, 65K, 262K, 1M, 4M}`, printing a results table.
4. **Passes the golden-file correctness check** (vs stage 1, `eps=1e-4`).
5. **Reports** the expected directional perf change vs the previous stage
   (e.g. stage 3 must be faster than stage 2 at N≥1M; if not, the implementation
   is wrong even if it passes correctness — the layout transformation didn't land).
6. **Has a clear `git diff`** from the prior stage's `sim.zig` — the change is
   readable in under 5 minutes and matches the stage's "DOD transformation" spec.

---

## 5. Per-stage specifications

Each stage below specifies: the problem it addresses, the naive prior approach,
the DOD transformation, the expected measurable outcome, the acceptance test,
and the DOD principle(s) illustrated.

The simulation domain (fixed across all stages):

```
For each particle, each frame:
  1. Integrate:   pos += vel * dt
  2. Forces:      vel += (gravity + drag*vel + impulse[kind]) * dt
  3. Age:         age += dt
  4. Kill:        if age >= kill_age  -> respawn (stages 1-3) / compact out (4+)
  5. Render:      splat pos,color,size into RGBA framebuffer
```

The particle's full field set, with usage cadence:

| field    | type | touched every frame?    | used by        |
|----------|------|-------------------------|----------------|
| pos      | Vec3 | yes (integrate+render)  | update, render |
| vel      | Vec3 | yes (integrate+forces)  | update         |
| life     | f32  | yes (kill test)         | update         |
| age      | f32  | yes                     | update         |
| color    | Vec4 | render only             | render         |
| size     | f32  | render only             | render         |
| rotation | f32  | render only             | render         |
| mass     | f32  | rarely (impulse events) | update (rare)  |
| flags    | u8   | spawn-time only         | spawn          |
| kind     | u8   | dispatch                | update         |
| seed     | u32  | spawn-time only         | spawn          |

3 fields hot every frame; the rest cold or rare. That asymmetry is the seed of
the whole lesson.

---

### Stage 0 — Benchmark harness & framework scaffolding

**Problem.** DOD is empirical; without numbers, every claim is vibes.
**Approach.** Build the measuring rig before any particles.
- `framework/bench.zig`: takes a `Sim` type, runs `M` steps over `N` particles
  for each N in the sweep, times via `Io.Timestamp.now(io, .awake)`, prints a table:
  `N | ns/frame | ns/particle | frames/sec | bytes-touched/frame (analytic)`.
- `framework/hardware.zig`: shells `sysctl`, prints cache facts.
- `framework/correctness.zig`: golden-file write (stage 1) / verify (others).
- `framework/play.zig`: raylib window loop, HUD, live keys.
- `framework/config.zig`, `framework/sim.zig`, `framework/render.zig`, `framework/vec.zig`.
- `src/bindings/raylib.zig`, `src/bindings/stb.zig`, `src/stb_impl.c`.
- `build.zig` with `-Dstage`/`-Dmode` plumbing and raylib C compilation.
- A no-op `stages/01_naive/sim.zig` that returns from `step` immediately — just
  to prove the rig end-to-end.
**Acceptance.** `zig build -Dstage=1 -Dmode=bench` prints a hardware block + an
empty results table; `zig build -Dstage=1 -Dmode=play` opens a black window.
**Principles.** none yet — this is the ruler.

---

### Stage 1 — The naive baseline (the strawman)

**Problem.** Build the "OOP brain" version on purpose. This is the villain.
**DOD transformation.** None — this is the line every later stage must beat.
**Implementation.**
```zig
const Particle = struct {
    pos: Vec3, vel: Vec3, life: f32, age: f32,
    color: Vec4, size: f32, rotation: f32, mass: f32,
    flags: u8, kind: u8, seed: u32,
};
var particles: []Particle;  // one AoS array
// step: for (particles) |*p| { integrate; forces; age; if (kill) respawn(p); }
//       with switch (p.kind) { .smoke => smoke_update(p), ... } inside the loop
```
Touches every field of every particle every frame, including `mass`/`flags`/`seed`
which the frame doesn't use. Per-particle `switch (kind)` is a deliberate hot
branch. `if (age >= kill_age) respawn(p)` is branchy in-place mutation.
Also generate the **golden file** in this stage (it's the reference for all others).
**Expected outcome.** Baseline ns/particle at each N. Analytically compute
`sizeof(Particle)` (likely ~80–96 B with padding) and the bytes-touched/frame.
You'll see the math *needs* ~28 B/frame but the loop walks ~80 B.
**Acceptance.** Compiles, runs, golden file written, baseline numbers recorded.
**Principles.** (sets up all of them — the strawman to be slain)

---

### Stage 2 — Hot/cold split (first real DOD move)

**Problem.** Stage 1 drags render-only and rare fields through the hot update loop.
**DOD transformation.** Keep AoS, but split the struct:
```zig
const ParticleHot  = struct { pos, vel, life, age };        // ~28 B
const ParticleCold = struct { color, size, rotation, mass, flags, kind, seed };
var hot:  []ParticleHot;
var cold: []ParticleCold;   // parallel array, same indices
```
Update loop walks `hot` only. Render walks `cold` (and reads `hot.pos`).
**Expected outcome.** Measurable ns/frame drop at N≥65K even though the math is
identical. The win is purely "we stopped dragging ~50 cold bytes/particle through L1."
**Acceptance.** Passes golden check; faster than stage 1 at N≥65K.
**Principles.** P2, P3.

---

### Stage 3 — AoS → SoA (the flagship transformation)

**Problem.** `[]ParticleHot` is still AoS; each cache line holds 4–5 hot particles
but we touch only one field at a time per particle, wasting cache bandwidth.
**DOD transformation.** Turn `[]ParticleHot` into parallel per-field arrays:
```zig
var pos_x, pos_y, pos_z: []f32;
var vel_x, vel_y, vel_z: []f32;
var life, age:           []f32;
```
The integrate loop becomes three tight loops over single streams.
**Expected outcome.** Large ns/particle drop at N≥1M. At small N both fit in L1
(AoS vs SoA is noise); at 1M+, SoA touches ~24 B/particle at high density vs AoS's
~80 B. **Plot ns/particle vs N for stages 1, 2, 3 on one graph** — the three
curves separating as N grows is the visual punchline of the whole project.
**Acceptance.** Passes golden; at N=1M, stage 3 < stage 2 ns/particle.
**Principles.** P1, P4.

---

### Stage 4 — Branchless compaction (kill the kill-branch)

**Problem.** Stages 1–3 respawn dead particles in place. Real systems need
uneven births/deaths, and naive `if alive then copy` is a branchy, unpredictable scan.
**DOD transformation.** Maintain an `alive: []u8` parallel to the hot arrays.
Two-pass:
1. Write `alive[i] = @intFromBool(age[i] < kill_age)` — no branch, just compare.
2. Compact via either (a) stream compaction with `@popCount`/prefix sum, or
   (b) swap-remove (move last live into dead slot, shrink len) — O(dead).
Compare both; also run with adversarial alive patterns (every-other alive —
worst case for branch prediction) to show the branchy version's cliff.
**Expected outcome.** Branchy scan vs count-then-compact vs swap-remove; the
branchless versions hold up under adversarial patterns where branchy collapses.
**Acceptance.** Passes golden (sort tolerates reordering); at adversarial alive
pattern, stage 4 branchless ≪ stage 4 branchy.
**Principles.** P5.

---

### Stage 5 — Sort by kind / split by kind (de-virtualize)

**Problem.** Stage 1's per-particle `switch (kind)` is a hot branch awful for the
predictor (kinds interleaved).
**DOD transformation.** Two variants, compare both:
- **(a) Sort by kind, then iterate each kind's contiguous run separately.**
  Each inner loop has constant behavior — no switch; the loop body is specialized.
- **(b) Split into per-kind streams** (`smoke.pos[]`, `spark.pos[]`, …). No dispatch
  at all — the dispatch moved out of the loop into the data layout.
**Expected outcome.** Both beat the stage-1 switch; (b) usually wins. Code gets
simpler — "removing code made it faster."
**Acceptance.** Passes golden; faster than stage 3 at all N.
**Principles.** P6.

---

### Stage 6 — SIMD vectorization

**Problem.** SoA + scalar is cache-friendly but doesn't use the FPU's lanes.
**DOD transformation.** Exploit that `pos_x`, `vel_x` are contiguous float streams:
```zig
const V = @Vector(8, f32);
const vdt: V = @splat(dt);
// 8 particles' x-components at once:
@as(*[8]f32, @ptrCast(&pos_x[i])).* =
    @as(V, pos_x[i..][0..8].*) + @as(V, vel_x[i..][0..8].*) * vdt;
```
Try `@Vector(4)`, `@Vector(8)`, `@Vector(16)`; find where the machine stops
benefiting. Compare to autovectorized scalar (inspect asm with `objdump -d`).
**Expected outcome.** ~2–4× over scalar-SoA on the math, *until* memory bandwidth
becomes the limit. The through-line: **the byte-reduction in stages 2–3 is what
unlocked the SIMD win here** — SIMD is a reward for layout, not a substitute.
**Acceptance.** Passes golden; stage 6 < stage 5 ns/particle at N≥65K.
**Principles.** P4, P7.

---

### Stage 7 — Alignment, padding, sizing to the cache line

**Problem.** Stage 6's streams aren't aligned; tails cause extra work; tile sizes
are arbitrary.
**DOD transformation.** Use the hardware facts from `framework/hardware.zig`:
- Align each stream to 128 B (`std.mem.alignAlloc` / `@alignOf`).
- Pad stream lengths to a multiple of the SIMD width (no tail branch).
- Tile the loop in chunks of 128 particles (one `alive` bitset line = one cache
  line) — show "tile = index cache line" is a sweet spot.
- Size the hot block per particle deliberately: 8 floats = 32 B = ¼ line → 4 hot
  particles per line. Try variations, measure.
**Expected outcome.** A clear minimum in ns/particle at "one hot tile = one line,"
worse on either side. The B-tree-node-size lesson, applied to a flat array.
**Acceptance.** Passes golden; stage 7 < stage 6 ns/particle; the alignment sweep
shows a visible minimum.
**Principles.** P8.

---

### Stage 8 — Allocators & streaming

**Problem.** Stages 1–7 preallocate. Real systems have spawn churn; naive `alloc`
per particle destroys cache locality and adds lock contention.
**DOD transformation.** Compare allocators under a spawn-heavy workload (50%
die/frame):
- Naive: `allocator.alloc` per spawn.
- Arena: one arena for the frame's spawns, bulk-reset at frame end.
- Free-list: fixed-capacity, dead slots reused by respawn.
- Double-buffer: write new alive list into buffer B while reading A, swap at end
  (also makes compaction trivial and branchless).
**Expected outcome.** Allocator differences often larger than all layout work in
stages 2–6 combined. A bracing but true lesson.
**Acceptance.** Passes golden; arena/free-list/double-buffer all ≪ naive at
high churn; double-buffer ≈ branchless compaction (ties stage 4's lesson).
**Principles.** P9.

---

### Stage 9 — Synthesis: the full DOD version

**Problem.** Each stage was isolated; do they compose?
**DOD transformation.** Compose every winner from 2–8:
- SoA hot streams, cold streams separate (2, 3)
- Per-kind separated streams (5b)
- Branchless double-buffer compaction (4 + 8)
- `@Vector(8, f32)` update (6)
- 128 B aligned, tile-sized to line (7)
- Arena-allocated, no per-frame heap (8)
**Expected outcome.** Re-run the full N-sweep, print cumulative speedup table:
stage 9 vs stage 1 at each N. Expect ~8–15× at N=1M, more at 4M, *diminishing
below 65K* — and the plan says so explicitly. DOD pays off at scale.
**Acceptance.** Passes golden; the cumulative ratio is roughly the product of the
per-stage ratios (each move was independent and measurable).
**Principles.** P10.

---

### Stage 10 — Bonus: optimize the rasterizer

**Problem.** The renderer has been a fixed shared module; it's data too.
**DOD transformation.** Override `framework/render.zig` with
`stages/10_rasterizer/render.zig` (stage 10's `sim.zig` just re-exports stage 9's
`Sim`). Optimize additive blending:
- Splats as packed RGBA, blended with clamped add.
- SIMD across 4 or 8 pixels at once.
- Tile the framebuffer to 128 B to match the cache line.
- Compare naive (per-pixel, per-splat, branchy) vs SIMD-vs-tiled.
**Expected outcome.** Higher play-mode FPS; render cost measurable separately
from sim cost.
**Acceptance.** `zig build -Dstage=10 -Dmode=play` runs at ≥ stage 9's FPS;
render-time benchmark (if added to `bench` mode behind a flag) shows the win.
**Principles.** P11.

---

### Stage 11 — Bonus: `--record` video export

**Problem.** Sometimes you want a shareable MP4, not an interactive game.
**DOD transformation.** Add a `--record out/` flag to `bench` mode (stage 11's
`sim.zig` re-exports stage 9's `Sim`): run headless for 600 fixed steps, call
`render()` each step, write PNGs via `stb_image_write` to `out/frames/`, then
shell out to `ffmpeg` to encode `out/video.mp4`.
**Expected outcome.** A deterministic, reproducible MP4 of the stage 9 sim.
**Acceptance.** `zig build -Dstage=11 -Dmode=bench -- --record out/` produces
`out/video.mp4` (30fps, 10s, 1024²) that matches the play-mode visualization.
**Principles.** P12 (determinism enables replay/export).

---

## 6. Build & run cheat sheet

```sh
# First time: init submodules
git submodule update --init --recursive

# Play (interactive game)
zig build -Dstage=1 -Dmode=play                       # the strawman
zig build -Dstage=3 -Dmode=play -Doptimize=ReleaseFast
zig build -Dstage=9 -Dmode=play -Doptimize=ReleaseFast   # full synthesis

# Bench (headless, no raylib, pure numbers + correctness check)
zig build -Dstage=1 -Dmode=bench -Doptimize=ReleaseFast   # also writes golden file
zig build -Dstage=3 -Dmode=bench -Doptimize=ReleaseFast

# Live in-game keys (play mode):
#   ←/→     shrink/grow N
#   1-9     switch stage (rebuilds Sim from current layout — needs recompile
#           for true stage switch; for runtime demo, 1-9 cycle N presets)
#   P       pause
#   F1      toggle HUD
#   ESC     quit

# Bonus
zig build -Dstage=10 -Dmode=play -Doptimize=ReleaseFast  # optimized render
zig build -Dstage=11 -Dmode=bench -Doptimize=ReleaseFast -- --record out/
```

Note: runtime stage-switching via hotkey (the `1-9` keys) requires either
recompiling per stage (the comptime-generic design) or, for a true live demo,
building a special "all stages" binary that links all 9 `Sim` types and switches
via a tagged union. That's a stretch goal, not in the acceptance criteria; the
default is recompile-per-stage, which is fast.

---

## 7. Deliverable checklist

For handoff, the project is complete when:

- [ ] `build.zig` + `build.zig.zon` work on Zig 0.17-dev + Apple M4.
- [ ] `vendor/stb` and `vendor/raylib` (pinned to 6.0) are submodules.
- [ ] `src/framework/*` is complete and shared across all stages.
- [ ] `src/bindings/raylib.zig` and `src/bindings/stb.zig` are minimal and correct.
- [ ] Stages 1–9 each have `sim.zig`, pass acceptance (§4), and the `git diff`
      from the prior stage is a readable, single-file DOD lesson.
- [ ] `golden/stage1.bin` is checked in; every later stage passes the check.
- [ ] A `RESULTS.md` (generated by bench runs, or hand-filled) records the
      cumulative speedup table across stages.
- [ ] Stages 10–11 are implemented as bonuses.
- [ ] This `plan.md` lives at the repo root and is the source of truth.

---

## 8. The narrative arc

Read top to bottom, the toy tells this story:

> The object was a lie. There was never a "Particle" — there were five loops
> that touched overlapping subsets of its fields. When we laid out memory for
> the loops instead of for the concept, the loops got 10× faster and the code
> got simpler. We didn't invent anything; we stopped paying for bytes we never
> read.

That's the whole talk, in one toy, in eleven measurable steps — and you can play it.
