// Shared software rasterizer (stages 1-9 use this; stage 10 overrides).
//
// Draws particles as additive splats into an RGBA framebuffer. The sim's
// render() method writes this buffer; the play driver uploads it to a GPU
// texture via raylib UpdateTexture.
//
// World coordinates are in [-view_half, view_half]; the framebuffer covers the
// same extent in both axes (square).

const std = @import("std");
const config = @import("config.zig");

/// Clear the framebuffer to black.
pub fn clear(fb: []u8) void {
    @memset(fb, 0);
}

/// Convert a world x in [-view_half, view_half] to framebuffer pixel x [0, w).
pub fn worldToPxX(x: f32, w: u32) i32 {
    const half: f32 = @floatFromInt(w);
    const norm = (x + config.view_half) / (2.0 * config.view_half); // [0,1)
    return @intFromFloat(norm * half);
}

/// Convert a world y in [-view_half, view_half] to framebuffer pixel y [0, h).
/// World +y is up; framebuffer +y is down → invert.
pub fn worldToPxY(y: f32, h: u32) i32 {
    const half: f32 = @floatFromInt(h);
    const norm = (config.view_half - y) / (2.0 * config.view_half); // [0,1)
    return @intFromFloat(norm * half);
}

/// Draw one particle as a 2x2 additive splat at world (x,y) with color (r,g,b).
/// Color components are f32; clamped to [0,255] internally.
pub fn splat(
    fb: []u8,
    w: u32,
    h: u32,
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
) void {
    const r8: u8 = clamp255(r);
    const g8: u8 = clamp255(g);
    const b8: u8 = clamp255(b);
    const px = worldToPxX(x, w);
    const py = worldToPxY(y, h);
    var dy: i32 = 0;
    while (dy < 2) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < 2) : (dx += 1) {
            const fx = px + dx;
            const fy = py + dy;
            if (fx < 0 or fx >= w or fy < 0 or fy >= h) continue;
            const i: usize = @intCast((fy * @as(i32, @intCast(w)) + fx) * 4);
            if (i + 3 >= fb.len) continue;
            fb[i + 0] = addClamp(fb[i + 0], r8);
            fb[i + 1] = addClamp(fb[i + 1], g8);
            fb[i + 2] = addClamp(fb[i + 2], b8);
            fb[i + 3] = 255;
        }
    }
}

fn clamp255(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(v);
}

fn addClamp(a: u8, b: u8) u8 {
    const sum: u16 = @as(u16, a) + @as(u16, b);
    return if (sum > 255) 255 else @intCast(sum);
}
