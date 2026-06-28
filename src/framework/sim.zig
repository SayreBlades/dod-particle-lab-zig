// The Sim interface contract.
//
// No vtable: the driver is generic over a concrete Sim type chosen at compile
// time. Each stage's sim.zig exposes a `pub const Sim = struct { ... }` with
// these methods. (Stage 5 teaches that per-particle vtables are bad; we must
// not use one ourselves at the per-frame boundary either — generics let us
// skip the question entirely.)

const std = @import("std");
const vec = @import("vec.zig");

pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;

pub const ParticleKind = enum(u8) { smoke, spark, debris };

pub const Desc = struct {
    n: usize,
    seed: u64,
    // physics params are NOT here — they live in config.zig, shared, so every
    // stage's math is provably identical. Desc only describes population/seed.
};

/// Each stage's Sim must expose:
///   pub const Sim = struct {
///       <stage-specific fields — the layout IS the lesson>
///       pub fn init(alloc: std.mem.Allocator, desc: Desc) anyerror!*@This();
///       pub fn step(self: *@This(), dt: f32) void;
///       pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void;
///       pub fn deinit(self: *@This()) void;
///   };
///
/// `name` is a short stage label for the HUD.
pub fn stageName(comptime n: u32) []const u8 {
    return switch (n) {
        1 => "Stage 1: naive",
        2 => "Stage 2: hot/cold",
        3 => "Stage 3: SoA",
        4 => "Stage 4: compact",
        5 => "Stage 5: sort-by-kind",
        6 => "Stage 6: SIMD",
        7 => "Stage 7: align",
        8 => "Stage 8: alloc",
        9 => "Stage 9: synthesis",
        10 => "Stage 10: rasterizer",
        11 => "Stage 11: record",
        else => "Stage ?: unknown",
    };
}
