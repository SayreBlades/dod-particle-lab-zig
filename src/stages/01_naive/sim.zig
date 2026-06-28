// Stub Sim for C1. Real particle logic lands at C2.
const std = @import("std");
const fw = @import("../../framework/sim.zig");

pub const Sim = struct {
    n: usize,

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        _ = alloc;
        const self = try std.heap.smp_allocator.create(@This());
        self.* = .{ .n = desc.n };
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        _ = self;
        _ = dt;
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        _ = self;
        _ = w;
        _ = h;
        // clear to black
        @memset(fb, 0);
    }

    pub fn deinit(self: *@This()) void {
        std.heap.smp_allocator.destroy(self);
    }
};
