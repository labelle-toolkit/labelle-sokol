//! Surfaceless headless golden for the sokol post-fx seam (labelle-gfx#305,
//! Phase 3). Renders a FIXED scene into an offscreen render target, runs a
//! `bloom` → `crt` post-fx stack through `applyPostPass` via the render-target
//! ping-pong, composites the final target to the backbuffer, and captures it
//! FULLY headless (raw-Metal offscreen FB, no window / no display server — the
//! `window.beginHeadless` path proven by material_golden), dumping a 24-bit BMP
//! via `window.takeScreenshot` and diffing against a committed golden.
//!
//! Mirrors labelle-bgfx's `src/post_fx_golden.zig`, adapted to sokol's
//! headless-Metal capture path AND its DEFERRED post-fx model: the render-target
//! / post-fx calls only RECORD a per-frame plan; `window.flushScene` executes it
//! (offscreen scene pass → ping-pong pass chain → backbuffer composite). See
//! src/gfx/render_target.zig for the deferred-plan rationale.
//!
//! This harness drives `applyPostPass` DIRECTLY (one fresh target per pass
//! output: scene→t0, bloom t0→t1, crt t1→t2), pinning the SHADERS. The companion
//! `post_fx_integration_golden.zig` drives the REAL gfx `PostFxDriver` (its
//! two-buffer ping-pong), pinning the DRIVER×backend seam. Keep BOTH.
//!
//! Two modes (baked at build time via `golden_options`):
//!   bless : write the committed golden (GOLDEN_PATH). Needs a Metal device.
//!   check : render a candidate BMP + diff it against the golden with a
//!           per-channel tolerance (GPU raster is not bit-exact across drivers).
//!
//! Exit codes (mirroring material_golden / bgfx):
//!   0 = OK / BLESSED
//!   2 = HEADLESS_INIT_FAILED   (no Metal device — e.g. non-macOS / no GPU)
//!   3 = CAPTURE_FAILED / RT_CREATE_FAILED
//!   4 = GOLDEN_MISMATCH
//!   5 = GOLDEN_MISSING         (check mode, no committed golden — run bless)
//!
//! Run with:  zig build post-fx-golden        (check)
//!            zig build post-fx-golden-bless   (regenerate)

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window");
const options = @import("golden_options");

const W: i32 = 192;
const H: i32 = 128;

const GOLDEN_PATH: [:0]const u8 = "test/golden/post_fx_bloom_crt.bmp";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/post_fx_bloom_crt_candidate.bmp";

// BMP: 14-byte file header + 40-byte info header = 54 bytes before pixels.
const BMP_HEADER: usize = 54;

// GPU rasterisation is not bit-exact across drivers/refreshes; allow a small
// per-channel delta and a tiny outlier fraction. A broken pass moves large areas
// well past this, so the gate still trips.
const CHANNEL_TOL: i32 = 14;
const MAX_OUTLIER_FRAC: f32 = 0.03;

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(path: [*:0]const u8) c_int;

/// makePath-style: create the parent-dir chain of `path` so `takeScreenshot`'s
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

fn rect(x: f32, y: f32, w: f32, h: f32) gfx.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// Draw the fixed source scene into the currently-active render target: a dark
/// backdrop, a BRIGHT central block (the bloom's bright-pass subject), and a few
/// saturated bars (edge colour for the CRT's chromatic aberration + shadow mask).
/// Byte-identical to bgfx's post_fx_golden scene.
fn drawScene() void {
    const full = rect(0, 0, @floatFromInt(W), @floatFromInt(H));
    gfx.drawRectangleRec(full, gfx.Color{ .r = 18, .g = 20, .b = 30, .a = 255 });

    // Bright warm block — well above the bloom threshold, so it blooms.
    gfx.drawRectangleRec(rect(76, 44, 40, 40), gfx.Color{ .r = 255, .g = 244, .b = 210, .a = 255 });

    // Saturated side bars for aberration/mask contrast.
    gfx.drawRectangleRec(rect(20, 30, 18, 68), gfx.Color{ .r = 235, .g = 40, .b = 40, .a = 255 });
    gfx.drawRectangleRec(rect(154, 30, 18, 68), gfx.Color{ .r = 40, .g = 90, .b = 235, .a = 255 });
    gfx.drawRectangleRec(rect(70, 96, 52, 12), gfx.Color{ .r = 40, .g = 210, .b = 90, .a = 255 });
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

fn renderScene() bool {
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // One target per pass output (scene→t0, bloom t0→t1, crt t1→t2). Strictly
    // increasing so every read resolves before its consumer runs.
    const t0 = gfx.createRenderTarget(@intCast(W), @intCast(H));
    const t1 = gfx.createRenderTarget(@intCast(W), @intCast(H));
    const t2 = gfx.createRenderTarget(@intCast(W), @intCast(H));
    if (t0 == 0 or t1 == 0 or t2 == 0) return false;
    defer {
        gfx.destroyRenderTarget(t2);
        gfx.destroyRenderTarget(t1);
        gfx.destroyRenderTarget(t0);
    }

    const bloom = gfx.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.62, .scalar1 = 0.85, .scalar2 = 2.0 } };
    const crt = gfx.PostPass{ .kind = .crt, .uniforms = .{ .scalar0 = 0.18, .scalar1 = 0.40, .scalar2 = 0.30, .scalar3 = 0.004 } };

    // Render several frames and capture the LAST — steady state. sokol's render
    // targets are created and first rendered mid-frame; the initial 1-2 frames of
    // a freshly-created ping-pong can show GPU warmup transients (the Metal
    // command-buffer double-buffering settles after a couple of frames), so we
    // render a comfortable margin before the capture. The deferred plan executes
    // fully at each flushScene; steady state is deterministic (verified stable).
    var frame: u32 = 0;
    while (frame < 6) : (frame += 1) {
        const pass_action = window.beginFrame();
        window.beginPass(pass_action);

        // Scene → t0 (deferred: records the plan; sgl commands buffered).
        gfx.beginRenderTarget(t0);
        drawScene();
        gfx.endRenderTarget();

        // Queue bloom t0 → t1, then crt t1 → t2.
        gfx.applyPostPass(bloom, t0, t1);
        gfx.applyPostPass(crt, t1, t2);

        // Composite the final target into the backbuffer (the FINAL blit).
        gfx.drawRenderTarget(t2, rect(0, 0, @floatFromInt(W), @floatFromInt(H)), gfx.white);

        // Execute the plan: offscreen scene pass → ping-pong chain → composite.
        window.flushScene();
        window.endFrame();
    }
    return true;
}

pub fn main() void {
    const bless = options.bless;

    if (!window.beginHeadless(W, H)) {
        std.debug.print("GOLDEN_RESULT: HEADLESS_INIT_FAILED (no Metal device)\n", .{});
        std.process.exit(2);
    }

    if (!renderScene()) {
        std.debug.print("GOLDEN_RESULT: RT_CREATE_FAILED\n", .{});
        window.endHeadless();
        std.process.exit(3);
    }

    const out_path = if (bless) GOLDEN_PATH else CANDIDATE_PATH;
    ensureParentDir(out_path);
    // Remove any stale output UP FRONT. `takeScreenshot` only logs + returns on
    // readback/write failure (never crashes), so if we didn't delete first a
    // silent capture failure would leave a PRIOR run's file in place and the
    // read-back below would treat it as a fresh capture → false pass. After the
    // unlink, a successful `readFile(out_path)` proves the capture ran THIS run.
    _ = remove(out_path.ptr);
    window.takeScreenshot(out_path);
    window.endHeadless();

    const captured = readFile(out_path) orelse {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (no fresh capture at {s})\n", .{out_path});
        std.process.exit(3);
    };
    defer std.heap.page_allocator.free(captured);

    if (bless) {
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
        std.process.exit(0);
    }

    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build post-fx-golden-bless)\n", .{});
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
