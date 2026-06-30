/// Screen / design / camera state for the sokol gfx backend, plus the
/// coordinate helpers (`toNdcX`, `toNdcY`, `screenToDesign`,
/// `designToPhysical`) every draw primitive needs. Everything that
/// touches the module-level mutable state lives here so the draw
/// submodule can stay state-free.
const std = @import("std");
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Camera2D = types.Camera2D;

// ── Screen dimensions (set by the app's frame callback) ─────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var design_w: i32 = 800;
var design_h: i32 = 600;

// Aspect-preserving fit scale from design → physical, recomputed on any
// dimension change instead of per-vertex. Used by toNdcX/toNdcY and
// drawCircle to letterbox/pillarbox the design canvas inside the window.
var fit_scale_x: f32 = 1.0;
var fit_scale_y: f32 = 1.0;

// When false, toNdcX/toNdcY skip the fit_scale multiplication and the
// design canvas stretches to fill the entire physical framebuffer. The
// renderer toggles this around `screen_fill` layers so backdrops can
// cover the pillarbox bars while game content stays correctly fitted.
var fit_active: bool = true;

pub fn setApplyFit(active: bool) void {
    fit_active = active;
}

/// Convert a physical-pixel screen coordinate (e.g. a sokol_app touch
/// or mouse event in framebuffer pixels) to a design-pixel coordinate
/// inside the pillarboxed/letterboxed canvas.
///
/// Touch / mouse events arrive in raw framebuffer pixels, but
/// game-level math (`cam.screenToWorld`, sprite positions, etc.) all
/// works in design pixels. Without this conversion, a pinch midpoint
/// computed from two touches would be off by the pillarbox bar width
/// and a global zoom factor.
pub fn screenToDesign(px: f32, py: f32) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return .{ .x = px, .y = py };
    }
    // Always apply the fitted-mode inverse mapping. `fit_active` is a
    // transient render-state flag toggled per-layer inside the draw
    // loop (fitted for world/UI layers, off for `screen_fill` layers)
    // — by the time event callbacks fire, it's whatever the last layer
    // left it at, which is meaningless for input mapping. Touch/mouse
    // events arrive in raw framebuffer pixels and need to be unmapped
    // back to design pixels regardless of which layer the draw loop
    // happens to be in mid-frame.
    // Exact inverse of toNdc: physical framebuffer px → NDC (full-
    // framebuffer viewport) → design. The fitted content spans NDC
    // [-fit,+fit] = fit_scale*screen_w physical pixels (NOT design_w*fit),
    // so the inverse must go through NDC, not a design-space bar. (#331:
    // the old design-space bar was wrong whenever screen != design — i.e.
    // on HiDPI/Retina — clicks drifted toward the edges.)
    const ndc_x = (px / sw) * 2.0 - 1.0;
    const ndc_y = 1.0 - (py / sh) * 2.0;
    return .{
        .x = ((ndc_x / fit_scale_x) + 1.0) * 0.5 * dw,
        .y = (1.0 - ndc_y / fit_scale_y) * 0.5 * dh,
    };
}

/// Inverse of `screenToDesign`: takes a design-pixel coordinate (the
/// space game code uses) and returns its physical-pixel position inside
/// the pillarboxed/letterboxed canvas. Used by the iOS keyboard bridge
/// to position the OS soft-keyboard caret on top of the design-space
/// text input field — the bridge needs *physical* CGPoints to talk to
/// UIKit, but the input element's position is stored in design pixels.
pub fn designToPhysical(pos: Vector2) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return pos;
    }
    // Forward of toNdc: design → NDC → physical framebuffer px. Exact
    // inverse of screenToDesign (#331).
    const ndc_x = ((pos.x / dw) * 2.0 - 1.0) * fit_scale_x;
    const ndc_y = (1.0 - (pos.y / dh) * 2.0) * fit_scale_y;
    return .{
        .x = (ndc_x + 1.0) * 0.5 * sw,
        .y = (1.0 - ndc_y) * 0.5 * sh,
    };
}

fn recomputeFitScale() void {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        fit_scale_x = 1.0;
        fit_scale_y = 1.0;
        return;
    }
    const sx = sw / dw;
    const sy = sh / dh;
    const s = @min(sx, sy);
    fit_scale_x = s * dw / sw;
    fit_scale_y = s * dh / sh;
}

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = @max(1, w);
    screen_h = @max(1, h);
    recomputeFitScale();
}

/// Set the design (logical) canvas size — the resolution game code
/// operates in. Camera offsets and sprite positions are interpreted
/// in this space and then aspect-fit into the physical framebuffer
/// via `fit_scale_*` (see `recomputeFitScale`).
pub fn setDesignSize(w: i32, h: i32) void {
    design_w = @max(1, w);
    design_h = @max(1, h);
    recomputeFitScale();
}

pub fn getDesignWidth() i32 {
    return design_w;
}

pub fn getDesignHeight() i32 {
    return design_h;
}

// ── Camera state ────────────────────────────────────────────────────

var active_camera: Camera2D = .{};
var camera_active: bool = false;

// ── Coordinate helpers ──────────────────────────────────────────────

/// Convert screen-space pixel coordinates to NDC (-1..1) for sokol_gl.
/// Always maps against the design canvas (design_w/design_h), then applies
/// the cached aspect-preserving fit scale so the same game coordinates
/// produce correct, non-stretched NDC regardless of the physical
/// framebuffer size.
///
/// The camera's offset is produced by labelle-gfx's camera.toBackend() as
/// `{ getScreenWidth()/2, getScreenHeight()/2 }`; since getScreenWidth/Height
/// return the design dimensions, `cam.offset` is also in design pixels and
/// the division cancels correctly.
///
/// design_w/h are clamped ≥ 1 by setScreenSize/setDesignSize, so the
/// divisions below are guaranteed safe.
pub fn toNdcX(px: f32) f32 {
    const dw: f32 = @floatFromInt(design_w);
    const raw = if (!camera_active)
        (px / dw) * 2.0 - 1.0
    else blk: {
        const cam = active_camera;
        const screen_x = (px - cam.target.x) * cam.zoom + cam.offset.x;
        break :blk (screen_x / dw) * 2.0 - 1.0;
    };
    return if (fit_active) raw * fit_scale_x else raw;
}

pub fn toNdcY(py: f32) f32 {
    const dh: f32 = @floatFromInt(design_h);
    const raw = if (!camera_active)
        1.0 - (py / dh) * 2.0
    else blk: {
        const cam = active_camera;
        // Positions arrive in screen-space Y-down (Y-flipped by renderer.toScreenY).
        const screen_y = (py - cam.target.y) * cam.zoom + cam.offset.y;
        break :blk 1.0 - (screen_y / dh) * 2.0;
    };
    return if (fit_active) raw * fit_scale_y else raw;
}

// ── Camera control + queries (used by drawCircle / public API) ─────

pub fn isCameraActive() bool {
    return camera_active;
}

pub fn cameraZoom() f32 {
    return active_camera.zoom;
}

pub fn isFitActive() bool {
    return fit_active;
}

pub fn fitScaleX() f32 {
    return fit_scale_x;
}

pub fn fitScaleY() f32 {
    return fit_scale_y;
}

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
    camera_active = true;
}

pub fn endMode2D() void {
    camera_active = false;
}

pub fn getScreenWidth() i32 {
    // Return the design canvas width so camera offset / viewport math works
    // in design pixels (resolution-independent). Physical framebuffer size is
    // tracked separately in screen_w/screen_h but isn't exposed here.
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        // Screen Y-down convention, same as raylib backend
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        // Screen Y-down convention, same as raylib backend
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}
