//! Gamepad demo HUD — drawn every frame with Dear ImGui.
//!
//! Backend-agnostic: the HUD reaches the full cimgui API through
//! `@import("gui_backend").ig`, which the assembler resolves to whichever
//! imgui bridge the project's backend selects (sokol-imgui on Android via
//! `backend = .sokol`, the rlImGui bridge on raylib desktop). The script
//! itself is identical across backends — this is a verbatim copy of the
//! raylib `examples/gamepad` HUD, recompiled against the sokol bridge.
//!
//! Exercises the engine input-mixin gamepad forwarders:
//!   - `game.isGamepadAvailable(id)`        — live connect / disconnect
//!   - `game.isGamepadButtonDown(id, btn)`  — held buttons (highlight)
//!   - `game.isGamepadButtonPressed(id, btn)` — press-edge (one frame)
//!   - `game.getGamepadAxisValue(id, axis)` — sticks + triggers
//!
//! On Android the availability/button/axis state is driven by the patched
//! sokol fork's AInputEvent gamepad forwarding + the #248 JNI detection +
//! `android_gamepad_state.zig`, so a controller paired to the device feeds
//! the same forwarders the desktop demo polls.
//!
//! Device names / type hints come from the engine `gamepad_connected`
//! event, captured in `connected_pads.zig` and read here via a shared
//! registry — polling alone can't surface the device name.
//!
//! The backend tracks at most 4 gamepad slots (MAX_GAMEPADS).

const std = @import("std");
const ig = @import("gui_backend").ig;
const pads = @import("connected_pads.zig");

const MAX_GAMEPADS: u32 = 4;

// Engine `GamepadButton` enum values (input_types.zig). Spelled out locally
// so the script doesn't need to import the engine module directly — the
// `game.isGamepadButtonDown` forwarder takes the engine enum, which the
// generated `game` module re-exports, but using the typed accessor below
// keeps this file self-contained and readable.
const Btn = enum(c_int) {
    left_face_up = 1,
    left_face_right = 2,
    left_face_down = 3,
    left_face_left = 4,
    right_face_up = 5,
    right_face_right = 6,
    right_face_down = 7,
    right_face_left = 8,
    left_trigger_1 = 9,
    left_trigger_2 = 10,
    right_trigger_1 = 11,
    right_trigger_2 = 12,
    middle_left = 13,
    middle = 14,
    middle_right = 15,
    left_thumb = 16,
    right_thumb = 17,
};

const Axis = enum(c_int) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

const ACTIVE = ig.ImVec4{ .x = 0.30, .y = 0.95, .z = 0.45, .w = 1.0 }; // green — pressed
const IDLE = ig.ImVec4{ .x = 0.45, .y = 0.45, .z = 0.50, .w = 1.0 }; // grey — released

fn down(game: anytype, id: u32, b: Btn) bool {
    return game.isGamepadButtonDown(id, @enumFromInt(@intFromEnum(b)));
}

fn axis(game: anytype, id: u32, a: Axis) f32 {
    return game.getGamepadAxisValue(id, @enumFromInt(@intFromEnum(a)));
}

/// One labelled button cell, coloured by its current pressed state.
fn buttonCell(game: anytype, id: u32, b: Btn, comptime text: [*:0]const u8) void {
    ig.igTextColored(if (down(game, id, b)) ACTIVE else IDLE, text);
}

pub fn drawGui(game: anytype) void {
    _ = ig.igBegin("Gamepad Demo", null, 0);
    defer ig.igEnd();

    ig.igTextUnformatted("LaBelle gamepad input demo");
    ig.igTextDisabled("polls isGamepad* forwarders every frame (raylib, up to 4 pads)");
    ig.igSeparator();

    // Enumerate connected pads by their actual device ids. On Android the
    // platform device id is sparse and not 0-based (e.g. a single Xbox pad is
    // id 9), so a 0..MAX_GAMEPADS slot scan would miss it (labelle-engine#261).
    // The connected-pad registry holds the real ids fed by the engine
    // `gamepad_connected` event; iterate those and poll each by its id.
    var ids: [MAX_GAMEPADS]u32 = undefined;
    const connected = pads.knownIds(ids[0..]);

    // ── Empty state ────────────────────────────────────────────────────
    if (connected == 0) {
        ig.igSpacing();
        ig.igTextColored(
            .{ .x = 1.0, .y = 0.8, .z = 0.3, .w = 1.0 },
            "No gamepad connected - plug one in",
        );
        ig.igSpacing();
        ig.igTextUnformatted("Connect a controller and it will appear here live.");
        return;
    }

    // ── Per-pad panels ─────────────────────────────────────────────────
    for (ids[0..connected]) |id| {
        if (!game.isGamepadAvailable(id)) continue;
        drawPad(game, id);
    }
}

fn drawPad(game: anytype, id: u32) void {
    var hdr_buf: [128]u8 = undefined;
    const name = pads.nameFor(id);
    const type_hint = pads.typeHintFor(id);
    const header = std.fmt.bufPrintZ(
        &hdr_buf,
        "Pad {d}: {s} [{s}]##pad{d}",
        .{ id, name, type_hint, id },
    ) catch "Pad##?";

    if (!ig.igCollapsingHeader(header, ig.ImGuiTreeNodeFlags_DefaultOpen)) return;

    ig.igPushIDInt(@intCast(id));
    defer ig.igPopID();

    // ── Face buttons (right cluster: A/B/X/Y on most pads) ──────────────
    ig.igTextUnformatted("Face:");
    ig.igSameLine();
    buttonCell(game, id, .right_face_down, "[A]");
    ig.igSameLine();
    buttonCell(game, id, .right_face_right, "[B]");
    ig.igSameLine();
    buttonCell(game, id, .right_face_left, "[X]");
    ig.igSameLine();
    buttonCell(game, id, .right_face_up, "[Y]");

    // ── D-pad (left cluster) ────────────────────────────────────────────
    ig.igTextUnformatted("DPad:");
    ig.igSameLine();
    buttonCell(game, id, .left_face_up, "[Up]");
    ig.igSameLine();
    buttonCell(game, id, .left_face_down, "[Dn]");
    ig.igSameLine();
    buttonCell(game, id, .left_face_left, "[Lt]");
    ig.igSameLine();
    buttonCell(game, id, .left_face_right, "[Rt]");

    // ── Shoulders + triggers (digital) + middle / thumbs ───────────────
    ig.igTextUnformatted("Bump:");
    ig.igSameLine();
    buttonCell(game, id, .left_trigger_1, "[LB]");
    ig.igSameLine();
    buttonCell(game, id, .right_trigger_1, "[RB]");
    ig.igSameLine();
    buttonCell(game, id, .left_thumb, "[L3]");
    ig.igSameLine();
    buttonCell(game, id, .right_thumb, "[R3]");
    ig.igSameLine();
    buttonCell(game, id, .middle_left, "[Sel]");
    ig.igSameLine();
    buttonCell(game, id, .middle_right, "[Start]");

    ig.igSpacing();

    // ── Sticks (axis dots as text + bars) ───────────────────────────────
    const lx = axis(game, id, .left_x);
    const ly = axis(game, id, .left_y);
    const rx = axis(game, id, .right_x);
    const ry = axis(game, id, .right_y);
    ig.igText("Left stick:  (% .2f, % .2f)", lx, ly);
    stickBar(lx, ly);
    ig.igText("Right stick: (% .2f, % .2f)", rx, ry);
    stickBar(rx, ry);

    ig.igSpacing();

    // ── Triggers (analog -1..1 → 0..1 fill) ─────────────────────────────
    const lt = (axis(game, id, .left_trigger) + 1.0) * 0.5;
    const rt = (axis(game, id, .right_trigger) + 1.0) * 0.5;
    ig.igTextUnformatted("LT");
    ig.igSameLine();
    ig.igProgressBar(lt, .{ .x = 200, .y = 0 }, null);
    ig.igTextUnformatted("RT");
    ig.igSameLine();
    ig.igProgressBar(rt, .{ .x = 200, .y = 0 }, null);

    ig.igSpacing();
    ig.igSeparator();
}

/// Render an axis pair as two normalised 0..1 bars so the stick position is
/// visible without a custom draw list. Maps -1..1 → 0..1.
fn stickBar(x: f32, y: f32) void {
    ig.igTextUnformatted("  X");
    ig.igSameLine();
    ig.igProgressBar((x + 1.0) * 0.5, .{ .x = 160, .y = 0 }, null);
    ig.igSameLine();
    ig.igTextUnformatted("Y");
    ig.igSameLine();
    ig.igProgressBar((y + 1.0) * 0.5, .{ .x = 160, .y = 0 }, null);
}
