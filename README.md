# DOD Particle Lab — Zig

A hands-on laboratory for *feeling* the cache/perf lessons from Mike Acton's
CppCon 2014 talk, ["Data-Oriented Design and C++"](https://www.youtube.com/watch?v=rX0ItVEVjHc),
implemented as an interactive **raylib game** in Zig on Apple Silicon.

The thesis, in one sentence: *the object was a lie.* There was never a "Particle"
— there were five loops that touched overlapping subsets of its fields. When we
laid out memory for the loops instead of for the concept, the loops got 10× faster
and the code got simpler. This lab walks through that transformation in stages;
the math never changes between stages, only the data layout and access pattern do.

**Status:** Stage 1 of 9 — last landed C4 (baseline locked, reference for all later stages)

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

### Reading the numbers

The whole project's payoff is watching `ns/particle` drop across stages.
Example (stage 1 baseline on M4):

```
           N |       ns/frame |    ns/particle |   frames/sec
        4000 |        11556.5 |          2.889 |      86531.7
      262000 |       338530.8 |          1.292 |       2953.9
     4000000 |      6477430.4 |          1.619 |        154.4
```

The curve dips (cache amortization) then rises (L2 spill). Stage 2 (hot/cold)
should nudge the whole curve down; stage 3 (SoA) drops it further; stage 9
(synthesis) should be ~8–15× lower than stage 1 at N=1M. If a stage's numbers
don't beat the prior stage's at large N, the implementation is wrong even
if correctness passes.

## Checkpoints

| #  | Checkpoint                                  | Stage | Complete |
|----|---------------------------------------------|-------|----------|
| C1 | Window opens with HUD (raylib+build proven) | 0     | [x]      |
| C2 | Particles render and move                   | 1     | [x]      |
| C3 | Bench mode works + golden file generated    | 0,1   | [x]      |
| C4 | Stage 1 fully passes acceptance (baseline)  | 1     | [x]      |
| C5 | Stage 2 (hot/cold) — first measured DOD win | 2     | [ ]      |
| C6 | Stage 3 (SoA) — flagship transformation     | 3     | [ ]      |
| C7 | Stages 4–9 each pass acceptance             | 4–9   | [ ]      |
| C8 | Synthesis verified, RESULTS recorded        | 9     | [ ]      |
| C9 | Bonus stages (rasterizer + video export)    | 10,11 | [ ]      |

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
hw.l1dcachesize    = 65536       (64 KB)
hw.l1icachesize    = 131072      (128 KB)
hw.l2cachesize     = 4194304     (4 MB)   ← benchmark sweep kink lives here
hw.pagesize        = 16384       (16 KB)
hw.memsize         = 17179869184  (16 GB)
SIMD               = NEON (128-bit → @Vector(4, f32) native; @Vector(8) = 2 ops)
```

The benchmark N-sweep `{4K, 16K, 65K, 262K, 1M, 4M}` is chosen so the L2
boundary (~524K hot particles at 8 B/hot-field) falls between 262K and 1M —
i.e. the cache spill shows up as a visible kink in the curve.

## Layout

```
build.zig, build.zig.zon      # build: -Dstage/-Dmode, raylib C compile
src/                          # the project
├── main.zig                  # comptime switch: stage -> SimImpl, mode -> driver
├── framework/                # shared across every stage
├── bindings/                 # minimal hand-written extern "c" (raylib)
└── stages/NN_name/sim.zig     # the ONLY file that changes between stages 1-9
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
