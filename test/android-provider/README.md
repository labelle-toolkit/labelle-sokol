# Sokol Android provider fixture

Uses the local Sokol backend beside the released `android` v0.2.0 plugin.
The CI D11 job runs the released assembler v0.116.1 on a clean runner:
`install` fetches the pinned packages, then `generate`. It checks that each
shared JNI helper is defined once, comes from `deps/labelle-android`, and
that no Android callback remains unresolved.
The fixture deliberately disables gamepad polling to cover the native-loader
failure caused by omitting the JNI event receivers in that configuration.

For runtime acceptance, use Zig 0.16.0, the provider CLI built from
`development` (9e4625623fa2, cli#444, or later) with `-Dversion=2.0.0`, and
an authorized arm64 device/emulator:

```sh
labelle providers resolve
# Review the Android pin, then accept it.
labelle providers resolve --accept
labelle run --platform=android --optimize=ReleaseFast
```

The plugin pin uses the `github.com/labelle-toolkit/labelle-android` form:
the assembler needs a hostname to download it, and the provider CLI (cli#444)
matches it against the lock's `labelle-toolkit/labelle-android` entry. On a
clean machine, `labelle providers fetch` (or `labelle install`) downloads the
archive the lock pins before `generate`/`run`.

`audio_probe.zig` opens the actual shared AAudio sink with silent PCM. Its
`ProviderProbe` logcat messages report nonzero shared callback frames, surface
size, and the intent-derived environment. Since assembler v0.116's Sokol
callback loop does not poll screenshot requests or route Zig stderr to logcat,
the fixture also drives `engine.requestedScreenshot()` through the backend's
real framebuffer capture. This is not an Android compositor screenshot.

To request capture on a fresh launch (without removing app data):

```sh
adb shell am force-stop com.labelle.sokol_provider
adb shell am start -n com.labelle.sokol_provider/android.app.NativeActivity \
  --es LABELLE_SCENE main \
  --es LABELLE_SCREENSHOT_PATH /data/data/com.labelle.sokol_provider/files/provider-capture.bmp \
  --es LABELLE_SCREENSHOT_AFTER_SEC 3
adb exec-out run-as com.labelle.sokol_provider cat files/provider-capture.bmp > provider-capture.bmp
```

Wait at least 3 seconds before retrieving capture and 30 seconds before
checking `adb shell pidof com.labelle.sokol_provider`. Exercise HOME then
`am start`, verify the PID survives, and inspect `adb logcat -b crash -d`.
