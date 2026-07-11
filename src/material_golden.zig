//! Surfaceless headless golden for the sokol material seam (labelle-gfx#305,
//! Phase 3 sokol parity slice 1). Renders a FIXED scene — one sprite with the
//! `flash` material (gray mixed 0.6 toward red) and one with `palette_swap` (a
//! 4-band index atlas recoloured through a LUT ramp) — FULLY headless (raw
//! Metal device via `window.beginHeadless`, no window / no display server),
//! then captures the offscreen framebuffer to a 24-bit BMP via
//! `window.takeScreenshot` and diffs it against a committed golden.
//!
//! Mirrors labelle-bgfx v0.10.0's `src/material_golden.zig`, adapted to sokol's
//! headless-Metal capture path (the one backend that can render with no GUI
//! session — see reference_sokol_headless_screenshots).
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

const W: i32 = 192;
const H: i32 = 96;

const GOLDEN_PATH: [:0]const u8 = "test/golden/material_flash_palette.bmp";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/material_flash_palette_candidate.bmp";

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

    // Two begin/draw/end cycles so the offscreen FB holds the scene before the
    // capture blit (belt-and-braces, matching the bgfx harness + sokol probes).
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        const pass_action = window.beginFrame();
        window.beginPass(pass_action);

        const src48 = gfx.Rectangle{ .x = 0, .y = 0, .width = 48, .height = 48 };
        const origin = gfx.Vector2{ .x = 0, .y = 0 };

        // Left: the GPU hit-flash — gray mixed 0.6 toward red → reddish sprite.
        gfx.drawTextureProMaterial(
            gray,
            src48,
            .{ .x = 24, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .flash, .uniforms = .{ .r = 1, .g = 0, .b = 0, .a = 1, .scalar0 = 0.6 } },
        );

        // Right: palette_swap — the 4-band index atlas recoloured via the LUT.
        gfx.drawTextureProMaterial(
            atlas,
            src48,
            .{ .x = 120, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .palette_swap, .uniforms = .{ .aux_texture = lut_handle, .aux_count = 4 } },
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
    // takeScreenshot reads back the headless offscreen color attachment and
    // writes a 24-bit BMP. It logs + returns on failure (never crashes), so we
    // detect success by reading the file back below.
    window.takeScreenshot(out_path);
    window.endHeadless();

    if (bless) {
        if (readFile(GOLDEN_PATH)) |g| {
            std.heap.page_allocator.free(g);
            std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
            std.process.exit(0);
        }
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (golden not written)\n", .{});
        std.process.exit(3);
    }

    const candidate = readFile(CANDIDATE_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (candidate unreadable)\n", .{});
        std.process.exit(3);
    };
    defer std.heap.page_allocator.free(candidate);
    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build material-golden-bless)\n", .{});
        std.process.exit(5);
    };
    defer std.heap.page_allocator.free(golden);

    if (withinTolerance(golden, candidate)) {
        std.debug.print("GOLDEN_RESULT: OK\n", .{});
        std.process.exit(0);
    }
    std.debug.print("GOLDEN_RESULT: GOLDEN_MISMATCH\n", .{});
    std.process.exit(4);
}
