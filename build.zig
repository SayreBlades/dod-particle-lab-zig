const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- build options: -Dstage=1 -Dmode=play ---
    const stage_str = b.option([]const u8, "stage", "stage number 1..11") orelse "1";
    const mode_str = b.option([]const u8, "mode", "play | bench") orelse "play";

    const stage: u32 = std.fmt.parseInt(u32, stage_str, 10) catch {
        std.debug.panic("invalid -Dstage='{s}' (expected integer)", .{stage_str});
    };
    const mode: Mode = blk: {
        if (std.mem.eql(u8, mode_str, "play")) break :blk .play;
        if (std.mem.eql(u8, mode_str, "bench")) break :blk .bench;
        std.debug.panic("invalid -Dmode='{s}' (play|bench)", .{mode_str});
    };
    const mode_enum: Mode = mode;

    const opts = b.addOptions();
    opts.addOption(u32, "stage", stage);
    opts.addOption(Mode, "mode", mode_enum);

    // --- raylib C library (compiled directly; raylib-zig build is broken on 0.17-dev) ---
    const raylib_lib = addRaylib(b, target, optimize);

    // --- main exe ---
    const exe = b.addExecutable(.{
        .name = "dod-particles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("options", opts);
    exe.root_module.addImport("raylib", raylib_module: {
        const rl_mod = b.createModule(.{
            .root_source_file = b.path("src/bindings/raylib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        rl_mod.linkLibrary(raylib_lib);
        break :raylib_module rl_mod;
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);
}

pub const Mode = enum { play, bench };

fn addRaylib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const c_flags = &.{
        "-std=c11",
        "-DPLATFORM_DESKTOP",
        "-DGRAPHICS_API_OPENGL_33",
        "-ObjC",
    };

    const sources = [_][]const u8{
        "rcore.c",
        "rglfw.c",
        "rshapes.c",
        "rtextures.c",
        "rtext.c",
        "rmodels.c",
    };

    const lib = b.addLibrary(.{
        .name = "raylib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    inline for (sources) |s| {
        lib.root_module.addCSourceFile(.{
            .file = b.path("vendor/raylib/src/" ++ s),
            .flags = c_flags,
        });
    }
    lib.root_module.addIncludePath(b.path("vendor/raylib/src"));
    lib.root_module.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));

    lib.root_module.linkFramework("Cocoa", .{});
    lib.root_module.linkFramework("IOKit", .{});
    lib.root_module.linkFramework("CoreVideo", .{});
    lib.root_module.linkFramework("CoreFoundation", .{});
    lib.root_module.linkFramework("OpenGL", .{});

    b.installArtifact(lib);
    return lib;
}
