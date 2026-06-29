// bench driver: headless, no window, no raylib. Sweeps N, times Sim.step()
// only, runs the golden-file correctness check. Prints a results table.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const correctness = @import("correctness.zig");

const SWEEP = [_]usize{ 4_000, 16_000, 65_000, 262_000, 1_000_000, 4_000_000 };
const ITERS: usize = 200;
const GOLDEN_STEPS: usize = 600;
const GOLDEN_N: usize = 1024;
const EPS: f32 = 1e-4;
const GOLDEN_PATH = "golden/stage1.bin";

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // --- hardware block ---
    const facts = hardware.detect();
    hardware.print(facts);

    // --- correctness: generate (stage 1) or verify ---
    const stage_n = @import("options").stage;
    const is_reference = (stage_n == 1);

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

    // --- benchmark sweep ---
    std.debug.print("=== Benchmark (iters={d} per N) ===\n", .{ITERS});
    std.debug.print("  {s:>10} | {s:>14} | {s:>14} | {s:>12}\n", .{ "N", "ns/frame", "ns/particle", "frames/sec" });
    std.debug.print("  {s:-<10}-+-{s:-<14}-+-{s:-<14}-+-{s:-<12}\n", .{ "", "", "", "" });

    for (SWEEP) |n| {
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        // warmup
        var w: usize = 0;
        while (w < 10) : (w += 1) sim.step(config.dt);

        const t0 = Io.Timestamp.now(io, .awake);
        var it: usize = 0;
        while (it < ITERS) : (it += 1) sim.step(config.dt);
        const t1 = Io.Timestamp.now(io, .awake);
        const ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
        const ns_per_frame = ns / @as(f64, @floatFromInt(ITERS));
        const ns_per_particle = ns_per_frame / @as(f64, @floatFromInt(n));
        const frames_sec = 1e9 / ns_per_frame;
        std.debug.print("  {d:>10} | {d:>14.1} | {d:>14.3} | {d:>12.1}\n", .{
            n, ns_per_frame, ns_per_particle, frames_sec,
        });
    }
}
