// hardware.zig — runtime cache/memory profile via sysctl.
// Printed at the start of every bench run so the numbers anchor the DOD story.
// (Same facts as scripts/hardware_profile.sh, consumed programmatically here.)

const std = @import("std");
const Io = std.Io;

pub const Facts = struct {
    cpu: [128]u8 = undefined,
    cpu_len: usize = 0,
    cachelinesize: u64 = 0,
    l1dcachesize: u64 = 0,
    l1icachesize: u64 = 0,
    l2cachesize: u64 = 0,
    l3cachesize: u64 = 0,
    pagesize: u64 = 0,
    memsize: u64 = 0,
    physicalcpu: u64 = 0,
    logicalcpu: u64 = 0,
};

pub fn detect() Facts {
    var f = Facts{};
    f.cpu_len = readSysctlBytes("machdep.cpu.brand_string", &f.cpu);
    f.cachelinesize = readSysctlU64("hw.cachelinesize");
    f.l1dcachesize = readSysctlU64("hw.l1dcachesize");
    f.l1icachesize = readSysctlU64("hw.l1icachesize");
    f.l2cachesize = readSysctlU64("hw.l2cachesize");
    f.l3cachesize = readSysctlU64("hw.l3cachesize");
    f.pagesize = readSysctlU64("hw.pagesize");
    f.memsize = readSysctlU64("hw.memsize");
    f.physicalcpu = readSysctlU64("hw.physicalcpu");
    f.logicalcpu = readSysctlU64("hw.logicalcpu");
    return f;
}

pub fn print(f: Facts) void {
    std.debug.print("=== Hardware ===\n", .{});
    std.debug.print("  cpu              : {s}\n", .{f.cpu[0..f.cpu_len]});
    std.debug.print("  cores            : physical={d} logical={d}\n", .{ f.physicalcpu, f.logicalcpu });
    std.debug.print("  hw.cachelinesize = {d}\n", .{f.cachelinesize});
    std.debug.print("  hw.l1dcachesize  = {d}\n", .{f.l1dcachesize});
    std.debug.print("  hw.l1icachesize  = {d}\n", .{f.l1icachesize});
    std.debug.print("  hw.l2cachesize   = {d}\n", .{f.l2cachesize});
    std.debug.print("  hw.l3cachesize   = {d}\n", .{f.l3cachesize});
    std.debug.print("  hw.pagesize      = {d}\n", .{f.pagesize});
    std.debug.print("  hw.memsize       = {d}\n", .{f.memsize});
    std.debug.print("\n", .{});
}

fn readSysctlU64(name: [:0]const u8) u64 {
    var value: u64 = 0;
    var size: usize = @sizeOf(u64);
    const c_name: [*:0]const u8 = name.ptr;
    if (std.c.sysctlbyname(c_name, @ptrCast(&value), &size, null, 0) != 0) return 0;
    return value;
}

fn readSysctlBytes(name: [:0]const u8, out: []u8) usize {
    var size: usize = out.len;
    const c_name: [*:0]const u8 = name.ptr;
    if (std.c.sysctlbyname(c_name, @ptrCast(out.ptr), &size, null, 0) != 0) return 0;
    if (size > 0 and size <= out.len) {
        // trim trailing null
        if (out[size - 1] == 0) size -= 1;
        return size;
    }
    return 0;
}
