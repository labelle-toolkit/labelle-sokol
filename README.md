# labelle-sokol

The **sokol** rendering backend for the [labelle](https://github.com/labelle-toolkit) 2D engine, as an **out-of-tree pluggable backend** (labelle-assembler#386).

Callback-style (sokol_app owns the run loop). Desktop + WASM (emscripten) + iOS + Android. Desktop gamepad via the shared `labelle-sdl-gamepad` (Linux routes through labelle-core's udev source); Android via `labelle-android-gamepad`. Audio via sokol_audio + the shared `labelle-audio` mixer.

Android launch-intent extras and the debuggable gate come from
[`labelle-android`](https://github.com/labelle-toolkit/labelle-android) v0.1.0.
The generated `sokol_main()` still calls `input.launch_intent_env.apply()`
before the engine reads its environment. Service logs now use `android:`.
The shared package owns the JNI implementation and allow-list tests.

## Use it
```zig
.backend = .sokol,
.backend_package = .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.1.0" },
```
(With the default-flip, `.backend = .sokol` resolves here automatically.)

## Layout
- `src/` — the four backend modules (gfx/window/input/audio)
- `backend.manifest.zon` (loop_style = .callback) + `build_fragments/` — drive the assembler's desktop manifest-splice codegen; WASM/iOS/Android use the assembler's enum path
- `templates/{desktop,mobile}.txt` — the generated callback `main()`

## Build
```sh
zig build test   # sokol backend unit tests + audio compile-check
```

> The `.sokol` pin tracks labelle-imgui's sokol-zig fork commit in lockstep — bump both together.
