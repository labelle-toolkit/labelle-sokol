const std = @import("std");

pub fn tick(game: anytype, dt: f32) void {
    const speed: f32 = 300.0;

    var dx: f32 = 0;
    var dy: f32 = 0;
    if (game.isKeyDown(.d)) dx += 1;
    if (game.isKeyDown(.a)) dx -= 1;
    if (game.isKeyDown(.w)) dy += 1;
    if (game.isKeyDown(.s)) dy -= 1;

    const mag = std.math.sqrt(dx * dx + dy * dy);
    if (mag == 0) return;
    dx /= mag;
    dy /= mag;

    const cam = game.getCamera();
    cam.pan(dx * speed * dt, dy * speed * dt);
}
