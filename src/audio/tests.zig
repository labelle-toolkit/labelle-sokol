//! Sokol audio adapter smoke tests + Phase 4 decoder regression locks.
//!
//! The decode/mixer/spinlock/UAF behaviour is now tested in `labelle-audio`
//! itself (the shared mixer). These thin tests confirm the sokol adapter wires
//! the shared mixer correctly (forwarding + the `uploadSound`/`unloadSound`
//! Phase 4 marshalling) and that the kept OGG/WAV decoder still rejects bad
//! input. Exercised headlessly: `SokolSink.ensureStarted` degrades to a silent
//! no-op when sokol_audio can't validate a device (CI has no speaker), so the
//! mixer's slot bookkeeping is testable without audio hardware.
const std = @import("std");
const audio = @import("../audio.zig");
const decode = @import("decode.zig");

const testing = std.testing;

// Pull the decode module's own tests (empty/garbage/unknown-format + the
// `Sound` extern-layout lock) into this aggregation root.
test {
    testing.refAllDecls(decode);
}

test "uploadSound rejects zero-channel DecodedAudio" {
    var samples = [_]i16{ 1, 2, 3, 4 };
    const decoded: audio.DecodedAudio = .{
        .samples = &samples,
        .sample_rate = 44100,
        .channels = 0,
    };
    try testing.expectError(error.AudioInvalidChannels, audio.uploadSound(decoded));
}

test "uploadSound returns a non-zero slot, unloadSound tears it down" {
    var samples = [_]i16{ 1, 2, 3, 4 };
    const decoded: audio.DecodedAudio = .{
        .samples = &samples,
        .sample_rate = 44100,
        .channels = 1,
    };
    const sound = try audio.uploadSound(decoded);
    // `defer` guarantees teardown even if the assertion below fails — otherwise
    // the slot would leak into the next test. The explicit unload before it then
    // exercises the idempotent double-unload (a no-op in the shared mixer).
    defer audio.unloadSound(sound);
    // The shared mixer reserves slot 0 as the "not loaded" sentinel, so a live
    // upload must land on a slot >= 1.
    try testing.expect(sound.slot_index != 0);
    audio.unloadSound(sound);
}

test "uploadSound + Sound round-trips the slot id through the extern handle" {
    var samples = [_]i16{ 10, 20, 30, 40 };
    const decoded: audio.DecodedAudio = .{
        .samples = &samples,
        .sample_rate = 44100,
        .channels = 2,
    };
    const sound = try audio.uploadSound(decoded);
    defer audio.unloadSound(sound);
    try testing.expectEqual(@as(u32, 1), sound.generation); // fixed for ABI
    try testing.expect(sound.slot_index != 0);
}

test "legacy sound id 0 is inert across play/stop/unload" {
    // The shared mixer treats id 0 as the "not loaded" sentinel: every entry
    // point short-circuits, so a failed `loadSound` (returns 0) can be passed to
    // the play/stop/unload surface without effect.
    audio.playSound(0);
    audio.stopSound(0);
    audio.unloadSoundById(0);
    try testing.expect(!audio.isSoundPlaying(0));
}

test "music id 0 is inert across the music surface" {
    audio.playMusic(0);
    audio.stopMusic(0);
    audio.pauseMusic(0);
    audio.resumeMusic(0);
    audio.updateMusic(0);
    audio.unloadMusic(0);
    try testing.expect(!audio.isMusicPlaying(0));
}
