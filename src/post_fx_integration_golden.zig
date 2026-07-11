//! End-to-end gfx×sokol integration golden for the post-fx ping-pong stack
//! (labelle-gfx#305 Phase 3). Where `post_fx_golden.zig` drives `applyPostPass`
//! DIRECTLY (one fresh target per pass output), THIS harness drives the REAL gfx
//! `PostFxDriver` — the exact composition logic the engine runs — over the REAL
//! sokol backend, surfaceless-headless (`window.beginHeadless`).
//!
//! It is the missing integration proof for sokol's DEFERRED execution model.
//! `post_fx_golden` runs the plan by hand; this proves the driver's
//! begin/applyPostPass/resolve sequence (its two-buffer ping-pong) records a
//! plan that `window.flushScene` executes in the correct order. bgfx's analogous
//! golden caught a real ascending-view-id ordering bug there; sokol's deferred
//! model has a DIFFERENT execution shape (each pass is a real, immediately-
//! executed offscreen pass, so submission order == execution order), and this
//! golden is what proves that shape is faithful to the driver's intent.
//!
//! The 2-pass bloom→crt stack is diffed against the reference golden
//! `post_fx_bloom_crt.bmp` (blessed by the one-target-per-pass `post_fx_golden`
//! harness, correct by construction). A correct driver+flush reproduces that
//! reference exactly.
//!
//! Modes (build option `bless`): --bless writes the committed golden; check
//! renders a candidate and diffs it with a per-channel tolerance (the CI gate).
//!
//! Exit codes (mirroring post_fx_golden):
//!   0 OK/BLESSED · 2 HEADLESS_INIT_FAILED · 3 CAPTURE/RT_CREATE_FAILED ·
//!   4 GOLDEN_MISMATCH · 5 GOLDEN_MISSING
//!
//! Run with:  zig build post-fx-integration-golden        (check)
//!            zig build post-fx-integration-golden-bless   (regenerate)

const std = @import("std");
const gfx = @import("gfx"); // the sokol backend impl (draw helpers + Backend(Impl) contract)
const gfx_lib = @import("labelle-gfx"); // the REAL gfx library — PostFxDriver + PostPass
const window = @import("window");
const options = @import("golden_options");

const W: i32 = 192;
const H: i32 = 128;

/// The driver instantiated over the sokol backend — precisely what the engine's
/// `RetainedEngineWith` holds. This is the whole point: exercise gfx's
/// composition logic against the real backend seam.
const Driver = gfx_lib.PostFxDriver(gfx);

// The 2-pass driver output must match the one-target-per-pass reference blessed
// by post_fx_golden.zig (same scene, same uniforms → same pixels).
const GOLDEN_PATH: [:0]const u8 = "test/golden/post_fx_bloom_crt.bmp";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/post_fx_driver_bloom_crt_candidate.bmp";

const BMP_HEADER: usize = 54;
const CHANNEL_TOL: i32 = 14;
const MAX_OUTLIER_FRAC: f32 = 0.03;

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(path: [*:0]const u8) c_int;

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

/// The fixed source scene — byte-identical to post_fx_golden.zig's so the driver
/// output can be diffed against that harness's reference golden.
fn drawScene() void {
    const full = rect(0, 0, @floatFromInt(W), @floatFromInt(H));
    gfx.drawRectangleRec(full, gfx.Color{ .r = 18, .g = 20, .b = 30, .a = 255 });
    gfx.drawRectangleRec(rect(76, 44, 40, 40), gfx.Color{ .r = 255, .g = 244, .b = 210, .a = 255 });
    gfx.drawRectangleRec(rect(20, 30, 18, 68), gfx.Color{ .r = 235, .g = 40, .b = 40, .a = 255 });
    gfx.drawRectangleRec(rect(154, 30, 18, 68), gfx.Color{ .r = 40, .g = 90, .b = 235, .a = 255 });
    gfx.drawRectangleRec(rect(70, 96, 52, 12), gfx.Color{ .r = 40, .g = 210, .b = 90, .a = 255 });
}

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

/// The canonical EVEN stack (bloom→crt); uniforms MATCH post_fx_golden.zig so the
/// driver output is pixel-comparable to that reference.
fn stack() [2]gfx_lib.PostPass {
    return .{
        .{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.62, .scalar1 = 0.85, .scalar2 = 2.0 } },
        .{ .kind = .crt, .uniforms = .{ .scalar0 = 0.18, .scalar1 = 0.40, .scalar2 = 0.30, .scalar3 = 0.004 } },
    };
}

pub fn main() void {
    const bless = options.bless;

    if (!window.beginHeadless(W, H)) {
        std.debug.print("GOLDEN_RESULT: HEADLESS_INIT_FAILED (no Metal device)\n", .{});
        std.process.exit(2);
    }

    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // The real driver: seed its ordered stack, then let IT own the ping-pong
    // targets + the src→dst hop sequencing across frames.
    var driver: Driver = .{};
    const passes = stack();
    driver.setPostFx(&passes);

    // Render several frames and capture the LAST (steady state). The driver
    // creates its two ping-pong targets lazily on the first active frame and
    // reuses target_a as BOTH the scene target and the crt output — a write-
    // after-read the standalone (3 fresh targets) never does. On Metal that
    // reuse needs a couple of frames for the command-buffer double-buffering to
    // settle; steady state is deterministic (verified stable over many runs).
    var failed = false;
    var frame: u32 = 0;
    while (frame < 6) : (frame += 1) {
        const pass_action = window.beginFrame();
        window.beginPass(pass_action);

        // Driver redirects the scene into target_a (records the plan)…
        const redirected = driver.begin(@intCast(W), @intCast(H));
        if (!redirected) {
            failed = true;
            break;
        }
        drawScene();
        // …then queues the ping-pong pass chain + records the composite.
        driver.resolve(@intCast(W), @intCast(H));

        // Execute the deferred plan the driver built: offscreen scene pass →
        // ping-pong chain → backbuffer composite.
        window.flushScene();
        window.endFrame();
    }

    if (failed) {
        std.debug.print("GOLDEN_RESULT: RT_CREATE_FAILED (driver did not redirect — backend seam missing?)\n", .{});
        driver.deinit();
        window.endHeadless();
        std.process.exit(3);
    }

    const out_path = if (bless) GOLDEN_PATH else CANDIDATE_PATH;
    ensureParentDir(out_path);
    _ = remove(out_path.ptr);
    window.takeScreenshot(out_path);
    driver.deinit();
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
