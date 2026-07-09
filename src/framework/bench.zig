// bench driver: headless, no window, no raylib. Sweeps N, times Sim.step()
// only, runs the golden-file correctness check. Prints a results table.
//
// Timing model:
//   - warmup: 10 steps (prime caches/branch predictors/battery clock).
//   - trial: ITERS steps, timed with Io.Timestamp (.awake = wall + CPU).
//   - trials per N: TRIALS, keep the MIN ns/frame (the cleanest sample — least
//     perturbed by interrupts, scheduling, DVFS transients). Max is also printed
//     so drift/noise is visible at a glance; if min≈max the number is stable.
//
// Columns:
//   N          particle count
//   bytes/p    hot-loop bytes touched per particle (sim.bytesPerParticle)
//   mem(MB)    N * bytes/p  — the per-frame working set
//   ns/particle (min)       cleanest per-particle cost
//   ns/frame (min)          cleanest per-frame cost
//   frames/sec (min)        1e9 / ns/frame
//   GB/s eff   N*bytes/p / ns/frame — effective hot-loop bandwidth. Compare to
//              the DRAM ceiling to see whether a stage is bandwidth-bound
//              (near ceiling) or compute/latency-bound (well below).
//   runtime(ms) (total)    TRIALS*ITERS + warmup wall time spent at this N
//
// The final TOTAL row sums the runtime(ms) column = the wall time of the whole
// sweep (correctness + bench), so you can see what the bench *cost*.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const correctness = @import("correctness.zig");

const SWEEP = [_]usize{ 4_000, 16_000, 65_000, 262_000, 1_000_000, 4_000_000, 16_000_000, 64_000_000 };
const ITERS: usize = 200;
const WARMUP: usize = 10;
const TRIALS: usize = 3;
const GOLDEN_STEPS: usize = 600;
const GOLDEN_N: usize = 1024;
const EPS: f32 = 1e-4;
const GOLDEN_PATH = "golden/stage1.bin";

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // Parse runtime args: --n <N> and --iters <K>. When --n is present, run
    // a single N only (no sweep, no golden check) — this is the PMC mode:
    // the whole process is a clean step() region for xctrace to wrap.
    var single_n: ?usize = null;
    var single_iters: ?usize = null;
    {
        var it_opt: ?std.process.Args.Iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, alloc) catch null;
        if (it_opt) |*it| {
            defer it.deinit();
            _ = it.next(); // skip program name
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--n")) {
                    if (it.next()) |val| single_n = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--iters")) {
                    if (it.next()) |val| single_iters = std.fmt.parseInt(usize, val, 10) catch null;
                }
            }
        }
    }
    const pmc_mode = single_n != null;

    // --- hardware block ---
    const facts = hardware.detect();
    hardware.print(facts);

    // --- correctness: generate (stage 1) or verify ---
    const stage_n = @import("options").stage;
    const is_reference = (stage_n == 1);

    if (!pmc_mode) {
        if (is_reference) {
            std.debug.print("=== Correctness: generating golden file ===\n", .{});
            const snap = try correctness.capture(SimImpl, alloc, .{ .n = GOLDEN_N, .seed = config.spawn_seed }, GOLDEN_STEPS, config.dt);
            defer alloc.free(snap.floats);
            try correctness.writeGolden(GOLDEN_PATH, snap, io);
            std.debug.print("  wrote {s} (n={d}, steps={d})\n\n", .{ GOLDEN_PATH, snap.n, GOLDEN_STEPS });
        }

        // verify (every stage, including stage 1 self-check after generating)
        {
            const golden = try correctness.loadGolden(GOLDEN_PATH, alloc, io);
            defer alloc.free(golden.floats);
            const cand = try correctness.capture(SimImpl, alloc, .{ .n = GOLDEN_N, .seed = config.spawn_seed }, GOLDEN_STEPS, config.dt);
            defer alloc.free(cand.floats);
            const r = correctness.compare(golden, cand, EPS);
            if (r.passed) {
                std.debug.print("=== Correctness: PASS (max delta = {d:.2}) ===\n\n", .{r.max_delta});
            } else {
                std.debug.print("=== Correctness: FAIL ===\n", .{});
                std.debug.print("  {d} floats diverge (max delta = {d:.2}, first at index {d})\n\n", .{ r.divergent_count, r.max_delta, r.first_divergent_index });
            }
        }
    }

    // --- benchmark sweep ---
    const sweep_t0 = Io.Timestamp.now(io, .awake);
    const iters = if (single_iters) |i| i else ITERS;
    const sweep_list: []const usize = if (single_n) |n| &.{n} else &SWEEP;
    std.debug.print("=== Benchmark (iters={d}, warmup={d}, trials={d} per N; reporting min){s}\n", .{ iters, WARMUP, TRIALS, if (pmc_mode) " [PMC mode]" else "" });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {s:>11}\n", .{
        "N", "bytes/p", "mem(MB)", "ns/particle(min)", "ns/frame(min)", "frames/sec", "GB/s eff", "runtime(ms)",
    });
    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<8}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "", "",
    });

    var total_runtime_ms: f64 = 0;
    var total_frames: u64 = 0;

    for (sweep_list) |n| {
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        const bytes_per_p = sim.bytesPerParticle();
        const working_set_bytes: u64 = @as(u64, n) * bytes_per_p;
        const working_set_mb: f64 = @as(f64, @floatFromInt(working_set_bytes)) / (1024.0 * 1024.0);

        // Time TRIALS independent runs of (warmup + ITERS), keep min ns/frame.
        // Each run includes its own warmup so the min reflects a fully-primed
        // cache state; runtime(ms) sums all trials (the real bench cost).
        var min_ns_frame: f64 = std.math.inf(f64);
        var max_ns_frame: f64 = 0;
        var trial_runtime_ns: f64 = 0;

        var trial: usize = 0;
        while (trial < TRIALS) : (trial += 1) {
            // warmup
            var w: usize = 0;
            while (w < WARMUP) : (w += 1) sim.step(config.dt);

            const t0 = Io.Timestamp.now(io, .awake);
            var it: usize = 0;
            while (it < iters) : (it += 1) sim.step(config.dt);
            const t1 = Io.Timestamp.now(io, .awake);
            const ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
            trial_runtime_ns += ns;
            const ns_frame: f64 = ns / @as(f64, @floatFromInt(iters));
            if (ns_frame < min_ns_frame) min_ns_frame = ns_frame;
            if (ns_frame > max_ns_frame) max_ns_frame = ns_frame;
        }

        const ns_per_particle = min_ns_frame / @as(f64, @floatFromInt(n));
        const frames_sec = 1e9 / min_ns_frame;
        // effective hot-loop bandwidth = bytes touched per frame / time per frame.
        // 1 byte/ns == 1e9 bytes/s == 1 GB/s, so bytes/ns is GB/s directly.
        const gbs_eff: f64 = @as(f64, @floatFromInt(working_set_bytes)) / min_ns_frame;
        const runtime_ms: f64 = trial_runtime_ns / 1e6;
        total_runtime_ms += runtime_ms;
        total_frames += @as(u64, n) * iters * TRIALS;

        std.debug.print("  {d:>10} | {d:>7} | {d:>9.1} | {d:>14.3} | {d:>14.1} | {d:>11.1} | {d:>8.2} | {d:>11.1}\n", .{
            n, bytes_per_p, working_set_mb, ns_per_particle, min_ns_frame, frames_sec, gbs_eff, runtime_ms,
        });
    }

    const sweep_t1 = Io.Timestamp.now(io, .awake);
    const sweep_wall_ms: f64 = @as(f64, @floatFromInt(sweep_t0.durationTo(sweep_t1).nanoseconds)) / 1e6;

    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<8}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "", "",
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {d:>11.1}\n", .{
        "TOTAL", "", "", "", "", "", "sweep(ms):", total_runtime_ms,
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {d:>11.1}\n", .{
        "", "", "", "", "", "", "wall(ms):", sweep_wall_ms,
    });
    std.debug.print("\n  total particles-frames simulated: {d}\n", .{total_frames});
}
