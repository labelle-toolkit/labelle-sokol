const std = @import("std");

const frames = [_][]const u8{
    "jump_0001.png", "jump_0002.png", "jump_0003.png",
    "jump_0004.png", "jump_0005.png", "jump_0006.png",
    "jump_0007.png", "jump_0008.png", "jump_0009.png",
};
const frame_duration: f32 = 0.1;
const total_duration: f32 = frame_duration * @as(f32, @floatFromInt(frames.len));

var elapsed: f32 = 0;
// Cached on first tick — avoids rescanning every entity + doing a string
// prefix check per frame. A production game would tag this with a
// dedicated animation component instead.
var anim_entity: ?u32 = null;

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

    if (anim_entity == null) {
        var view = game.ecs_backend.view(.{Sprite}, .{});
        defer view.deinit();
        while (view.next()) |entity| {
            const sprite = game.ecs_backend.getComponent(entity, Sprite).?;
            if (std.mem.startsWith(u8, sprite.sprite_name, "jump_")) {
                anim_entity = @intCast(entity);
                break;
            }
        }
    }

    if (anim_entity) |entity_id| {
        if (game.ecs_backend.getComponent(@intCast(entity_id), Sprite)) |sprite| {
            sprite.sprite_name = frames[idx];
        }
    }
}
