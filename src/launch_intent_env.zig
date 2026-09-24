//! Android launch-intent `LABELLE_*` extras → process env vars — the DRIVER
//! (labelle-sokol#25).
//!
//! The engine reads its `labelle run` options from environment variables at
//! startup (`LABELLE_SCENE`, `LABELLE_SCREENSHOT_PATH` /
//! `LABELLE_SCREENSHOT_AFTER_SEC`, `LABELLE_PROFILE`). An Android app the system
//! starts has no such env, so the cli (labelle-cli#397) passes them as
//! launch-intent string extras (`am start … --es LABELLE_SCENE X`) and this
//! copies the allow-listed ones back into the environment. The engine, the
//! assembler and games stay unchanged — they keep reading `getenv`.
//!
//! Three pieces, the same split labelle-bgfx uses (labelle-bgfx#139):
//!   * `android_intent_env.zig` — the PURE half: the allow-list and the per-key
//!     decision (set / unset / keep, the debuggable gate). Host-tested.
//!   * `android_intent_extras.c` — the JNI half: `getIntent().getStringExtra`
//!     and `getApplicationInfo().flags & FLAG_DEBUGGABLE`.
//!   * this file — glue: libc `setenv`/`unsetenv` and the call order.
//!
//! ## Where it runs
//!
//! `apply()` is called from the TOP of the generated `sokol_main()`
//! (`templates/mobile.txt`). sokol's `ANativeActivity_onCreate` calls
//! `sokol_main()` on the Android UI thread with the activity pointer already
//! stored (so `sapp_android_get_native_activity()` is valid there), BEFORE it
//! spawns the render thread that later runs the `init` callback — which is
//! where `AssembledGame.init` and the engine's first `getenv` of these keys
//! happen. So the env is complete before anything reads it, and `setenv` runs
//! before any native thread that reads the environment exists.

const std = @import("std");
const builtin = @import("builtin");
const intent_env = @import("android_intent_env.zig");

/// True on Android (arm64/x86_64 `.android`, arm/x86 `.androideabi`). Mirrors
/// `android.zig`'s check.
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// `android_intent_extras.c` — only referenced on Android, where build.zig
// compiles the C TU into this module.
extern "c" fn labelle_sokol_read_intent_extras(
    activity: ?*const anyopaque,
    keys: [*]const [*:0]const u8,
    count: c_int,
    buf: [*]u8,
    buf_cap: usize,
    lens: [*]c_int,
) c_int;
extern "c" fn labelle_sokol_app_is_debuggable(activity: ?*const anyopaque) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Survives activity relaunches in a cached process, so a plain launch can
/// clear what a previous `--scene` launch set (see `intent_env.action`). sokol
/// `exit(0)`s on activity destroy today, which resets this anyway; the state
/// keeps the behaviour identical to bgfx if that ever changes.
var state: intent_env.State = .{};
/// Backing store for the extras' values. `setenv` copies them, so it is only
/// needed for the duration of `apply`.
var buf: [4096]u8 = undefined;

const LibcEnv = struct {
    activity: ?*const anyopaque,

    pub fn get(_: LibcEnv, name: [:0]const u8) ?[:0]const u8 {
        return if (getenv(name.ptr)) |v| std.mem.span(v) else null;
    }
    pub fn set(_: LibcEnv, name: [:0]const u8, value: [:0]const u8) bool {
        return setenv(name.ptr, value.ptr, 1) == 0;
    }
    pub fn unset(_: LibcEnv, name: [:0]const u8) void {
        _ = unsetenv(name.ptr);
    }
    pub fn debuggable(self: LibcEnv) bool {
        return labelle_sokol_app_is_debuggable(self.activity) != 0;
    }
};

/// Copy the launch intent's allow-listed `LABELLE_*` string extras into the
/// process environment. Call ONCE from `sokol_main()`, before anything reads
/// these vars. Comptime no-op off Android. A launch with no extras (the
/// launcher icon) or any JNI failure changes nothing, except clearing values a
/// previous intent set.
pub fn apply() void {
    if (comptime !is_android) return;
    const activity = @import("sokol").app.androidGetNativeActivity() orelse return;

    var names: [intent_env.keys.len][*:0]const u8 = undefined;
    for (intent_env.keys, 0..) |k, i| names[i] = k.name.ptr;
    var lens: [intent_env.keys.len]c_int = undefined;
    if (labelle_sokol_read_intent_extras(activity, &names, names.len, &buf, buf.len, &lens) == 0) {
        std.log.warn("sokol: could not read the launch intent; LABELLE_* extras ignored", .{});
        // Still revert what an earlier launch's intent set in this process
        // (all-absent extras only ever revert/keep, never set).
        intent_env.apply(&state, @splat(null), LibcEnv{ .activity = activity });
        return;
    }
    var extras: [intent_env.keys.len]?[:0]const u8 = @splat(null);
    var off: usize = 0;
    for (lens, 0..) |len, i| {
        if (len == -2) std.log.warn("sokol: intent extra {s} too long; ignored", .{intent_env.keys[i].name});
        if (len < 0) continue;
        const n: usize = @intCast(len);
        extras[i] = buf[off .. off + n :0];
        off += n + 1;
    }
    intent_env.apply(&state, extras, LibcEnv{ .activity = activity });
}

test {
    // The pure allow-list / decision tests.
    _ = intent_env;
}
