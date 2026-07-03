const std = @import("std");

const frames = [_][]const u8{
    "jump_0001.png", "jump_0002.png", "jump_0003.png",
    "jump_0004.png", "jump_0005.png", "jump_0006.png",
    "jump_0007.png", "jump_0008.png", "jump_0009.png",
};
const frame_duration: f32 = 0.1;
const total_duration: f32 = frame_duration * @as(f32, @floatFromInt(frames.len));

var elapsed: f32 = 0;

pub fn tick(game: anytype, dt: f32) void {
    // `@mod` on f32 handles an arbitrarily large `dt` — e.g. a long
    // first-frame stall or wakeup after Android backgrounding — without
    // letting `elapsed / frame_duration` walk off the end on the next
    // iteration. But `@mod` alone isn't enough: when `elapsed` is the
    // largest f32 strictly below `total_duration`, the division can
    // round up to exactly `frames.len` in f32, so we also clamp the
    // final index.
    elapsed = @mod(elapsed + dt, total_duration);
    const raw_idx: usize = @intFromFloat(elapsed / frame_duration);
    const idx: usize = @min(raw_idx, frames.len - 1);

    const Sprite = @TypeOf(game.*).SpriteComp;

    // Re-query the animated entity each frame rather than caching its id in a
    // file-level global: a cached id would dangle — or, worse, point at a
    // DIFFERENT reused entity — across a scene reload or a `running`-state
    // re-entry. The frames all keep the `jump_` prefix, so this re-finds the
    // same entity every tick. The scan is trivial for a demo; a production game
    // would tag the entity with a dedicated animation component instead.
    var view = game.ecs_backend.view(.{Sprite}, .{});
    defer view.deinit();
    while (view.next()) |entity| {
        const sprite = game.ecs_backend.getComponent(entity, Sprite).?;
        if (std.mem.startsWith(u8, sprite.sprite_name, "jump_")) {
            sprite.sprite_name = frames[idx];
            break;
        }
    }
}
