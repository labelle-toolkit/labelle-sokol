const std = @import("std");
extern "c" fn __android_log_write(c_int, [*:0]const u8, [*:0]const u8) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
var frames: usize = 0;
pub fn tick(game: anytype, _: f32) void {
    frames += 1;
    if (frames != 30) return;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "scene={s} env_scene={s} screenshot={s} after={s}", .{
        game.getCurrentSceneName() orelse "<none>",
        if (getenv("LABELLE_SCENE")) |v| std.mem.span(v) else "<unset>",
        if (getenv("LABELLE_SCREENSHOT_PATH")) |v| std.mem.span(v) else "<unset>",
        if (getenv("LABELLE_SCREENSHOT_AFTER_SEC")) |v| std.mem.span(v) else "<unset>",
    }) catch unreachable;
    _ = __android_log_write(4, "INTENT_ACCEPTANCE", text);
}
