// The single source of truth for physics. Imported by every stage's step().
// If two stages ever diverge on one of these, the golden-file test catches it.
//
// MODEL (locked here so every stage shares it):
//   At spawn:  vel = impulse[kind] + jitter        (impulse is INITIAL velocity)
//   Per frame: vel += (gravity + drag*vel) * dt     (no impulse in the force)
//              pos += vel * dt
//              age += dt
//              if age >= kill_age: respawn
//
// impulse is a spawn-time initial velocity, NOT a continuous force. This gives
// proper ballistic arcs (fountain) instead of monotonic acceleration. The
// per-frame force is gravity + drag only.

const vec = @import("vec.zig");

pub const dt: f32 = 1.0 / 60.0;
pub const gravity: vec.Vec3 = .{ .x = 0, .y = -1.0, .z = 0 }; // gentle, unit-world scale
pub const drag: f32 = 0.02;
pub const kill_age: f32 = 2.0; // particle respawns at age >= 2.0s
pub const spawn_seed: u64 = 0xC0FFEE;
pub const spawn_radius: f32 = 0.05; // tight emitter around origin

// World extents: positions in [-view_half, view_half] map to the framebuffer.
pub const view_half: f32 = 2.0;

// Per-kind initial velocity (set at spawn). Lookup, not branch.
pub const impulse: [3]vec.Vec3 = .{
    .{ .x = 0, .y = 0.8, .z = 0 }, // smoke:  gentle rise
    .{ .x = 1.0, .y = 1.2, .z = 0 }, // spark:   diagonal arc
    .{ .x = 0.4, .y = 0.6, .z = 0.2 }, // debris:  slow scatter
};
