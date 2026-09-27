//! Open the real Android sink with silent PCM so acceptance can verify the
//! AAudio callback without making noise on the test device.
const audio = @import("backend_audio");

pub fn setup(_: anytype) void {
    var samples = [_]i16{0} ** 960;
    const sound = audio.uploadSound(.{
        .samples = &samples,
        .channels = 2,
        .sample_rate = 48000,
    }) catch return;
    audio.playSound(sound.slot_index);
}

const std = @import("std");
const engine = @import("labelle-engine");
const window = @import("backend_window");
const android = @import("android");
extern "c" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
var elapsed: f32 = 0;
var reported = false;
var captured = false;

// Released assembler 0.116's callback loop does not poll screenshot requests
// or route Zig stderr to logcat. This fixture observes the shared runtime and
// drives the engine's capture request through its real backend readback.
pub fn tick(_: anytype, dt: f32) void {
    elapsed += dt;
    if (!reported and android.aaudio.framesMixed() > 0) {
        reported = true;
        _ = __android_log_write(4, "ProviderProbe", "android: AAudio started (shared callback frames > 0)");
        var buf: [1024]u8 = undefined;
        const surface = std.fmt.bufPrintZ(&buf, "sokol surface init: {d}x{d}", .{ window.width(), window.height() }) catch unreachable;
        _ = __android_log_write(4, "ProviderProbe", surface);
        for ([_][:0]const u8{ "LABELLE_SCENE", "LABELLE_SCREENSHOT_PATH", "LABELLE_SCREENSHOT_AFTER_SEC" }) |name| {
            if (getenv(name)) |value| {
                const line = std.fmt.bufPrintZ(&buf, "android: {s}={s} (observed environment)", .{ name, std.mem.span(value) }) catch continue;
                _ = __android_log_write(4, "ProviderProbe", line);
            }
        }
    }
    if (!captured) {
        if (engine.requestedScreenshot()) |request| {
            if (elapsed >= request.after_sec) {
                window.takeScreenshot(request.path);
                captured = true;
            }
        }
    }
}
