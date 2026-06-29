// correctness.zig — golden-file element-wise check.
//
// Proves the DOD claim: every stage reshapes data, none change math.
//
// Snapshot = sorted array of (pos.xyz, vel.xyz) across all particles, after a
// fixed number of steps from a fixed seed. Sorting means storage-order changes
// (stage 4 compaction, stage 5 sort-by-kind) don't count as failures — only
// numeric drift does. Compared element-wise within eps.
//
// Stage 1 generates the golden file (it's the reference). Every later stage
// verifies against it.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");

pub const Snapshot = struct {
    // flattened: n particles * 6 floats (pos.xyz, vel.xyz)
    floats: []f32,
    n: usize,
};

pub const Result = struct {
    passed: bool,
    max_delta: f32,
    divergent_count: usize,
    first_divergent_index: usize,
};

/// Run `steps` fixed-step updates from a fresh sim seeded with `desc`, then
/// capture a sorted snapshot.
pub fn capture(
    comptime SimImpl: type,
    alloc: std.mem.Allocator,
    desc: fw.Desc,
    steps: usize,
    dt: f32,
) !Snapshot {
    var sim = try SimImpl.init(alloc, desc);
    defer sim.deinit();
    var i: usize = 0;
    while (i < steps) : (i += 1) sim.step(dt);
    return try snapshotFromSim(SimImpl, sim, alloc);
}

/// Build the snapshot by reading pos/vel out of the sim via its render-adjacent
/// accessor. Stages expose `snapshot()` returning a borrowed []const f32 of
/// n*6 floats; we copy + sort here.
pub fn snapshotFromSim(comptime SimImpl: type, sim: *SimImpl, alloc: std.mem.Allocator) !Snapshot {
    // Each stage must implement: pub fn snapshot(self: *const Sim, out: []f32) void
    // writing n*6 floats (px,py,pz,vx,vy,vz) per particle.
    const n = sim.n;
    const floats = try alloc.alloc(f32, n * 6);
    sim.snapshot(floats);
    // Sort so storage order doesn't matter.
    std.mem.sort(f32, floats, {}, lessThan);
    return .{ .floats = floats, .n = n };
}

fn lessThan(_: void, a: f32, b: f32) bool {
    // Bit-pattern compare for a stable, sign-correct total order.
    return std.math.order(a, b) == .lt;
}

pub fn writeGolden(path: []const u8, snap: Snapshot, io: Io) !void {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "golden") catch {};
    var f = try dir.createFile(io, path, .{});
    var io_buf: [4096]u8 = undefined;
    var w = f.writer(io, &io_buf);
    // header: magic + n
    try w.interface.writeAll("DODP\x01\x00\x00\x00");
    var n_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &n_buf, snap.n, .little);
    try w.interface.writeAll(&n_buf);
    for (snap.floats) |fl| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(fl), .little);
        try w.interface.writeAll(&buf);
    }
    try w.end();
    f.close(io);
}

pub fn loadGolden(path: []const u8, alloc: std.mem.Allocator, io: Io) !Snapshot {
    var dir = std.Io.Dir.cwd();
    var f = try dir.openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var io_buf: [4096]u8 = undefined;
    var r = f.reader(io, &io_buf);
    const rr = &r.interface;
    var magic: [8]u8 = undefined;
    try rr.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "DODP\x01\x00\x00\x00")) return error.BadMagic;
    var n_buf: [8]u8 = undefined;
    try rr.readSliceAll(&n_buf);
    const n = std.mem.readInt(u64, &n_buf, .little);
    const floats = try alloc.alloc(f32, @intCast(n * 6));
    var i: usize = 0;
    while (i < floats.len) : (i += 1) {
        var buf: [4]u8 = undefined;
        try rr.readSliceAll(&buf);
        floats[i] = @bitCast(std.mem.readInt(u32, &buf, .little));
    }
    return .{ .floats = floats, .n = @intCast(n) };
}

pub fn compare(golden: Snapshot, candidate: Snapshot, eps: f32) Result {
    if (golden.n != candidate.n) return .{
        .passed = false,
        .max_delta = std.math.inf(f32),
        .divergent_count = @max(golden.n, candidate.n),
        .first_divergent_index = 0,
    };
    var max_delta: f32 = 0;
    var divergent: usize = 0;
    var first: usize = 0;
    var i: usize = 0;
    while (i < golden.floats.len) : (i += 1) {
        const d = @abs(golden.floats[i] - candidate.floats[i]);
        if (d > max_delta) max_delta = d;
        if (d > eps) {
            if (divergent == 0) first = i;
            divergent += 1;
        }
    }
    return .{
        .passed = divergent == 0,
        .max_delta = max_delta,
        .divergent_count = divergent,
        .first_divergent_index = first,
    };
}
