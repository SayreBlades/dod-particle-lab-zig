// Minimal hand-written raylib bindings.
// @cImport is gone in 0.17-dev; we declare only what we use as extern "c".
// Grown as stages need more functions.

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Image = extern struct {
    data: ?*anyopaque,
    width: c_int,
    height: c_int,
    mipmaps: c_int,
    format: c_int,
};

pub const Texture2D = extern struct {
    id: c_uint,
    width: c_int,
    height: c_int,
    mipmaps: c_int,
    format: c_int,
};

pub const Vector2 = extern struct { x: f32, y: f32 };

pub const PIXELFORMAT_UNCOMPRESSED_R8G8B8A8: c_int = 7;

pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const yellow: Color = .{ .r = 255, .g = 255, .b = 0, .a = 255 };

// key codes (subset; from raylib KeyboardKey)
pub const KEY_ESCAPE: c_int = 256;
pub const KEY_F1: c_int = 290;
pub const KEY_P: c_int = 80;
pub const KEY_RIGHT: c_int = 262;
pub const KEY_LEFT: c_int = 263;

extern "c" fn InitWindow(width: c_int, height: c_int, title: [*:0]const u8) void;
extern "c" fn CloseWindow() void;
extern "c" fn WindowShouldClose() bool;
extern "c" fn SetTargetFPS(fps: c_int) void;
extern "c" fn BeginDrawing() void;
extern "c" fn EndDrawing() void;
extern "c" fn ClearBackground(color: Color) void;
extern "c" fn DrawText(text: [*:0]const u8, pos_x: c_int, pos_y: c_int, font_size: c_int, color: Color) void;
extern "c" fn DrawFPS(pos_x: c_int, pos_y: c_int) void;
extern "c" fn IsKeyPressed(key: c_int) bool;
extern "c" fn IsKeyDown(key: c_int) bool;
extern "c" fn GetFrameTime() f32;
extern "c" fn GenImageColor(width: c_int, height: c_int, color: Color) Image;
extern "c" fn UnloadImage(image: Image) void;
extern "c" fn ImageFormat(image: *Image, new_format: c_int) void;
extern "c" fn LoadTextureFromImage(image: Image) Texture2D;
extern "c" fn UnloadTexture(texture: Texture2D) void;
extern "c" fn UpdateTexture(texture: Texture2D, pixels: ?*const anyopaque) void;
extern "c" fn DrawTexture(texture: Texture2D, pos_x: c_int, pos_y: c_int, tint: Color) void;

pub const initWindow = InitWindow;
pub const closeWindow = CloseWindow;
pub const windowShouldClose = WindowShouldClose;
pub const setTargetFPS = SetTargetFPS;
pub const beginDrawing = BeginDrawing;
pub const endDrawing = EndDrawing;
pub const clearBackground = ClearBackground;
pub const drawText = DrawText;
pub const drawFPS = DrawFPS;
pub const isKeyPressed = IsKeyPressed;
pub const isKeyDown = IsKeyDown;
pub const getFrameTime = GetFrameTime;
pub const genImageColor = GenImageColor;
pub const unloadImage = UnloadImage;
pub const imageFormat = ImageFormat;
pub const loadTextureFromImage = LoadTextureFromImage;
pub const unloadTexture = UnloadTexture;
pub const updateTexture = UpdateTexture;
pub const drawTexture = DrawTexture;
