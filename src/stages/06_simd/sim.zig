// Stage 6: SIMD vectorization (claim the layout's throughput reward).
//
// P7: vectorize the hot loop — but SoA first. SIMD is a *reward* for layout.
//
// Stage 3 laid out the SoA streams (per-component `[]f32` arrays) but, on this
// toolchain (Zig 0.17-dev), the scalar loops don't autovectorize — so the
// layout's throughput reward went unclaimed and stage 3 lost on time to stage 2.
// Stage 6 finally collects that reward: explicit `@Vector` over the contiguous
// per-component streams. Each NEON `fma` retires 4× the math of a scalar `fma`.
//
// The through-line: **the byte-reduction + per-component layout in stages 2–3 is
// what unlocked the SIMD win here.** SIMD is a reward for layout, not a
// substitute. Stage 3 laid the layout (and paid its overhead on this toolchain);
// stage 6 finally collects the reward that makes the layout pay.
//
// BUILDS ON STAGE 3 (not stage 5). Stages 4 (branchless compaction) and 5
// (sort-by-kind) were honest detours — they demonstrated techniques but added
// O(n) overhead that can't be vectorized away. Stage 6 goes back to stage 3's
// clean SoA layout + branchy kill (respawn in place) and vectorizes the math
// passes. The compaction and sort techniques will be recomposed in stage 9's
// synthesis (where stage 8's double-buffer allocator makes compaction cheap
// enough to be worth composing).
//
// LOOP STRUCTURE (step):
//   1. Math passes — VECTORIZED. 3 per-component passes (x, y, z), each
//      processing W=4 particles at once via @Vector(4, f32). The integrate
//      (`pos += vel * dt`) and forces (`vel += (g + drag*vel) * dt`) are fused
//      per component so `vel` is loaded once and used for both — same
//      single-load profile as stages 2–3. Handles the tail (n % W) with a
//      scalar fallback.
//   2. Age + kill + dispatch — SCALAR (same as stage 3). The branchy respawn
//      and per-particle switch can't vectorize (data-dependent control flow).
//      This pass is a smaller fraction of the work; the math passes are the bulk.
//
// WIDTH CHOICE (W=4). The M4's NEON is 128-bit = 4×f32 per register. @Vector(4)
// maps to 1 NEON op per math step; @Vector(8) = 2 ops; @Vector(16) = 4 ops. The
// minimum is at W=4 (native lane count) — wider vectors don't help because the
// backend can't retire more than 128 bits/cycle. The width sweep is documented
// in the README (§3); W=4 is the implementation choice.
//
// GOLDEN CHECK. The math is bit-identical to stages 1–5 (same FP ops, same
// per-particle order — the vectorized pass processes particles in the same
// index order, just W at a time). The RNG sequence is identical (stage 3's
// branchy kill, same draw order). Golden PASS (max delta = 0.00).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// SIMD width: 4×f32 = 128-bit NEON (the M4's native lane count).
const W: usize = 4;
const V = @Vector(W, f32);

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // Hot SoA streams — same per-component layout as stage 3.
    pos_x: []f32,
    pos_y: []f32,
    pos_z: []f32,
    vel_x: []f32,
    vel_y: []f32,
    vel_z: []f32,
    life: []f32, // stored but NOT touched by step() — same as stage 3
    age: []f32,
    kind: []fw.ParticleKind,

    cold: []ParticleCold,
    rng: std.Random.DefaultPrng,
    n: usize,

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const n = desc.n;
        const pos_x = try alloc.alloc(f32, n);
        errdefer alloc.free(pos_x);
        const pos_y = try alloc.alloc(f32, n);
        errdefer alloc.free(pos_y);
        const pos_z = try alloc.alloc(f32, n);
        errdefer alloc.free(pos_z);
        const vel_x = try alloc.alloc(f32, n);
        errdefer alloc.free(vel_x);
        const vel_y = try alloc.alloc(f32, n);
        errdefer alloc.free(vel_y);
        const vel_z = try alloc.alloc(f32, n);
        errdefer alloc.free(vel_z);
        const life = try alloc.alloc(f32, n);
        errdefer alloc.free(life);
        const age = try alloc.alloc(f32, n);
        errdefer alloc.free(age);
        const kind = try alloc.alloc(fw.ParticleKind, n);
        errdefer alloc.free(kind);
        const cold = try alloc.alloc(ParticleCold, n);
        self.* = .{
            .alloc = alloc,
            .pos_x = pos_x,
            .pos_y = pos_y,
            .pos_z = pos_z,
            .vel_x = vel_x,
            .vel_y = vel_y,
            .vel_z = vel_z,
            .life = life,
            .age = age,
            .kind = kind,
            .cold = cold,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = n,
        };
        var i: usize = 0;
        while (i < n) : (i += 1) self.spawnParticle(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        const px = self.pos_x; const py = self.pos_y; const pz = self.pos_z;
        const vx = self.vel_x; const vy = self.vel_y; const vz = self.vel_z;
        const ag = self.age; const kd = self.kind;
        const n = self.n;

        // 1. Integrate + forces, VECTORIZED per component (@Vector(4, f32) =
        //    128-bit NEON). Each pass processes W=4 particles at once: one NEON
        //    `fma` retires 4× the math of a scalar `fma`. The integrate
        //    (`pos += vel * dt`) and forces (`vel += (g + drag*vel) * dt`) are
        //    fused per component so `vel` is loaded once and used for both —
        //    same single-load profile as stages 2–3. Math is bit-identical (same
        //    FP ops, same per-particle order — just W at a time).
        //
        //    Stage 3's scalar version was compute-bound at ~17 GB/s (32% of the
        //    ~54 GB/s ceiling) — the FPU was the bottleneck, not memory.
        //    Vectorizing 4× should drop the compute floor to ~0.5–0.7 ns/particle
        //    at 1M, potentially bandwidth-bound (29 B/particle ÷ 54 GB/s ≈ 0.54 ns
        //    minimum). This is where stage 3's deferred time win materializes.
        mathPassVec(px, vx, n, dt, config.gravity.x);
        mathPassVec(py, vy, n, dt, config.gravity.y);
        mathPassVec(pz, vz, n, dt, config.gravity.z);

        // 2. Age + kill + dispatch — SCALAR (same as stage 3). The branchy
        //    respawn and per-particle switch can't vectorize (data-dependent
        //    control flow). This pass is a smaller fraction of the work; the
        //    vectorized math passes are the bulk.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            ag[i] += dt;
            if (ag[i] >= config.kill_age) {
                self.respawnHot(i);
            }
            // Deliberate hot branch: per-particle dispatch (removed in stage 5).
            _ = switch (kd[i]) {
                .smoke => {},
                .spark => {},
                .debris => {},
            };
        }
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const col = self.cold[i].color;
            rast.splat(fb, w, h, self.pos_x[i], self.pos_y[i], col.x, col.y, col.z);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.alloc.free(self.pos_x);
        self.alloc.free(self.pos_y);
        self.alloc.free(self.pos_z);
        self.alloc.free(self.vel_x);
        self.alloc.free(self.vel_y);
        self.alloc.free(self.vel_z);
        self.alloc.free(self.life);
        self.alloc.free(self.age);
        self.alloc.free(self.kind);
        self.alloc.free(self.cold);
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    pub fn snapshot(self: *const @This(), out: []f32) void {
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i * 6 + 0] = self.pos_x[i];
            out[i * 6 + 1] = self.pos_y[i];
            out[i * 6 + 2] = self.pos_z[i];
            out[i * 6 + 3] = self.vel_x[i];
            out[i * 6 + 4] = self.vel_y[i];
            out[i * 6 + 5] = self.vel_z[i];
        }
    }

    /// Bytes per particle that step() touches each frame (the working-set cost).
    /// Same as stage 3: pos (12) + vel (12) + age (4) + kind (1) = 29 B.
    /// `life` is stored but not touched (zero hot bandwidth). The @Vector doesn't
    /// change the bytes touched — it changes how many cycles the FPU spends on
    /// them (4× the math per retired instruction).
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1; // pos + vel + age + kind (life not touched)
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Same 8 streams as stage 3 (same layout — @Vector
    /// doesn't change the data, only how the FPU processes it). The fingerprint
    /// matches stage 3; the density reflects the same real signal.
    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        const n = self.n;
        const out = try alloc.alloc(fw.FieldDump, 8);
        out[0] = .{ .name = "pos.x", .bytes = try copyStream(self.pos_x, n, alloc) };
        out[1] = .{ .name = "pos.y", .bytes = try copyStream(self.pos_y, n, alloc) };
        out[2] = .{ .name = "pos.z", .bytes = try copyStream(self.pos_z, n, alloc) };
        out[3] = .{ .name = "vel.x", .bytes = try copyStream(self.vel_x, n, alloc) };
        out[4] = .{ .name = "vel.y", .bytes = try copyStream(self.vel_y, n, alloc) };
        out[5] = .{ .name = "vel.z", .bytes = try copyStream(self.vel_z, n, alloc) };
        out[6] = .{ .name = "age", .bytes = try copyStream(self.age, n, alloc) };
        out[7] = .{ .name = "kind", .bytes = try copyStream(self.kind, n, alloc) };
        return out;
    }

    /// Draw the hot fields from the shared RNG (kind, jitter_x, jitter_y, age —
    /// same order, same methods as stages 1–3's spawnParticle) and write them
    /// straight into the SoA streams. Used by both init and respawn.
    fn drawHotToStreams(self: *@This(), i: usize) void {
        const r = self.rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        self.pos_x[i] = 0;
        self.pos_y[i] = 0;
        self.pos_z[i] = 0;
        self.vel_x[i] = imp.x + jitter_x;
        self.vel_y[i] = imp.y + jitter_y;
        self.vel_z[i] = imp.z;
        self.life[i] = config.kill_age;
        self.age[i] = r.float(f32) * config.kill_age; // staggered spawn ages
        self.kind[i] = kind;
    }

    fn spawnParticle(self: *@This(), i: usize) void {
        self.drawHotToStreams(i);
        self.cold[i] = .{
            .color = kindColor(self.kind[i]),
            .size = 1.0,
            .rotation = 0,
            .mass = 1.0,
            .flags = 0,
            .seed = @intCast(i),
        };
    }

    fn respawnHot(self: *@This(), i: usize) void {
        self.drawHotToStreams(i);
    }
};

const ParticleCold = struct {
    color: fw.Vec4,
    size: f32,
    rotation: f32,
    mass: f32,
    flags: u8,
    seed: u32,
};

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

/// Copy a contiguous SoA stream's raw bytes for the audit (same as stage 3).
fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, VECTORIZED (@Vector(4, f32) = 128-bit
/// NEON). Processes W=4 particles at once: one NEON `fma` per step retires 4×
/// the math of a scalar `fma`.
///
///   pos[i..i+W] += vel[i..i+W] * dt                    (integrate, using OLD vel)
///   vel[i..i+W]  = old_vel + (g + drag*old_vel) * dt    (forces)
///
/// `vel` is loaded once (as a vector) and used for both — same single-load
/// profile as stage 3's scalar version. The tail (n % W) falls back to scalar.
///
/// Math equivalence with stage 3: each particle's FP ops are identical (same
/// order: pos uses old vel, then vel is updated). The vectorized pass processes
/// particles in the same index order, just W at a time — no reordering, no
/// precision difference. Golden passes byte-for-byte.
fn mathPassVec(pos: []f32, vel: []f32, n: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    const vdt: V = @splat(dt);
    const vdrag: V = @splat(drag);
    const vg: V = @splat(g);

    // Vectorized main loop: process W particles at once via pointer-cast to
    // [W]f32, loaded as @Vector(W, f32). One NEON fma per step retires 4×
    // the math of a scalar fma.
    const main = n - (n % W);
    var i: usize = 0;
    while (i < main) : (i += W) {
        const pos_w: *[W]f32 = @ptrCast(&pos[i]);
        const vel_w: *[W]f32 = @ptrCast(&vel[i]);
        const o: V = vel_w.*; // load old vel (1 vector load)
        const p: V = pos_w.*; // load old pos
        pos_w.* = p + o * vdt; // integrate: pos += vel * dt
        vel_w.* = o + (vg + vdrag * o) * vdt; // forces: vel += (g+drag*vel)*dt
    }

    // Scalar tail: remaining particles (n % W).
    while (i < n) : (i += 1) {
        const o = vel[i];
        pos[i] += o * dt;
        vel[i] = o + (g + drag * o) * dt;
    }
}
