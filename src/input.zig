/// Sokol input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses sokol_app events for keyboard/mouse/touch state.
// Contract-version tags (labelle-assembler#453 item 1). The assembler emits
// directional `@compileError` version asserts in the generated game's main.zig
// comparing these against labelle-core's `*_CONTRACT_VERSION` consts. v1 is the
// initial revision of each contract.
pub const targets_input_contract: u32 = 1;

const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;

// ── iOS / tvOS gamepad bridge (labelle-assembler#251) ──────────────
//
// sokol_app has no gamepad pipeline of its own, so gamepad state on
// ios/tvos comes from Apple's GameController.framework. The objc bridge
// lives in labelle-core (`src/gamepad_source/ios.zig`) — it owns the single
// `GCController` connection, so there is exactly one set of live state.
//
// This backend module has no dependency edge to labelle-core, so we reach
// the GC state through a tiny exported C ABI rather than a Zig import: the
// core file `@export`s `labelle_gc_*` and we re-declare them `extern` here.
// Both sides are gated on ios/tvos, so on every other target these symbols
// never exist and are never referenced — the gamepad poll methods below fall
// back to the original "no gamepad" behavior.
//
// The exe links both labelle-core (which provides the symbols) and this
// `input` module (which consumes them), and GameController.framework is
// linked by the generated build.zig — so the link resolves on-device.
const gc_enabled = builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos;

const gc = if (gc_enabled) struct {
    extern "c" fn labelle_gc_button_down(slot: u32, button: u32) bool;
    extern "c" fn labelle_gc_axis_value(slot: u32, axis: u32) f32;
    extern "c" fn labelle_gc_connected(slot: u32) bool;
} else struct {};

// ── Android analog gamepad bridge (labelle-assembler#250) ──────────────
//
// sokol_app drops controller input on Android. The labelle-toolkit sokol fork
// (branch `feat/forward-android-gamepad-events`) instead forwards the raw
// gamepad data to a registered C callback. We register `androidGamepadCallback`
// at `init`, accumulate per-device button/axis state in
// `android_gamepad_state.zig` (mapping + quirk table), and resolve the
// engine's `(gamepad_id, button/axis)` queries against it.
//
// The engine queries with `gamepad_id == Android device id`, because the #248
// detection registry emits its hotplug `.slot` as the device id. The state
// module keys its records on the same device id, so the two layers line up
// without an extra translation table.
//
// All of this is gated behind `agp.is_android`: on every other target the
// extern fork symbol is never referenced and the poll methods fall back to the
// iOS GameController path (or the no-gamepad defaults).
const agp = @import("android_gamepad");

// ── Desktop gamepad bridge (core#28) ───────────────────────────────────
//
// sokol_app has NO desktop gamepad pipeline, so on macOS/Windows/Linux the
// gamepad surface routes to the shared windowless-SDL source (the same copy
// the raylib backend uses, `backends/sdl_gamepad/`). SDL's per-device HID
// drivers decode controllers (Switch / 8BitDo) the platform layer can't.
//
// Gating mirrors the `agp.is_android` style: `use_sdl_gamepad` is true only on
// a desktop target. The source gates its own SDL `extern`s behind the same
// comptime `is_desktop`, so Android/iOS/wasm reference no SDL and fall back to
// the android_gamepad_state path / GameController bridge / no-gamepad defaults.
//
// `gamepad_enabled` (core#28 slice 5) is forwarded from the backend build.zig.
// When false (`.gamepad = .none` opt-out) the `sdl_gamepad` module is NOT in
// the build graph, so we must not `@import` it; the `@import` therefore lives
// inside the taken comptime branch. With the source absent `use_sdl_gamepad`
// is false on desktop, so the gamepad queries fall through to the no-gamepad
// defaults (`gc_enabled` is false off ios/tvos) — truly disabled, no SDL. The
// Android / iOS branches are unaffected (the flag only governs the SDL path).
const gamepad_enabled = @import("build_options").gamepad_enabled;
// Opt-in for HIDAPI raw-HID decode in the shared SDL gamepad source; OFF by
// default (HIDAPI's per-connect init stalls the render thread for seconds on
// some platforms). Pushed into the source before its lazy SDL init.
const gamepad_hidapi = @import("build_options").gamepad_hidapi;
// Mirrors `targetIsDesktop` in build.zig: the SDL source module is wired ONLY
// when (gamepad_enabled AND desktop target), so the `@import` must match — on
// Android/iOS/wasm the module isn't in the graph (and those keep their JNI /
// GameController / no-gamepad paths). Importing it there is a compile error.
const target_is_desktop = blk: {
    const t = builtin.target;
    if (t.abi == .android or t.abi == .androideabi) break :blk false;
    if (t.cpu.arch.isWasm()) break :blk false;
    break :blk switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
};
// Linux desktop routes to labelle-core's kernel-native udev/evdev source
// instead of the SDL one (core#33 scope 2): same Source surface, no SDL2
// link. Mirrors `targetUsesCoreGamepad` in build.zig — there the build wires
// a direct `labelle-core` import (and no `sdl_gamepad`, no SDL2) on Linux,
// so both `@import`s below must be gated identically.
const target_is_linux_desktop = target_is_desktop and builtin.target.os.tag == .linux;

const sdl_gp = if (gamepad_enabled and target_is_desktop and !target_is_linux_desktop) @import("sdl_gamepad") else struct {
    pub const is_desktop = false;
};
const use_core_gamepad = gamepad_enabled and target_is_linux_desktop;
const core_gp = if (use_core_gamepad) @import("labelle-core").gamepad_source else struct {};
const use_sdl_gamepad = gamepad_enabled and sdl_gp.is_desktop;

const AndroidGamepadEventType = enum(c_int) {
    invalid = 0,
    key = 1,
    motion = 2,
};

// Mirrors `sapp_android_gamepad_event` in the patched sokol_app.h. Field order
// and types are ABI — keep in lockstep with the fork header.
const SappAndroidGamepadEvent = extern struct {
    type: AndroidGamepadEventType,
    device_id: i32,
    key_code: i32,
    key_down: bool,
    axis: [agp.FORWARDED_AXIS_COUNT]f32,
};

const android_gp = if (agp.is_android) struct {
    extern "c" fn sapp_android_register_gamepad_callback(
        cb: ?*const fn (ev: *const SappAndroidGamepadEvent) callconv(.c) void,
    ) void;
    // JNI detection glue (android_gamepad_jni.c). Enumerates the InputManager
    // device ids at startup and registers the device listener, seeding the
    // gamepad state for controllers already connected before launch. The C
    // signature is `void labelle_android_gamepad_init(const void *activity_ptr)`.
    extern "c" fn labelle_android_gamepad_init(activity: ?*const anyopaque) void;
} else struct {};

/// Forwarded-event sink, invoked by the sokol fork on the Android Looper
/// thread. Exported with C linkage so the fork's registration can call it.
/// `export` is harmless on non-Android targets (it is just never invoked, and
/// the body is a comptime no-op there).
export fn androidGamepadCallback(ev: *const SappAndroidGamepadEvent) callconv(.c) void {
    if (comptime !agp.is_android) return;
    switch (ev.type) {
        .key => agp.applyKey(ev.device_id, ev.key_code, ev.key_down),
        .motion => agp.applyMotion(ev.device_id, ev.axis),
        .invalid => {},
    }
}

/// Register the forwarded-gamepad callback with the sokol fork. Call once at
/// startup (from `window.zig`'s init, alongside the detection-registry init).
/// No-op off Android.
pub fn initAndroidGamepad() void {
    if (comptime agp.is_android) {
        // Forwarded-event sink first, then the JNI enumeration: the latter
        // walks the InputManager device ids and emits state-added for pads
        // already connected at launch, so the HUD shows them without a button
        // press. `androidGetNativeActivity()` wraps sokol's
        // `sapp_android_get_native_activity()`; it is null before sokol has a
        // running activity, and the C side no-ops on a null pointer.
        android_gp.sapp_android_register_gamepad_callback(&androidGamepadCallback);
        android_gp.labelle_android_gamepad_init(sapp.androidGetNativeActivity());
    }
}

// ── State ─────────────────────────────────────────────────

var keys_down: [512]bool = [_]bool{false} ** 512;
var keys_pressed: [512]bool = [_]bool{false} ** 512;
var keys_released: [512]bool = [_]bool{false} ** 512;
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_buttons_down: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_pressed: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_released: [3]bool = [_]bool{false} ** 3;
var mouse_wheel: f32 = 0;

const MAX_TOUCHES = 10;
var touch_count: u32 = 0;
var touch_xs: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ys: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ids: [MAX_TOUCHES]u64 = [_]u64{0} ** MAX_TOUCHES;

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (key >= 512) return false;
    return keys_down[key];
}

pub fn isKeyPressed(key: u32) bool {
    if (key >= 512) return false;
    return keys_pressed[key];
}

pub fn isKeyReleased(key: u32) bool {
    if (key >= 512) return false;
    return keys_released[key];
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_down[btn];
}

pub fn isMouseButtonPressed(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_pressed[btn];
}

pub fn isMouseButtonReleased(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_released[btn];
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return touch_count;
}

pub fn getTouchX(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_xs[index];
}

pub fn getTouchY(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ys[index];
}

pub fn getTouchId(index: u32) u64 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ids[index];
}

// ── Gamepad back-button interception (Android, labelle-assembler#248) ─
//
// On Android the controller "B" button is reported by the system as
// `KEYCODE_BACK`. sokol_app's Android backend hard-consumes `AKEYCODE_BACK`
// in `_sapp_android_key_event` and calls `_sapp_android_shutdown()` directly
// — it never forwards a sokol event for it. So a player pressing B on a
// controller silently quits the game.
//
// We cannot intercept that from the Zig event callback for the *default*
// sokol build, because sokol consumes the key before our `event_cb` runs.
// What we CAN do here is provide the policy hook + state used by the
// interception path, and treat a forwarded BACK/B (when a sokol patch or a
// controller that does NOT alias B→BACK delivers it) as a gamepad button
// rather than a window-close. `consume_back` defaults true so games don't
// exit on B; flip it off if you want BACK to close the app.
//
// On-device wiring (PR checklist): the complete fix routes controller key
// events through the JNI glue's listener path and only forwards true
// navigation BACK (touch / system bar) to the quit path.
pub var consume_back: bool = true;

/// True if `keycode` is the Android BACK key — which is also what a
/// controller B reports on Android. 0x04 == AKEYCODE_BACK. We deliberately
/// do NOT include sokol's ESCAPE (256) here: on desktop, ESCAPE-to-quit is a
/// game-level policy driven by `g.isRunning()`, not a window-close, so
/// guarding it would silently break desktop quit handling.
pub fn isBackKey(keycode: i32) bool {
    return keycode == 0x04; // AKEYCODE_BACK
}

/// Whether a BACK/B key event should be swallowed (kept from quitting the
/// app). Returns true when interception is enabled. The event callback uses
/// this to decide whether to record the key vs. drop it.
pub fn shouldConsumeBack(keycode: i32) bool {
    return consume_back and isBackKey(keycode);
}

// ── Gamepad ───────────────────────────────────────────────
//
// On ios/tvos these forward to the GameController bridge in labelle-core
// (see the `gc` extern block above). On every other target sokol_app has no
// gamepad pipeline, so they return the original defaults.
//
// `isGamepadButtonPressed` needs a rising-edge: GameController is a pure
// state API (`isPressed`), with no "pressed-this-frame" flag. We derive the
// edge by comparing the current `down` state against the previous frame's,
// snapshotted in `newFrame`. Button/axis numbering follows the engine's
// canonical raylib-compatible `GamepadButton`/`GamepadAxis` enums — the same
// values the core bridge maps to GCExtendedGamepad elements.

const MAX_GAMEPADS = 4;
const MAX_GAMEPAD_BUTTONS = 18; // raylib GamepadButton range [0, 17]
const MAX_GAMEPAD_AXES = 6; // raylib GamepadAxis range [0, 5] (LX, LY, RX, RY, LT, RT)

// Previous-frame "down" snapshot, used to compute the rising edge in
// `isGamepadButtonPressed`. Updated once per frame in `newFrame`.
var gamepad_prev_down: [MAX_GAMEPADS][MAX_GAMEPAD_BUTTONS]bool =
    [_][MAX_GAMEPAD_BUTTONS]bool{[_]bool{false} ** MAX_GAMEPAD_BUTTONS} ** MAX_GAMEPADS;

pub fn isGamepadAvailable(gamepad_id: u32) bool {
    if (comptime use_core_gamepad) return core_gp.Source.isAvailable(gamepad_id);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isAvailable(gamepad_id);
    if (comptime agp.is_android) return agp.connected(gamepad_id);
    if (!gc_enabled) return false;
    if (gamepad_id >= MAX_GAMEPADS) return false;
    return gc.labelle_gc_connected(gamepad_id);
}

pub fn isGamepadButtonDown(gamepad_id: u32, button: u32) bool {
    if (comptime use_core_gamepad) return core_gp.Source.isButtonDown(gamepad_id, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonDown(gamepad_id, button);
    if (comptime agp.is_android) return agp.buttonDown(gamepad_id, button);
    if (!gc_enabled) return false;
    if (gamepad_id >= MAX_GAMEPADS or button >= MAX_GAMEPAD_BUTTONS) return false;
    return gc.labelle_gc_button_down(gamepad_id, button);
}

pub fn isGamepadButtonPressed(gamepad_id: u32, button: u32) bool {
    // On desktop the wired source owns the prev/cur edge snapshot (refreshed
    // in its `update()`), keyed by the dense 0..3 slot.
    if (comptime use_core_gamepad) return core_gp.Source.isButtonPressed(gamepad_id, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonPressed(gamepad_id, button);
    // On Android, edge detection lives in the state module (it snapshots
    // prev-down across `newFrame`), keyed by Android device id rather than a
    // fixed 0..3 slot.
    if (comptime agp.is_android) return agp.buttonPressed(gamepad_id, button);
    if (!gc_enabled) return false;
    // Bounds-check before indexing `gamepad_prev_down` and before the extern
    // call — out-of-range queries report "not pressed" (matches isKeyPressed).
    if (gamepad_id >= MAX_GAMEPADS or button >= MAX_GAMEPAD_BUTTONS) return false;
    const now = gc.labelle_gc_button_down(gamepad_id, button);
    return now and !gamepad_prev_down[gamepad_id][button];
}

pub fn getGamepadAxisValue(gamepad_id: u32, axis: u32) f32 {
    if (comptime use_core_gamepad) return core_gp.Source.axisValue(gamepad_id, axis);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.axisValue(gamepad_id, axis);
    if (comptime agp.is_android) return agp.axisValue(gamepad_id, axis);
    if (!gc_enabled) return 0;
    // Guard the axis too (not just gamepad_id) so an out-of-range index can't
    // cross the C ABI — matches the SDL backend's safe-0 return.
    if (gamepad_id >= MAX_GAMEPADS or axis >= MAX_GAMEPAD_AXES) return 0;
    return gc.labelle_gc_axis_value(gamepad_id, axis);
}

/// Snapshot current gamepad button state so the next frame's
/// `isGamepadButtonPressed` can compute the rising edge. No-op off ios/tvos.
fn snapshotGamepadButtons() void {
    // Desktop: pump the wired gamepad source once per frame. `update()`
    // refreshes the button-edge snapshot the source uses for
    // `isButtonPressed` (and, on the Linux core source, pumps hotplug on an
    // internal ~1/s throttle). This is the single per-frame pump point for
    // the sokol desktop gamepad path.
    if (comptime use_core_gamepad) {
        core_gp.Source.update();
        return;
    }
    if (comptime use_sdl_gamepad) {
        sdl_gp.hidapi_enabled = gamepad_hidapi;
        sdl_gp.Source.update();
        return;
    }
    if (comptime agp.is_android) {
        agp.newFrame();
        return;
    }
    if (!gc_enabled) return;
    var g: u32 = 0;
    while (g < MAX_GAMEPADS) : (g += 1) {
        // Skip the per-button C-calls for slots with no controller (clear any
        // stale state so a reconnect can't surface a ghost rising edge).
        if (gc.labelle_gc_connected(g)) {
            var btn: u32 = 0;
            while (btn < MAX_GAMEPAD_BUTTONS) : (btn += 1) {
                gamepad_prev_down[g][btn] = gc.labelle_gc_button_down(g, btn);
            }
        } else {
            gamepad_prev_down[g] = [_]bool{false} ** MAX_GAMEPAD_BUTTONS;
        }
    }
}

// ── Event handling ────────────────────────────────────────

/// Call from the sokol event callback to feed input state.
pub fn handleEvent(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            // Intercept controller-B/BACK so it doesn't trigger an app quit.
            // When interception is enabled we drop the key entirely (do not
            // record it) so neither sokol nor game code treats it as a
            // window-close. See `shouldConsumeBack` for the sokol-level
            // limitation this works around.
            if (shouldConsumeBack(ki)) return;
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = true;
                // Only record the down-*edge* on a fresh press, not on OS
                // auto-repeat. sokol re-sends KEY_DOWN with `key_repeat == true`
                // while a key is held; `keys_pressed` is the edge array (cleared
                // each frame by newFrame()) and must be true exactly once per
                // physical press to match raylib's `IsKeyPressed` semantics.
                // `keys_down` (held state) is still set on every event.
                if (!ev.*.key_repeat) keys_pressed[k] = true;
            }
        },
        .KEY_UP => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            // Symmetric with KEY_DOWN: if we swallow the press, we must also
            // swallow the release. Otherwise BACK/B records a `keys_released`
            // with no matching press, producing a spurious release event.
            if (shouldConsumeBack(ki)) return;
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = false;
                keys_released[k] = true;
            }
        },
        .MOUSE_MOVE => {
            mouse_x = ev.*.mouse_x;
            mouse_y = ev.*.mouse_y;
        },
        .MOUSE_DOWN => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = true;
                mouse_buttons_pressed[b] = true;
            }
        },
        .MOUSE_UP => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = false;
                mouse_buttons_released[b] = true;
            }
        },
        .MOUSE_SCROLL => {
            mouse_wheel = ev.*.scroll_y;
        },
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            touch_count = @intCast(ev.*.num_touches);
            const n: usize = @intCast(ev.*.num_touches);
            // Zig 0.16: chained access like `ev.*.touches[i].field`
            // through a `[*c]` C pointer fails to resolve the field.
            // Copy the touches array to a local first, then index it.
            const touches: [8]sapp.Touchpoint = ev[0].touches;
            for (0..n) |i| {
                if (i >= MAX_TOUCHES) break;
                touch_xs[i] = touches[i].pos_x;
                touch_ys[i] = touches[i].pos_y;
                touch_ids[i] = @intCast(touches[i].identifier);
            }
            if (ev.*.type == .TOUCHES_ENDED or ev.*.type == .TOUCHES_CANCELLED) {
                touch_count = 0;
            }
        },
        else => {},
    }
}

/// Re-export Event type for consumers that need it (e.g., GUI adapters).
pub const Event = sapp.Event;

/// Sokol Android backend adapter for labelle-core's backend-agnostic JNI seam
/// (labelle-core#310, Stage 3). Exposes `backendContext()`, which the generated
/// sokol-Android `sokol_main()` registers with core
/// (`engine.core.registerAndroidBackend(...)`) so core's gamepad source and the
/// engine's immersive mode can reach the running ANativeActivity / InputManager
/// without core/engine linking any sokol symbol directly. See `android.zig`.
// Android-only: the adapter imports `labelle-core` (for `AndroidBackendContext`)
// and references sokol's `androidGetNativeActivity`, neither of which is wired
// into the input module on desktop/wasm. Gate the re-export so `android.zig` is
// only analyzed on Android (where `build.zig` wires core in); on other targets
// it resolves to an empty namespace and is never compiled.
pub const android = if (builtin.target.abi == .android or builtin.target.abi == .androideabi)
    @import("android.zig")
else
    struct {};

/// One-shot guard so we register the Android forwarded-gamepad callback with
/// the sokol fork exactly once, lazily, at the first frame. Registering here
/// (rather than requiring the generated main to call a sokol-specific init)
/// keeps the engine→backend contract unchanged. Idempotent: the fork just
/// stores the latest pointer.
var android_gp_registered: bool = false;

/// Clear per-frame state (call at start of each frame).
pub fn newFrame() void {
    if (comptime agp.is_android) {
        if (!android_gp_registered) {
            initAndroidGamepad();
            android_gp_registered = true;
        }
    }

    keys_pressed = [_]bool{false} ** 512;
    keys_released = [_]bool{false} ** 512;
    mouse_buttons_pressed = [_]bool{false} ** 3;
    mouse_buttons_released = [_]bool{false} ** 3;
    mouse_wheel = 0;

    // Snapshot the gamepad button state at the frame boundary. Queries made
    // during this frame compare the (continuously-updated) live state against
    // this snapshot to derive `isGamepadButtonPressed`'s rising edge. Keyboard
    // and mouse edges are event-driven (set in `handleEvent`); GameController
    // has no event pipeline here, so the gamepad edge is sampled instead.
    snapshotGamepadButtons();
}

// ── Tests (pure back-key policy; no sokol calls) ──────────────────────────

const std = @import("std");

test "isBackKey matches Android AKEYCODE_BACK only" {
    try std.testing.expect(isBackKey(0x04)); // AKEYCODE_BACK / controller B
    try std.testing.expect(!isBackKey(256)); // ESCAPE — game-level quit, not guarded
    try std.testing.expect(!isBackKey(65)); // 'A'
}

test "shouldConsumeBack honors the consume_back flag" {
    const saved = consume_back;
    defer consume_back = saved;

    consume_back = true;
    try std.testing.expect(shouldConsumeBack(0x04));
    try std.testing.expect(!shouldConsumeBack(65));

    consume_back = false;
    try std.testing.expect(!shouldConsumeBack(0x04));
}

// Regression lock for labelle-assembler#263: a KEY_DOWN carrying
// `key_repeat == true` (OS auto-repeat) must NOT set the down-*edge*
// (`keys_pressed` / isKeyPressed), while still tracking held state
// (`keys_down` / isKeyDown). isKeyPressed must be true exactly once per
// physical press, matching raylib's `IsKeyPressed` semantics.
test "key_repeat does not re-trigger the isKeyPressed edge" {
    // A representative in-range keycode (must be < 512 and not the back key).
    const key: usize = 65; // 'A'

    // Reset the module-global state this test touches.
    keys_down = [_]bool{false} ** 512;
    keys_pressed = [_]bool{false} ** 512;
    defer {
        keys_down = [_]bool{false} ** 512;
        keys_pressed = [_]bool{false} ** 512;
    }

    var ev = std.mem.zeroes(sapp.Event);
    ev.key_code = @enumFromInt(@as(i32, @intCast(key)));

    // Fresh press: sets both held state and the down-edge.
    ev.type = .KEY_DOWN;
    ev.key_repeat = false;
    handleEvent(&ev);
    try std.testing.expect(isKeyDown(key));
    try std.testing.expect(isKeyPressed(key));

    // Model the frame boundary: newFrame() clears the edge array (but pumps
    // the gamepad source, so clear the edge directly to keep the test pure).
    keys_pressed = [_]bool{false} ** 512;
    try std.testing.expect(isKeyDown(key));
    try std.testing.expect(!isKeyPressed(key));

    // OS auto-repeat while held: still down, but NO new edge.
    ev.key_repeat = true;
    handleEvent(&ev);
    try std.testing.expect(isKeyDown(key));
    try std.testing.expect(!isKeyPressed(key));
}
