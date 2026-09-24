//! Android launch-intent `LABELLE_*` extras → process env vars
//! (labelle-sokol#25).
//!
//! ## Why this exists
//!
//! The engine reads its `labelle run` options from environment variables at
//! startup: `LABELLE_SCENE` (`engine.requestedScene()`), the
//! `LABELLE_SCREENSHOT_PATH` / `LABELLE_SCREENSHOT_AFTER_SEC` pair
//! (`ScreenshotRequest`) and `LABELLE_PROFILE`. On desktop the cli puts them in
//! the child's env. An Android app the system starts has no such env, so
//! `labelle run --platform=android --scene=X` used to boot the default scene.
//!
//! The cli half (labelle-cli#397) passes those options as launch-intent string
//! extras instead: `am start -n <pkg>/android.app.NativeActivity --es
//! LABELLE_SCENE X …`. This module is the device half: at startup it reads the
//! launching activity's Intent over JNI and `setenv`s each extra whose key is
//! in the ALLOW-LIST below. The engine, the assembler and games stay unchanged —
//! they keep reading `getenv`.
//!
//! Only the allow-listed keys are ever copied: an arbitrary extra (`PATH`,
//! `LD_PRELOAD`, …) never reaches the environment. The list and its behaviour
//! are kept identical to labelle-bgfx's (labelle-bgfx#139).
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
//!
//! ## Layout
//!
//! The JNI walk lives in C (`launch_intent_env_jni.c`, compiled into the input
//! module on Android only) for the same reason as `android_gamepad_jni.c`:
//! `<jni.h>` already declares the JNI vtables. The C side is handed the key
//! list and reports each present extra back through `onExtra`, which applies the
//! allow-list gate a second time before `setenv`. The pure part — the key list
//! and the gate — is host-testable below.

const std = @import("std");
const builtin = @import("builtin");

/// True on Android (arm64/x86_64 `.android`, arm/x86 `.androideabi`). Mirrors
/// `android.zig`'s check.
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

/// The ONLY intent extras that become env vars. Keep in lockstep with the cli's
/// `--es` keys (labelle-cli#397) and labelle-bgfx's list (labelle-bgfx#139).
pub const allowed_keys = [_][:0]const u8{
    "LABELLE_SCENE",
    "LABELLE_SCREENSHOT_PATH",
    "LABELLE_SCREENSHOT_AFTER_SEC",
    "LABELLE_PROFILE",
};

/// C-string view of `allowed_keys`, the array handed to the JNI walk.
const allowed_keys_c: [allowed_keys.len][*:0]const u8 = blk: {
    var out: [allowed_keys.len][*:0]const u8 = undefined;
    for (allowed_keys, 0..) |k, i| out[i] = k.ptr;
    break :blk out;
};

/// Exact, case-sensitive allow-list membership. `LABELLE_SCENEX`,
/// `labelle_scene` and `""` are all rejected.
pub fn isAllowedKey(key: []const u8) bool {
    for (allowed_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// The gate every extra passes through on its way to the environment: an
/// allow-listed key is handed to `sink.set(key, value)` with the value
/// verbatim (an empty value included — the engine's readers already treat an
/// empty var as unset, exactly as on desktop); any other key is dropped.
/// Returns whether the extra was forwarded. `sink` is anything with
/// `fn set(self, key: [*:0]const u8, value: [*:0]const u8) void`.
pub fn forwardExtra(sink: anytype, key: [*:0]const u8, value: [*:0]const u8) bool {
    if (!isAllowedKey(std.mem.span(key))) return false;
    sink.set(key, value);
    return true;
}

/// Production sink: libc `setenv(key, value, 1)`. libc directly because Zig
/// 0.16 has no `std.posix` env mutation, and the engine reads with libc
/// `getenv` — the same environ block.
const LibcEnvSink = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

    fn set(_: LibcEnvSink, key: [*:0]const u8, value: [*:0]const u8) void {
        _ = setenv(key, value, 1);
    }
};

/// Called by the C walk for each allow-listed key the intent carries as a
/// string extra. `value` is only valid for the duration of the call; `setenv`
/// copies it.
fn onExtra(_: ?*anyopaque, key: [*:0]const u8, value: [*:0]const u8) callconv(.c) void {
    _ = forwardExtra(LibcEnvSink{}, key, value);
}

const ExtraFn = *const fn (ctx: ?*anyopaque, key: [*:0]const u8, value: [*:0]const u8) callconv(.c) void;

/// `launch_intent_env_jni.c`. Returns the number of extras reported, or -1 when
/// the Intent could not be read (no activity/VM, JNI failure). Only referenced
/// on Android, where the C TU is compiled in.
extern "c" fn labelle_sokol_read_intent_extras(
    activity: ?*const anyopaque,
    keys: [*]const [*:0]const u8,
    key_count: usize,
    on_extra: ExtraFn,
    ctx: ?*anyopaque,
) c_int;

/// Copy the launching Intent's allow-listed `LABELLE_*` string extras into the
/// process environment. Call ONCE from `sokol_main()`, before anything reads
/// these vars. Comptime no-op off Android. A launch with no extras (the
/// launcher icon) sets nothing, and every failure is silent: the game then
/// boots exactly as it did before this existed.
pub fn apply() void {
    if (comptime !is_android) return;
    const activity = @import("sokol").app.androidGetNativeActivity() orelse return;
    const n = labelle_sokol_read_intent_extras(activity, &allowed_keys_c, allowed_keys_c.len, &onExtra, null);
    if (n > 0) std.log.info("labelle: applied {d} launch-intent LABELLE_* extra(s) as env vars", .{n});
}

// ── Tests (pure allow-list + gate; no JNI) ───────────────────────────────

/// Records what would have been `setenv`ed.
const RecordingSink = struct {
    keys: [8][]const u8 = undefined,
    values: [8][]const u8 = undefined,
    len: usize = 0,

    fn set(self: *RecordingSink, key: [*:0]const u8, value: [*:0]const u8) void {
        self.keys[self.len] = std.mem.span(key);
        self.values[self.len] = std.mem.span(value);
        self.len += 1;
    }
};

test "allow-list is exactly the four labelle run keys" {
    try std.testing.expectEqual(@as(usize, 4), allowed_keys.len);
    for ([_][]const u8{
        "LABELLE_SCENE",
        "LABELLE_SCREENSHOT_PATH",
        "LABELLE_SCREENSHOT_AFTER_SEC",
        "LABELLE_PROFILE",
    }) |k| try std.testing.expect(isAllowedKey(k));
}

test "keys outside the allow-list are rejected" {
    for ([_][]const u8{
        "",
        "PATH",
        "LD_PRELOAD",
        "LABELLE_",
        "LABELLE_SCENEX",
        "XLABELLE_SCENE",
        "labelle_scene",
        "LABELLE_SCREENSHOT",
        "LABELLE_ANYTHING_ELSE",
    }) |k| try std.testing.expect(!isAllowedKey(k));
}

test "the C key array mirrors the allow-list" {
    for (allowed_keys, allowed_keys_c) |k, c| {
        try std.testing.expectEqualStrings(k, std.mem.span(c));
    }
}

test "forwardExtra sets allow-listed extras verbatim and drops the rest" {
    // A launch intent as `am start` would build it: the cli's keys plus
    // unrelated extras another launcher (or a hostile caller) might add.
    const Extra = struct { key: [:0]const u8, value: [:0]const u8 };
    const intent = [_]Extra{
        .{ .key = "LABELLE_SCENE", .value = "big_colony" },
        .{ .key = "PATH", .value = "/evil" },
        .{ .key = "LABELLE_SCREENSHOT_PATH", .value = "/sdcard/shot.bmp" },
        .{ .key = "labelle_profile", .value = "1" },
        .{ .key = "LABELLE_SCREENSHOT_AFTER_SEC", .value = "2.5" },
        .{ .key = "LABELLE_PROFILE", .value = "" },
    };

    var sink: RecordingSink = .{};
    var forwarded: usize = 0;
    for (intent) |e| {
        if (forwardExtra(&sink, e.key, e.value)) forwarded += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), forwarded);
    try std.testing.expectEqual(@as(usize, 4), sink.len);
    try std.testing.expectEqualStrings("LABELLE_SCENE", sink.keys[0]);
    try std.testing.expectEqualStrings("big_colony", sink.values[0]);
    try std.testing.expectEqualStrings("LABELLE_SCREENSHOT_PATH", sink.keys[1]);
    try std.testing.expectEqualStrings("/sdcard/shot.bmp", sink.values[1]);
    try std.testing.expectEqualStrings("LABELLE_SCREENSHOT_AFTER_SEC", sink.keys[2]);
    try std.testing.expectEqualStrings("2.5", sink.values[2]);
    // Empty values are forwarded as-is (same as an empty desktop env var).
    try std.testing.expectEqualStrings("LABELLE_PROFILE", sink.keys[3]);
    try std.testing.expectEqualStrings("", sink.values[3]);
}
