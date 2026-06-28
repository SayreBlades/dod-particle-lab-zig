# DOD Particle Lab — Zig

A hands-on laboratory for *feeling* the cache/perf lessons from Mike Acton's
CppCon 2014 talk, ["Data-Oriented Design and C++"](https://www.youtube.com/watch?v=rX0ItVEVjHc),
implemented as an interactive **raylib game** in Zig on Apple Silicon.

The thesis, in one sentence: *the object was a lie.* There was never a "Particle"
— there were five loops that touched overlapping subsets of its fields. When we
laid out memory for the loops instead of for the concept, the loops got 10× faster
and the code got simpler. This lab walks through that transformation in 11
measurable stages; the math never changes between stages, only the data layout
and access pattern do.

**Status:** Stage 0 of 9 — last landed C1

## Checkpoints

Progress mirror of §0 in the [full plan](.scratch/plan/plan.md). Checkboxes link
to the evidence report for each checkpoint.

| #  | Checkpoint                                  | Stage | Complete |
|----|---------------------------------------------|-------|----------|
| C1 | Window opens with HUD (raylib+build proven) | 0     | [x](.scratch/plan/evidence/C1.md) |
| C2 | Particles render and move                   | 1     | [ ]()    |
| C3 | Bench mode works + golden file generated    | 0,1   | [ ]()    |
| C4 | Stage 1 fully passes acceptance (baseline)  | 1     | [ ]()    |
| C5 | Stage 2 (hot/cold) — first measured DOD win | 2     | [ ]()    |
| C6 | Stage 3 (SoA) — flagship transformation     | 3     | [ ]()    |
| C7 | Stages 4–9 each pass acceptance             | 4–9   | [ ]()    |
| C8 | Synthesis verified, RESULTS.md recorded     | 9     | [ ]()    |
| C9 | Bonus stages (rasterizer + video export)    | 10,11 | [ ]()    |

## Quick start

```sh
git submodule update --init --recursive

# Interactive game
zig build -Dstage=1 -Dmode=play -Doptimize=ReleaseFast

# Headless benchmark + correctness check (no window)
zig build -Dstage=1 -Dmode=bench -Doptimize=ReleaseFast
```

Stage selects the data layout (1–11); mode selects the driver (`play` = window,
`bench` = numbers). Full cheat sheet in [plan §6](.scratch/plan/plan.md).

## Layout

```
build.zig, src/, vendor/     # the project
.scratch/plan/               # design + evidence (this is the source of truth)
├── plan.md                  # full design, stages, acceptance criteria
├── evidence/CN.md           # per-checkpoint proof (created on landing)
└── RESULTS.md               # cumulative speedup table (created at C8)
```

The full design lives in [`plan.md`](.scratch/plan/plan.md); this README is the
door, not the room. Design detail belongs in the plan, never here.

## Hardware target

Apple M4 — 128 B cache line, 64 KB L1d, 4 MB L2, 16 KB page, NEON. The framework
prints these facts at the start of every run; DOD only makes sense relative to
concrete cache/memory facts. See [plan §2](.scratch/plan/plan.md).
