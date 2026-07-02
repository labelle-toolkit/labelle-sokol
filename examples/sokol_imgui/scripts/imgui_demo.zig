// Sokol + ImGui bridge smoke test.
//
// Opens a Dear ImGui window every frame and renders a few widgets through
// the labelle-imgui adapter. If the sokol_imgui_bridge is wired correctly,
// you should see a draggable window with frame stats and a button. If the
// bridge or its symbol resolution is broken, the build fails to link or
// the window never appears.

const std = @import("std");

var click_count: i32 = 0;
var slider_value: f32 = 0.5;
var frame_counter: u64 = 0;

pub fn drawGui(game: anytype) void {
    const Gui = @TypeOf(game.*).Gui;
    if (!Gui.supportsWidgets()) return;

    if (!Gui.beginWindow("Sokol + ImGui Bridge")) {
        Gui.endWindow();
        return;
    }
    defer Gui.endWindow();

    Gui.label("If you can read this, the bridge is alive.");
    Gui.separator();

    var fps_buf: [64]u8 = undefined;
    Gui.label(std.fmt.bufPrintZ(&fps_buf, "frame: {d}", .{frame_counter}) catch "frame: ?");

    if (Gui.button("Click me")) click_count += 1;
    Gui.sameLine();
    var click_buf: [32]u8 = undefined;
    Gui.label(std.fmt.bufPrintZ(&click_buf, "clicks: {d}", .{click_count}) catch "clicks: ?");

    Gui.spacing();
    _ = Gui.sliderFloat("slider", &slider_value, 0, 1);
}

pub fn tick(_: anytype, _: f32) void {
    frame_counter += 1;
}
