/// Sokol audio backend — satisfies the engine AudioInterface(Impl) contract.
///
/// Phase 2 of the pluggable-backends RFC (the **f32** fan-out of the audio
/// pilot): the WAV decode + PCM mixer + slot management this backend used to
/// reimplement (~1,200 lines across `audio/{state,system,legacy}.zig` +
/// `audio_slots.zig`) now live in the shared `labelle-audio` package. This file
/// is a thin adapter over `labelle_audio.Mixer(SokolSink)`.
///
/// ## The f32 case (the new part of the pilot)
///
/// Unlike bgfx/wgpu (i16 device callbacks), sokol drives audio through
/// `sokol_audio.h`, whose stream callback is **f32**. labelle-audio v0.3.0
/// added an f32 output path for exactly this: `SokolSink` (in `audio/sink.zig`)
/// declares `pub const sample_format = .f32`, so `Mixer(SokolSink)` renders the
/// mix directly into the `[*]f32` buffer sokol_audio hands the stream callback,
/// in normalized `[-1.0, 1.0]` interleaved samples — **no i16⇄f32 conversion**
/// at the seam. The mixer requests a stereo (2-channel) stream.
///
/// ## What this file keeps
///
///   * `audio/sink.zig`   — the sokol_audio device + its f32 stream callback,
///                          satisfying the shared f32 `DeviceSink` contract.
///   * `audio/decode.zig` — the Phase 4 OGG/WAV decode surface (`decodeAudio` +
///                          `DecodedAudio`/`Sound`). The decode itself now
///                          FORWARDS to the shared `labelle-audio-decode`
///                          module (issue #391, pure-Zig WAV + stb_vorbis OGG);
///                          this file keeps only the thin forward + the sokol
///                          `Sound` ABI handle. The decoded i16 PCM is handed
///                          to the shared mixer via `loadSoundFromPcm`.
///   * `audio/tests.zig`  — adapter smoke tests + decoder regression locks.
///
/// Everything else — the spinlock, the #298 unload/mix UAF fix, mono→stereo
/// duplication, the slot arrays — is provided by the shared mixer
/// (`labelle-audio/src/mixer.zig`). The public API names + signatures below are
/// preserved verbatim: the engine/assembler call them by name (and the
/// assembler's `writeAudioBackendWiring` calls `decodeAudio`/`uploadSound`/
/// `unloadSound`/`DecodedAudio`/`Sound`).
const std = @import("std");
const labelle_audio = @import("labelle-audio");
const SokolSink = @import("audio/sink.zig");
const decode = @import("audio/decode.zig");

/// The shared PCM mixer, parameterized by sokol's sokol_audio device as the
/// **f32** `DeviceSink`. Owns slot arrays + the spinlock + the full
/// AudioInterface surface; the public fns below forward to it.
const Audio = labelle_audio.Mixer(SokolSink);

// ── Audio system lifecycle ─────────────────────────────────────────────

/// Stop the device (joins the audio thread) and free all loaded PCM. Must be
/// called before program exit to avoid leaking memory.
pub fn deinit() void {
    Audio.deinit();
}

pub fn setVolume(volume: f32) void {
    Audio.setVolume(volume);
}

// ── Path-based file-read shim ──────────────────────────────────────────
//
// The shared mixer is byte-buffer based (`loadSoundFromMemory` / WAV), but
// sokol's public `loadSound`/`loadMusic` take a file path. Zig 0.16 removed
// `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which requires an `Io`
// threaded through the call site. Rather than thread `Io` through the backend
// for a one-shot legacy loader, we read the file via libc `fopen`/`fread`/
// `fclose` — `link_libc = true` is set on the audio module (see
// backends/sokol/build.zig, already pulled in for stb_vorbis / dr_wav). The
// bytes are then handed to the shared mixer, which owns decode + ownership.

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

/// Read an entire file into a freshly page-allocated buffer via libc. Returns
/// null on any IO error or short read (a short `fread` can occur on EOF
/// mid-read without setting an error flag, so we compare against the full
/// requested size). Caller owns the returned slice and frees it via
/// `std.heap.page_allocator`.
fn readFileBytes(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 44) return null; // minimum WAV size
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);
    if (file_size > 256 * 1024 * 1024) return null;

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return null;

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        std.log.warn("audio: short read on {s} ({d}/{d} bytes)", .{ path, bytes_read, file_size });
        allocator.free(data);
        return null;
    }
    return data;
}

// ── Legacy path-based sound effects ────────────────────────────────────

/// Load a WAV file from `path` and register it as a sound effect. Reads the
/// file via the libc shim, then hands the bytes to the shared mixer (which owns
/// decode + the PCM). Returns the sound id, or 0 on failure.
pub fn loadSound(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadSoundFromMemory(bytes);
}

/// Legacy path-based unload, paired with `loadSound(path)`. Named distinctly
/// from the Phase 4 `unloadSound(Sound)` so the catalog-shaped surface can take
/// the bare name (the engine contract requires `unloadSound(sound: Sound)`).
pub fn unloadSoundById(id: u32) void {
    Audio.unloadSound(id);
}

pub fn playSound(id: u32) void {
    Audio.playSound(id);
}

pub fn stopSound(id: u32) void {
    Audio.stopSound(id);
}

pub fn isSoundPlaying(id: u32) bool {
    return Audio.isSoundPlaying(id);
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    Audio.setSoundVolume(id, volume);
}

// ── Legacy path-based music (streaming) ────────────────────────────────

/// Load a WAV file from `path` and register it as a looping music stream. Same
/// libc file-read shim as `loadSound`. Returns the music id, or 0 on failure.
pub fn loadMusic(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadMusicFromMemory(bytes);
}

pub fn unloadMusic(id: u32) void {
    Audio.unloadMusic(id);
}

pub fn playMusic(id: u32) void {
    Audio.playMusic(id);
}

pub fn stopMusic(id: u32) void {
    Audio.stopMusic(id);
}

pub fn pauseMusic(id: u32) void {
    Audio.pauseMusic(id);
}

pub fn resumeMusic(id: u32) void {
    Audio.resumeMusic(id);
}

pub fn isMusicPlaying(id: u32) bool {
    return Audio.isMusicPlaying(id);
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    Audio.setMusicVolume(id, volume);
}

/// No-op (kept for API compatibility). Music position is advanced exclusively
/// on the audio thread by the mixer's device callback, so advancing here would
/// double-advance / drift.
pub fn updateMusic(id: u32) void {
    Audio.updateMusic(id);
}

// ── Phase 4 audio loader surface (labelle-engine#447) ──────────────────
//
// The decode half (`DecodedAudio`/`Sound`/`decodeAudio`) lives in
// `audio/decode.zig` — KEPT because the shared mixer decodes WAV only and the
// assembler's `writeAudioBackendWiring` needs OGG (stb_vorbis). The upload/
// unload half routes the decoded i16 PCM into the shared mixer's slot pool.

pub const DecodedAudio = decode.DecodedAudio;
pub const Sound = decode.Sound;
pub const decodeAudio = decode.decodeAudio;

/// Main-thread audio-device registration. Hands the decoded interleaved i16 PCM
/// to the shared mixer (`loadSoundFromPcm` copies it into a slot) and returns a
/// generation-tagged `Sound` wrapping the slot id.
///
/// Does NOT take ownership of `decoded.samples` — caller frees on both the
/// success and discard paths (`loadSoundFromPcm` copies). The `generation`
/// field is fixed at 1 for ABI stability; the assembler's adapter tracks its
/// own per-slot generation (see `writeAudioBackendWiring`).
pub fn uploadSound(decoded: DecodedAudio) !Sound {
    if (decoded.channels == 0) return error.AudioInvalidChannels;
    const id = Audio.loadSoundFromPcm(decoded.samples, decoded.channels, decoded.sample_rate);
    if (id == 0) return error.AudioSlotsExhausted;
    return .{ .slot_index = id, .generation = 1 };
}

/// Counterpart to `uploadSound`. Tears down the shared-mixer slot the handle
/// references (the #298 UAF-safe detach-then-free lives in the shared mixer).
pub fn unloadSound(sound: Sound) void {
    Audio.unloadSound(sound.slot_index);
}

// ── Test aggregation ───────────────────────────────────────────────────
//
// The build.zig's `audio_compile_check` runs `b.addTest({ .root_module =
// audio_mod })` over this file. Pull in `tests.zig` (and the decode submodule
// via its imports) so Zig's test discovery picks up the adapter smoke tests +
// the decoder regression locks.
test {
    std.testing.refAllDecls(@import("audio/tests.zig"));
}
