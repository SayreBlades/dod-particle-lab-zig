// audit.zig — the data-density audit driver (Acton's zip-test).
//
// Reference: Mike Acton, "Data-Oriented Design and C++", CppCon 2014 (~49:38).
// He printed the per-element values of a field (a `is_spawn` bool) and zipped
// the output. gzip is an entropy oracle: a lossless compressor cannot shrink a
// stream below its information content, so the compression ratio is a
// lower-bound estimate of a field's information density.
//
//   - low density  → the field is redundant per-particle (constant / a handful
//     of distinct values). Storing it per-element drags bytes through cache for
//     zero signal. Candidate to leave the hot loop, stop existing per-particle,
//     or become a lookup.
//   - high density → the field carries real signal. Leave it alone.
//
// This driver runs the SAME fixed seed + steps the golden check uses, then
// asks the Sim to dump each field's raw bytes (layout-aware — stage 1 strides
// an AoS array, stage 3 will emit per-component SoA streams), pipes each
// through `gzip -c`, and tabulates the density. It links no raylib, opens no
// window, and never touches the hot path — it is a *context* instrument, not
// an acceptance gate.
//
// The headline number is the size-weighted mean density of the fields the hot
// loop touches. Stage 1 touches every field (strawman), so its mean is dragged
// down by a pile of constants (size/rotation/mass/flags/life) and a 3-value
// kind. Stages 2–9 should drive this number UP as cold/constant fields leave the
// hot loop — the qualitative twin of ns/particle falling.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");
const hardware = @import("hardware.zig");

// Same population/seed/duration as the golden check, so the audit samples the
// exact state the correctness gate verifies.
const AUDIT_N: usize = 1024;
const AUDIT_STEPS: usize = 600;
const TEMP_PATH = ".scratch/audit/field.bin";

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // Hardware block — same ritual as bench: never let the reader forget the
    // platform the density numbers are measured against.
    const facts = hardware.detect();
    hardware.print(facts);

    // Bring the sim to the same state the golden check captures.
    var sim = try SimImpl.init(alloc, .{ .n = AUDIT_N, .seed = config.spawn_seed });
    defer sim.deinit();
    var i: usize = 0;
    while (i < AUDIT_STEPS) : (i += 1) sim.step(config.dt);

    const fields = try sim.dumpFields(alloc);
    defer {
        for (fields) |f| alloc.free(f.bytes);
        alloc.free(fields);
    }

    std.debug.print("=== Data-density audit (Acton zip-test) ===\n", .{});
    std.debug.print("  sim: {s}, N={d}, steps={d} (post-step snapshot)\n", .{
        fw.stageName(@import("options").stage), AUDIT_N, AUDIT_STEPS,
    });
    std.debug.print("  oracle: gzip -c (lower bound on information content)\n\n", .{});

    std.debug.print("  {s:>10} | {s:>10} | {s:>10} | {s:>9} | {s:>13}\n", .{
        "field", "raw(B)", "gz(B)", "density", "bits/byte(8*d)",
    });
    std.debug.print("  {s:-<10}-+-{s:-<10}-+-{s:-<10}-+-{s:-<9}-+-{s:-<13}\n", .{
        "", "", "", "", "",
    });

    var total_raw: u64 = 0;
    var total_gz: u64 = 0;

    for (fields) |f| {
        const raw_len: u64 = f.bytes.len;
        const gz_len: u64 = gzipLen(io, alloc, f.bytes) catch |e| {
            std.debug.print("  {s:>10} | (gzip failed: {t})\n", .{ f.name, e });
            continue;
        };
        total_raw += raw_len;
        total_gz += gz_len;
        const density: f64 = @as(f64, @floatFromInt(gz_len)) / @as(f64, @floatFromInt(@max(raw_len, 1)));
        const bits_per_byte: f64 = 8.0 * density;
        std.debug.print("  {s:>10} | {d:>10} | {d:>10} | {d:>9.3} | {d:>13.2}\n", .{
            f.name, raw_len, gz_len, density, bits_per_byte,
        });
    }

    const mean_density: f64 = @as(f64, @floatFromInt(total_gz)) / @as(f64, @floatFromInt(@max(total_raw, 1)));
    const mean_bits: f64 = 8.0 * mean_density;
    std.debug.print("  {s:-<10}-+-{s:-<10}-+-{s:-<10}-+-{s:-<9}-+-{s:-<13}\n", .{
        "", "", "", "", "",
    });
    std.debug.print("  {s:>10} | {d:>10} | {d:>10} | {d:>9.3} | {d:>13.2}\n", .{
        "MEAN*", total_raw, total_gz, mean_density, mean_bits,
    });
    std.debug.print("\n  * MEAN = size-weighted over all dumped fields.\n", .{});
    std.debug.print("    dumpFields reports only the fields step() actually touches (the\n", .{});
    std.debug.print("    hot-loop footprint); cold/constant fields leave the dump as they\n", .{});
    std.debug.print("    leave the hot loop. Stages 2-9 should drive MEAN density UP\n", .{});
    std.debug.print("    (reclaimed entropy ≈ reclaimed bandwidth) — the qualitative twin\n", .{});
    std.debug.print("    of ns/particle falling.\n", .{});
}

/// Pipe `bytes` through `gzip -c` and return the compressed length.
/// Uses a temp file under .scratch/audit/ (gitignored) so gzip reads from a
/// path argument — quick and dirty, faithful to Acton's "print it, zip it".
fn gzipLen(io: Io, alloc: std.mem.Allocator, bytes: []const u8) !u64 {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, ".scratch/audit") catch {};

    {
        var f = try dir.createFile(io, TEMP_PATH, .{});
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.end();
        f.close(io);
    }

    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "gzip", "-c", TEMP_PATH },
        .stdout_limit = .limited(1 << 30),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    dir.deleteFile(io, TEMP_PATH) catch {};

    return result.stdout.len;
}
