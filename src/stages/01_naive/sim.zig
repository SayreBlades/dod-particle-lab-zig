// Stage 1: the naive baseline (the strawman).
//
// One big AoS array of Particle. step() touches every field of every particle
// every frame, including cold fields (mass/flags/seed/kind) that the update
// doesn't use. Per-particle switch(kind) is a deliberate hot branch. respawn
// is branchy in-place. This is the line every later stage must beat.
//
// Also the reference: bench mode (C3) generates the golden file from this stage.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

const Particle = struct {
    pos: fw.Vec3,
    vel: fw.Vec3,
    life: f32,
    age: f32,
    color: fw.Vec4,
    size: f32,
    rotation: f32,
    mass: f32,
    flags: u8,
    kind: fw.ParticleKind,
    seed: u32,
};

pub const Sim = struct {
    alloc: std.mem.Allocator,
    particles: []Particle,
    rng: std.Random.DefaultPrng,
    n: usize,

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const ps = try alloc.alloc(Particle, desc.n);
        self.* = .{
            .alloc = alloc,
            .particles = ps,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = desc.n,
        };
        // Spawn all particles.
        var i: usize = 0;
        while (i < desc.n) : (i += 1) self.spawnParticle(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        for (self.particles) |*p| {
            // 1. Integrate: pos += vel * dt
            p.pos = p.pos.add(p.vel.scale(dt));

            // 2. Forces: vel += (gravity + drag*vel) * dt
            //    (impulse was set at spawn; per-frame force is gravity + drag only)
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };

            // 3. Age
            p.age += dt;

            // 4. Kill → respawn
            if (p.age >= config.kill_age) {
                self.spawnParticle(@intCast(p.seed % self.particles.len));
            }

            // Deliberate hot branch: per-particle dispatch (removed in stage 5).
            _ = switch (p.kind) {
                .smoke => smokeNudge(p),
                .spark => sparkNudge(p),
                .debris => debrisNudge(p),
            };

            // Cold fields touched every frame (the strawman's sin).
            _ = p.mass;
            _ = p.flags;
            _ = p.seed;
        }
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        for (self.particles) |p| {
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.alloc.free(self.particles);
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    pub fn snapshot(self: *const @This(), out: []f32) void {
        for (self.particles, 0..) |p, i| {
            out[i * 6 + 0] = p.pos.x;
            out[i * 6 + 1] = p.pos.y;
            out[i * 6 + 2] = p.pos.z;
            out[i * 6 + 3] = p.vel.x;
            out[i * 6 + 4] = p.vel.y;
            out[i * 6 + 5] = p.vel.z;
        }
    }

    /// Bytes per particle that step() touches each frame (the working-set cost).
    /// Used by the bench driver to compute the mem(MB) column. Stage 1 walks the
    /// full AoS Particle struct (the strawman's sin: cold fields dragged too).
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return @sizeOf(Particle);
    }

    /// Dump each field's raw bytes across the particle array (AoS-strided) for
    /// the data-density audit. The hot loop in stage 1 touches *every* field of
    /// *every* particle (the strawman's sin), so every blob below is paid for
    /// in cache bandwidth every frame — the audit shows how little of it carries
    /// information. (Stage 2 will stop walking the cold ones; stage 3 will turn
    /// these AoS blobs into per-component SoA streams; stage 4 will drop the
    /// constants entirely.)
    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        const ps = self.particles;
        const out = try alloc.alloc(fw.FieldDump, 11);
        out[0] = .{ .name = "pos", .bytes = try extractField("pos", ps, alloc) };
        out[1] = .{ .name = "vel", .bytes = try extractField("vel", ps, alloc) };
        out[2] = .{ .name = "life", .bytes = try extractField("life", ps, alloc) };
        out[3] = .{ .name = "age", .bytes = try extractField("age", ps, alloc) };
        out[4] = .{ .name = "color", .bytes = try extractField("color", ps, alloc) };
        out[5] = .{ .name = "size", .bytes = try extractField("size", ps, alloc) };
        out[6] = .{ .name = "rotation", .bytes = try extractField("rotation", ps, alloc) };
        out[7] = .{ .name = "mass", .bytes = try extractField("mass", ps, alloc) };
        out[8] = .{ .name = "flags", .bytes = try extractField("flags", ps, alloc) };
        out[9] = .{ .name = "kind", .bytes = try extractField("kind", ps, alloc) };
        out[10] = .{ .name = "seed", .bytes = try extractField("seed", ps, alloc) };
        return out;
    }

    fn spawnParticle(self: *@This(), i: usize) void {
        const r = self.rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        const col = kindColor(kind);
        self.particles[i] = .{
            .pos = .{ .x = 0, .y = 0, .z = 0 },
            .vel = .{
                .x = imp.x + jitter_x,
                .y = imp.y + jitter_y,
                .z = imp.z,
            },
            .life = config.kill_age,
            .age = r.float(f32) * config.kill_age, // staggered spawn ages
            .color = col,
            .size = 1.0,
            .rotation = 0,
            .mass = 1.0,
            .flags = 0,
            .kind = kind,
            .seed = @intCast(i),
        };
    }
};

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

// Per-kind nudges (deliberate hot-loop dispatch — stage 5 removes this).
fn smokeNudge(p: *Particle) void { _ = p; }
fn sparkNudge(p: *Particle) void { _ = p; }
fn debrisNudge(p: *Particle) void { _ = p; }

/// Extract one field's bytes from the AoS array (AoS-strided: the natural
/// memory layout of that field as the hot loop reads it).
fn extractField(comptime field: []const u8, ps: []const Particle, alloc: std.mem.Allocator) ![]u8 {
    const FT = @TypeOf(@field(ps[0], field));
    const sz = @sizeOf(FT);
    const out = try alloc.alloc(u8, ps.len * sz);
    for (ps, 0..) |_, i| {
        const ptr = &@field(ps[i], field);
        @memcpy(out[i * sz ..][0..sz], std.mem.asBytes(ptr));
    }
    return out;
}
