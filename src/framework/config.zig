// The single source of truth for physics. Imported by every stage's step().
// If two stages ever diverge on one of these, the golden-file test catches it.

const vec = @import("vec.zig");

pub const dt: f32 = 1.0 / 60.0;
pub const gravity: vec.Vec3 = .{ .x = 0, .y = -9.81, .z = 0 };
pub const drag: f32 = 0.01;
pub const kill_age: f32 = 4.0; // particle dies at age >= 4.0s
pub const spawn_seed: u64 = 0xC0FFEE;
pub const spawn_radius: f32 = 0.5;

// Per-kind impulse tables (lookup, not branch):
pub const impulse: [3]vec.Vec3 = .{
    .{ .x = 0, .y = 2.0, .z = 0 }, // smoke:  gentle up
    .{ .x = 3.0, .y = 4.0, .z = 0 }, // spark:   sharp diagonal
    .{ .x = 1.0, .y = 1.0, .z = 0.5 }, // debris:  slow scatter
};
