//! Engine gamepad-event hook → identity registry.
//!
//! Handles the two engine events the demo declares in `events/`:
//!   - `engine__gamepad_connected`    → record id, name, type hint
//!   - `engine__gamepad_disconnected` → forget the id
//!
//! Handler function names MUST match the `GameEvents` variant names
//! (`engine__gamepad_connected` / `engine__gamepad_disconnected`) — that's
//! the MergeHooks dispatch contract. Declaring these variants (via the
//! `events/*.zig` files) is also what flips the engine's comptime
//! `gamepad_events_wanted` gate ON, so the backend hotplug queue is drained.
//!
//! The payload is taken as `anytype` so this file needs no engine import:
//! `engine__gamepad_connected` carries `.id` + `nameSlice()` + `.type_hint`,
//! `engine__gamepad_disconnected` carries `.id`.

const pads = @import("../scripts/connected_pads.zig");

pub const GamepadHooks = struct {
    pub fn engine__gamepad_connected(_: *GamepadHooks, payload: anytype) void {
        pads.record(payload.id, payload.nameSlice(), @tagName(payload.type_hint));
    }

    pub fn engine__gamepad_disconnected(_: *GamepadHooks, payload: anytype) void {
        pads.forget(payload.id);
    }
};
