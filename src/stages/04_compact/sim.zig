// Stage 4: branchless compaction (kill the kill-branch).
//
// P5: turn data-dependent control flow into data-dependent arithmetic.
//
// Stages 1–3 handle death with a branch: `if (age >= kill_age) respawn(i)` —
// a data-dependent branch in the hot loop that the branch predictor must
// guess per-particle, per-frame. Stage 4 replaces that with branchless
// stream compaction:
//
//   1. Alive marking — NO branch, just a comparison turned into 0/1:
//        alive[i] = @intFromBool(age[i] < kill_age)
//      `@intFromBool` is a compare-to-register, not a branch. The CPU does not
//      predict it; it always executes both "sides" (the 0 and the 1) and picks.
//
//   2. Branchless in-place compaction — the destination for each particle is
//      selected by *arithmetic*, not by `if`:
//        dest = write * is_alive + i * (1 - is_alive)
//      If alive: dest = write (copy forward, bump write). If dead: dest = i
//      (self-copy = no-op, write unchanged). Every iteration does EXACTLY the
//      same work — one read, one write, one add — regardless of alive/dead.
//      No branch for the predictor to mispredict.
//
//   3. Spawn — the dead slots (indices live_count..n-1, left in place by the
//      self-copies above) are filled with new particles drawn from the RNG.
//      N is maintained — the sim still has exactly `n` particles every frame,
//      same as stages 1–3.
//
// The golden check still passes: the RNG draw *sequence* is identical to
// stages 1–3 (dead particles processed in order → same draws), the spawned
// particles get the same (kind, jitter, age) values, and the sorted golden
// check tolerates the storage-order change compaction introduces. The multiset
// of particle states after every step is the same; only the storage order
// differs.
//
// TWO RECLAIMS BESIDES THE BRANCH (both predicted by the audit):
//
//   - `life` leaves STORAGE entirely. Stages 1–3 stored `life = kill_age` per
//     particle — a constant duplicated N times (density 0.013). Stage 3 stopped
//     *touching* it in the hot loop; stage 4 stops *storing* it. The kill check
//     compares `age` against `config.kill_age` directly — no `life` field at all.
//
//   - The entire `cold` array is gone. The audit flagged `color` (density 0.036
//     — a 3-entry dictionary, a pure function of `kind`), `size`/`rotation`/
//     `mass`/`flags` (density ~0.01 — constants), and `seed` (write-once, never
//     read after init — dead data). Stage 4 removes them all: `color` is
//     computed from `kind` via `kindColor()` in `render()`; the constants are
//     hardcoded where needed; `seed` is deleted. The only per-particle data is
//     the 8 hot streams — pos, vel, age, kind.
//
// HONEST OUTCOME. The branchless compaction pass is O(n) every frame — it
// reads and writes all 8 hot streams even when only ~n/120 particles die (the
// natural death rate at kill_age=2.0, dt=1/60). So stage 4 does MORE total work
// than stage 3's branchy kill (which only touches the dead particles). In the
// natural alive pattern, stage 4 may be slower than stage 3 — the compaction
// overhead is uncompensated. The payoff P5 promises is under ADVERSARIAL alive
// patterns (every-other alive — worst case for branch prediction), where the
// branchy version's misprediction rate hits 50% and the branchless version's
// is 0%. The plan's gate for stage 4 is the branchy-vs-branchless gap under
// adversarial input, not vs stage 3 in the natural pattern. The PMC data
// (stage 3's ~6–8% Discarded) is the branch cost stage 4 eliminates.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // Hot SoA streams — same per-component layout as stage 3, but with `life`
    // removed from storage entirely (it was a constant) and the cold array
    // deleted (color computed from kind in render; size/rotation/mass/flags
    // hardcoded; seed was dead data). The only per-particle state is these 8
    // streams.
    pos_x: []f32,
    pos_y: []f32,
    pos_z: []f32,
    vel_x: []f32,
    vel_y: []f32,
    vel_z: []f32,
    age: []f32,
    kind: []fw.ParticleKind,

    // Branchless-compaction scratch: the alive mask. Written once per frame
    // (alive marking pass), read once (compaction pass). 1 byte/particle. NOT
    // a particle field — it's transient computation, so it's not in dumpFields.
    alive: []u8,

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
        const age = try alloc.alloc(f32, n);
        errdefer alloc.free(age);
        const kind = try alloc.alloc(fw.ParticleKind, n);
        errdefer alloc.free(kind);
        const alive = try alloc.alloc(u8, n);
        self.* = .{
            .alloc = alloc,
            .pos_x = pos_x,
            .pos_y = pos_y,
            .pos_z = pos_z,
            .vel_x = vel_x,
            .vel_y = vel_y,
            .vel_z = vel_z,
            .age = age,
            .kind = kind,
            .alive = alive,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = n,
        };
        var i: usize = 0;
        while (i < n) : (i += 1) self.drawHotToStreams(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        const px = self.pos_x;
        const py = self.pos_y;
        const pz = self.pos_z;
        const vx = self.vel_x;
        const vy = self.vel_y;
        const vz = self.vel_z;
        const ag = self.age;
        const kd = self.kind;
        const al = self.alive;
        const n = self.n;

        // 1. Integrate + forces, fused per component (same scalar mathPass as
        //    stage 3 — 3 tight 2-stream passes; vel loaded once, used for both
        //    pos += vel*dt and the vel += (g+drag*vel)*dt update). The math is
        //    byte-for-byte identical to stages 1–3 (golden check proves it).
        mathPass(px, vx, n, dt, config.gravity.x);
        mathPass(py, vy, n, dt, config.gravity.y);
        mathPass(pz, vz, n, dt, config.gravity.z);

        // 2. Age update — a separate branchless pass (no kill check here).
        //    Stages 1–3 fused `age += dt` with the branchy kill check in one
        //    loop; stage 4 splits them so the kill decision can be made
        //    branchlessly in the next pass.
        for (ag[0..n]) |*a| a.* += dt;

        // 3. Alive marking — BRANCHLESS. `@intFromBool` is a compare-to-register:
        //    the CPU computes both outcomes and selects, with no branch for the
        //    predictor to mispredict. This is P5's core move — the data-dependent
        //    `if (age >= kill_age)` control flow becomes data-dependent *arithmetic*
        //    (a 0/1 value in a register). `life` is gone: the check compares
        //    directly against `config.kill_age`.
        for (0..n) |i| {
            al[i] = @intFromBool(ag[i] < config.kill_age);
        }

        // 4. Branchless in-place compaction. Live particles compacted forward
        //    into the front of the array; dead particles left in place (their
        //    self-copy is a no-op) for the spawn pass to overwrite. The
        //    destination is selected by ARITHMETIC, not a branch:
        //
        //      dest = write * is_alive + i * (1 - is_alive)
        //
        //    If alive: dest = write (copy to the next live slot, bump write).
        //    If dead:  dest = i    (self-copy = no-op, write unchanged).
        //
        //    Every iteration does the same work: 8 reads, 8 writes, 1 add. No
        //    `if`, no branch, no misprediction. This is the P5 payoff — under an
        //    adversarial alive pattern (every-other alive), the branchy version
        //    (`if alive, copy`) mispredicts ~50% of the time; this version's
        //    misprediction rate is 0%.
        //
        //    Forward in-place safety: dest <= i always (prefix-count of live
        //    particles before i can't exceed i). So we never overwrite a
        //    position we haven't read yet. Positions < i have already been
        //    processed; overwriting them is safe.
        var write: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const is_alive: usize = @intCast(al[i]);
            const one_minus: usize = 1 - is_alive;
            const dest = write * is_alive + i * one_minus;

            // Copy particle i → dest (unconditional; self-copy when dead = no-op).
            // Read into a register first, then write — never aliasing since
            // dest <= i and we read i before any later particle overwrites it.
            const px_i = px[i];
            px[dest] = px_i;
            const py_i = py[i];
            py[dest] = py_i;
            const pz_i = pz[i];
            pz[dest] = pz_i;
            const vx_i = vx[i];
            vx[dest] = vx_i;
            const vy_i = vy[i];
            vy[dest] = vy_i;
            const vz_i = vz[i];
            vz[dest] = vz_i;
            const ag_i = ag[i];
            ag[dest] = ag_i;
            const kd_i = kd[i];
            kd[dest] = kd_i;

            write += is_alive;
        }
        const live_count = write;

        // 5. Spawn — fill the dead slots (indices live_count..n-1) with new
        //    particles drawn from the RNG. N is maintained: the sim has exactly
        //    `n` particles every frame, same as stages 1–3.
        //
        //    RNG-draw-order equivalence with stages 1–3: in stages 1–3 the kill
        //    pass processes particles in index order and draws RNG for each dead
        //    one (first dead → first draw, second dead → second draw, …). Here,
        //    the dead slots are live_count, live_count+1, …, n-1 — filled in
        //    that order. The SAME number of draws, in the SAME sequence. The
        //    spawned particles get the same (kind, jitter_x, jitter_y, age)
        //    values; they start at (0,0,0) with the same impulse velocity; and
        //    they're integrated identically from the next frame on. The golden
        //    check sorts, so the index assignment doesn't matter — only the
        //    multiset of states, which is identical. Golden PASS.
        var j: usize = live_count;
        while (j < n) : (j += 1) {
            self.drawHotToStreams(j);
        }

        // 6. Dispatch — the deliberate per-particle `switch(kind)` hot branch
        //    (same as stages 1–3; removed in stage 5). Reads the final kind array
        //    (compacted + spawned). Kept scalar/branchy: stage 4's lesson is the
        //    kill branch, not the dispatch branch.
        for (0..n) |k| {
            _ = switch (kd[k]) {
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
            // Color is computed from kind (a 3-entry lookup) — no longer stored
            // in a cold array. The audit flagged color at 0.036 density (a pure
            // function of kind); stage 4 makes it a lookup, not a field.
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
        self.alloc.free(self.age);
        self.alloc.free(self.kind);
        self.alloc.free(self.alive);
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
    /// Stage 4: pos (12) + vel (12) + age (4) + kind (1) + alive (1) = 30 B.
    /// `life` and the entire cold array are gone from storage — the audit
    /// predicted both removals. The +1 vs stage 3's 29 is the `alive` scratch
    /// mask the branchless compaction reads and writes.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1 + 1; // pos + vel + age + kind + alive
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Same 8 streams as stage 3 (life was already gone
    /// from stage 3's dump; the cold array was never dumped). The `alive` mask
    /// is NOT dumped — it's transient scratch (computed and consumed each
    /// frame), not a particle field. The fingerprint matches stage 3 (same
    /// streams, same per-component layout); the density reflects the same real
    /// signal (pos/vel/age) + the same 3-value kind dispatch.
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
    /// same order, same methods as stages 1–3's drawHotToStreams/spawnParticle)
    /// and write them into the SoA streams. Used by both init and the spawn
    /// pass, so the RNG sequence stays synchronized and the math matches
    /// byte-for-byte. `life` is gone — it was a constant (kill_age); the kill
    /// check compares directly. No cold to write — color is computed from kind
    /// in render, and size/rotation/mass/flags/seed are removed (constants or
    /// dead data).
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
        self.age[i] = r.float(f32) * config.kill_age; // staggered spawn ages
        self.kind[i] = kind;
    }
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

/// One component's integrate + forces pass, SCALAR (same as stage 3 — no
/// @Vector; stage 6 introduces explicit SIMD, the throughput reward the SoA
/// layout unlocks, per P7).
///   pos[i] += vel[i] * dt        (integrate, using OLD vel)
///   vel[i]  = old_vel + (g + drag*old_vel) * dt   (forces)
/// `vel` is loaded once and used for both — matches stage 2/3's single-load
/// profile.
fn mathPass(pos: []f32, vel: []f32, n: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    for (pos[0..n], vel[0..n]) |*p, *v| {
        const o = v.*;
        p.* += o * dt;
        v.* = o + (g + drag * o) * dt;
    }
}
