/// Sokol window backend — windowing lifecycle via sokol_app.
// Contract-version tags (labelle-assembler#453 item 1). The assembler emits
// directional `@compileError` version asserts in the generated game's main.zig
// comparing these against labelle-core's `*_CONTRACT_VERSION` consts. v1 is the
// initial revision of each contract.
pub const targets_window_contract: u32 = 1;
const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
// The frame host drives the gfx material seam's per-frame lifecycle
// (labelle-gfx#305): reset the queue in `beginFrame`, replay it in
// `flushScene` right after the sokol_gl batch flush. Same module instance the
// game/assembler import, so the module-level queue state is shared.
const gfx = @import("gfx");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const slog = sokol.log;

// ──────────────────────────────────────────────────────────────────
// Headless preview mode (labelle-assembler#140 — no-window preview)
// ──────────────────────────────────────────────────────────────────
// When `LABELLE_PREVIEW` is set, the game runs without sokol-app: no
// NSWindow, no dock icon. We create an MTLDevice directly, hand it to
// sokol-gfx via a custom sg_environment, and drive the frame loop at
// ~60Hz. The Path-A IOSurface ring publishes frames to the gui's
// Game View consumer — that's the only visible surface.
//
// Public API below (initGfx, width, height, metalDevice, requestQuit,
// beginPass) branches internally on `headless_mode`, so the codegen
// needs zero changes.
var headless_mode: bool = false;
var headless_w: i32 = 0;
var headless_h: i32 = 0;
var headless_mtl_device: ?*anyopaque = null;
var headless_quit_requested: bool = false;

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

/// True when env var `name` is set and non-empty (mirrors the original
/// LABELLE_PREVIEW check: `std.mem.span(raw).len > 0`).
fn envTruthy(name: [*:0]const u8) bool {
    if (getenv(name)) |raw| return std.mem.span(raw).len > 0;
    return false;
}

/// Re-export `sokol.gfx` so the generated `main.zig` (which only depends
/// on `backend_window`, not directly on `sokol`) can reach sg.Image,
/// sg.View, sg.Attachments, sg.makeImage, sg.makeView, sg.destroyImage,
/// sg.destroyView, sg.ImageDesc, etc. Used by the Path-A IOSurface ring
/// the Play-in-Editor preview producer builds at module scope — every
/// member of the ring is an sg-flavoured handle, so without this re-
/// export the codegen would either need a parallel `sokol` dep on the
/// root module (cross-cutting concern) or duplicate the type defs.
pub const gfx_types = sokol.gfx;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

/// Set config flags before initialization.
/// Note: sokol_app does not natively support hidden windows. This is a
/// no-op stub for API compatibility; the flag is stored but has no effect
/// on the sokol backend (sokol_app always shows the window).
pub fn setConfigFlags(_: ConfigFlags) void {}

/// sokol_gl pipeline with alpha blending enabled. The default sgl pipeline
/// has blend disabled, which makes atlas sprites render their transparent
/// pixels as opaque (the underlying layer doesn't show through). We create
/// this once in initGfx and load it on every beginFrame so all sgl draws —
/// textured sprites, rectangles, circles, text — get correct alpha blending.
var alpha_pipeline: sgl.Pipeline = .{};

pub fn initGfx() void {
    // Headless preview mode supplies its own MTLDevice; sglue.environment()
    // reads from sapp which isn't valid (sokol-app never ran).
    const env: sg.Environment = if (headless_mode) .{
        .defaults = .{
            .color_format = .BGRA8,
            .depth_format = .DEPTH_STENCIL,
            .sample_count = 1,
        },
        .metal = .{ .device = headless_mtl_device },
    } else sglue.environment();

    sg.setup(.{
        .environment = env,
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });
    alpha_pipeline = sgl.makePipeline(.{
        .colors = .{ .{ .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        } }, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
}

/// Screenshot capture — per-backend pixel readback + BMP encode
/// (labelle-assembler#213). The raylib backend uses raylib's builtin
/// `TakeScreenshot`; sokol-gfx has no equivalent, so we dispatch on
/// `sg.queryBackend()` and run the native readback for each graphics
/// API.
///
/// Called from the generated `desktop.txt` between `window.endFrame()`
/// (which ends with `sg.commit()`) and the next frame's `newFrame()`.
/// At that point the swapchain has presented and the back buffer holds
/// the just-rendered pixels — exactly the state each backend's
/// readback API expects.
///
/// Output: 24-bit BMP via the vendored `screenshot/bmp.zig` writer
/// (a copy of `labelle-gfx/src/window_utils.zig:writeBmp` — the sokol
/// backend doesn't carry a `labelle-gfx` dep, and adding one for an
/// 80-line pure-std encoder would widen the dep graph). PNG output is
/// deliberately out of scope for this PR; see the issue for a
/// follow-up.
///
/// Failure mode: any readback step that fails logs a `std.log.warn`
/// and returns early. Screenshot failures never crash the game.
///
/// Memory: a one-shot `w*h*4` pixel buffer + the BMP file buffer come
/// from `std.heap.page_allocator`. The backend module has no allocator
/// in scope (it's stateless w.r.t. host allocators) and screenshots
/// are infrequent enough that the page allocator's per-call overhead
/// is irrelevant; threading the engine's allocator through would
/// require a new vtable slot for one rarely-fired path.
pub fn takeScreenshot(path: [:0]const u8) void {
    const w_i = width();
    const h_i = height();
    if (w_i <= 0 or h_i <= 0) {
        std.log.warn("screenshot: invalid framebuffer size ({d}x{d})", .{ w_i, h_i });
        return;
    }
    const w: u32 = @intCast(w_i);
    const h: u32 = @intCast(h_i);

    var alloc = std.heap.page_allocator;
    const pixels = alloc.alloc(u8, @as(usize, w) * @as(usize, h) * 4) catch {
        std.log.warn("screenshot: pixel buffer alloc failed ({d}x{d})", .{ w, h });
        return;
    };
    defer alloc.free(pixels);

    // Channel order depends on the backend's native swapchain format:
    // - GL / GLES → GL_RGBA readback → `writeBmp` (RGBA-to-BGR swizzle).
    // - Metal / D3D11 → BGRA8Unorm swapchain → `writeBmpFromBgra` (no swizzle).
    var got_bgra = false;
    const backend = sg.queryBackend();
    const ok = switch (backend) {
        .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR => blk: {
            got_bgra = true;
            break :blk readbackMetal(pixels, w, h);
        },
        .GLCORE, .GLES3 => readbackGL(pixels, w, h),
        .D3D11 => blk: {
            got_bgra = true;
            break :blk readbackD3D11(pixels, w, h);
        },
        .WGPU => readbackWGPU(pixels, w, h),
        .DUMMY => false,
        .VULKAN => false, // unreachable today (sokol disables Vulkan); guarded so the switch is exhaustive
    };
    if (!ok) {
        std.log.warn(
            "screenshot readback failed on backend {s}; no file written ({s})",
            .{ @tagName(backend), path },
        );
        return;
    }

    const bmp = @import("screenshot/bmp.zig");
    const result = if (got_bgra)
        bmp.writeBmpFromBgra(alloc, path, pixels, w, h)
    else
        bmp.writeBmp(alloc, path, pixels, w, h);
    result catch |err| {
        std.log.warn("screenshot: BMP write failed ({s})", .{@errorName(err)});
        return;
    };
    std.log.info("screenshot saved to {s} ({d}x{d})", .{ path, w, h });
}

// ── Per-backend readback helpers ─────────────────────────────────────
// Each helper returns `false` on any failure path; the main
// `takeScreenshot` switch logs and aborts cleanly. The Metal / GL /
// D3D11 helpers live in `screenshot/*.zig` so this file stays focused
// on the dispatch shape; WGPU's stub is so small it stays inline.

fn readbackMetal(pixels: []u8, w: u32, h: u32) bool {
    // Use an explicit `if (comptime ...) { ... } else { ... }` so the
    // Darwin-only `screenshot/metal.zig` import is fully discarded by
    // the compiler on non-Darwin targets — relying on dead-code
    // elimination after a comptime-return can leave the import in the
    // analysis graph and trip link-time references to libobjc.
    if (comptime builtin.target.os.tag.isDarwin()) {
        // Headless mode never ran sokol_app, so the swapchain drawable is
        // invalid (`sapp_metal_get_current_drawable` aborts on
        // `!_sapp.valid`). The frame was rendered into the offscreen
        // fallback color attachment instead — read that texture back.
        if (headless_mode) {
            const tex = headlessColorTexture() orelse {
                std.log.warn("screenshot: headless offscreen texture unavailable", .{});
                return false;
            };
            return @import("screenshot/metal.zig").readbackFromTexture(pixels, w, h, metalDevice(), tex);
        }
        return @import("screenshot/metal.zig").readback(pixels, w, h, metalDevice());
    } else {
        std.log.warn("screenshot: Metal backend reported on non-Darwin target", .{});
        return false;
    }
}

fn readbackGL(pixels: []u8, w: u32, h: u32) bool {
    // Same comptime-gate shape as `readbackMetal` / `readbackD3D11`: the GL
    // backend is only ever selected on GL targets (desktop Linux, GLES on
    // Android/wasm) — never on Windows (D3D11) or Darwin (Metal). Without the
    // gate the `screenshot/gl.zig` import stays in the analysis graph on those
    // targets and its `glReadPixels` / `glPixelStorei` externs force a
    // spurious opengl32 link (the exact failure mode the sibling comments warn
    // about).
    if (comptime builtin.target.os.tag != .windows and
        !builtin.target.os.tag.isDarwin())
    {
        return @import("screenshot/gl.zig").readback(pixels, w, h);
    } else {
        std.log.warn("screenshot: GL backend reported on non-GL target", .{});
        return false;
    }
}

fn readbackD3D11(pixels: []u8, w: u32, h: u32) bool {
    // Same comptime-gate shape as `readbackMetal` so the
    // Windows-only `screenshot/d3d11.zig` import is dropped entirely
    // on non-Windows builds.
    if (comptime builtin.target.os.tag == .windows) {
        return @import("screenshot/d3d11.zig").readback(pixels, w, h);
    } else {
        std.log.warn("screenshot: D3D11 backend reported on non-Windows target", .{});
        return false;
    }
}

fn readbackWGPU(_: []u8, _: u32, _: u32) bool {
    // WebGPU's only readback path is async: `commandEncoder.copyTextureToBuffer`
    // followed by `buffer.mapAsync(...)`. On wasm the JS event loop has to
    // tick before the mapped data is available — i.e. the screenshot cannot
    // be written synchronously inside `takeScreenshot`. Properly handling
    // this requires plumbing an async-completion callback through the
    // screenshot CLI flow (labelle-cli#227) — out of scope for this PR.
    // Log so users on wgpu builds get a clear signal instead of a silent
    // missing file, and file a follow-up if anyone actually needs wasm
    // screenshots.
    std.log.warn(
        "screenshot: wgpu readback is async and not yet wired through; no file written",
        .{},
    );
    return false;
}

/// Quiet-exit handler for the upstream sokol-gfx SIGSEGV in
/// `_sg_mtl_garbage_collect` during `sg_shutdown` (labelle-assembler#140).
/// Bug lives in sokol-gfx's deferred-release queue, not our cleanup.
/// By the time the signal fires the game has already published its
/// last frame to the editor consumer, so an immediate `_exit(0)` keeps
/// the gui's preview state machine in a clean disconnect instead of
/// surfacing a crash dump.
fn quietExitOnShutdownCrash(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // _exit(2) bypasses atexit handlers — important because the
    // crash happens INSIDE sokol's teardown, and running more cleanup
    // would re-enter the broken state.
    std.c._exit(0);
}

pub fn shutdownGfx() void {
    sgl.destroyPipeline(alpha_pipeline);
    sgl.shutdown();

    // labelle-assembler#140 workaround — install the quiet-exit handler
    // ONLY on the Darwin/Metal path where the upstream crash reproduces.
    // Linux/Windows/etc. take the normal sg.shutdown path and crash
    // legitimately on any real bug.
    if (builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .sigaction = quietExitOnShutdownCrash },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(std.posix.SIG.SEGV, &sa, null);
        std.posix.sigaction(std.posix.SIG.BUS, &sa, null);
        std.posix.sigaction(std.posix.SIG.ABRT, &sa, null);
    }

    sg.shutdown();
}

// ── Surfaceless headless golden entry points (labelle-gfx#305) ──────────────
// sokol is the one backend that can render + read back with NO window / no
// display server (a raw Metal device — see reference_sokol_headless_screenshots).
// `beginHeadless` arms the same offscreen path `runHeadless` uses but WITHOUT
// the frame loop, so a one-shot golden harness can: beginHeadless → beginFrame/
// beginPass/draw/flushScene/endFrame → takeScreenshot → endHeadless. Darwin/
// Metal only (returns false elsewhere: no `MTLCreateSystemDefaultDevice`), so
// the material golden build step is gated to macOS.

/// Arm surfaceless headless rendering at `w`×`h`. Returns false when no Metal
/// device is available (non-Darwin, or a runner with no GPU), so the caller
/// can skip cleanly rather than crash.
pub fn beginHeadless(w: i32, h: i32) bool {
    const is_darwin = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios;
    if (!is_darwin) return false;
    const device = MTLCreateSystemDefaultDevice() orelse return false;
    headless_mode = true;
    headless_mtl_device = device;
    headless_w = w;
    headless_h = h;
    initGfx();
    return true;
}

/// Tear down a `beginHeadless` session.
pub fn endHeadless() void {
    shutdownGfx();
    headless_mode = false;
    headless_mtl_device = null;
}

/// Request that the sokol_app event loop terminate on the next iteration.
/// Mirrors `rl.closeWindow` / `sdl.quit` — the generated frame callback
/// polls `g.isRunning()` and calls this when a script called `game.quit()`.
pub fn requestQuit() void {
    if (headless_mode) {
        headless_quit_requested = true;
        return;
    }
    sapp.requestQuit();
}

/// Query whether the window is currently fullscreen.
/// Mirrors raylib's `IsWindowFullscreen`. Headless preview has no real
/// window, so it's never fullscreen.
pub fn isFullscreen() bool {
    if (headless_mode) return false;
    return sapp.isFullscreen();
}

/// Switch the window to fullscreen (`on=true`) or windowed (`on=false`).
/// The generated frame callback polls `g.takeFullscreenRequest()` and
/// calls this when a script flipped `game.setFullscreen`. sokol_app only
/// exposes a *toggle*, so we read the current mode and toggle only when
/// it differs from the requested one (idempotent). No-op in headless
/// preview mode (no sokol_app window to resize).
pub fn setFullscreen(on: bool) void {
    if (headless_mode) return;
    if (sapp.isFullscreen() != on) sapp.toggleFullscreen();
}

/// Desired swap interval (1 = vsync on, 0 = off). Consumed by `makeDesc`
/// at startup so the initial present rate honours the setting.
///
/// Unlike fullscreen (sokol exposes `sapp.toggleFullscreen`), sokol_app
/// has **no runtime swap-interval setter** — `swap_interval` is read once
/// at init. On macOS the present rate is additionally paced by the
/// MTKView display link + the WindowServer compositor, so a clean *live*
/// toggle isn't achievable through the public sokol API. Therefore on the
/// sokol backend the vsync choice applies at the **next launch**; the
/// engine flag still updates so the Options checkbox reflects intent, and
/// the **bgfx** backend (FP's shipping backend) does the fully-live
/// toggle. On Web/WASM vsync is browser-owned (requestAnimationFrame) and
/// ignores this entirely. See labelle-assembler vsync-toggle plan.
var desired_swap_interval: i32 = 1;

/// Set the desired vsync state. The generated frame loop forwards
/// `g.takeVsyncRequest()` here (mirrors `setFullscreen`). See
/// `desired_swap_interval` for why this is apply-at-launch on sokol.
pub fn setVsync(on: bool) void {
    desired_swap_interval = if (on) 1 else 0;
}

// ── Canonical window contract (labelle-core/src/window_contract.zig) ──────
// The uniform window surface the pluggable-backends contract standardizes on
// (labelle-assembler#386, the first step of extracting sokol out-of-tree). The
// required core is `width`/`height`/`frameDuration`/`requestQuit`; sokol already
// names them canonically (unlike raylib's legacy `getScreenWidth`-style getters),
// so `core.assertWindow` is satisfied without aliases. `requestQuit` lives above
// (next to the other lifecycle calls) and wraps `sapp.requestQuit()`.
//
// sokol is a *callback*-model backend: sokol_app's run loop is pumped by the
// OS (it does NOT own a `while (!shouldQuit())` loop), so we deliberately omit
// `shouldQuit`. `core.ownsLoop()` reads `shouldQuit`'s presence, so leaving it
// off correctly classifies sokol as callback-style; the app ends via
// `requestQuit` driving sokol_app's own pump instead.

/// Current framebuffer width (physical px).
pub fn width() i32 {
    return if (headless_mode) headless_w else sapp.width();
}

/// Current framebuffer height (physical px).
pub fn height() i32 {
    return if (headless_mode) headless_h else sapp.height();
}

/// Duration of the last frame in seconds.
/// Use this for dt in the frame callback instead of a hardcoded value.
///
/// In headless preview mode sokol-app never ran, so `sapp.frameDuration()`
/// returns ~0 — which causes divide-by-zero or stalled physics in game
/// code that derives delta-time from this. `runHeadless` paces at ~60 Hz
/// via `nanosleep`, so 1/60 is the truthful answer there.
pub fn frameDuration() f64 {
    if (headless_mode) return 1.0 / 60.0;
    return sapp.frameDuration();
}

pub fn beginFrame() sg.PassAction {
    sgl.defaults();
    // sgl.defaults() resets to the default non-blended pipeline; load our
    // alpha-blended pipeline so sprites render transparency correctly.
    sgl.loadPipeline(alpha_pipeline);
    // Drop last frame's queued material sprites + post-fx plan (labelle-gfx#305).
    gfx.resetMaterials();
    gfx.resetRenderTargets();
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // Match the raylib backend's default clear color (30, 30, 35) so
        // projects render the same backdrop regardless of backend.
        .clear_value = .{ .r = 30.0 / 255.0, .g = 30.0 / 255.0, .b = 35.0 / 255.0, .a = 1.0 },
    };
    return pass_action;
}

/// Editor-mode override for the next `beginPass`. When non-null, `beginPass`
/// routes the game's render into these attachments (Path-A offscreen
/// IOSurface render target — labelle-assembler#133) instead of the
/// sokol_app swapchain. The override stays set across frames; the host
/// flips it on/off around each frame's render via `setEditorRenderTarget`
/// / `clearEditorRenderTarget`. Defaults to null so the standalone /
/// non-editor path renders to the swapchain as before.
var current_editor_render_target: ?sg.Attachments = null;

/// Route the next `beginPass` into these attachments instead of the
/// swapchain. The Path-A producer (Metal/IOSurface ring) populates one
/// `sg.Attachments` per ring slot during ring (re)negotiation, then on
/// each frame the host picks `_write_slot` and passes the corresponding
/// attachments through this shim before `g.render()`. The pass clears
/// to the same color the swapchain path uses.
pub fn setEditorRenderTarget(attachments: sg.Attachments) void {
    current_editor_render_target = attachments;
}

/// Clear the editor render-target override so the next `beginPass`
/// returns to the swapchain. Called after the host's frame body emits
/// `signalSlotReady` for the just-rendered slot — keeps the override
/// strictly one-frame scoped even if a later frame skips the
/// `setEditorRenderTarget` call (e.g. transient ring re-negotiation
/// or editor disconnect).
pub fn clearEditorRenderTarget() void {
    current_editor_render_target = null;
}

/// The pass action `beginPass` last recorded — stashed so `flushScene` /
/// `endFrame` can open the backbuffer with the intended clear.
var last_pass_action: sg.PassAction = .{};

/// The backbuffer pass is opened LAZILY (labelle-gfx#305, Phase 3). `beginPass`
/// only RECORDS the action; the actual `sg.beginPass` fires on the first thing
/// that needs the backbuffer (`flushScene` or `endFrame`). This is what lets the
/// post-fx path run its offscreen scene + ping-pong passes FIRST — sokol passes
/// can't nest, so the backbuffer must not already be open — and then open the
/// backbuffer EXACTLY ONCE for the composite. Opening it twice per frame (an
/// empty pass then the composite) broke the headless screenshot readback, whose
/// double-buffered attachment slot then pointed at the empty first pass. Every
/// render path (plain, material, post-fx) now opens the backbuffer exactly once.
///
/// Safe because nothing draws to the backbuffer between `beginPass` and
/// `flushScene`: all sprites/shapes/gizmos ride sokol_gl (drained at
/// `flushScene`) and materials are queued (replayed at `flushScene`).
var backbuffer_pass_pending: bool = false;

pub fn beginPass(pass_action: sg.PassAction) void {
    last_pass_action = pass_action;
    backbuffer_pass_pending = true;
}

/// Open the backbuffer pass now if `beginPass` recorded one and it isn't open
/// yet. Idempotent within a frame. Called by `flushScene` (normal path + the
/// post-fx composite) and defensively by `endFrame`.
fn ensureBackbufferPass() void {
    if (!backbuffer_pass_pending) return;
    backbuffer_pass_pending = false;
    beginBackbufferPass(last_pass_action);
}

/// Open the backbuffer pass — the editor render target, the headless offscreen
/// fallback, or the real swapchain (in that priority). Factored out of `beginPass`
/// so `ensureBackbufferPass` (and the post-fx `flushScene` path) can open the
/// backbuffer after the offscreen scene + pass chain (see `flushScene`).
fn beginBackbufferPass(pass_action: sg.PassAction) void {
    if (current_editor_render_target) |attachments| {
        sg.beginPass(.{ .action = pass_action, .attachments = attachments });
        return;
    }
    if (headless_mode) {
        // No swapchain in headless preview mode. Route the pass into a
        // small fallback offscreen attachments so the game's draws
        // complete (this happens for the very first frames before
        // preview_mtl arms its IOSurface ring + the editor accepts).
        sg.beginPass(.{ .action = pass_action, .attachments = headlessFallbackAttachments() });
        return;
    }
    sg.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });
}

// ── Headless fallback render target ──────────────────────────────
var headless_fallback_attachments: sg.Attachments = .{};
var headless_fallback_color_img: sg.Image = .{};
var headless_fallback_color_view: sg.View = .{};
var headless_fallback_depth_img: sg.Image = .{};
var headless_fallback_depth_view: sg.View = .{};

fn headlessFallbackAttachments() sg.Attachments {
    // sg.Attachments isn't a handle (no .id) so use the color-view's
    // id as the lazy-init sentinel.
    if (headless_fallback_color_view.id != 0) return headless_fallback_attachments;

    // Size the offscreen target to the actual headless framebuffer so the
    // game renders the full frame (not a 16×16 stub) — the headless
    // screenshot path (labelle-assembler#368) reads this color image back
    // as the captured image, so it must match `width()`/`height()`.
    // Guard against a zero size (pre-`runHeadless`) with a 16×16 floor.
    const fb_w: i32 = if (headless_w > 0) headless_w else 16;
    const fb_h: i32 = if (headless_h > 0) headless_h else 16;

    // Build everything in locals first; only commit to module-scope
    // statics when all four handles validate. If any creation fails
    // (pool exhaustion / driver error), return an empty
    // `sg.Attachments` and leave `headless_fallback_color_view.id == 0`
    // so the next call retries the lazy-init cleanly instead of
    // caching broken attachments forever.
    //
    // BGRA8 matches the Metal swapchain's native format so the screenshot
    // readback can reuse `writeBmpFromBgra` (no channel swizzle).
    const color_img = sg.makeImage(.{
        .width = fb_w,
        .height = fb_h,
        .pixel_format = .BGRA8,
        .usage = .{ .color_attachment = true, .immutable = true },
    });
    if (color_img.id == 0) return .{};
    const color_view = sg.makeView(.{
        .color_attachment = .{ .image = color_img },
    });
    if (color_view.id == 0) {
        sg.destroyImage(color_img);
        return .{};
    }
    const depth_img = sg.makeImage(.{
        .width = fb_w,
        .height = fb_h,
        .pixel_format = .DEPTH_STENCIL,
        .usage = .{ .depth_stencil_attachment = true, .immutable = true },
    });
    if (depth_img.id == 0) {
        sg.destroyView(color_view);
        sg.destroyImage(color_img);
        return .{};
    }
    const depth_view = sg.makeView(.{
        .depth_stencil_attachment = .{ .image = depth_img },
    });
    if (depth_view.id == 0) {
        sg.destroyImage(depth_img);
        sg.destroyView(color_view);
        sg.destroyImage(color_img);
        return .{};
    }

    var att: sg.Attachments = .{};
    att.colors[0] = color_view;
    att.depth_stencil = depth_view;

    // All four handles valid — commit to module scope.
    headless_fallback_color_img = color_img;
    headless_fallback_color_view = color_view;
    headless_fallback_depth_img = depth_img;
    headless_fallback_depth_view = depth_view;
    headless_fallback_attachments = att;
    return att;
}

/// Native `MTLTexture*` backing the headless offscreen color attachment,
/// or null if the fallback hasn't been created yet / on non-Metal builds.
/// The headless screenshot path (labelle-assembler#368) reads this texture
/// back instead of the (invalid, never-presented) window swapchain drawable
/// — `sapp_metal_get_current_drawable` aborts on `!_sapp.valid` headless.
///
/// `sg.mtlQueryImageInfo` returns the (double-buffered) native texture
/// array; `active_slot` selects the slot the most recent pass rendered into.
pub fn headlessColorTexture() ?*const anyopaque {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .ios) return null;
    // Ensure the attachment exists (lazy-inits if a frame hasn't rendered).
    _ = headlessFallbackAttachments();
    if (headless_fallback_color_img.id == 0) return null;
    const info = sg.mtlQueryImageInfo(headless_fallback_color_img);
    const slot: usize = @intCast(@max(0, info.active_slot));
    // Defensive: `tex` is a fixed 2-slot array; never index past it even
    // if sokol-gfx ever reports an unexpected `active_slot`.
    if (slot >= info.tex.len) return null;
    return info.tex[slot];
}

/// Flush queued sokol-gl primitives (sprites, gizmos, sgl-rendered text)
/// to the active sokol-gfx pass. The frame-loop template calls this
/// **between** scene rendering (`g.render()` / `g.renderGizmos()`) and
/// GUI rendering (`g.guiBegin()` / drawGui / `g.guiEnd()`), so sgl
/// primitives land in the framebuffer before any imgui draws are
/// emitted. The original `endFrame` flushed sgl AFTER `simgui.render()`
/// had already submitted the GUI's draw calls in the same pass — and
/// since draws are layered in submission order, the sprites painted on
/// top of the GUI and hid it entirely. See labelle-toolkit/labelle-imgui#4.
pub fn flushScene() void {
    // ── Post-fx path (labelle-gfx#305, Phase 3) ─────────────────────────────
    // When the gfx `PostFxDriver` armed a redirection this frame, the scene must
    // land in an offscreen target, run through the post-fx pass chain, and only
    // THEN composite to the backbuffer. sokol can't nest passes and sokol_gl
    // flushes exactly once, so we orchestrate the whole thing HERE — the single
    // sgl-flush seam. The gfx side owns the offscreen passes + pipelines; window
    // owns the sgl flush + the backbuffer routing (see gfx/render_target.zig).
    if (gfx.postFxActive()) {
        // The backbuffer pass is NOT open yet (lazy — see `backbuffer_pass_pending`),
        // so we can open the offscreen scene target directly (sokol passes can't
        // nest). Scene (sgl + materials) → the offscreen scene target.
        gfx.beginPostFxScenePass();
        sgl.draw();
        gfx.flushMaterials();
        // End the scene pass + run the ping-pong post-fx passes (each its own
        // offscreen pass; submission order == execution order on sokol).
        gfx.endPostFxScenePassAndApply();
        // Now open the backbuffer ONCE and composite the final target into it.
        // Left OPEN for the GUI + `endFrame`, exactly like the straight path below.
        ensureBackbufferPass();
        gfx.compositePostFx();
        return;
    }

    // Normal path: open the backbuffer (lazy) and drain the scene into it.
    ensureBackbufferPass();
    sgl.draw();
    // Replay queued material sprites (labelle-gfx#305) immediately AFTER the
    // sokol_gl batch so they composite on top of it. Must be inside the active
    // pass — flushScene always is. No-op when nothing was queued.
    gfx.flushMaterials();
}

pub fn endFrame() void {
    // No `sgl.draw()` here on purpose — `flushScene()` already drained
    // the queue between scene rendering and GUI rendering. Calling
    // `sgl.draw()` a second time would *re-submit* the same vertex /
    // command buffers (sokol-gl rewinds them on `sg_commit`, not on
    // `sgl_draw`), painting the sprites a second time on top of any
    // GUI submitted between the two flushes — which is exactly the
    // labelle-imgui#4 symptom this split fixes.
    //
    // Defensive: if a frame opened `beginPass` but never reached `flushScene`
    // (so the backbuffer pass is still pending — lazy open, labelle-gfx#305),
    // open it now so there is always exactly one pass to end + commit.
    ensureBackbufferPass();
    sg.endPass();
    sg.commit();
}

/// Metal device pointer (MTLDevice*) for the Play-in-Editor preview's
/// macOS/iOS Path-A producer (labelle-assembler#131). Returns the same
/// device sokol acquires for the swapchain — safe to call any number
/// of times per frame. `null` on non-Metal builds and pre-init
/// (sapp not valid yet).
///
/// Path A wraps each IOSurface as an `MTLTexture` via
/// `[device newTextureWithDescriptor:iosurface:plane:]` — the device
/// pointer is the *only* sokol-side resource we still need. The
/// drawable accessor that the Path-B blit chain needed
/// (`sapp_metal_get_current_drawable`, lived on the
/// `feat/expose-cached-metal-drawable` sokol-zig fork) is gone from
/// the generated source. The fork itself is now vestigial — its
/// removal is a separate cleanup step.
pub fn metalDevice() ?*const anyopaque {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .ios) return null;
    if (headless_mode) return headless_mtl_device;
    return sapp.getEnvironment().metal.device;
}

/// Hide the sokol-app window from the screen (labelle-assembler#137).
///
/// Called by the generated `main.zig` once the Play-in-Editor preview
/// connection succeeds — the editor's Game View tab is the user-facing
/// surface in that mode, and the standalone sokol-app window is at
/// best redundant and at worst a foot-gun (closing it tears down the
/// whole preview subprocess).
///
/// Why "hide" not "never open": sokol-app insists on creating a real
/// platform window because the Metal swapchain (and the GL/D3D11
/// contexts) need an NSWindow / HWND attached at init time. The
/// cheapest reliable suppression is therefore post-creation — let
/// sokol bring the window up, then yank it off-screen before the user
/// ever sees it. `orderOut:` (macOS) / `ShowWindow(SW_HIDE)` (Win32)
/// are the platform-specific knobs for that; both leave the window
/// fully functional from a swapchain-lifecycle standpoint, just
/// invisible.
///
/// macOS-only for this slice. Windows D3D11 + Linux GL can land as
/// follow-ups; the call is a no-op on every other platform so callers
/// can invoke it unconditionally inside a comptime-agnostic block.
pub fn hideWindow() void {
    // Currently a no-op on macOS pending a way to suppress the standalone
    // sokol-app window without breaking Path-A's IOSurface pipeline.
    // Every approach tried in this session regressed something:
    //
    // - [NSWindow orderOut:]               → suspended sokol's frame
    //   callbacks (Metal display link), Game View went black.
    // - [NSApp setActivationPolicy:Accessory] → also stopped frame
    //   callbacks, Game View black.
    // - [NSWindow setAlphaValue:0.0]       → display link treated the
    //   alpha-0 window as occluded, frame callbacks stopped.
    // - [NSWindow setFrameOrigin: far off-screen] → window landed on a
    //   phantom screen with mismatched backing scale, the IOSurface
    //   dimensions stopped matching the MTLTexture descriptor and
    //   `_mtlValidateStrideTextureParameters` aborted in-frame.
    //
    // For now the standalone game window stays visible during
    // LABELLE_PREVIEW runs on macOS. Game View renders normally;
    // the user just has an extra window they can ignore or move
    // behind the editor. Real fix is tracked separately.
    _ = sapp;
}

/// The sokol app descriptor type — re-exported so callers don't need to
/// import sokol directly (used by mobile sokol_main return type).
pub const Desc = sapp.Desc;

// ──────────────────────────────────────────────────────────────────
// Preview-mode bridges (labelle-assembler#140 architecture rethink)
// ──────────────────────────────────────────────────────────────────
// These were previously emitted inline by the assembler codegen as
// `\\`-escaped Zig source in `PREVIEW_READBACK_HELPERS_METAL_SOKOL`.
// They're pure backend-specific Metal/objc runtime bindings — the
// generated `main.zig` shouldn't have known about libobjc, Metal
// pixel formats, MTLTextureDescriptor, or IOSurface texture
// wrapping. Moving them here is step one of the preview-decoupling:
// the codegen template now just aliases `window.PreviewMtlBridge`,
// and a future migration moves the per-frame state + frame logic
// across the same seam.

// The libobjc/Metal bindings (`PreviewMtlBridge`), the Path-A IOSurface
// ring state + frame/cleanup logic (`preview_mtl`), the
// `PreviewIOSurfaceVtable`, and the `preview_metal_enabled` comptime gate
// were extracted to `window/preview_mtl.zig` to keep this host file under
// the per-file line budget. They are re-exported below so every name the
// codegen template references stays reachable as `window.<name>` — the
// public API and behaviour are unchanged. The comptime gate (and its
// `if (comptime ...) struct {...} else struct {}` shape that keeps libobjc
// off the non-Darwin link line) lives there verbatim.
const preview_mtl_mod = @import("window/preview_mtl.zig");

pub const preview_metal_enabled = preview_mtl_mod.preview_metal_enabled;
pub const PreviewMtlBridge = preview_mtl_mod.PreviewMtlBridge;
pub const PreviewIOSurfaceVtable = preview_mtl_mod.PreviewIOSurfaceVtable;
pub const preview_mtl = preview_mtl_mod.preview_mtl;

/// Build a sokol app descriptor without starting the event loop.
/// Used on mobile targets where sokol calls sokol_main() and reads its
/// return value as sapp_desc — the host must NOT call sapp_run() itself.
pub fn makeDesc(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) sapp.Desc {
    // Android emulators typically support GLES 3.0 but not 3.1.
    // Sokol defaults to 3.1 on Android, which causes EGL_BAD_CONFIG on emulators.
    // Request 3.0 explicitly so the app works on both real devices and emulators.
    // std.Target.isAndroid() is not available in Zig 0.15.2; check ABI directly.
    // .android covers arm64/x86_64; .androideabi covers arm/x86.
    const is_android = comptime builtin.target.abi == .android or
        builtin.target.abi == .androideabi;
    return .{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb orelse null,
        .width = desc.w,
        .height = desc.h,
        .window_title = desc.title,
        .gl = if (is_android) .{ .major_version = 3, .minor_version = 0 } else .{},
        .high_dpi = true,
        // Honour the desired vsync state at init (sokol reads this once;
        // there's no runtime setter — see `setVsync`). Default 1 = vsync on.
        .swap_interval = desired_swap_interval,
        .logger = .{ .func = slog.func },
    };
}

/// Run the sokol application loop with callbacks. Forwards each field
/// explicitly because Zig treats `run`'s anon-struct parameter and
/// `makeDesc`'s anon-struct parameter as distinct types — passing one
/// to the other directly would fail to compile.
pub fn run(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) void {
    // Windowless branch — when LABELLE_PREVIEW *or* LABELLE_HEADLESS is set
    // on Darwin, skip sokol-app entirely (no NSWindow, no dock icon) and drive
    // sokol-gfx ourselves against a manually-acquired MTLDevice.
    //   * LABELLE_PREVIEW: the editor preview path — the Path-A IOSurface ring
    //     (preview_mtl) is the only visible surface, and the generated main
    //     connects to the editor's TCP listener (also gated on LABELLE_PREVIEW).
    //   * LABELLE_HEADLESS: first-class headless perf-measurement path — same
    //     windowless loop, but no preview/editor connection (the generated
    //     main's preview hooks are LABELLE_PREVIEW-gated, so they stay inert).
    const is_darwin = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios;
    if (is_darwin) {
        if (envTruthy("LABELLE_PREVIEW") or envTruthy("LABELLE_HEADLESS")) {
            runHeadless(.{
                .init_cb = desc.init_cb,
                .frame_cb = desc.frame_cb,
                .cleanup_cb = desc.cleanup_cb,
                .w = desc.w,
                .h = desc.h,
            });
            return;
        }
    }

    sapp.run(makeDesc(.{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb,
        .w = desc.w,
        .h = desc.h,
        .title = desc.title,
    }));
}

/// Run the game without sokol-app. Creates an MTLDevice, lets the game
/// init sokol-gfx against it (via `initGfx`'s headless branch), drives
/// a ~60 Hz frame loop. Darwin-only — `MTLCreateSystemDefaultDevice` is
/// the entry point. Headless preview only path.
fn runHeadless(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    w: i32 = 800,
    h: i32 = 600,
}) void {
    const device = MTLCreateSystemDefaultDevice() orelse {
        std.debug.print("labelle: runHeadless: MTLCreateSystemDefaultDevice returned null; aborting headless/preview run.\n", .{});
        return;
    };

    headless_mode = true;
    headless_mtl_device = device;
    headless_w = desc.w;
    headless_h = desc.h;
    headless_quit_requested = false;
    defer {
        headless_mode = false;
        headless_mtl_device = null;
    }

    desc.init_cb();
    defer desc.cleanup_cb();

    // Perf-measurement knobs — HEADLESS mode only. `runHeadless` also backs
    // the `LABELLE_PREVIEW` editor path, which must keep its normal ~60 Hz,
    // run-until-killed behaviour, so gate the knobs on `LABELLE_HEADLESS`
    // being set rather than reading them unconditionally:
    //   * LABELLE_HEADLESS_UNCAPPED — skip the per-frame nanosleep so the loop
    //     runs flat-out, giving accurate per-frame timing.
    //   * LABELLE_HEADLESS_TICKS=<N> — quit cleanly after N frame callbacks
    //     (0/unset = run until externally killed). A clean exit lets the
    //     existing `cleanup_cb` run so buffered stdio flushes.
    const is_headless = envTruthy("LABELLE_HEADLESS");
    const uncapped = is_headless and envTruthy("LABELLE_HEADLESS_UNCAPPED");
    const max_ticks: u64 = if (is_headless)
        (if (getenv("LABELLE_HEADLESS_TICKS")) |raw|
            (std.fmt.parseInt(u64, std.mem.span(raw), 10) catch 0)
        else
            0)
    else
        0;

    // ~60 Hz frame loop via libc nanosleep (Zig 0.16 moved std.Thread.sleep
    // to an Io-context API we don't have here). Skipped when uncapped.
    const frame_ns: c_long = @intCast(std.time.ns_per_s / 60);
    var ticks: u64 = 0;
    while (!headless_quit_requested) {
        desc.frame_cb();
        ticks += 1;
        if (max_ticks != 0 and ticks >= max_ticks) headless_quit_requested = true;
        if (!uncapped) {
            const ts = std.c.timespec{ .sec = 0, .nsec = frame_ns };
            _ = nanosleep(&ts, null);
        }
    }
}
