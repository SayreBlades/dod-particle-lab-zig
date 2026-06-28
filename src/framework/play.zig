// play driver: opens a raylib window and runs update+render in an infinite
// loop. Never reports benchmark numbers (that's bench.zig's job).

const std = @import("std");
const rl = @import("raylib");
const fw = @import("sim.zig");

const W: c_int = 1024;
const H: c_int = 1024;
const DEFAULT_N: usize = 65_000; // enough to look dense, few enough to be fast

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    _ = init; // play mode does no I/O beyond raylib + stderr
    const alloc = std.heap.smp_allocator;

    rl.initWindow(W, H, "DOD Particle Lab");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const stage_n = @import("options").stage;
    const stage_label = fw.stageName(stage_n);

    var sim = try SimImpl.init(alloc, .{ .n = DEFAULT_N, .seed = 0xC0FFEE });
    defer sim.deinit();

    // CPU RGBA framebuffer; Sim.render() writes here, we upload to GPU each frame.
    const fb = try alloc.alloc(u8, @intCast(W * H * 4));
    defer alloc.free(fb);

    // Create an empty GPU texture sized to the framebuffer.
    var img = rl.genImageColor(W, H, rl.black);
    defer rl.unloadImage(img);
    rl.imageFormat(&img, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    const tex = rl.loadTextureFromImage(img);
    defer rl.unloadTexture(tex);

    var paused = false;
    var show_hud = true;

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(rl.KEY_P)) paused = !paused;
        if (rl.isKeyPressed(rl.KEY_F1)) show_hud = !show_hud;

        const dt: f32 = if (paused) 0 else rl.getFrameTime();
        sim.step(dt);
        sim.render(fb, @intCast(W), @intCast(H));
        rl.updateTexture(tex, @ptrCast(fb.ptr));

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.black);
        rl.drawTexture(tex, 0, 0, rl.white);

        if (show_hud) {
            rl.drawFPS(10, 10);
            drawTextZ(stage_label, 10, 32, 20, rl.green);
            var buf: [64]u8 = undefined;
            const n_str = std.fmt.bufPrint(&buf, "N: {d}", .{sim.n}) catch "N: ?";
            drawTextZ(n_str, 10, 56, 20, rl.yellow);
            if (paused) drawTextZ("PAUSED", 10, 80, 20, rl.yellow);
            drawTextZ("ESC: quit  P: pause  F1: hud", 10, H - 28, 16, rl.white);
        }
    }
}

fn drawTextZ(text: []const u8, x: c_int, y: c_int, size: c_int, color: rl.Color) void {
    var buf: [128]u8 = undefined;
    if (text.len >= buf.len) return;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    rl.drawText(@ptrCast(&buf), x, y, size, color);
}
