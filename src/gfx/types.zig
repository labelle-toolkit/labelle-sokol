/// Pure-data types and color constants for the sokol gfx backend.
/// Kept self-contained (no state, no sokol_gl calls) so they can be
/// imported by every other gfx submodule without creating cycles.
const sokol = @import("sokol");
const sg = sokol.gfx;
const core = @import("labelle-core");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct {
    /// THIS BACKEND's texture identifier (the `sg.Image` id), deliberately
    /// NOT the engine-facing `TextureId` that labelle-gfx's registry hands
    /// out. Those are independent numbering spaces — sokol's is
    /// `(gen_ctr << 16) | slot`, which is exactly why keying gfx's registry
    /// by it collided with catalog handles (labelle-engine#813). Typed so the
    /// two cannot be confused (RFC-TEXTURE-ID-TYPING, labelle-gfx#328).
    id: core.BackendTextureId = .none,
    img: sg.Image = .{},
    view: sg.View = .{},
    smp: sg.Sampler = .{},
    width: i32 = 0,
    height: i32 = 0,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Vector2 = struct {
    x: f32,
    y: f32,
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
