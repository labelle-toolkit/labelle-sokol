//! NativeActivity probe without sokol's onDestroy exit(0), so activity
//! recreation preserves process state and tests the actual shared JNI driver.
const std = @import("std");
const android = @import("labelle_android");
extern "c" fn __android_log_write(c_int, [*:0]const u8, [*:0]const u8) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn ANativeActivity_finish(?*anyopaque) void;
extern "c" fn getpid() c_int;
var launches: usize = 0;
export fn ANativeActivity_onCreate(activity: ?*anyopaque, _: ?*anyopaque, _: usize) void {
    android.launch_intent.apply(activity);
    launches += 1;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "pid={d} launch={d} scene={s} screenshot={s} after={s} debuggable={}", .{
        getpid(), launches, value("LABELLE_SCENE"), value("LABELLE_SCREENSHOT_PATH"), value("LABELLE_SCREENSHOT_AFTER_SEC"), android.debuggable.isDebuggable(activity),
    }) catch unreachable;
    _ = __android_log_write(4, "SERVICE_ACCEPTANCE", text);
    ANativeActivity_finish(activity);
}
fn value(name: [*:0]const u8) []const u8 {
    return if (getenv(name)) |v| std.mem.span(v) else "<unset>";
}
