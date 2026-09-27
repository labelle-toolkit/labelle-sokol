//! Android device adapter. All AAudio lifecycle and callback code is shared.
const builtin = @import("builtin");
const shared = @import("labelle_android").aaudio;
const audio = @import("labelle-audio");

// Preserve Sokol's explicit headless/test control without opening hardware.
pub var null_device: bool = builtin.is_test;
pub fn ensureStarted(mix: audio.MixCallback) void {
    if (!null_device) shared.ensureStarted(mix);
}
pub fn stop() void {
    shared.stop();
}
pub fn framesMixed() u64 {
    return shared.framesMixed();
}
