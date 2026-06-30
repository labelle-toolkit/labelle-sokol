//! Cross-compile SDL-gating probe (core#28). NOT shipped — used only by the
//! `gating-obj` build step to prove the shared `sdl_gamepad` source pulls NO
//! SDL symbols on a non-desktop target.
//!
//! It force-references the SDL-touching `Source` surface through an exported
//! entry point so dead-code elimination cannot strip the SDL `extern`
//! references on a desktop target (which would make a "no SDL symbols" check
//! vacuously pass everywhere). On a desktop target the emitted object DOES
//! contain undefined `SDL_*` symbols (init/update/the state queries reach the
//! externs); on Android/wasm the source's `is_desktop` is false, so the same
//! object contains NONE — proving the non-desktop sokol path pulls no SDL.
const sdl_gp = @import("sdl_gamepad");

export fn labelle_gamepad_gating_probe() u32 {
    sdl_gp.Source.init();
    sdl_gp.Source.update();
    var sum: u32 = 0;
    if (sdl_gp.Source.isAvailable(0)) sum += 1;
    if (sdl_gp.Source.isButtonDown(0, 1)) sum += 1;
    if (sdl_gp.Source.isButtonPressed(0, 1)) sum += 1;
    sum +%= @intFromFloat(sdl_gp.Source.axisValue(0, 0));
    sdl_gp.Source.deinit();
    return sum;
}
