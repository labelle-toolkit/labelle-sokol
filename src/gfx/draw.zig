/// Shape and sprite draw primitives for the sokol gfx backend.
/// Each function converts design-pixel input → NDC via `state.toNdc*`
/// and submits through sokol_gl. State-free at the module level — all
/// camera/screen/fit state lives in `state.zig`.
const std = @import("std");
const sokol = @import("sokol");
const sgl = sokol.gl;
const types = @import("types.zig");
const state = @import("state.zig");

const Texture = types.Texture;
const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    // Guard against division by zero
    if (texture.width == 0 or texture.height == 0) return;

    // Calculate UV coordinates from the source rectangle.
    //
    // Negative source.width / source.height are the labelle-gfx convention
    // for "flip horizontally / vertically" — the renderer negates the rect
    // dimensions when sprite.flip_x or sprite.flip_y is set. The atlas
    // region itself always lives at [source.x, source.x + |source.width|]
    // and [source.y, source.y + |source.height|], so we compute the UV
    // bounds from the absolute extents and then SWAP u0/u1 (or v0/v1) on
    // the flip path.
    //
    // The previous implementation used `(source.x + source.width)` directly,
    // which on a flip moved the sampling LEFT of source.x and read pixels
    // from a neighboring atlas region. On a packed atlas with hundreds of
    // sprites, that neighbor was usually some other character's frame —
    // hence the "characters wearing each other's animations" symptom in
    // flying-platform-labelle when workers turned around.
    const tex_width: f32 = @floatFromInt(texture.width);
    const tex_height: f32 = @floatFromInt(texture.height);

    const sw_abs = @abs(source.width);
    const sh_abs = @abs(source.height);
    const flip_x = source.width < 0;
    const flip_y = source.height < 0;

    const u_left = source.x / tex_width;
    const u_right = (source.x + sw_abs) / tex_width;
    const v_top = source.y / tex_height;
    const v_bottom = (source.y + sh_abs) / tex_height;

    const uv0 = if (flip_x) u_right else u_left;
    const uv1 = if (flip_x) u_left else u_right;
    const tv0 = if (flip_y) v_bottom else v_top;
    const tv1 = if (flip_y) v_top else v_bottom;

    // Tint as floats (0.0 - 1.0)
    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Enable texturing and bind the image + sampler directly
    sgl.enableTexture();
    sgl.texture(texture.view, texture.smp);

    if (rotation != 0) {
        // Rotation path: translate to dest origin, rotate, draw at local coords
        const dx = dest.x;
        const dy = dest.y;
        const dw = dest.width;
        const dh = dest.height;

        // Convert to NDC for the pivot point
        const pivot_ndc_x = state.toNdcX(dx);
        const pivot_ndc_y = state.toNdcY(dy);
        // Calculate NDC scale factors using toNdcX/toNdcY difference so camera zoom applies consistently
        const ndc_w = state.toNdcX(dx + dw) - state.toNdcX(dx);
        const ndc_h = state.toNdcY(dy) - state.toNdcY(dy + dh); // positive height in NDC (Y flipped)
        const ndc_ox = state.toNdcX(dx + origin.x) - state.toNdcX(dx);
        const ndc_oy = state.toNdcY(dy) - state.toNdcY(dy + origin.y);

        sgl.pushMatrix();
        sgl.translate(pivot_ndc_x, pivot_ndc_y, 0);
        sgl.rotate(rotation * std.math.pi / 180.0, 0, 0, 1);
        sgl.translate(-ndc_ox, ndc_oy, 0); // Y flipped in NDC

        sgl.beginQuads();
        sgl.v2fT2fC4f(0, 0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, 0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, -ndc_h, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(0, -ndc_h, uv0, tv1, r, g, b, a);
        sgl.end();

        sgl.popMatrix();
    } else {
        // Fast path: no rotation, draw directly in NDC
        const dx = dest.x - origin.x;
        const dy = dest.y - origin.y;

        const x0 = state.toNdcX(dx);
        const y0 = state.toNdcY(dy);
        const x1 = state.toNdcX(dx + dest.width);
        const y1 = state.toNdcY(dy + dest.height);

        sgl.beginQuads();
        sgl.v2fT2fC4f(x0, y0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y1, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(x0, y1, uv0, tv1, r, g, b, a);
        sgl.end();
    }

    sgl.disableTexture();
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const x0 = state.toNdcX(rec.x);
    const y0 = state.toNdcY(rec.y);
    const x1 = state.toNdcX(rec.x + rec.width);
    const y1 = state.toNdcY(rec.y + rec.height);

    sgl.beginQuads();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();
}

/// Draw a filled rectangle rotated `rotation` radians around its
/// centre `(center_x, center_y)`. Width and height are in world
/// pixels (same as `drawRectangleRec`). Screen space is Y-down and
/// the rotation matrix is `[cos -sin; sin cos]`, so positive
/// rotation rotates **clockwise** in visible screen space — the
/// same direction as raylib's `DrawRectanglePro(..., rotation,
/// color)` with positive values.
///
/// Required by labelle-gfx's `drawRectanglePro` shim once a game
/// sets `Shape.rotation` on a rectangle entity. Backends that don't
/// implement this primitive fall back to the axis-aligned
/// `drawRectangleRec` via the shim — no behavioural regression for
/// games that never rotate rectangles.
pub fn drawRectanglePro(center_x: f32, center_y: f32, width: f32, height: f32, rotation: f32, tint: Color) void {
    const hw = width * 0.5;
    const hh = height * 0.5;
    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);

    const local = [4][2]f32{
        .{ -hw, -hh },
        .{ hw, -hh },
        .{ hw, hh },
        .{ -hw, hh },
    };

    sgl.beginQuads();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    for (local) |p| {
        const wx = center_x + p[0] * cos_r - p[1] * sin_r;
        const wy = center_y + p[0] * sin_r + p[1] * cos_r;
        sgl.v2f(state.toNdcX(wx), state.toNdcY(wy));
    }
    sgl.end();
}

/// Draw a rectangle outline. `line_thick` is accepted for API compatibility
/// with raylib's drawRectangleLinesEx but is ignored — sgl LINES always
/// render 1 pixel thick. For thicker outlines, the caller can compose four
/// drawRectangleRec bars instead.
pub fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
    _ = line_thick;
    const x0 = state.toNdcX(rec.x);
    const y0 = state.toNdcY(rec.y);
    const x1 = state.toNdcX(rec.x + rec.width);
    const y1 = state.toNdcY(rec.y + rec.height);

    sgl.beginLineStrip();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.v2f(x0, y0);
    sgl.end();
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments = 32;
    const cx = state.toNdcX(center_x);
    const cy = state.toNdcY(center_y);
    // Convert radius to NDC scale using design dims so it matches toNdcX/Y.
    // In camera mode, scale by zoom so the circle grows/shrinks with the camera.
    // Apply the same cached aspect-preserving fit as toNdcX/Y so the circle
    // stays round under letterbox/pillarbox.
    const rw: f32 = @floatFromInt(state.getDesignWidth());
    const rh: f32 = @floatFromInt(state.getDesignHeight());
    const zoom: f32 = if (state.isCameraActive()) state.cameraZoom() else 1.0;
    const fx: f32 = if (state.isFitActive()) state.fitScaleX() else 1.0;
    const fy: f32 = if (state.isFitActive()) state.fitScaleY() else 1.0;
    const rx = (radius * zoom / rw) * 2.0 * fx;
    const ry = (radius * zoom / rh) * 2.0 * fy;

    sgl.beginTriangleStrip();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    for (0..segments + 1) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        const next_angle = @as(f32, @floatFromInt(i + 1)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
        sgl.v2f(cx + @cos(next_angle) * rx, cy + @sin(next_angle) * ry);
    }
    sgl.end();
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, _: f32, tint: Color) void {
    sgl.beginLines();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(state.toNdcX(start_x), state.toNdcY(start_y));
    sgl.v2f(state.toNdcX(end_x), state.toNdcY(end_y));
    sgl.end();
}

/// Filled triangle through the three absolute vertices `v1`, `v2`,
/// `v3` (design-pixel space — the retained engine has already applied
/// position + scale). Submitted as a single sgl triangle, mirroring
/// how `drawCircle` / `drawRectanglePro` fill via sgl primitives with
/// `state.toNdc*` coordinate conversion. Winding is irrelevant — sgl
/// triangles are not back-face culled.
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
    sgl.beginTriangles();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(state.toNdcX(v1.x), state.toNdcY(v1.y));
    sgl.v2f(state.toNdcX(v2.x), state.toNdcY(v2.y));
    sgl.v2f(state.toNdcX(v3.x), state.toNdcY(v3.y));
    sgl.end();
}

/// Filled convex polygon through the absolute rim vertices in `points`
/// (design-pixel space — centre + scale already applied by the caller).
/// Slice/Color signature matches the labelle-gfx Backend contract;
/// emitted as a triangle fan anchored at `points[0]`, mirroring how
/// `drawTriangle` submits via sgl with `state.toNdc*` conversion.
pub fn drawPolygon(points: []const Vector2, tint: Color) void {
    if (points.len < 3) return;
    // Convert each vertex to NDC exactly once: the anchor up front and a
    // sliding window over the rim, instead of re-converting per fan triangle.
    const anchor_x = state.toNdcX(points[0].x);
    const anchor_y = state.toNdcY(points[0].y);
    sgl.beginTriangles();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    var prev_x = state.toNdcX(points[1].x);
    var prev_y = state.toNdcY(points[1].y);
    var i: usize = 2;
    while (i < points.len) : (i += 1) {
        const next_x = state.toNdcX(points[i].x);
        const next_y = state.toNdcY(points[i].y);
        sgl.v2f(anchor_x, anchor_y);
        sgl.v2f(prev_x, prev_y);
        sgl.v2f(next_x, next_y);
        prev_x = next_x;
        prev_y = next_y;
    }
    sgl.end();
}
