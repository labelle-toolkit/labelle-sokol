//! Sokol Android backend adapter for labelle-core's backend-agnostic JNI seam
//! (labelle-core#310, Stage 3).
//!
//! ## Why this exists
//!
//! Core's Android gamepad source (`gamepad_source/android.zig`) and the
//! engine's `enableImmersiveMode()` used to reach the running
//! `ANativeActivity` and the InputManager JNI glue through fixed `extern`
//! symbols that **sokol** provided at link time (`sapp_android_*`,
//! `labelle_android_gamepad_*`). That forced a sokol-shaped dependency into
//! core/engine: every other backend had to ship fake stubs just so core would
//! link on Android.
//!
//! Stage 1 replaced those fixed externs with a runtime `AndroidBackendContext`
//! vtable that the active backend **registers at startup** (see
//! `labelle-core/src/android_backend.zig`). Core's gamepad source and the
//! engine's immersive call now route through whatever context was registered —
//! and do **nothing** if none was. So the sokol backend MUST register one, or
//! sokol-Android regresses (no immersive mode, no gamepad detection).
//!
//! This module is that sokol-side adapter. It builds the
//! `AndroidBackendContext` literal from sokol's own symbols:
//!
//!   * `get_native_activity` → a `callconv(.c)` wrapper around sokol's
//!     `sapp_android_get_native_activity()` (the sokol fork's accessor). The
//!     sokol symbol returns `?*const anyopaque`; the seam wants `?*anyopaque`,
//!     so the wrapper `@constCast`s the result.
//!   * `gamepad_init` / `gamepad_shutdown` → the backend-agnostic JNI glue in
//!     `android_gamepad_jni.c` (`labelle_android_gamepad_init/_shutdown`),
//!     declared `extern` here. That C TU is compiled into this (the
//!     `backend_input`) module's graph by `build.zig` and is a no-op off
//!     Android.
//!
//! ## Wiring
//!
//! The generated sokol-Android `sokol_main()` calls
//! `engine.core.registerAndroidBackend(@import("backend_input").android.backendContext())`
//! ONCE at startup, before `enableImmersiveMode()` and before the gamepad
//! source initializes (assembler codegen, `lifecycle/callback.zig`).
//!
//! ## Gating
//!
//! Everything here is gated behind `is_android`. On desktop/wasm/ios this
//! module references no sokol-Android symbol; `backendContext()` is intended
//! to be emitted only by the Android codegen path, so non-Android backends
//! never construct it. The C glue's `labelle_android_gamepad_*` symbols exist
//! as no-ops on every target (see `android_gamepad_jni.c`), so even if the
//! literal were referenced off-device it would link.

const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const core = @import("labelle-core");

/// True on Android (arm64/x86_64 `.android`, arm/x86 `.androideabi`). Mirrors
/// `android_gamepad_state.is_android` and `window.zig`'s Android check.
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// JNI detection glue (android_gamepad_jni.c). The C signatures are:
//   void labelle_android_gamepad_init(const void *activity_ptr);
//   void labelle_android_gamepad_shutdown(void);
// They are defined as no-ops off Android, so declaring them unconditionally is
// safe — but we only ever wire them into a registered context on Android.
// `extern "c"` already implies the C calling convention — no `callconv(.c)`.
extern "c" fn labelle_android_gamepad_init(activity: ?*anyopaque) void;
extern "c" fn labelle_android_gamepad_shutdown() void;

/// `callconv(.c)` adapter for the seam's `get_native_activity`. sokol's
/// `sapp_android_get_native_activity()` returns `?*const anyopaque`; the seam's
/// vtable field is `?*anyopaque`, so `@constCast` away the constness. Core only
/// passes this pointer straight back into `gamepad_init` (which re-`const`s it
/// on the C side), so dropping `const` here is sound. Returns `null` before
/// sokol has a running activity (core treats `null` as "nothing to bind").
fn getNativeActivity() callconv(.c) ?*anyopaque {
    const act = sapp.androidGetNativeActivity();
    return @constCast(act);
}

/// Build the `AndroidBackendContext` the sokol backend hands to core. Intended
/// to be referenced only from the generated sokol-Android `sokol_main()` (via
/// `@import("backend_input").android.backendContext()`); core then routes its
/// Android JNI calls (immersive-mode activity lookup + gamepad enumeration)
/// through these pointers. See the module header for the lifecycle contract.
pub fn backendContext() core.AndroidBackendContext {
    return .{
        .get_native_activity = &getNativeActivity,
        .gamepad_init = &labelle_android_gamepad_init,
        .gamepad_shutdown = &labelle_android_gamepad_shutdown,
    };
}
