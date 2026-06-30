//! Phase 4 audio decode surface (labelle-engine#447) — the OGG/WAV CPU
//! decoder the assembler's `writeAudioBackendWiring` codegen calls.
//!
//! The mixer + slot management + f32 PCM playback live in the shared
//! `labelle-audio` package (Phase 2 fan-out). The pure-CPU OGG/WAV decode that
//! used to live HERE (a hand-rolled dr_wav + stb_vorbis copy) is now ALSO
//! shared: issue #391 collapses every backend's identical `decodeAudio` onto
//! the `labelle-audio-decode` module (pure-Zig WAV via `wav.decode` + OGG via
//! stb_vorbis). This file keeps ONLY the thin forward + the sokol-specific
//! `Sound` ABI handle the assembler's slot table marshals through.
//!
//! ## Why the mixer + decode now coexist in one binary (v0.4.1)
//!
//! sokol needs BOTH the shared mixer (`labelle-audio`) AND OGG decode
//! (`labelle-audio-decode`) in one Compile. v0.4.0 packaged `wav.zig` into BOTH
//! module roots by file path, so importing both modules failed with
//! `error: file exists in modules 'labelle-audio' and 'labelle-audio-decode'`.
//! v0.4.1 fixes it: the decode module reaches `wav`/`DecodedAudio` through the
//! BASE module BY NAME, so every shared file is rooted in exactly one module
//! and the two coexist. That's what unblocked this rewire (#391).
//!
//! ## DecodedAudio unifies with the mixer's type
//!
//! The shared `DecodedAudio` is `@import("labelle-audio-decode").DecodedAudio`,
//! which is `wav.DecodedAudio` — the SAME type the base mixer consumes. So the
//! decoded i16 PCM hands straight to the shared mixer via `loadSoundFromPcm`
//! (see `audio.zig`'s `uploadSound`), no conversion at the seam.
const std = @import("std");
const shared_decode = @import("labelle-audio-decode");

/// CPU-decoded interleaved-PCM audio. Re-exported from the shared
/// `labelle-audio-decode` module (issue #391) — `{ samples: []i16,
/// sample_rate: u32, channels: u8 }`, the same shape the assembler's
/// `writeAudioBackendWiring` field-by-field copy marshals AND the shared mixer
/// consumes (it unifies with the base mixer's `DecodedAudio`).
pub const DecodedAudio = shared_decode.DecodedAudio;

/// Opaque sound handle for the Phase 4 loader. Kept as an `extern struct`
/// with the same `{ slot_index, generation }` shape (size 8, align 4) the
/// assembler's slot table marshals through — the test in `tests.zig` locks
/// this layout. `slot_index` now carries the shared mixer's slot id; the
/// `generation` field is retained for ABI stability (the assembler's adapter
/// tracks its own per-slot generation and ignores this one).
pub const Sound = extern struct {
    slot_index: u32,
    generation: u32,
};

/// Pure CPU decode — worker-thread safe. Forwards to the shared
/// `labelle-audio-decode` module, which only touches the input bytes + the
/// allocator-owned PCM buffer.
///
/// Dispatches on `file_type`:
///   - "wav" → the pure-Zig overflow-safe `wav.decode` (drops the old dr_wav
///     C dependency).
///   - "ogg" → `stb_vorbis` (open_memory + get_samples_short_interleaved).
///   - anything else → `error.AudioUnsupportedFormat`.
///
/// Error-name surface (shared module): empty input → `error.AudioEmptyInput`,
/// unknown format → `error.AudioUnsupportedFormat`, decode failure →
/// `error.AudioDecodeFailed` (a garbage WAV surfaces the pure-Zig parser's
/// more specific `error.NotRiff`).
///
/// The returned `samples` slice is from `allocator` — caller frees on BOTH
/// success and discard paths.
pub fn decodeAudio(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedAudio {
    return shared_decode.decodeAudio(file_type, data, allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeAudio rejects empty data" {
    try testing.expectError(error.AudioEmptyInput, decodeAudio("wav", &.{}, testing.allocator));
    try testing.expectError(error.AudioEmptyInput, decodeAudio("ogg", &.{}, testing.allocator));
}

test "decodeAudio rejects unknown file_type" {
    const fake = "anything";
    try testing.expectError(error.AudioUnsupportedFormat, decodeAudio("flac", fake, testing.allocator));
    try testing.expectError(error.AudioUnsupportedFormat, decodeAudio("mp3", fake, testing.allocator));
}

test "decodeAudio surfaces a parse error on garbage wav input" {
    // Not a RIFF header — the shared pure-Zig WAV parser rejects it with its
    // more specific `error.NotRiff` (the old dr_wav copy returned the generic
    // `error.AudioDecodeFailed`).
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectError(error.NotRiff, decodeAudio("wav", &fake, testing.allocator));
}

test "Sound has stable extern layout" {
    // Locks the Phase 4 wire shape: the assembler's codegen does a field-by-
    // field copy through this struct, so size + alignment need to stay
    // invariant.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Sound));
    try testing.expectEqual(@as(usize, 4), @alignOf(Sound));
}
