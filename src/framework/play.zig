// play driver: opens a raylib window and runs update+render in an infinite
// loop. Never reports benchmark numbers (that's bench.zig's job).
const std = @import("std");
const rl = @import("raylib");
const fw = @import("sim.zig");

const W: c_int = 1024;
const H: c_int = 1024;

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    _ = init; // play mode does no I/O beyond raylib + stderr
    const alloc = std.heap.smp_allocator;

    rl.initWindow(W, H, "DOD Particle Lab");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const stage_n = @import("options").stage;
    const stage_label = fw.stageName(stage_n);

    var sim = try SimImpl.init(alloc, .{ .n = 0, .seed = 0 });
    defer sim.deinit();

    // RGBA framebuffer for the software rasterizer (stages 1-9 use render.zig;
    // stage 10 overrides). For C1 the stub just clears to black.
    const fb = try alloc.alloc(u8, @intCast(W * H * 4));
    defer alloc.free(fb);

    var paused = false;
    var show_hud = true;

    while (!rl.windowShouldClose()) {
        // input
        if (rl.isKeyPressed(rl.KEY_P)) paused = !paused;
        if (rl.isKeyPressed(rl.KEY_F1)) show_hud = !show_hud;

        const dt: f32 = if (paused) 0 else rl.getFrameTime();
        sim.step(dt);
        sim.render(fb, @intCast(W), @intCast(H));

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.black);

        // (In C1 render() just clears fb to black; nothing else to draw yet.
        //  C2 will upload fb to a texture and DrawTexture it here.)
        // Draw a black rect to indicate the framebuffer region.
        // (placeholder until C2 wires up a GPU texture)

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
