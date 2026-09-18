//! sokol-audio device sink — the **f32** `DeviceSink` for the shared
//! `labelle-audio` mixer (Phase 2 audio fan-out, the sokol case).
//!
//! Unlike bgfx/wgpu (i16 device callbacks), sokol drives audio through
//! `sokol_audio.h`, whose stream callback hands the app a `[*]f32` buffer it
//! must fill with normalized `[-1.0, 1.0]` interleaved samples. labelle-audio
//! v0.3.0 added an f32 output path for exactly this: a sink declares
//! `pub const sample_format = .f32` and `Mixer(SokolSink).ensureInit()` wires
//! the f32 thunk (`mixThunkF32`) into `ensureStarted`. The mixer fills the
//! buffer directly in `[-1.0, 1.0]` — no i16⇄f32 conversion at the seam.
//!
//! This is the device half of the audio backend (mirrors bgfx's
//! `audio_device.zig`): the shared mixer owns decode + slot arrays + the
//! spinlock + the full AudioInterface surface; this file owns only the
//! sokol_audio device + its f32 stream callback.
//!
//! ## The f32 `DeviceSink` contract this satisfies
//!   * `ensureStarted(mix: MixCallbackF32) void` — lazily `saudio.setup` the
//!     device, wiring `mix` as the audio-thread fill callback. Idempotent.
//!   * `stop() void` — `saudio.shutdown` (joins the audio thread) if started.
//!   * `framesMixed() u64` — cumulative frames pushed through the callback.
//!   * `pub const sample_format: SampleFormat = .f32` — opt into the f32 path.
const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const saudio = sokol.audio;
const labelle_audio = @import("labelle-audio");

/// **Null-device mode** — the device-independent test fixture (#22 review).
///
/// When true, `ensureStarted` wires the mixer callback and reports the sink as
/// started WITHOUT opening a sokol_audio device. Everything above the device —
/// the shared mixer's slot pool, `uploadSound`/`unloadSound` marshalling, the
/// whole `AudioInterface` control surface — behaves exactly as it does with a
/// real device; only the speaker is missing.
///
/// Defaults to `builtin.is_test`, so `zig build test` / `test-host` never touch
/// audio hardware. That is not cosmetic: the sokol_audio ALSA backend on a
/// machine with no sound card (every Linux CI runner) aborts out of
/// `saudio.setup` — `cannot find card '0'` → SIGABRT — which is precisely how
/// the audio tests died once #21 made `zig build test` actually execute them.
/// A null device is preferred over `error.SkipZigTest` because a skip would
/// preserve the "these assertions never run" status quo that #21 exists to end.
///
/// It is a runtime `var`, not a comptime constant, on purpose: a comptime-known
/// condition would let Zig drop the un-taken branch from semantic analysis, so
/// in a test build the real `saudio.setup` path would stop being type-checked —
/// silently gutting what `audio_compile_check` is for. A single predictable
/// bool load on an already-idempotent path is a fair price. It is also `pub` so
/// a headless/dedicated-server build can opt out of audio hardware on purpose.
pub var null_device: bool = builtin.is_test;

/// Opt into the shared mixer's f32 render path. This single decl is what makes
/// `Mixer(SokolSink)` render the mix into `[]f32` and wire `ensureStarted` to a
/// `MixCallbackF32` (vs the default i16 `MixCallback`).
pub const sample_format: labelle_audio.SampleFormat = .f32;

/// Signature of the mixer fill callback this device drives on the audio thread
/// — the shared f32 device-sink callback (`out: []f32, channels: u8`). Imported
/// from the shared package (rather than redeclared) so the `DeviceSink`
/// contract enforces the signature at the `Mixer(...)` instantiation site.
const MixFn = labelle_audio.MixCallbackF32;

const DEVICE_SAMPLE_RATE: i32 = 44100;
const DEVICE_CHANNELS: i32 = 2;

// `ensureStarted` / `stop` are called from the game thread only (the
// AudioInterface control surface is single-threaded; only the mixer runs on the
// audio callback thread, and it never reads this). Atomic anyway for safe
// publication of the device's started state.
var device_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Whether a REAL sokol_audio device is open (i.e. `saudio.setup` ran and the
// device validated). Distinct from `device_started`, which is also true in
// null-device mode: `stop()` must not call `saudio.shutdown` on a device that
// was never set up.
var real_device_open: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// The mixer supplied by the shared `Mixer`, published before the device starts
// and read on the audio thread. Stored as a nullable so a stray callback
// (shouldn't happen — set before start) degrades to silence, not a crash.
var mix_fn: ?MixFn = null;

/// Cumulative frames pushed through the device callback. sokol hands `num_frames`
/// per callback; we accumulate. Atomic because it's written from the audio
/// thread and read from the game thread (`framesMixed`).
var frames_mixed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// The f32 stream callback sokol_audio invokes on its own thread. sokol hands a
/// `[*]f32` buffer plus `num_frames` + `num_channels`; we wrap it as
/// `out[0 .. num_frames * num_channels]` and let the shared mixer fill it in
/// normalized `[-1.0, 1.0]` interleaved f32 — exactly what sokol_audio expects,
/// no conversion. The mixer takes its own slot lock internally, so this is safe
/// against concurrent load/unload on the game thread (#298).
fn streamCallback(buffer: [*c]f32, num_frames: i32, num_channels: i32) callconv(.c) void {
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    const sample_count: usize = frames * channels;

    // Proof-of-life so headless runs can confirm the callback is firing
    // (audibility can't be asserted without a speaker). Log once on the first
    // invocation; thereafter just count.
    const prev = frames_mixed.fetchAdd(@intCast(frames), .monotonic);
    if (prev == 0) {
        std.log.info("audio: sokol_audio stream callback firing (first {d} frames)", .{frames});
    }

    if (mix_fn) |mix| {
        // Shared f32 device-sink contract: pass the channel count and a buffer
        // of `frames * channels` interleaved f32; the mixer recovers the frame
        // count from `out.len`.
        mix(buffer[0..sample_count], @intCast(channels));
    } else {
        // No mixer wired yet — emit silence, not whatever stale samples the
        // device buffer happens to hold.
        @memset(buffer[0..sample_count], 0);
    }
}

/// Open + start the sokol_audio device on first use, wiring `mix` as the
/// audio-thread fill callback. Idempotent and cheap to call from every public
/// entry point that can start audio. Requests a **2-channel** stream (the
/// shared mixer is stereo-only; a non-2 channel count → silence). If the device
/// fails to validate (e.g. no audio hardware in CI) we leave it un-started — the
/// rest of the backend keeps working as a silent state machine.
pub fn ensureStarted(mix: MixFn) void {
    if (device_started.load(.acquire)) return;

    // Publish the mixer before the device starts so the audio thread never
    // observes a null `mix_fn`.
    mix_fn = mix;

    if (null_device) {
        // Null-device fixture: the sink is "started" (the mixer is wired and
        // the control surface is live) but no sokol_audio device is opened, so
        // nothing here needs a sound card. `framesMixed` stays 0 — with no
        // device thread there is no stream callback to count.
        device_started.store(true, .release);
        std.log.info("audio: sokol_audio null device (no hardware opened)", .{});
        return;
    }

    saudio.setup(.{
        .num_channels = DEVICE_CHANNELS,
        .sample_rate = DEVICE_SAMPLE_RATE,
        .stream_cb = streamCallback,
        .logger = .{ .func = sokol.log.func },
    });

    if (saudio.isvalid()) {
        real_device_open.store(true, .release);
        device_started.store(true, .release);
        std.log.info(
            "audio: sokol_audio device started: {d}Hz {d}ch f32",
            .{ saudio.sampleRate(), saudio.channels() },
        );
    } else {
        std.log.warn("audio: sokol_audio device failed to validate", .{});
    }
}

/// Stop and close the device if it was started. `saudio.shutdown` joins the
/// audio callback thread, so after it the mixer is no longer called and the
/// caller can free PCM without taking the slot lock.
///
/// `device_started` is only set when `saudio.setup` succeeded *and* the device
/// validated (see `ensureStarted`), so reaching here means `setup_called` is
/// true — `saudio.shutdown` (which asserts `setup_called`, not `isvalid`) is
/// safe to call unconditionally, and is *required* to reset sokol_audio's
/// internal setup state even if the device later became invalid.
pub fn stop() void {
    if (!device_started.load(.acquire)) return;
    // Only tear down a device that was actually set up. In null-device mode
    // `saudio.setup` never ran, and `saudio.shutdown` asserts `setup_called`.
    if (real_device_open.load(.acquire)) {
        saudio.shutdown();
        real_device_open.store(false, .release);
    }
    device_started.store(false, .release);
    std.log.info(
        "audio: sokol_audio device stopped ({d} frames mixed)",
        .{frames_mixed.load(.monotonic)},
    );
}

/// Cumulative frames pushed through the device callback so far.
pub fn framesMixed() u64 {
    return frames_mixed.load(.monotonic);
}

/// Whether the sink is started — true for a live sokol_audio device AND for the
/// null-device fixture. Introspection for tests/diagnostics; not part of the
/// `DeviceSink` contract.
pub fn isStarted() bool {
    return device_started.load(.acquire);
}

/// Whether a REAL sokol_audio device is open. Lets a test assert which path
/// `ensureStarted` actually took, rather than only that the outcome looked
/// right — the null-device fixture and a working speaker produce identical
/// mixer-side results, so a value-only assertion would be vacuous.
pub fn isRealDeviceOpen() bool {
    return real_device_open.load(.acquire);
}
