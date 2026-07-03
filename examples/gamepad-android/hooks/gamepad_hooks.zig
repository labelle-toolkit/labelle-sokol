//! Engine gamepad-event hook → identity registry.
//!
//! Handles two ENGINE-declared events (from labelle-engine's `pub const Events`
//! block — NOT game-defined `events/*.zig`; this demo has no `events/` dir):
//!   - `engine__gamepad_connected`    → record id, name, type hint
//!   - `engine__gamepad_disconnected` → forget the id
//!
//! Handler function names MUST match the `GameEvents` variant names
//! (`engine__gamepad_connected` / `engine__gamepad_disconnected`) — that's the
//! MergeHooks dispatch contract. It is ALSO what wires the events IN: the
//! assembler folds an engine event into the generated `GameEvents` only when a
//! consumer references it, and this hook IS that consumer. That inclusion flips
//! the engine's comptime `gamepad_events_wanted` gate ON (it keys on
//! `@hasField(GameEvents, "engine__gamepad_connected")`), so the backend hotplug
//! queue is drained. Engine builtin events therefore need NO local `events/*.zig`
//! declaration — only custom game events do.
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
