const std = @import("std");
const builtin = @import("builtin");

/// True when `t` is a native desktop OS (matches the shared SDL source's
/// comptime `is_desktop`): only there are the SDL `extern`s referenced and SDL
/// must be linked. Android/iOS/tvOS/wasm are excluded — they keep their own
/// gamepad path and pull no SDL.
fn targetIsDesktop(t: std.Target) bool {
    if (t.abi == .android or t.abi == .androideabi) return false;
    if (t.cpu.arch.isWasm()) return false;
    return switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
}

/// macOS Homebrew SDL2 library path for a NATIVE macOS host build (Zig does
/// not search Homebrew by default). Returns null when cross-compiling or on
/// other hosts. On Windows the path is supplied out-of-band via the
/// `LABELLE_SDL2_LIB` env var (see the call site) — Zig ships no default SDL2
/// search path for the MinGW/`windows-gnu` toolchain. No include path is
/// needed on any platform (the shared gamepad source uses `extern fn`).
fn sdlLibPath(target_os: std.Target.Os.Tag, host_os: std.Target.Os.Tag) ?[]const u8 {
    if (target_os != .macos or host_os != .macos) return null;
    if (dirExists("/opt/homebrew/lib")) return "/opt/homebrew/lib";
    if (dirExists("/usr/local/lib")) return "/usr/local/lib";
    return null;
}

/// Desktop Linux (not Android) routes gamepad to labelle-core's kernel-native
/// udev/evdev source (core#33 scope 2): the `sdl_gamepad` module is not wired
/// and NO SDL2 is linked there. input.zig gates its `@import("sdl_gamepad")`
/// on the same predicate.
fn targetUsesCoreGamepad(t: std.Target) bool {
    if (t.abi == .android or t.abi == .androideabi) return false;
    return t.os.tag == .linux;
}

fn dirExists(path: []const u8) bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Re-export sokol's emscripten linker helpers so consumers (generated build.zig)
/// can use emLinkStep for WASM builds without a direct sokol dep.
pub const EmLinkOptions = @import("sokol").EmLinkOptions;
pub const emLinkStep = @import("sokol").emLinkStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward dont_link_system_libs for iOS builds — we link frameworks manually.
    const dont_link_system_libs = b.option(bool, "dont_link_system_libs", "Don't link system libraries (for iOS cross-compilation)") orelse false;

    // Opt-in `with_sokol_imgui` switch — only the imgui-plugin path
    // needs sokol_imgui.c compiled. Forcing it on for every project
    // breaks no-gui builds because sokol_imgui.c `#include`s
    // `cimgui.h`, which only the imgui bridge provides on the include
    // path. WASM-without-imgui was the canonical regression
    // (`sokol_imgui.c:8:10: error: 'cimgui.h' file not found`); session
    // smoke testing surfaced it.
    //
    // IMPORTANT: when `with_imgui=true`, the option set passed here
    // MUST match `labelle-imgui/bridges/sokol/build.zig` exactly. Zig
    // keys each `b.dependency("sokol", .{...})` resolution by the
    // option set, so mismatched options produce *two* separately
    // compiled `sokol_clib` artifacts in the same binary — and
    // therefore two copies of the `_sg` static state. Symptom: sgl
    // draws land in the IOSurface pass but simgui draws don't
    // (different state machines). Symmetric option list = one
    // artifact = one `_sg` (labelle-assembler#140). The assembler's
    // generated build.zig flips `with_imgui` on only when the project
    // has the imgui plugin in its gui config.
    //
    // `with_sokol_imgui_no_app` stays unconditional on every target
    // EXCEPT Android because sokol-zig gates its cflag on the outer
    // `with_sokol_imgui` already — it's a harmless no-op when imgui is
    // off, and keeps the option set identical to the bridge's when
    // imgui is on. Android is the exception: the device runs sokol_app
    // natively (no headless preview), and the freshly-fetched sokol-zig
    // hasn't been patched with the option, so passing it trips
    // `error: invalid option: -Dwith_sokol_imgui_no_app`. The matching
    // skip in `labelle-imgui/bridges/sokol/build.zig` keeps the option
    // sets symmetric on Android too (still one `sokol_clib` artifact,
    // one `_sg`). See labelle-assembler#146.
    const with_imgui = b.option(bool, "with_imgui", "Build sokol with sokol_imgui (must match imgui bridge if used)") orelse false;
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;
    const sokol_dep = if (is_android)
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = with_imgui,
            .dont_link_system_libs = dont_link_system_libs,
        })
    else
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = with_imgui,
            .with_sokol_imgui_no_app = true,
            .dont_link_system_libs = dont_link_system_libs,
        });
    const sokol_mod = sokol_dep.module("sokol");
    const sokol_clib = sokol_dep.artifact("sokol_clib");

    // Shared windowless-SDL desktop gamepad source (core#28). One copy in
    // `backends/sdl_gamepad/`, shared with the raylib backend. On DESKTOP the
    // sokol input backend routes gamepad state/hotplug here (sokol_app has no
    // desktop gamepad pipeline at all); on Android it keeps
    // `android_gamepad_state.zig` (the existing forwarded-event path); on
    // ios/tvos it keeps the GameController bridge. labelle-core is unified onto
    // this module (it imports core under `labelle_core`) so the `GamepadEvent`
    // types match the engine's across the seam. The sub-package gates its SDL
    // `extern`s behind a comptime desktop check, so the Android/iOS/wasm sokol
    // builds reference no SDL.
    //
    // labelle-core: the sokol input backend has no core dep of its own (it
    // reaches ios state via a C ABI), so the sub-package's OWN labelle-core pin
    // is what flows through here. The generated build does not currently
    // overrideImport core onto the sokol input module, so there is no second
    // core instance to clash with on this backend.
    // Desktop gamepad source toggle (core#28 slice 5). When true (default) the
    // shared SDL desktop gamepad source is wired into `input` + SDL2 linked on
    // desktop; when false (opt-out, `.gamepad = .none`) the `sdl_gamepad`
    // import is absent, no SDL2 is linked, and input.zig's desktop gamepad
    // queries resolve to the disabled path (Android/iOS paths are unaffected).
    // The assembler forwards this via `b.dependency(..., .gamepad_enabled)`.
    // Gated so that when opted out, `labelle_sdl_gamepad` is not even resolved
    // as a dependency (the generated zon no longer declares it).
    const gamepad_enabled = b.option(bool, "gamepad_enabled", "Wire the shared SDL desktop gamepad source + link SDL2 (default true; false = opt out, no SDL)") orelse true;
    const gamepad_hidapi = b.option(bool, "gamepad_hidapi", "Opt the SDL gamepad source into HIDAPI raw-HID decode (Switch/8BitDo); default false — HIDAPI per-connect init stalls the render thread for seconds on some platforms") orelse false;

    // Gated on `gamepad_enabled` AND a desktop target: non-desktop sokol builds
    // (Android/iOS/wasm) never use the SDL source, so don't resolve/require it
    // there — Android keeps its JNI gamepad path, iOS its GameController path.
    // Linux desktop is additionally excluded (core#33 scope 2): it routes to
    // labelle-core's udev/evdev source instead, so SDL never enters the graph.
    const sdl_gp_mod: ?*std.Build.Module = if (gamepad_enabled and targetIsDesktop(target.result) and !targetUsesCoreGamepad(target.result)) blk: {
        const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
        const sdl_gp_dep = b.dependency("labelle_sdl_gamepad", .{ .target = target, .optimize = optimize });
        const m = sdl_gp_dep.module("sdl_gamepad");
        m.addImport("labelle_core", core_dep.module("labelle-core"));
        break :blk m;
    } else null;

    // `build_options` carried into `input.zig` so its comptime gamepad routing
    // knows whether `sdl_gamepad` was wired. When false input.zig does not
    // `@import("sdl_gamepad")` and the desktop gamepad path is disabled.
    const input_opts = b.addOptions();
    input_opts.addOption(bool, "gamepad_enabled", gamepad_enabled);
    input_opts.addOption(bool, "gamepad_hidapi", gamepad_hidapi);

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("sokol", sokol_mod);
    gfx_mod.addIncludePath(b.path("src"));

    // labelle-core: the material seam (labelle-gfx#305, src/gfx/material.zig)
    // uses the contract's `MaterialEffect` / `MaterialUniforms` / `Material`
    // value types — exactly as the bgfx backend does — so the gfx module now
    // carries a core import. Shared with input/window below.
    const gfx_core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const gfx_core_mod = gfx_core_dep.module("labelle-core");
    gfx_mod.addImport("labelle-core", gfx_core_mod);

    // When cross-compiling to wasm32-emscripten the C compile of
    // `stb_image_impl.c` cannot find `<stdlib.h>` / `<stdio.h>`
    // because Zig does not ship libc headers for `wasm32-emscripten`
    // — they live in emsdk's sysroot. Plumb the emsdk sysroot include
    // path into the gfx module BEFORE adding the C sources so the
    // build graph has it attached when the consuming Compile step
    // collects translation units. Gated on `.emscripten` so the
    // desktop / mobile builds remain untouched (labelle-cli#197,
    // labelle-assembler#141).
    //
    // Note: this MUST run before `addCSourceFile` below. In testing,
    // setting it after the addCSourceFile calls caused emcc to bail
    // with `'stdio.h' file not found`. Mirrors sokol-zig's pattern
    // in `mod_sokol_clib`'s setup.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            gfx_mod.addSystemIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });
    // Phase 4 font baker (labelle-engine#448). stb_truetype lives next
    // to stb_image and is compiled in the same way — single-header C
    // lib, separate `_impl.c` translation unit defining the
    // implementation macro.
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_truetype_impl.c"), .flags = &.{} });

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sokol", sokol_mod);
    input_mod.addImport("build_options", input_opts.createModule());
    if (sdl_gp_mod) |m| input_mod.addImport("sdl_gamepad", m);

    // Linux desktop core route (core#33 scope 2): input.zig reaches the
    // kernel-native udev/evdev source through a DIRECT labelle-core import
    // (the sokol input backend historically had no core dep of its own — it
    // only existed transitively through sdl_gamepad). The generated build
    // unifies the app's core onto this import (guarded overrideImport in the
    // backend_sokol template section) so event/state types match the engine's.
    if (gamepad_enabled and targetUsesCoreGamepad(target.result)) {
        const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
        input_mod.addImport("labelle-core", core_dep.module("labelle-core"));
    } else if (is_android) {
        // Android seam adapter (labelle-core#310, Stage 3): `src/android.zig`
        // builds the `core.AndroidBackendContext` literal the generated
        // sokol-Android main registers with core, so it imports `labelle-core`
        // for the `AndroidBackendContext` type. The generated build unifies the
        // app's core onto this import (guarded overrideImport in the
        // backend_sokol template section) so the registered vtable's type
        // matches the engine's `engine.core.AndroidBackendContext`. (Mutually
        // exclusive with the Linux-desktop core route above — Android is never
        // a desktop target.)
        const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
        input_mod.addImport("labelle-core", core_dep.module("labelle-core"));
    }

    // Link SDL2 for the shared desktop gamepad source — DESKTOP targets ONLY,
    // and only when the gamepad source is wired (`gamepad_enabled`). Android
    // keeps `android_gamepad_state.zig` (no SDL); iOS/tvOS keep the
    // GameController bridge; wasm has no gamepad. The shared source gates its
    // SDL `extern`s behind a comptime desktop check, so those builds reference
    // no SDL and must not link it. When opted out NO SDL is linked anywhere.
    // No `@cImport`/include path needed (the source uses `extern fn`); on macOS
    // the Homebrew lib path is added.
    if (gamepad_enabled and targetIsDesktop(target.result) and !targetUsesCoreGamepad(target.result)) {
        input_mod.link_libc = true;
        if (sdlLibPath(target.result.os.tag, builtin.target.os.tag)) |p| {
            input_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        // Windows: Zig has no default SDL2 search path for the MinGW
        // (`windows-gnu`) toolchain, so honor `LABELLE_SDL2_LIB` — the dir
        // holding the import lib (`libSDL2.dll.a`) from the SDL2 MinGW devel
        // package. `SDL2.dll` must be on PATH (or beside the exe) at runtime.
        if (target.result.os.tag == .windows and builtin.target.os.tag == .windows) {
            if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
                input_mod.addLibraryPath(.{ .cwd_relative = p });
            }
        }
        input_mod.linkSystemLibrary("SDL2", .{});
    } else if (gamepad_enabled and targetUsesCoreGamepad(target.result)) {
        // Linux core route: no SDL, but core's udev source dlopens libudev at
        // runtime via std.DynLib, which needs real dlopen — link libc.
        input_mod.link_libc = true;
    }

    // Android gamepad source (#310 Stage 4): the per-device STATE machine
    // (`android_gamepad_state.zig`) and the InputManager JNI DETECTION glue
    // (`android_gamepad_jni.c`) now live in the shared `../android_gamepad`
    // sub-package, consumed by BOTH the sokol and bgfx Android backends.
    //
    // `input.zig` imports the state module under `android_gamepad` (mapping +
    // quirk table + per-device button/axis state). The JNI glue calls into
    // Android's InputManager to detect controller hotplug/identity;
    // labelle-core's `gamepad_source/android.zig` declares the
    // `extern fn labelle_android_gamepad_init/_shutdown` entry points it
    // defines, and the `export fn labelle_android_on_device_*` callbacks it
    // invokes. The C TU is wrapped in `#ifdef __ANDROID__`, so it emits an
    // empty object on every other target. We pull its source via
    // `dep.path(...)` (cross-package `b.path("..")` is rejected by Zig 0.16)
    // and compile it into THIS module, where the Android NDK sysroot/libc is
    // already wired. Gated on Android so desktop/wasm builds stay linker-free.
    const android_gp_dep = b.dependency("labelle_android_gamepad", .{ .target = target, .optimize = optimize });
    input_mod.addImport("android_gamepad", android_gp_dep.module("android_gamepad"));
    if (is_android) {
        input_mod.link_libc = true;
        input_mod.addCSourceFile(.{
            .file = android_gp_dep.path("src/android_gamepad_jni.c"),
            .flags = &.{},
        });
    }

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_mod.addImport("sokol", sokol_mod);
    audio_mod.addIncludePath(b.path("src"));

    // Shared audio engine (Phase 2 of the pluggable-backends RFC). The WAV
    // decode + PCM mixer + slot management this backend used to reimplement now
    // live in `labelle-audio`; `src/audio.zig` instantiates
    // `labelle_audio.Mixer(SokolSink)`, where `SokolSink` (src/audio/sink.zig)
    // is the sokol_audio device adapted to the shared **f32** `DeviceSink`
    // contract (sokol_audio's stream callback is f32, so the mixer renders
    // straight into it — v0.3.0's f32 path). The generated app build must also
    // wire this dep onto the `audio` module (mirrors bgfx — see report).
    const labelle_audio_dep = b.dependency("labelle_audio", .{ .target = target, .optimize = optimize });
    audio_mod.addImport("labelle-audio", labelle_audio_dep.module("labelle-audio"));

    // Shared OGG/WAV CPU decoder (issue #391). The `decodeAudio` surface the
    // assembler's `writeAudioBackendWiring` calls used to be a hand-rolled
    // dr_wav + stb_vorbis copy living in `src/audio/decode.zig` (+ the four C
    // files below). It now forwards to the shared `labelle-audio-decode` module
    // from the SAME package (pure-Zig WAV via `wav.decode` + OGG via
    // stb_vorbis, which the decode module carries internally).
    //
    // The mixer (`labelle-audio`) AND this decoder (`labelle-audio-decode`)
    // coexist in ONE Compile here — the sokol-specific need (mixer + OGG). That
    // is exactly what v0.4.0 could NOT build ("file exists in modules
    // 'labelle-audio' and 'labelle-audio-decode'"): it packaged wav.zig into
    // both module roots by path. v0.4.1 fixes it — decode reaches wav by NAME
    // through the base module, so every shared file is rooted in exactly one
    // module. The decode module declares `link_libc` (for stb_vorbis); it
    // propagates onto the audio module.
    audio_mod.addImport("labelle-audio-decode", labelle_audio_dep.module("labelle-audio-decode"));

    // ── Window backend module ───────────────────────────────────────
    // `link_libc = true` is required because `screenshot/bmp.zig` writes
    // the BMP file via libc `fopen` / `fwrite` / `fclose` — Zig 0.16
    // dropped the allocator-free `std.fs.cwd()` helper and threading an
    // `Io` through `takeScreenshot` (which is invoked from a deep
    // callback) wasn't worth it for a 60-line writer. See bmp.zig's
    // header comment and the matching libc shims in gfx/texture.zig and
    // audio/legacy.zig (PR #218).
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_mod.addImport("sokol", sokol_mod);
    // The window frame host drives the gfx material seam's per-frame lifecycle
    // (labelle-gfx#305), so it imports the SAME gfx module instance the game
    // imports — module-level material-queue state is shared.
    window_mod.addImport("gfx", gfx_mod);

    // ── Re-export the native artifact so consumers can link it ──────
    b.installArtifact(sokol_clib);

    // ── Unit tests ──────────────────────────────────────────────────
    const test_step = b.step("test", "Run sokol backend unit tests");

    // The audio slot/mixer/decode state-transition tests that used to live in
    // `src/audio_slots.zig` (the #10 unloaded-slot leak lock, #110/#111 slot
    // recycling) moved into the shared `labelle-audio` package along with the
    // mixer + slot management itself (Phase 2 fan-out). They run under
    // `labelle-audio`'s own `zig build test`; the sokol adapter's thin
    // forwarding + the kept OGG/WAV decoder are exercised by `audio_compile_check`
    // / `test-host` below.
    const host_target = b.resolveTargetQuery(.{});

    // Run the ASTC container-parsing tests (#341). `gfx/astc.zig` is pure byte
    // parsing with no sokol dependency, so it EXECUTES on the host (magic
    // detection, block/image dims, ceil-to-block payload sizing, truncation).
    // It's a verbatim copy of the bgfx backend's parser, so this keeps the
    // container handling consistent across backends.
    const astc_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gfx/astc.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(astc_run).step);

    // Compile-check audio.zig via a test binary off audio_mod. This
    // pulls in the full sokol module graph so it only works when the
    // host has sokol's system libs installed (libasound, libGL, libX11,
    // libXi, libXcursor on Linux). Depending on the compile step keeps
    // this useful for cross-compile (the binary doesn't need to run);
    // the host_audio_tests step below adds the run side for native.
    const audio_compile_check = b.addTest(.{ .root_module = audio_mod });
    test_step.dependOn(&audio_compile_check.step);

    // Compile-check gfx.zig — same trick as `audio_compile_check`.
    // Verifies the Phase 4 font surface (`FontAtlas`, `decodeFont`,
    // `uploadFontAtlas`, `unloadFontAtlas`) keeps compiling against
    // sokol_gfx + stb_truetype.
    const gfx_compile_check = b.addTest(.{ .root_module = gfx_mod });
    test_step.dependOn(&gfx_compile_check.step);

    // Compile-check input.zig — pulls in sokol_app + (on Android) the JNI
    // gamepad-detection C glue. Regression lock for labelle-assembler#248:
    // verifies the back-key policy compiles and, on the Android target, that
    // `android_gamepad_jni.c` links into the input module graph. Like the
    // other checks this only builds the binary (cross-compile safe).
    const input_compile_check = b.addTest(.{ .root_module = input_mod });
    test_step.dependOn(&input_compile_check.step);

    // ── Cross-compile SDL-gating object (core#28) ───────────────────────
    // Emits ONLY the gamepad-routing surface as an object for the requested
    // target, via a standalone module that imports sdl_gamepad but NOT sokol
    // (so it does not drag in sokol_clib, whose C compile needs the Android
    // NDK sysroot). On a non-desktop target the shared source's `is_desktop`
    // is false, so the object must contain NO undefined `SDL_*` symbols —
    // proving the Android sokol path pulls no SDL. Verify with:
    //   zig build gating-obj -Dtarget=aarch64-linux-android
    //   nm -u zig-out/bin/sdl_gamepad_gating.o | grep -E 'SDL_[A-Z]'  # empty
    // Only meaningful when the gamepad source is wired; on opt-out there is no
    // `sdl_gamepad` module to probe, so the step is omitted.
    if (sdl_gp_mod) |m| {
        const gating_obj = b.addObject(.{
            .name = "sdl_gamepad_gating",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gamepad_gating_probe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sdl_gamepad", .module = m },
                },
            }),
        });
        const gating_step = b.step("gating-obj", "Emit the gamepad surface as an object (no sokol_clib) for cross-compile SDL symbol gating");
        gating_step.dependOn(&b.addInstallBinFile(gating_obj.getEmittedBin(), "sdl_gamepad_gating.o").step);
    }

    // Android gamepad STATE (labelle-assembler#250) — the mapping table, quirk
    // routing, and per-device state machine — now live in the shared
    // `../android_gamepad` sub-package (#310 Stage 4). Its pure-Zig unit tests
    // run under `cd backends/android_gamepad && zig build test`, so they are no
    // longer duplicated here; `input_compile_check` above still pulls the state
    // module (imported as `android_gamepad`) into the sokol input graph.

    // Compile-check window.zig — pulls in sokol + the per-backend
    // screenshot readback helpers (`screenshot/metal.zig`, `gl.zig`,
    // `d3d11.zig`, `bmp.zig`). Regression lock for the screenshot
    // implementation (labelle-assembler#213); without this the four
    // helper files were unreached by any test target.
    const window_compile_check = b.addTest(.{ .root_module = window_mod });
    test_step.dependOn(&window_compile_check.step);

    // ── Phase 4 host-native test runs ────────────────────────────────
    //
    // The compile-checks above only ensure the bytecode builds. The
    // Phase 4 decoder unit tests (decodeFont rejecting empty/garbage
    // input, decodeAudio dispatching on file_type, Sound layout
    // invariants) are pure-CPU and exercise no sokol API — they're
    // safe to run on the host target when the user explicitly asks
    // for it. Wired off a separate `test-host` step rather than
    // `test` so the default cross-compile flow stays linker-free.
    const test_host_step = b.step(
        "test-host",
        "Run Phase 4 decoder unit tests natively (needs sokol's system libs).",
    );
    test_host_step.dependOn(&b.addRunArtifact(audio_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(gfx_compile_check).step);
    // input.zig's pure keyboard-edge tests (back-key policy + the #263
    // key-repeat regression) call no sokol API, so run them natively too.
    test_host_step.dependOn(&b.addRunArtifact(input_compile_check).step);

    // ── Material golden harness (labelle-gfx#305, Phase 3 — full set) ────────
    // `zig build material-golden`       — render the FIXED 10-column scene
    //     (flash, palette_swap, dissolve, outline + the atlas/tint/threshold
    //     boundary cases, mirroring the bgfx golden) surfaceless-headless and
    //     DIFF it against the committed golden BMP.
    // `zig build material-golden-bless` — regenerate + overwrite the golden.
    //
    // macOS-only: the headless path is raw-Metal (`window.beginHeadless` →
    // `MTLCreateSystemDefaultDevice`), which only links/resolves on Darwin. On a
    // non-macOS host the step is simply absent. The exe links `sokol_clib` (which
    // carries the Metal/QuartzCore framework links) + the gfx/window modules.
    if (target.result.os.tag == .macos) {
        // ── labelle-gfx (TEST/GOLDEN-ONLY) — the real backend-agnostic gfx
        // library, pulled in ONLY to drive its `PostFxDriver` over THIS sokol
        // backend in the post-fx INTEGRATION golden. gfx deps `labelle-core`,
        // sokol deps `labelle-core`, and labelle-gfx is BACKEND-AGNOSTIC (deps
        // core, NOT sokol), so there is no cycle. We MUST override labelle-gfx's
        // own `labelle-core` onto the sokol backend's core module (`gfx_core_mod`,
        // v1.26.0) so the diamond unifies at the SOURCE level — otherwise
        // `PostPass`/`RenderTargetId` from gfx's core instance would not type-check
        // against the sokol backend's core instance and `PostFxDriver(gfx)`
        // wouldn't compile (the same core-unify seam the material seam added).
        // Lazy → only fetched when this macOS golden target is actually built.
        const gfx_lib_mod: ?*std.Build.Module = if (b.lazyDependency("labelle_gfx", .{ .target = target, .optimize = optimize })) |dep| blk: {
            const m = dep.module("labelle-gfx");
            m.addImport("labelle-core", gfx_core_mod); // unify the core diamond onto sokol's pin
            break :blk m;
        } else null;

        const Golden = struct {
            fn make(
                bb: *std.Build,
                t: std.Build.ResolvedTarget,
                o: std.builtin.OptimizeMode,
                smod: *std.Build.Module,
                gmod: *std.Build.Module,
                wmod: *std.Build.Module,
                gfx_lib_m: ?*std.Build.Module, // non-null only for the integration golden
                clib: *std.Build.Step.Compile,
                name: []const u8,
                src: []const u8,
                bless: bool,
            ) *std.Build.Step.Run {
                const opts = bb.addOptions();
                opts.addOption(bool, "bless", bless);
                const exe = bb.addExecutable(.{
                    .name = bb.fmt("{s}{s}", .{ name, if (bless) "_bless" else "" }),
                    .root_module = bb.createModule(.{
                        .root_source_file = bb.path(src),
                        .target = t,
                        .optimize = o,
                        .link_libc = true,
                    }),
                });
                exe.root_module.addImport("sokol", smod);
                exe.root_module.addImport("gfx", gmod);
                exe.root_module.addImport("window", wmod);
                if (gfx_lib_m) |glm| exe.root_module.addImport("labelle-gfx", glm);
                exe.root_module.addImport("golden_options", opts.createModule());
                exe.root_module.linkLibrary(clib);
                const run = bb.addRunArtifact(exe);
                // Render/diff writes into the checkout — run from the project root.
                run.setCwd(bb.path("."));
                return run;
            }
        };

        const golden_check = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, null, sokol_clib, "material_golden", "src/material_golden.zig", false);
        const golden_step = b.step("material-golden", "Diff the full material-effect scene (flash/palette_swap/dissolve/outline) against the committed golden (#305)");
        golden_step.dependOn(&golden_check.step);

        const golden_bless = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, null, sokol_clib, "material_golden", "src/material_golden.zig", true);
        const golden_bless_step = b.step("material-golden-bless", "Regenerate the material golden BMP (#305)");
        golden_bless_step.dependOn(&golden_bless.step);

        // ── Post-fx golden (bloom→crt, DIRECT applyPostPass) — pins the shaders ──
        const pfx_check = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, null, sokol_clib, "post_fx_golden", "src/post_fx_golden.zig", false);
        const pfx_step = b.step("post-fx-golden", "Diff the bloom+crt post-fx stack against the committed golden (#305)");
        pfx_step.dependOn(&pfx_check.step);

        const pfx_bless = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, null, sokol_clib, "post_fx_golden", "src/post_fx_golden.zig", true);
        const pfx_bless_step = b.step("post-fx-golden-bless", "Regenerate the post-fx golden BMP (#305)");
        pfx_bless_step.dependOn(&pfx_bless.step);

        // ── Post-fx INTEGRATION golden (drives the REAL gfx PostFxDriver) ────────
        // The integration proof: exercises the driver's begin/applyPostPass/resolve
        // ping-pong through sokol's DEFERRED plan (executed at flushScene). Diffed
        // against the reference golden `post_fx_golden` blesses. Needs labelle-gfx.
        if (gfx_lib_mod) |gfx_lib_m| {
            const int_check = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, gfx_lib_m, sokol_clib, "post_fx_integration_golden", "src/post_fx_integration_golden.zig", false);
            const int_step = b.step("post-fx-integration-golden", "Drive the REAL gfx PostFxDriver over sokol (bloom→crt) and diff against the reference golden (#305)");
            int_step.dependOn(&int_check.step);

            const int_bless = Golden.make(b, target, optimize, sokol_mod, gfx_mod, window_mod, gfx_lib_m, sokol_clib, "post_fx_integration_golden", "src/post_fx_integration_golden.zig", true);
            const int_bless_step = b.step("post-fx-integration-golden-bless", "Regenerate the integration golden BMP (#305)");
            int_bless_step.dependOn(&int_bless.step);
        }
    }
}
