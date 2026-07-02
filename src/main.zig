// Entry point. Comptime switch on opts.stage -> SimImpl, opts.mode -> driver.
const std = @import("std");
const opts = @import("options");
const fw = @import("framework/sim.zig");

const SimImpl = switch (opts.stage) {
    1 => @import("stages/01_naive/sim.zig").Sim,
    2 => @import("stages/02_hotcold/sim.zig").Sim,
    else => @compileError("stage not yet implemented"),
};

pub fn main(init: std.process.Init) !void {
    return switch (opts.mode) {
        .play => @import("framework/play.zig").run(SimImpl, init),
        .bench => @import("framework/bench.zig").run(SimImpl, init),
        .audit => @import("framework/audit.zig").run(SimImpl, init),
    };
}
