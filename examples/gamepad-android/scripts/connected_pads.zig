//! Connected-pad identity registry.
//!
//! Live button/axis state comes from polling the engine forwarders each
//! frame (see `gamepad_hud.zig`), but polling can't surface the *device
//! name* or *type hint* — those only arrive on the engine `gamepad_connected`
//! event. The hook in `hooks/gamepad_hooks.zig` writes them here on connect
//! and clears them on disconnect; the HUD reads them back via `nameFor` /
//! `typeHintFor`.
//!
//! Process-global fixed array (raylib tracks at most 4 slots). No allocator,
//! no lifecycle — a slot is "known" only between its connect and disconnect
//! events.
//!
//! The engine `gamepad_connected.id` is the platform device id, which is NOT
//! a dense 0..3 slot: on Android it is the raw `InputDevice` id (e.g. 9), well
//! above raylib's 4-slot range. We therefore key entries by the device id and
//! match the HUD's poll-by-slot loop (0..MAX_GAMEPADS) by also exposing a
//! compact slot view, rather than indexing the array with the raw id (which
//! silently dropped any id >= 4 — labelle-engine#261).

const MAX_GAMEPADS: usize = 4;
const NAME_CAP: usize = 64;

const Entry = struct {
    known: bool = false,
    id: u32 = 0,
    name: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    name_len: usize = 0,
    type_hint: [:0]const u8 = "unknown",
};

var entries: [MAX_GAMEPADS]Entry = [_]Entry{.{}} ** MAX_GAMEPADS;

/// Find the entry holding device `id`, or null.
fn findById(id: u32) ?*Entry {
    for (&entries) |*e| {
        if (e.known and e.id == id) return e;
    }
    return null;
}

/// Record a connect: store the device name + type hint for `id`. The id can be
/// any platform device id; it is assigned the first free compact slot.
pub fn record(id: u32, name: []const u8, type_hint: [:0]const u8) void {
    var e = findById(id) orelse blk: {
        for (&entries) |*slot| {
            if (!slot.known) break :blk slot;
        }
        return; // all slots in use
    };
    e.known = true;
    e.id = id;
    // Cap at NAME_CAP-1 so a terminator always fits within the fixed buffer
    // (nameFor returns a sentinel-terminated slice; a name filling all
    // NAME_CAP bytes would leave no room for the NUL → OOB).
    const n = @min(name.len, NAME_CAP - 1);
    @memcpy(e.name[0..n], name[0..n]);
    e.name_len = n;
    e.type_hint = type_hint;
}

/// Forget a disconnected pad.
pub fn forget(id: u32) void {
    if (findById(id)) |e| e.* = .{};
}

/// Best-known device name for `id`. Falls back to a generic label when the
/// pad is live (polling says available) but no connect event was captured —
/// e.g. a pad already plugged in at launch on a backend that reports it via
/// a one-shot the demo missed.
pub fn nameFor(id: u32) [:0]const u8 {
    // Look up by device id (NOT array slot): Android `InputDevice` ids are not
    // dense 0..3 and routinely exceed MAX_GAMEPADS (e.g. 9), so indexing
    // `entries[id]` both missed the stored entry and risked OOB. Mirror
    // `record`/`typeHintFor`, which already key by id (labelle-assembler#270,
    // same class of bug as labelle-engine#261).
    const e = findById(id) orelse return "Gamepad";
    if (e.name_len == 0) return "Gamepad";
    // `record` caps name_len at NAME_CAP-1, so the terminator always fits.
    // Clamp defensively too, so the sentinel slice can never read out of bounds.
    const n = @min(e.name_len, NAME_CAP - 1);
    e.name[n] = 0;
    return e.name[0..n :0];
}

/// Type hint string for `id` (e.g. "xbox", "playstation", "unknown").
pub fn typeHintFor(id: u32) [:0]const u8 {
    if (findById(id)) |e| return e.type_hint;
    return "unknown";
}

/// Snapshot the device ids of all currently-known pads into `out`, returning
/// the count written. Lets the HUD iterate the actual (possibly sparse)
/// platform device ids instead of assuming a dense 0..3 slot range — Android
/// `InputDevice` ids are not 0-based and routinely exceed 4
/// (labelle-engine#261).
pub fn knownIds(out: []u32) usize {
    var n: usize = 0;
    for (&entries) |*e| {
        if (e.known and n < out.len) {
            out[n] = e.id;
            n += 1;
        }
    }
    return n;
}

// ── tests (host) ─────────────────────────────────────────────────────────

const std = @import("std");

test "nameFor/typeHintFor resolve a sparse Android device id (#270)" {
    // Reset module state (process-global array) before/after.
    entries = [_]Entry{.{}} ** MAX_GAMEPADS;
    defer entries = [_]Entry{.{}} ** MAX_GAMEPADS;

    // Android InputDevice id 9 is well above MAX_GAMEPADS — the old slot-indexed
    // `nameFor` returned "Gamepad" and never surfaced the recorded name.
    record(9, "Xbox Wireless Controller", "xbox");
    try std.testing.expectEqualStrings("Xbox Wireless Controller", nameFor(9));
    try std.testing.expectEqualStrings("xbox", typeHintFor(9));

    // Unknown id still falls back cleanly.
    try std.testing.expectEqualStrings("Gamepad", nameFor(3));
    try std.testing.expectEqualStrings("unknown", typeHintFor(3));

    // Forget clears it.
    forget(9);
    try std.testing.expectEqualStrings("Gamepad", nameFor(9));
}

test "nameFor handles a name that fills the buffer without OOB (#270)" {
    entries = [_]Entry{.{}} ** MAX_GAMEPADS;
    defer entries = [_]Entry{.{}} ** MAX_GAMEPADS;

    // A name >= NAME_CAP previously made name_len == NAME_CAP, so the
    // sentinel slice `e.name[0..name_len :0]` read out of bounds. record()
    // now caps at NAME_CAP-1 and nameFor clamps, so this must not panic and
    // returns the (truncated) name with a valid in-bounds terminator.
    const long = "X" ** (NAME_CAP + 8);
    record(2, long, "generic");
    const got = nameFor(2);
    try std.testing.expectEqual(@as(usize, NAME_CAP - 1), got.len);
    try std.testing.expectEqual(@as(u8, 0), got.ptr[got.len]); // NUL in bounds
}
