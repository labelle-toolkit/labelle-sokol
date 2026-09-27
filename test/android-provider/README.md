# Sokol Android provider fixture

Uses the local Sokol backend beside the released `android` v0.2.0 plugin.
The CI D11 job stages the released dependencies and generates with assembler
v0.116.0. It checks that each shared JNI helper is defined once, comes from
`deps/labelle-android`, and that no Android callback remains unresolved.
The fixture deliberately disables gamepad polling to cover the native-loader
failure caused by omitting the JNI event receivers in that configuration.

For runtime acceptance, use Zig 0.16.0, the provider CLI built from
`development` with `-Dversion=2.0.0`, and an authorized arm64 device/emulator:

```sh
labelle providers resolve
# Review the Android pin, then accept it.
labelle providers resolve --accept
labelle run --platform=android --optimize=ReleaseFast
```

The released assembler's installer currently interprets `owner/repo` as a
hostname. Until the CLI/assembler repository-form fix lands, stage Android's
v0.2.0 source in `~/.labelle/packages/plugins/labelle-toolkit/labelle-android/0.2.0`
(as CI does). This workaround does not alter the verified provider lock.

`audio_probe.zig` opens the actual shared AAudio sink with silent PCM. Its
`ProviderProbe` logcat messages report nonzero shared callback frames, surface
size, and the intent-derived environment. Since assembler v0.116.0's Sokol
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
