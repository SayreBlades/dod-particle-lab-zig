// Stage 3: AoS → SoA (the flagship layout transformation).
//
// Turn the hot array of structs into parallel per-field (per-component)
// arrays. The math is unchanged; only the *layout* changes: `p.pos.x` →
// `self.pos_x[i]`. That one move reclaims every byte the cache used to carry
// for nothing:
//
//   - No more struct stride waste. Stage 2's ParticleHot was 36 B/particle on
//     the wire, but step() only *used* 29 B of it (the other 7 = life's 4 B +
//     3 B padding were loaded into the cache line and discarded). Each SoA
//     stream is contiguous, so a 128 B line now holds 32 particles' worth of
//     ONE field at ~100% utilization — no padding, no cross-field interleaving.
//   - life stops being walked at all. As a separate stream step() never
//     touches, its 4 B/particle leave the hot loop's cache footprint entirely
//     (the first stage where an *allocated* field costs zero bandwidth). Stage
//     4 will then remove life from storage as the constant it is.
//
// The hot loop now touches ~29 B/particle (pos 12 + vel 12 + age 4 + kind 1)
// vs stage 2's ~36 B on the wire.
//
// HONEST OUTCOME ON THIS TOOLCHAIN. The plan expected the scalar SoA loops
// to autovectorize for free, so stage 3 alone would win at N≥1M. Zig 0.17-dev
// does NOT autovectorize (confirmed in assembly — scalar s0/s1 registers, no
// q-register lanes), so scalar-SoA is measured 1.5× SLOWER than stage 2 at
// large N — the layout transformation alone is an uncompensated cost without
// the throughput reward. The transformation still *lands* (the data-density
// audit proves it: MEAN density 0.655 → 0.722, `life` leaves the dump, the
// fingerprint changes to per-component streams); the *time* win is deferred to
// stage 6, which is exactly where the plan says the SIMD reward belongs (P7:
// "SIMD is a reward for layout"). Stage 3 lays the layout; stage 6 claims the
// reward. Full analysis: .scratch/analysis/stage3-perf-degradation.md.
//
// Loop structure: integrate + forces fused per component so `vel` is loaded
// once and used for both pos += vel*dt and the vel += (g+drag*vel)*dt update —
// matches stage 2's single-load profile (no cross-pass vel reload). age +
// kill + dispatch stay scalar (branchy; can't vectorize respawn).
//
// Cold stays AoS (ParticleCold) — stage 3's lesson is the hot loop; render's
// layout is a separate concern. Math byte-for-byte identical to stages 1–2
// (golden check proves it): the RNG draw sequence (kind, jitter_x, jitter_y,
// age — same order) is preserved in both init and respawn.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// Render-only + spawn-time only. Same parallel-array split as stage 2; the
// stage-3 lesson is the *hot* loop, so cold keeps its AoS shape for a focused diff.
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

    // Hot SoA streams — parallel per-component arrays. step() indexes these by
    // particle; each is contiguous, so a cache line holds 32 particles' worth of
    // ONE field (vs AoS's ~3.5 whole-particles per line with stride waste).
    pos_x: []f32,
    pos_y: []f32,
    pos_z: []f32,
    vel_x: []f32,
    vel_y: []f32,
    vel_z: []f32,
    life: []f32, // stored but NOT touched by step() — a separate stream the hot
    // loop never walks. The first stage where an allocated field costs zero
    // bandwidth. (Stage 4 removes it from storage as the constant it is.)
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
        // Per-component tight passes over the SoA streams (SCALAR — no @Vector;
        // stage 6 introduces explicit SIMD, the throughput reward this layout
        // unlocks, per P7 "SIMD is a reward for layout"). Each pass touches 1-2
        // contiguous streams; the plan assumed the compiler would autovectorize
        // these, but Zig 0.17-dev does not (assembly confirms scalar s0/s1
        // registers), so this stage does NOT win on time over stage 2 — measured
        // ~1.5× slower at large N. The transformation still lands (audit:
        // density 0.655 → 0.722, life leaves the dump, fingerprint changes to
        // per-component streams); the time win is deferred to stage 6. See the
        // file header and .scratch/analysis/stage3-perf-degradation.md.
        //
        // Integrate + forces are *fused* per component so `vel` is loaded once
        // and used for both pos += vel*dt and the vel += (g+drag*vel)*dt update
        // — matches stage 2's single-load profile (a split integrate-then-forces
        // would reload the whole vel array between passes, a loss at large N).
        //
        // Math equivalence with stage 2: pos uses the *old* vel (the forces
        // update hasn't run yet for this particle), then vel is updated — same
        // per-particle order as stage 2's single loop. age is updated before
        // the kill check reads it. RNG consumed only in the kill pass, in index
        // order. Golden passes byte-for-byte.
        const px = self.pos_x; const py = self.pos_y; const pz = self.pos_z;
        const vx = self.vel_x; const vy = self.vel_y; const vz = self.vel_z;
        const ag = self.age; const kd = self.kind;
        const n = self.n;

        // 1. Integrate + forces, fused per component (3 tight 2-stream passes;
        //    vel loaded once, used for pos then forces). Reads old vel for both.
        mathPass(px, vx, n, dt, config.gravity.x);
        mathPass(py, vy, n, dt, config.gravity.y);
        mathPass(pz, vz, n, dt, config.gravity.z);

        // 2. Age + kill + dispatch (scalar; branchy, rare-ish). age is written
        //    then read back in a register — one load, no separate age pass that
        //    would stream age a second time. Kept scalar because the respawn
        //    branch and per-particle switch can't vectorize.
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
    /// Stage 3's win: SoA streams carry no stride waste (no padding, no
    /// cross-field interleaving), and `life` — a separate stream step() never
    /// walks — costs zero bandwidth. So the hot footprint drops from stage 2's
    /// 36 B/particle (on the wire) to 29 B (pos 12 + vel 12 + age 4 + kind 1).
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1; // pos + vel + age + kind (life not touched)
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Stage 3's `dumpFields` fingerprint differs from
    /// stage 2's: each stream is a *contiguous* run of one component (pos.x,
    /// pos.y, …) rather than an AoS-strided blob, and `life` is gone from the
    /// dump — it's an allocated stream step() never walks, so it carries no hot
    /// bandwidth and isn't counted. (Stage 4 will remove life from storage
    /// entirely as the constant it is.)
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
    /// same order, same methods as stage 1/2's spawnParticle) and write them
    /// straight into the SoA streams. Used by both init (which also writes
    /// cold) and respawn (hot only), so the RNG sequence stays synchronized and
    /// the math matches byte-for-byte.
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

    /// Init-time spawn: write hot (drawn from RNG) + cold (constants derived
    /// from the drawn kind). Seed is the particle's index — a write-once
    /// constant the kill path reads via the loop index, never via cold.
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

    /// Respawn (kill path): re-roll hot only. Cold is write-once — its values
    /// never feed back into the math, so leaving them stale changes neither the
    /// golden check (pos/vel only) nor the physics. Skipping the cold write
    /// avoids a read-for-ownership miss on the cold array at large N.
    fn respawnHot(self: *@This(), i: usize) void {
        self.drawHotToStreams(i);
    }
};

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

/// Copy a contiguous SoA stream's raw bytes for the audit. Unlike stage 1/2's
/// AoS-strided extractField, this is a plain memcpy — the stream is already
/// contiguous, which is the whole point of SoA (and why a cache line serves 32
/// particles' worth of one field with zero stride waste).
fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, SCALAR (no @Vector — stage 6
/// introduces explicit SIMD, the throughput reward this layout unlocks).
///   pos[i] += vel[i] * dt        (integrate, using OLD vel)
///   vel[i]  = old_vel + (g + drag*old_vel) * dt   (forces)
/// `vel` is loaded once and used for both — matches stage 2's single-load
/// profile (no cross-pass vel reload). A split integrate-then-forces would
/// reload the whole vel array between passes.
///
/// NOTE: this scalar version is measured ~1.5× SLOWER than stage 2 at large N
/// (Zig 0.17-dev doesn't autovectorize these loops; stage 2's AoS single
/// stream is prefetcher-perfect and already compute-bound, so cutting bytes
/// can't help and the multi-pass overhead shows up uncompensated). The
/// transformation still lands (density audit proves it); the time win is
/// deferred to stage 6's explicit @Vector. See file header.
fn mathPass(pos: []f32, vel: []f32, n: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    for (pos[0..n], vel[0..n]) |*p, *v| {
        const o = v.*;
        p.* += o * dt;
        v.* = o + (g + drag * o) * dt;
    }
}
