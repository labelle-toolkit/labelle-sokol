//! Sokol audio adapter smoke tests + Phase 4 decoder regression locks.
//!
//! The decode/mixer/spinlock/UAF behaviour is now tested in `labelle-audio`
//! itself (the shared mixer). These thin tests confirm the sokol adapter wires
//! the shared mixer correctly (forwarding + the `uploadSound`/`unloadSound`
//! Phase 4 marshalling) and that the kept OGG/WAV decoder still rejects bad
//! input.
//!
//! ## Why these run without a sound card
//! `uploadSound` goes through the shared mixer's `ensureInit`, which drives
//! `SokolSink.ensureStarted` — i.e. the real sokol_audio device. On a machine
//! with no sound card the ALSA backend does not degrade gracefully, it ABORTS
//! (`cannot find card '0'` → SIGABRT), which is how these tests died on CI the
//! moment #21 made `zig build test` actually execute them.
//!
//! So `sink.zig` carries a null-device fixture (`SokolSink.null_device`,
//! defaulting to `builtin.is_test`): the mixer is wired and the sink reports as
//! started, but no hardware is opened. Every assertion below still runs — a
//! fixture rather than `error.SkipZigTest`, because a skip would preserve the
//! exact "no coverage" state #21 exists to fix. The first test asserts the
//! fixture is the path taken, not merely that the results look right.
const std = @import("std");
const audio = @import("../audio.zig");
const decode = @import("decode.zig");
const sink = @import("sink.zig");

const testing = std.testing;

// Pull the decode module's own tests (empty/garbage/unknown-format + the
// `Sound` extern-layout lock) into this aggregation root.
test {
    testing.refAllDecls(decode);
}

test "the audio suite runs on the null-device fixture, not real hardware" {
    // MECHANISM assertion. The tests below would pass identically on a laptop
    // with working speakers, so asserting their return values proves nothing
    // about CI. Assert instead which path `ensureStarted` took: an upload must
    // have started the sink WITHOUT opening a sokol_audio device. If this ever
    // fails, the Linux CI job is about to SIGABRT in ALSA again.
    try testing.expect(sink.null_device);

    var samples = [_]i16{ 1, 2 };
    const sound = try audio.uploadSound(.{
        .samples = &samples,
        .sample_rate = 44100,
        .channels = 1,
    });
    defer audio.unloadSound(sound);

    try testing.expect(sink.isStarted()); // the mixer DID drive ensureStarted
    try testing.expect(!sink.isRealDeviceOpen()); // ...but opened no hardware
    try testing.expectEqual(@as(u64, 0), sink.framesMixed()); // no device thread
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
