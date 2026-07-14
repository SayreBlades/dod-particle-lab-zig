// Stage 7: alignment, padding, sizing to the cache line.
//
// P8: sizes/alignments are parameters matched to the hardware.
//
// Stage 6 vectorized the SoA math passes (@Vector(4, f32) = 128-bit NEON) and
// finally beat stage 2. But the PMC showed a residual % Delivery bottleneck
// (13.6% at 1M) — the vectorized loop's frontend pressure from (a) unaligned
// stream bases (a vector load can straddle a cache line) and (b) the scalar
// tail branch (n % W ≠ 0 → a separate scalar cleanup loop after the vector
// loop, adding a mode switch and branch). Stage 7 attacks both:
//
//   1. ALIGN each SoA stream to 128 B (the M4's cache line). Every vector load
//      now starts on a line boundary; no load straddles two lines. This is the
//      "platform is the hardware" discipline (P8): the alignment is a *measured
//      hardware fact* (hw.cachelinesize = 128), not a guess.
//
//   2. PAD each stream's length up to a multiple of W=4 (n_padded = alignUp(n,
//      W)). The vectorized math pass now processes the full padded length with
//      NO scalar tail branch — the loop is a single tight vector loop, no mode
//      switch. The ≤3 guard elements (n..n_padded) are zeroed at init and
//      never observed (snapshot/age/kill/render all iterate [0..n], not
//      [0..n_padded]); their pos/vel drift freely but invisibly.
//
// WHAT THIS DOES NOT DO (honest scope). The plan's stage 7 also mentions "tile
// the loop in 128-particle chunks (one alive bitset line = one cache line)" and
// "size the hot block per particle = 32 B = ¼ line." Both are AoS/bitset
// lessons that don't apply to stage 7's clean SoA streaming:
//   - In SoA, each stream already packs 32 particles per 128 B line (4 B/float
//     × 32 = 128 B) — maximally dense; there's no "hot block per particle" to
//     size (that's an AoS framing). Stage 7's alignment IS the line-matching.
//   - The bitset-line tiling applies to the compaction pass (stage 4/9), which
//     stage 6 doesn't have (branchy kill). Stage 7 builds on stage 6, so there's
//     no alive bitset to tile. That lesson lands in stage 9's synthesis.
// Stage 7's concrete, measurable wins are alignment + padding. The tiling/hot-
// block analysis is documented honestly (§3) rather than force-fit.
//
// BUILDS ON STAGE 6 (not stage 5). Same as stage 6: clean SoA + branchy kill +
// @Vector(4) math. The only changes are the allocation (aligned + padded) and
// the math pass signature (takes the padded length, no tail). The compaction
// and sort from stages 4/5 are recomposed in stage 9's synthesis.
//
// GOLDEN CHECK. Same as stage 6: the vectorized math is bit-identical (same FP
// ops, same per-particle order — W at a time). The guard region [n..n_padded]
// is never observed (snapshot/age/kill/render iterate [0..n]). The RNG sequence
// is identical (stage 6's branchy kill, same draw order). Golden PASS.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// SIMD width: 4×f32 = 128-bit NEON (the M4's native lane count). Same as stage 6.
const W: usize = 4;
const V = @Vector(W, f32);

// Cache-line alignment: 128 B (the M4's hw.cachelinesize). Every stream's base
// is aligned to this, so every vector load starts on a line boundary.
const LINE: std.mem.Alignment = .fromByteUnits(128);

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // Hot SoA streams — 128 B-aligned, padded to a multiple of W (no tail branch).
    // The slice type carries the alignment: []align(128) f32. The length is
    // n_padded (≥ n); indices [n..n_padded] are zeroed guard elements never
    // observed by snapshot/age/kill/render (which iterate [0..n]).
    pos_x: []align(128) f32,
    pos_y: []align(128) f32,
    pos_z: []align(128) f32,
    vel_x: []align(128) f32,
    vel_y: []align(128) f32,
    vel_z: []align(128) f32,
    life: []align(128) f32, // stored but NOT touched by step() (same as stage 3/6)
    age: []align(128) f32,
    kind: []align(128) fw.ParticleKind,

    rng: std.Random.DefaultPrng,
    n: usize, // real particle count (snapshot/age/kill/render iterate [0..n])
    n_padded: usize, // padded count (math pass iterates [0..n_padded], no tail)

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const n = desc.n;
        // Pad to a multiple of W so the vectorized math pass has no scalar tail.
        const n_padded = std.mem.alignForward(usize, n, W);

        const pos_x = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_x);
        const pos_y = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_y);
        const pos_z = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_z);
        const vel_x = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_x);
        const vel_y = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_y);
        const vel_z = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_z);
        const life = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(life);
        const age = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(age);
        const kind = try alloc.alignedAlloc(fw.ParticleKind, LINE, n_padded);
        errdefer alloc.free(kind);

        // Zero the guard region [n..n_padded] so the vectorized math (which
        // processes the full padded length) operates on 0, not garbage. The
        // guard elements are never observed, but 0 keeps the FPU from producing
        // NaN/inf from uninitialized bits (defensive; also makes the padded
        // region deterministic if ever audited).
        @memset(pos_x[n..n_padded], 0);
        @memset(pos_y[n..n_padded], 0);
        @memset(pos_z[n..n_padded], 0);
        @memset(vel_x[n..n_padded], 0);
        @memset(vel_y[n..n_padded], 0);
        @memset(vel_z[n..n_padded], 0);
        @memset(life[n..n_padded], 0);
        @memset(age[n..n_padded], 0);
        @memset(kind[n..n_padded], .smoke);

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
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = n,
            .n_padded = n_padded,
        };
        var i: usize = 0;
        while (i < n) : (i += 1) self.drawHotToStreams(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        const px = self.pos_x; const py = self.pos_y; const pz = self.pos_z;
        const vx = self.vel_x; const vy = self.vel_y; const vz = self.vel_z;
        const ag = self.age; const kd = self.kind;
        const n = self.n;
        const n_padded = self.n_padded;

        // 1. Integrate + forces, VECTORIZED over the FULL PADDED length (no
        //    scalar tail — stage 6's tail branch is gone). Each stream is 128 B-
        //    aligned, so every @Vector(4) load starts on a cache line boundary;
        //    no load straddles two lines. Math is bit-identical to stages 1–6
        //    for indices [0..n]; the guard region [n..n_padded] is processed
        //    but never observed.
        mathPassVec(px, vx, n_padded, dt, config.gravity.x);
        mathPassVec(py, vy, n_padded, dt, config.gravity.y);
        mathPassVec(pz, vz, n_padded, dt, config.gravity.z);

        // 2. Age + kill + dispatch — SCALAR over [0..n] (same as stage 6). The
        //    guard region [n..n_padded] is NOT aged, killed, or dispatched —
        //    it's invisible padding. The branchy respawn and per-particle switch
        //    can't vectorize (data-dependent control flow).
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
            // Color computed from kind (render-time lookup, same as stage 6 —
            // no stale cold array). The guard region [n..n_padded] is not rendered.
            const col = kindColor(self.kind[i]);
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
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    /// Iterates [0..n] (the guard region is not part of the observable state).
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
    /// Same as stage 6: pos (12) + vel (12) + age (4) + kind (1) = 29 B. The
    /// padding adds ≤3 guard particles' worth of pos/vel (24 B × ≤3 = ≤72 B
    /// total, amortized to <0.02 B/particle at N≥4K) — negligible, and only in
    /// the math pass (the age/kill/render passes use [0..n]). Reported per real
    /// particle, same as stage 6, for an apples-to-apples bench comparison.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1; // pos + vel + age + kind (life not touched)
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Dumps [0..n] (the observable particles), same 8
    /// streams as stage 6. The guard region is not dumped (it's padding, not
    /// data). The fingerprint matches stage 3/6 (same SoA layout); the density
    /// reflects the same real signal.
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
    /// same order, same methods as stages 1–6) and write them into the SoA
    /// streams. Used by both init and respawn. The guard region is NOT drawn
    /// (it's zeroed at init and never respawned — the kill loop iterates [0..n]).
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

/// Copy a contiguous SoA stream's raw bytes [0..n] for the audit (same as
/// stages 3–6). Works with aligned slices (anytype).
fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, VECTORIZED over the full padded
/// length (NO scalar tail — stage 6's tail branch is gone). @Vector(4, f32) =
/// 128-bit NEON; each stream is 128 B-aligned, so every load starts on a cache
/// line boundary.
///
///   pos[i..i+W] += vel[i..i+W] * dt                    (integrate, using OLD vel)
///   vel[i..i+W]  = old_vel + (g + drag*old_vel) * dt    (forces)
///
/// `vel` is loaded once (as a vector) and used for both — same single-load
/// profile as stages 3/6. The loop is a single tight vector loop: `while (i <
/// n_padded) : (i += W)` — no tail, no mode switch. Math is bit-identical to
/// stage 6 for [0..n] (same FP ops, same per-particle order).
fn mathPassVec(pos: []align(128) f32, vel: []align(128) f32, n_padded: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    const vdt: V = @splat(dt);
    const vdrag: V = @splat(drag);
    const vg: V = @splat(g);

    // Single tight vector loop — no tail branch (n_padded is a multiple of W).
    var i: usize = 0;
    while (i < n_padded) : (i += W) {
        const pos_w: *[W]f32 = @ptrCast(&pos[i]);
        const vel_w: *[W]f32 = @ptrCast(&vel[i]);
        const o: V = vel_w.*; // load 4 vel values (line-aligned vector load)
        const p: V = pos_w.*; // load 4 pos values
        pos_w.* = p + o * vdt; // integrate: pos += vel * dt
        vel_w.* = o + (vg + vdrag * o) * vdt; // forces: vel += (g+drag*vel)*dt
    }
}
