# DOD Particle Lab — Zig

A hands-on laboratory for *feeling* the cache/perf lessons from Mike Acton's
CppCon 2014 talk, ["Data-Oriented Design and C++"](https://www.youtube.com/watch?v=rX0ItVEVjHc),
implemented as an interactive **raylib game** in Zig on Apple Silicon.

The thesis, in one sentence: *the object was a lie.* There was never a "Particle"
— there were five loops that touched overlapping subsets of its fields. When we
laid out memory for the loops instead of for the concept, the loops got 10× faster
and the code got simpler. This lab walks through that transformation in stages;
the math never changes between stages, only the data layout and access pattern do.

**Status:** Stage 0 of 9 — last landed C1 (window opens with HUD)

## Quick start

```sh
git submodule update --init --recursive

# Build + launch the interactive game (opens a 1024×1024 window)
zig build run -Dstage=1 -Dmode=play -Doptimize=ReleaseFast

# Or build only, then run manually:
#   zig build -Dstage=1 -Dmode=play -Doptimize=ReleaseFast
#   ./zig-out/bin/dod-particles

# Headless benchmark + correctness check (no window) — lands at C3
#   zig build run -Dstage=1 -Dmode=bench -Doptimize=ReleaseFast
```

`-Dstage` selects the data layout (1–11); `-Dmode` selects the driver
(`play` = window, `bench` = numbers). `run` is a build step that builds
and executes; without it, `zig build` only builds to `zig-out/bin/`.

## Checkpoints

| #  | Checkpoint                                  | Stage | Complete |
|----|---------------------------------------------|-------|----------|
| C1 | Window opens with HUD (raylib+build proven) | 0     | [x]      |
| C2 | Particles render and move                   | 1     | [ ]      |
| C3 | Bench mode works + golden file generated    | 0,1   | [ ]      |
| C4 | Stage 1 fully passes acceptance (baseline)  | 1     | [ ]      |
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
