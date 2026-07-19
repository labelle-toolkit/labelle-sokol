//! Surfaceless headless golden for the sokol material seam (labelle-gfx#305,
//! Phase 3 — the FULL curated set). Renders the same FIXED 10-column scene as
//! the bgfx reference golden, covering `flash` (amount 0.6 toward red),
//! `palette_swap` (a 4-band index atlas recoloured through a LUT ramp),
//! `dissolve` (procedural-noise burn-away at threshold 0.5 with an orange edge
//! glow, plus an ATLAS sub-rect frame guarding the sprite-local noise remap,
//! plus the threshold==1 fully-clear and threshold==0 fully-solid boundary
//! cases), and `outline` (an opaque square, an anti-aliased soft disc whose
//! fractional-alpha boundary exercises the over-operator composite, an ATLAS
//! frame whose opaque red neighbour must NOT bleed into the outline, and a
//! tint.a=0.5 case whose outline fades with the sprite WITHOUT tinting its
//! interior) — FULLY headless (raw Metal device via `window.beginHeadless`, no
//! window / no display server), then captures the offscreen framebuffer to a
//! 24-bit BMP via `window.takeScreenshot` and diffs it against a committed
//! golden.
//!
//! Mirrors labelle-bgfx origin/main's `src/material_golden.zig` (same column
//! layout + uniforms + 20/20/30 background, so the two backends' captures are
//! directly comparable), adapted to sokol's headless-Metal capture path (the
//! one backend that can render with no GUI session — see
//! reference_sokol_headless_screenshots).
//!
//! Two modes (baked at build time via the `golden_options` module):
//!   bless : write the committed golden (GOLDEN_PATH). Run on a machine/CI
//!           runner with a Metal device to (re)generate after a shader change.
//!   check : render a candidate BMP + diff it against the golden with a
//!           per-channel tolerance (GPU raster is not bit-exact across drivers).
//!
//! Exit codes (mirroring bgfx):
//!   0 = OK          (bless wrote the golden, or check matched)
//!   2 = HEADLESS_INIT_FAILED  (no Metal device — e.g. non-macOS / no GPU)
//!   3 = CAPTURE_FAILED        (render/readback/BMP-write failed)
//!   4 = GOLDEN_MISMATCH       (candidate drifted beyond tolerance)
//!   5 = GOLDEN_MISSING        (check mode, no committed golden — run bless)
//!
//! Run with:  zig build material-golden        (check)
//!            zig build material-golden-bless   (regenerate)

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window");
const options = @import("golden_options");

const W: i32 = 720;
const H: i32 = 96;

const GOLDEN_PATH: [:0]const u8 = "test/golden/material_effects.bmp";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/material_effects_candidate.bmp";

// BMP: 14-byte file header + 40-byte info header = 54 bytes before pixels.
const BMP_HEADER: usize = 54;

// Diff tolerance: GPU rasterisation is not bit-exact across drivers/refreshes,
// so allow a small per-channel delta and a tiny fraction of outlier bytes. A
// broken shader recolours large areas well past this — the gate still trips.
const CHANNEL_TOL: i32 = 14;
const MAX_OUTLIER_FRAC: f32 = 0.03;

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(path: [*:0]const u8) c_int;

/// makePath-style: create the parent-dir chain of `base` so `takeScreenshot`'s
/// `fopen(.., "wb")` can't fail on a clean checkout. Zig 0.16 dropped
/// `std.fs.cwd()` (needs an Io) and we already link libc, so mkdir each prefix.
fn ensureParentDir(path: [:0]const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    var buf: [1024:0]u8 = undefined;
    if (dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        @memcpy(buf[0..i], dir[0..i]);
        buf[i] = 0;
        _ = mkdir(&buf, 0o755);
    }
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    if (fseek(file, 0, SEEK_END) != 0) return null;
    const sz = ftell(file);
    if (sz < BMP_HEADER) return null;
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const n: usize = @intCast(sz);
    const buf = std.heap.page_allocator.alloc(u8, n) catch return null;
    if (std.c.fread(buf.ptr, 1, n, file) != n) {
        std.heap.page_allocator.free(buf);
        return null;
    }
    return buf;
}

/// Solid-colour RGBA sprite (the `flash` subject).
fn makeSolid(w: u32, h: u32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 255;
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// `palette_swap` INDEX atlas: `w`×`h`, `n` vertical bands whose RED channel
/// encodes the palette index (0..n-1). The shader reads `round(red*255)`.
fn makeIndexAtlas(w: u32, h: u32, n: u32) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const band = @min(n - 1, x * n / w);
            const o = (y * w + x) * 4;
            px[o] = @intCast(band);
            px[o + 1] = 0;
            px[o + 2] = 0;
            px[o + 3] = 255;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// `outline` subject: a `w`×`h` sprite that is fully transparent except a
/// centred opaque square of side `inner`. The transparent border is what lets
/// the alpha-dilated silhouette show up INSIDE the quad.
fn makeShape(w: u32, h: u32, inner: u32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    const lo_x = (w - inner) / 2;
    const lo_y = (h - inner) / 2;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const solid = x >= lo_x and x < lo_x + inner and y >= lo_y and y < lo_y + inner;
            px[o] = if (solid) r else 0;
            px[o + 1] = if (solid) g else 0;
            px[o + 2] = if (solid) b else 0;
            px[o + 3] = if (solid) 255 else 0;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// SOFT-EDGED `outline` subject: a transparent field with a centred
/// anti-aliased disc of radius `radius`, alpha ramping 1→0 over a `feather`-px
/// band. Along the boundary `base.a` is strictly between 0 and 1, so the
/// outline composite's over-operator math is actually exercised — a
/// double-`(1−base.a)` bug reads visibly faint here (the bgfx #49 fix).
fn makeSoftDisc(w: u32, h: u32, radius: f32, feather: f32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5) - cx;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            const cov = std.math.clamp((radius - dist) / feather + 0.5, 0.0, 1.0);
            const o = (y * w + x) * 4;
            px[o] = r;
            px[o + 1] = g;
            px[o + 2] = b;
            px[o + 3] = @intFromFloat(cov * 255.0 + 0.5);
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// 2-frame ATLAS (`fw`×`h`, two side-by-side `fw/2`-wide frames):
///   frame 0 (left)  = a small opaque `inner`-px square (rgb0) on transparent —
///                     the outline subject, drawn from sub-rect (0,0,fw/2,h).
///   frame 1 (right) = solid OPAQUE rgb1 — the "neighbouring frame" whose
///                     content an atlas-unaware outline would bleed (its opaque
///                     pixels start right at the seam) and whose dissolve must
///                     use sprite-LOCAL noise UVs. Guards the u_material rect
///                     fixes carried from bgfx #49.
fn makeAtlas2(fw: u32, h: u32, inner: u32, r0: u8, g0: u8, b0: u8, r1: u8, g1: u8, b1: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, fw * h * 4) catch unreachable;
    const half = fw / 2;
    const lo_x = (half - inner) / 2;
    const lo_y = (h - inner) / 2;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < fw) : (x += 1) {
            const o = (y * fw + x) * 4;
            if (x < half) {
                const solid = x >= lo_x and x < lo_x + inner and y >= lo_y and y < lo_y + inner;
                px[o] = if (solid) r0 else 0;
                px[o + 1] = if (solid) g0 else 0;
                px[o + 2] = if (solid) b0 else 0;
                px[o + 3] = if (solid) 255 else 0;
            } else {
                px[o] = r1;
                px[o + 1] = g1;
                px[o + 2] = b1;
                px[o + 3] = 255;
            }
        }
    }
    return .{ .pixels = px, .width = fw, .height = h };
}

/// LUT ramp: `n`×1 RGBA, one distinct colour per entry.
fn makeLut(colors: []const [3]u8) gfx.DecodedImage {
    const n: u32 = @intCast(colors.len);
    const px = std.heap.page_allocator.alloc(u8, n * 4) catch unreachable;
    for (colors, 0..) |c, k| {
        px[k * 4] = c[0];
        px[k * 4 + 1] = c[1];
        px[k * 4 + 2] = c[2];
        px[k * 4 + 3] = 255;
    }
    return .{ .pixels = px, .width = n, .height = 1 };
}

fn renderScene() void {
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    const gray = gfx.uploadTexture(makeSolid(48, 48, 140, 140, 140)) catch unreachable;
    const atlas = gfx.uploadTexture(makeIndexAtlas(48, 48, 4)) catch unreachable;
    const lut = gfx.uploadTexture(makeLut(&.{
        .{ 220, 40, 40 }, // index 0 → red
        .{ 40, 200, 40 }, // index 1 → green
        .{ 40, 90, 230 }, // index 2 → blue
        .{ 230, 210, 40 }, // index 3 → yellow
    })) catch unreachable;
    // Register the LUT → flat aux_texture handle the palette draw expects.
    const lut_handle = gfx.registerLut(lut);
    // dissolve subject: another solid sprite the procedural noise burns away.
    const burn = gfx.uploadTexture(makeSolid(48, 48, 90, 160, 200)) catch unreachable;
    // outline subject: an opaque 24px square on a transparent 48px field.
    const shape = gfx.uploadTexture(makeShape(48, 48, 24, 235, 235, 235)) catch unreachable;
    // outline subject with ANTI-ALIASED edges (fractional base.a boundary).
    const disc = gfx.uploadTexture(makeSoftDisc(48, 48, 15.0, 3.0, 235, 235, 235)) catch unreachable;
    // ATLAS subject: 96x48, frame 0 = small opaque square on transparent,
    // frame 1 = solid opaque red (the neighbour an atlas-unaware shader bleeds).
    const atlas2 = gfx.uploadTexture(makeAtlas2(96, 48, 20, 235, 235, 235, 210, 40, 40)) catch unreachable;

    // Two begin/draw/end cycles so the offscreen FB holds the scene before the
    // capture blit (belt-and-braces, matching the bgfx harness + sokol probes).
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        var pass_action = window.beginFrame();
        // Match the bgfx material golden's 20/20/30 background (instead of the
        // sokol default 30/30/35) so the two backends' captures are directly
        // comparable pixel-for-pixel.
        pass_action.colors[0].clear_value = .{ .r = 20.0 / 255.0, .g = 20.0 / 255.0, .b = 30.0 / 255.0, .a = 1.0 };
        window.beginPass(pass_action);

        const src48 = gfx.Rectangle{ .x = 0, .y = 0, .width = 48, .height = 48 };
        const origin = gfx.Vector2{ .x = 0, .y = 0 };

        // Ten 48px sprites across the 720px canvas (12px left margin, 24px
        // gaps) — the SAME columns as the bgfx golden.
        // Col 1: the GPU hit-flash — gray mixed 0.6 toward red → reddish sprite.
        gfx.drawTextureProMaterial(
            gray,
            src48,
            .{ .x = 12, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .flash, .uniforms = .{ .r = 1, .g = 0, .b = 0, .a = 1, .scalar0 = 0.6 } },
        );

        // Col 2: palette_swap — the 4-band index atlas recoloured via the LUT.
        gfx.drawTextureProMaterial(
            atlas,
            src48,
            .{ .x = 84, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .palette_swap, .uniforms = .{ .aux_texture = lut_handle, .aux_count = 4 } },
        );

        // Col 3: dissolve — burned by the built-in procedural noise at
        // threshold 0.5, an orange glow on the burn front (edge_width 6px).
        // aux_texture = 0 → procedural noise (no bound noise texture).
        gfx.drawTextureProMaterial(
            burn,
            src48,
            .{ .x = 156, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 0.5, .scalar1 = 6.0 } },
        );

        // Col 4: outline — the opaque square wrapped in a green silhouette
        // (thickness 3px, softness 0.4). base.a ∈ {0, 1}.
        gfx.drawTextureProMaterial(
            shape,
            src48,
            .{ .x = 228, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 5: outline on the ANTI-ALIASED soft disc — only here is
        // 0 < base.a < 1, catching a double-attenuation composite bug.
        gfx.drawTextureProMaterial(
            disc,
            src48,
            .{ .x = 300, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 6: ATLAS outline — frame 0 (sub-rect 0..48) whose neighbour frame
        // 1 (48..96) is solid opaque red. The per-frame tap gate must keep the
        // green outline OFF frame 0's right edge (no red-neighbour bleed).
        const atlas_f0 = gfx.Rectangle{ .x = 0, .y = 0, .width = 48, .height = 48 };
        gfx.drawTextureProMaterial(
            atlas2,
            atlas_f0,
            .{ .x = 372, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 7: ATLAS dissolve — frame 1 (sub-rect 48..96, solid red) burned
        // by the procedural noise remapped to sprite-LOCAL UV (per-frame-
        // consistent cell size, not scaled by the frame's atlas fraction).
        const atlas_f1 = gfx.Rectangle{ .x = 48, .y = 0, .width = 48, .height = 48 };
        gfx.drawTextureProMaterial(
            atlas2,
            atlas_f1,
            .{ .x = 444, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 0.5, .scalar1 = 6.0 } },
        );

        // Col 8: TINT-FADED outline — the opaque square at tint.a = 0.5. The
        // outline fades WITH the sprite (half-strength vs col 4) and the
        // interior must stay GRAY, not outline-green (tint-leak fix).
        gfx.drawTextureProMaterial(
            shape,
            src48,
            .{ .x = 516, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 9: dissolve at threshold = 1.0 — FULLY dissolved: every texel
        // must vanish, even noise texels of exactly 1.0 (boundary fix).
        gfx.drawTextureProMaterial(
            burn,
            src48,
            .{ .x = 588, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 1.0, .scalar1 = 6.0 } },
        );

        // Col 10: dissolve at threshold = 0.0 — FULLY SOLID at rest, pixel-
        // identical to a plain sprite: nothing dissolved AND no burn glow
        // anywhere (the edge_gate zeroes the glow at threshold 0).
        gfx.drawTextureProMaterial(
            burn,
            src48,
            .{ .x = 660, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 0.0, .scalar1 = 6.0 } },
        );

        window.flushScene();
        window.endFrame();
    }
}

/// Compare two BMPs (same writer, same dims). Returns true within tolerance.
fn withinTolerance(golden: []const u8, candidate: []const u8) bool {
    if (golden.len != candidate.len or golden.len <= BMP_HEADER) return false;
    const body_len = golden.len - BMP_HEADER;
    var outliers: usize = 0;
    var i: usize = BMP_HEADER;
    while (i < golden.len) : (i += 1) {
        const d = @as(i32, golden[i]) - @as(i32, candidate[i]);
        if (@abs(d) > CHANNEL_TOL) outliers += 1;
    }
    const frac = @as(f32, @floatFromInt(outliers)) / @as(f32, @floatFromInt(body_len));
    std.debug.print("GOLDEN: outlier bytes {d}/{d} ({d:.3}%)\n", .{ outliers, body_len, frac * 100 });
    return frac <= MAX_OUTLIER_FRAC;
}

pub fn main() void {
    const bless = options.bless;

    if (!window.beginHeadless(W, H)) {
        std.debug.print("GOLDEN_RESULT: HEADLESS_INIT_FAILED (no Metal device)\n", .{});
        std.process.exit(2);
    }

    renderScene();

    const out_path = if (bless) GOLDEN_PATH else CANDIDATE_PATH;
    ensureParentDir(out_path);
    // Remove any stale output UP FRONT. `takeScreenshot` only logs + returns on
    // readback/write failure (never crashes), so if we didn't delete first a
    // silent capture failure would leave a PRIOR run's file in place and the
    // read-back below would treat it as a fresh capture → false pass. After the
    // unlink, a successful `readFile(out_path)` proves the capture actually ran
    // THIS invocation.
    _ = remove(out_path.ptr);
    window.takeScreenshot(out_path);
    window.endHeadless();

    // Freshness gate: the file must exist now (only true if takeScreenshot wrote
    // it, since we removed it above). Read it once and reuse for bless/compare.
    const captured = readFile(out_path) orelse {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (no fresh capture at {s})\n", .{out_path});
        std.process.exit(3);
    };

    defer std.heap.page_allocator.free(captured);

    if (bless) {
        // `captured` IS the freshly-written golden (out_path == GOLDEN_PATH).
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
        std.process.exit(0);
    }

    // Check mode: `captured` is the fresh candidate; diff it against the golden.
    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build material-golden-bless)\n", .{});
        std.process.exit(5);
    };
    defer std.heap.page_allocator.free(golden);

    if (withinTolerance(golden, captured)) {
        std.debug.print("GOLDEN_RESULT: OK\n", .{});
        std.process.exit(0);
    }
    std.debug.print("GOLDEN_RESULT: GOLDEN_MISMATCH\n", .{});
    std.process.exit(4);
}
