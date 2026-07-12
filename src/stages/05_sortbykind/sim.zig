// Stage 5: sort by kind / de-virtualize (P6).
//
// P6: per-element dispatch is a layout problem in disguise. De-virtualize.
//
// Stages 1–4 have a per-particle `switch (kind)` dispatch in the hot loop —
// a data-dependent branch the predictor must guess per-particle, per-frame.
// (In this sim the cases are deliberately empty no-ops — the *branch* is the
// point, not the work. See "the dispatch was already free" below for what the
// PMC measured about that.) Stage 5 restructures the data so the dispatch
// moves OUT of the per-particle loop INTO the data layout: after compaction +
// spawn, the particles are sorted by kind (Dutch-flag 3-way partition, in-place,
// O(n), O(1) space). Now same-kind particles are contiguous — a "run." The
// dispatch loop iterates each kind's run separately, with NO per-particle
// switch: the loop body is "specialized" per run (in a real system, each run
// would have kind-specific physics; here the work is identical, but the
// *structure* is de-virtualized).
//
// The layout transformation:
//   before (stages 1–4): [smoke, spark, smoke, debris, spark, smoke, ...] (mixed)
//     → per-particle switch(kind) in the dispatch loop
//   after  (stage 5):    [smoke, smoke, ..., spark, spark, ..., debris, debris, ...]
//     → per-kind run iteration, no switch
//
// The sort is variant (a) of the plan: "sort by kind, then iterate each kind's
// contiguous run separately." Variant (b) — split into per-kind streams
// (smoke.pos[], spark.pos[], ...) — avoids the per-frame sort but requires 3×
// the memory (worst case all particles are one kind), infeasible at N=64M on a
// 16 GB machine. The sort approach uses the same memory as stage 4 (no blowup).
//
// THE DISPATCH WAS ALREADY FREE — THE HONEST FINDING. The plan expected the
// per-particle switch to be a real branch cost that de-virtualizing would
// remove. The PMC data says otherwise: stage 4 (which still HAS the switch)
// measured % Discarded at ~0.3–0.9% — near zero. The kill branch (eliminated
// by stage 4's branchless compaction) was the source of the discarded cycles;
// the switch (empty cases) was compiler-optimized away. So removing the switch
// in stage 5 changes nothing in the generated binary. The sort is pure O(n)
// overhead with no compensating dispatch savings. The de-virtualization
// *structure* lands (per-kind runs, no switch in source); the *time* does not
// improve — the switch was already free, and the sort adds overhead. The time
// win P6 promises would require per-kind WORK (not present in this sim — all
// kinds share the same physics) or the SIMD reward (stage 6), where per-kind
// contiguous runs enable kind-specialized vectorized loops.
//
// GOLDEN CHECK. The sort changes storage order each frame, but:
//   1. The RNG sequence is preserved — kill/respawn happens BEFORE the sort
//      (in storage order), so the RNG draws are in the same sequence as stage 4.
//   2. The sorted golden check tolerates reordering — it compares the multiset
//      of (pos, vel), not the storage order. The multiset is preserved because
//      the same RNG values are drawn (in the same sequence), just assigned to
//      different slots; the physics is slot-independent, so the multiset of
//      trajectories is identical.
// Golden PASS (max delta = 0.00).
//
// LOOP STRUCTURE (step):
//   1. Math passes (same as stage 3/4 — fused per-component, scalar).
//   2. Age update (branchless pass, same as stage 4).
//   3. Alive marking (branchless, same as stage 4).
//   4. Compaction (branchless, same as stage 4).
//   5. Spawn (fill dead slots, same as stage 4 — RNG drawn in slot order).
//   6. Sort by kind (NEW — Dutch flag 3-way partition, in-place, O(n)).
//   7. Dispatch: REMOVED (was a no-op switch; per-kind runs are implicit in
//      the sorted layout — in a real system, each run gets a specialized loop).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // Hot SoA streams — same 8 streams as stage 4 (life and cold are gone from
    // storage). The sort-by-kind reorders these in-place each frame so same-kind
    // particles are contiguous.
    pos_x: []f32,
    pos_y: []f32,
    pos_z: []f32,
    vel_x: []f32,
    vel_y: []f32,
    vel_z: []f32,
    age: []f32,
    kind: []fw.ParticleKind,

    // Branchless-compaction scratch (same as stage 4). Transient — not in
    // dumpFields.
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
        // Sort by kind at init so the first frame starts sorted (the per-frame
        // sort in step() maintains the invariant thereafter).
        self.sortByKind();
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
        //    stages 3–4). Math is byte-for-byte identical (golden check proves it).
        mathPass(px, vx, n, dt, config.gravity.x);
        mathPass(py, vy, n, dt, config.gravity.y);
        mathPass(pz, vz, n, dt, config.gravity.z);

        // 2. Age update (branchless pass, same as stage 4).
        for (ag[0..n]) |*a| a.* += dt;

        // 3. Alive marking (branchless, same as stage 4).
        for (0..n) |i| {
            al[i] = @intFromBool(ag[i] < config.kill_age);
        }

        // 4. Branchless in-place compaction (same as stage 4). Live particles
        //    compacted forward; dead slots left at the end for spawn.
        var write: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const is_alive: usize = @intCast(al[i]);
            const one_minus: usize = 1 - is_alive;
            const dest = write * is_alive + i * one_minus;

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

        // 5. Spawn — fill dead slots (same as stage 4). RNG drawn in slot order
        //    (live_count..n-1), same sequence as stage 4. The sort in step 6
        //    doesn't affect the RNG draws.
        var j: usize = live_count;
        while (j < n) : (j += 1) {
            self.drawHotToStreams(j);
        }

        // 6. Sort by kind — the stage 5 transformation. Dutch-flag 3-way
        //    partition (in-place, O(n), O(1) space). After this, the array is
        //    [smoke..., spark..., debris...] — same-kind particles contiguous.
        //    The per-particle switch dispatch is replaced by per-kind run
        //    iteration (implicit in the sorted layout).
        //
        //    The sort has a data-dependent 3-way branch (on kind), but it's in
        //    a structural sort pass, not in the per-particle hot loop. In a real
        //    system with per-kind work, the sorted layout enables specialized
        //    inner loops (no switch) — the de-virtualization P6 promises. Here,
        //    without per-kind work, the sort is overhead (see file header).
        self.sortByKind();

        // 7. Dispatch — REMOVED. Stages 1–4 had a per-particle `switch(kind)`
        //    here; stage 5 replaces it with the sorted layout above. The
        //    dispatch is now structural (per-kind runs), not per-particle. In a
        //    real system, each run would get a specialized loop:
        //
        //      // smoke run: [0, smoke_end)
        //      // spark run: [smoke_end, spark_end)
        //      // debris run: [spark_end, n)
        //      // — each with kind-specific physics, no switch.
        //
        //    Here the physics is kind-independent (gravity + drag, same for all),
        //    so the dispatch was a no-op. The PMC confirmed the switch was
        //    already compiler-optimized away (stage 4's % Discarded ~0.5% WITH
        //    the switch present). Removing it changes nothing in the binary;
        //    the sort is the only source-level change that affects the generated
        //    code. The layout transformation is the lesson; the time win would
        //    require per-kind work or SIMD (stage 6).
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
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
    /// Same as stage 4: pos (12) + vel (12) + age (4) + kind (1) + alive (1) = 30 B.
    /// The sort touches the same 8 hot streams (reads + writes them in-place);
    /// it doesn't add new fields, just reorders the existing ones.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1 + 1; // pos + vel + age + kind + alive
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Same 8 streams as stage 4, but `kind` is now SORTED
    /// ([0,0,...,0, 1,1,...,1, 2,2,...,2]) — gzip compresses it to almost
    /// nothing (density → ~0). This is the audit signal the sort landed: kind
    /// goes from a per-particle dispatch field (3 interleaved values, density
    /// ~0.32) to a structural run boundary (3 contiguous runs, density ~0).
    /// The MEAN density drops slightly (kind contributes ~0 instead of ~0.32),
    /// but this is the sort transformation reflected in the audit — kind left
    /// per-particle dispatch and became a layout boundary.
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
    /// same order, same methods as stages 1–4) and write them into the SoA
    /// streams. Used by both init and the spawn pass, so the RNG sequence stays
    /// synchronized and the math matches byte-for-byte.
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

    /// Dutch-flag 3-way partition by kind (smoke=0, spark=1, debris=2).
    /// In-place, O(n) time, O(1) space. After this, the array is sorted:
    /// [smoke..., spark..., debris...]. Same-kind particles are contiguous —
    /// the per-particle switch dispatch becomes per-kind run iteration.
    ///
    /// The algorithm: three pointers (lo, mid, hi). lo is the boundary between
    /// smoke and spark; mid is the current element; hi is the boundary between
    /// spark and debris (exclusive). Elements < mid are sorted; elements >= hi
    /// are debris (in place). Each iteration places at least one element:
    ///   kind[mid] == smoke (0): swap(lo, mid), lo++, mid++ (smoke grows left)
    ///   kind[mid] == spark (1): mid++ (spark stays in the middle)
    ///   kind[mid] == debris (2): hi--, swap(mid, hi) (debris grows right;
    ///                            don't advance mid — the swapped element is new)
    fn sortByKind(self: *@This()) void {
        const kd = self.kind;
        const n = self.n;
        var lo: usize = 0;
        var mid: usize = 0;
        var hi: usize = n;
        while (mid < hi) {
            const k = @intFromEnum(kd[mid]);
            if (k == 0) { // smoke → swap to the left
                self.swapParticle(lo, mid);
                lo += 1;
                mid += 1;
            } else if (k == 1) { // spark → stays in the middle
                mid += 1;
            } else { // debris → swap to the right
                hi -= 1;
                self.swapParticle(mid, hi);
            }
        }
    }

    /// Swap all 8 hot fields between two particle indices. The Dutch-flag sort
    /// calls this to move particles between kind-regions. Each swap is 8 field
    /// swaps (8 reads + 8 writes); the sort does at most n swaps (each swap
    /// places at least one element in its final region).
    fn swapParticle(self: *@This(), i: usize, j: usize) void {
        if (i == j) return;
        std.mem.swap(f32, &self.pos_x[i], &self.pos_x[j]);
        std.mem.swap(f32, &self.pos_y[i], &self.pos_y[j]);
        std.mem.swap(f32, &self.pos_z[i], &self.pos_z[j]);
        std.mem.swap(f32, &self.vel_x[i], &self.vel_x[j]);
        std.mem.swap(f32, &self.vel_y[i], &self.vel_y[j]);
        std.mem.swap(f32, &self.vel_z[i], &self.vel_z[j]);
        std.mem.swap(f32, &self.age[i], &self.age[j]);
        std.mem.swap(fw.ParticleKind, &self.kind[i], &self.kind[j]);
    }
};

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

/// Copy a contiguous SoA stream's raw bytes for the audit (same as stages 3–4).
fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, SCALAR (same as stages 3–4 — no
/// @Vector; stage 6 introduces explicit SIMD, the throughput reward the SoA
/// layout unlocks, per P7).
fn mathPass(pos: []f32, vel: []f32, n: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    for (pos[0..n], vel[0..n]) |*p, *v| {
        const o = v.*;
        p.* += o * dt;
        v.* = o + (g + drag * o) * dt;
    }
}
