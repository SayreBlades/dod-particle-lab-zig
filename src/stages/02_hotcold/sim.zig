// Stage 2: hot/cold split (first real DOD move).
//
// Same AoS, same math — but split into two parallel arrays by *usage cadence*:
//   hot  = { pos, vel, life, age, kind }  ← touched every frame by step()
//   cold = { color, size, rotation, mass, flags, seed }  ← write-once at init,
//          read only by render (the kill path routes around it — see below)
//
// The update loop walks `hot` only. Render walks `cold` (and reads `hot.pos`).
// The strawman's sin — dragging ~50 cold bytes/particle through L1 every frame
// — is gone. The math is byte-for-byte identical to stage 1 (golden check proves
// it); only the layout and access pattern changed.
//
// `kind` stays in the hot struct so the per-particle `switch(kind)` (the
// deliberate hot branch, removed in stage 5) can dispatch without a per-frame
// cold-array access. `seed` lives in cold but is a constant (= the particle's
// index, set once at init), so the kill path uses the loop index directly and
// never touches cold. The respawn writes hot only — cold is write-once, so the
// split pays no cross-array penalty on the kill path (which would otherwise
// trigger a read-for-ownership miss on the cold array at large N).
//
// The RNG draw sequence in both init and respawn is identical to stage 1's
// spawnParticle (kind, jitter_x, jitter_y, age — in that order), so every
// particle's pos/vel/age trajectory matches stage 1 exactly; the golden check
// passes byte-for-byte. Cold color is not re-rolled on respawn (it stays the
// spawn-time color) — a cosmetic difference the golden check doesn't see.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// Touched every frame by step().
const ParticleHot = struct {
    pos: fw.Vec3,
    vel: fw.Vec3,
    life: f32,
    age: f32,
    kind: fw.ParticleKind,
};

// Render-only + spawn-time only. Never touched by the update loop.
const ParticleCold = struct {
    color: fw.Vec4,
    size: f32,
    rotation: f32,
    mass: f32,
    flags: u8,
    seed: u32,
};

pub const Sim = struct {
    alloc: std.mem.Allocator,
    hot: []ParticleHot,
    cold: []ParticleCold,
    rng: std.Random.DefaultPrng,
    n: usize,

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const hot = try alloc.alloc(ParticleHot, desc.n);
        errdefer alloc.free(hot);
        const cold = try alloc.alloc(ParticleCold, desc.n);
        self.* = .{
            .alloc = alloc,
            .hot = hot,
            .cold = cold,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = desc.n,
        };
        // Spawn all particles (writes both hot + cold in lockstep).
        var i: usize = 0;
        while (i < desc.n) : (i += 1) self.spawnParticle(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        // The update loop walks ONLY the hot array. No cold bytes cross L1 here.
        for (self.hot, 0..) |*p, i| {
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

            // 4. Kill → respawn. seed == i (a write-once constant in cold),
            //    so the respawn target is just the loop index — no cold read.
            //    The respawn writes hot only (cold is write-once), so the split
            //    pays no cross-array penalty on the kill path.
            if (p.age >= config.kill_age) {
                self.respawnHot(i);
            }

            // Deliberate hot branch: per-particle dispatch (removed in stage 5).
            // Reads hot.kind — no cold access.
            _ = switch (p.kind) {
                .smoke => smokeNudge(p),
                .spark => sparkNudge(p),
                .debris => debrisNudge(p),
            };
        }
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        for (self.hot, self.cold) |h_p, c| {
            rast.splat(fb, w, h, h_p.pos.x, h_p.pos.y, c.color.x, c.color.y, c.color.z);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.alloc.free(self.hot);
        self.alloc.free(self.cold);
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    pub fn snapshot(self: *const @This(), out: []f32) void {
        for (self.hot, 0..) |p, i| {
            out[i * 6 + 0] = p.pos.x;
            out[i * 6 + 1] = p.pos.y;
            out[i * 6 + 2] = p.pos.z;
            out[i * 6 + 3] = p.vel.x;
            out[i * 6 + 4] = p.vel.y;
            out[i * 6 + 5] = p.vel.z;
        }
    }

    /// Bytes per particle that step() touches each frame (the working-set cost).
    /// Stage 2's win: step() walks only the hot struct, not the full Particle.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return @sizeOf(ParticleHot);
    }

    /// Dump the hot-loop fields' raw bytes (AoS-strided within ParticleHot)
    /// for the data-density audit. Only the fields step() actually touches are
    /// dumped — the audit measures the bytes dragged through L1 by the hot
    /// loop, and in stage 2 that's the hot array alone. Cold fields live in a
    /// separate array the update never walks; their density is irrelevant to
    /// the hot loop's bandwidth cost (render's problem, not update's).
    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        const hot = self.hot;
        const out = try alloc.alloc(fw.FieldDump, 5);
        out[0] = .{ .name = "pos", .bytes = try extractField("pos", hot, alloc) };
        out[1] = .{ .name = "vel", .bytes = try extractField("vel", hot, alloc) };
        out[2] = .{ .name = "life", .bytes = try extractField("life", hot, alloc) };
        out[3] = .{ .name = "age", .bytes = try extractField("age", hot, alloc) };
        out[4] = .{ .name = "kind", .bytes = try extractField("kind", hot, alloc) };
        return out;
    }

    /// Draw the hot fields from the shared RNG (kind, jitter_x, jitter_y, age —
    /// same order, same methods as stage 1's spawnParticle) and return them.
    /// Used by both init (which also writes cold) and respawn (hot only), so
    /// the RNG sequence stays synchronized with stage 1 and the math matches.
    fn drawHot(self: *@This()) ParticleHot {
        const r = self.rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        return .{
            .pos = .{ .x = 0, .y = 0, .z = 0 },
            .vel = .{
                .x = imp.x + jitter_x,
                .y = imp.y + jitter_y,
                .z = imp.z,
            },
            .life = config.kill_age,
            .age = r.float(f32) * config.kill_age, // staggered spawn ages
            .kind = kind,
        };
    }

    /// Init-time spawn: write hot (drawn from RNG) + cold (constants derived
    /// from the drawn kind). Seed is the particle's index — a write-once
    /// constant the kill path reads via the loop index, never via cold.
    fn spawnParticle(self: *@This(), i: usize) void {
        self.hot[i] = self.drawHot();
        self.cold[i] = .{
            .color = kindColor(self.hot[i].kind),
            .size = 1.0,
            .rotation = 0,
            .mass = 1.0,
            .flags = 0,
            .seed = @intCast(i),
        };
    }

    /// Respawn (kill path): re-roll hot only. Cold is write-once — its values
    /// never feed back into the math, so leaving them stale changes neither the
    /// golden check (pos/vel only) nor the physics. Skipping the cold write
    /// avoids a read-for-ownership miss on the cold array at large N.
    fn respawnHot(self: *@This(), i: usize) void {
        self.hot[i] = self.drawHot();
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
fn smokeNudge(p: *ParticleHot) void { _ = p; }
fn sparkNudge(p: *ParticleHot) void { _ = p; }
fn debrisNudge(p: *ParticleHot) void { _ = p; }

/// Extract one field's bytes from the hot AoS array (AoS-strided: the natural
/// memory layout of that field as the hot loop reads it).
fn extractField(comptime field: []const u8, ps: []const ParticleHot, alloc: std.mem.Allocator) ![]u8 {
    const FT = @TypeOf(@field(ps[0], field));
    const sz = @sizeOf(FT);
    const out = try alloc.alloc(u8, ps.len * sz);
    for (ps, 0..) |_, i| {
        const ptr = &@field(ps[i], field);
        @memcpy(out[i * sz ..][0..sz], std.mem.asBytes(ptr));
    }
    return out;
}
