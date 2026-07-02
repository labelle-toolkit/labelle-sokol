// Playing state script — moves the player with arrow keys.
// Numeric prefix 01_ controls execution order (runs first).

const std = @import("std");

pub fn tick(game: anytype, dt: f32) void {
    const speed: f32 = 200.0;

    // Find player entity and move it
    const Player = @import("../../components/player.zig").Player;
    var view = game.ecs_backend.view(.{Player}, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        // Build a direction vector from input, then normalize so
        // diagonal movement isn't ~1.41x faster than axis-aligned.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (game.isKeyDown(.right)) dx += 1;
        if (game.isKeyDown(.left)) dx -= 1;
        if (game.isKeyDown(.down)) dy += 1;
        if (game.isKeyDown(.up)) dy -= 1;

        const mag = std.math.sqrt(dx * dx + dy * dy);
        if (mag > 0) {
            dx /= mag;
            dy /= mag;
        }

        var pos = game.getPosition(entity);
        pos.x += dx * speed * dt;
        pos.y += dy * speed * dt;
        game.setPosition(entity, pos);
    }
}
