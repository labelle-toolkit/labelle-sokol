# Android launch-intent acceptance

Run against an idle ARM64 Android device/emulator, with Zig 0.16.0, the Android
SDK/NDK, and a JDK on PATH. The script installs/removes only its test package,
`com.labelle.services_probe`. Pass the intended device explicitly:

```sh
export ANDROID_HOME=/path/to/sdk
export ANDROID_NDK_HOME=/path/to/sdk/ndk/version
python3 tests/android-services/check.py --serial emulator-5554 --zig /path/to/zig
```

This builds the real released labelle-android v0.1.0 module and JNI code into a
minimal NativeActivity APK with `android:debuggable=false`. It verifies that
scene extras arrive, screenshot extras are rejected, and a second Activity
launch with no extras clears the scene **in the same PID**. The native entry
finishes each Activity without exiting its process; the launch counter proves
that the library's process state survived. A failed assertion fails the script. If Android evicts the cached process, the
script reports **INCONCLUSIVE** and exits 2; retry on an idle device. It never
counts a fresh-process relaunch as proof of same-process cleanup.

The separate `game/` fixture checks the actual sokol entry point and current
engine scene consumer. Build games with the CLI:

```sh
labelle build tests/android-services/game --platform=android
adb -s emulator-5554 install -r tests/android-services/game/.labelle/sokol_android/game.apk
adb -s emulator-5554 shell am start -W -n com.labelle.intent_acceptance/android.app.NativeActivity --es LABELLE_SCENE probe --es LABELLE_SCREENSHOT_PATH /sdcard/intent-probe.png --es LABELLE_SCREENSHOT_AFTER_SEC 1
adb -s emulator-5554 logcat -d -s INTENT_ACCEPTANCE:I '*:S'
```

Expected: `scene=probe env_scene=probe screenshot=<unset> after=<unset>`.
After force-stopping this test package and launching without extras, expect
`scene=main env_scene=<unset> screenshot=<unset> after=<unset>`.
The empty gamepad hooks retain the core callbacks used by sokol's JNI glue.

## Recorded acceptance (2026-09-26)

Pixel_7_API_34, Android 14 ARM64, Hypervisor.Framework on macOS, two cores / 2 GB:

- Sokol game using engine 3.4.1, core 2.1.0, gfx 2.2.0, assembler 0.113.2:
  `scene=probe env_scene=probe screenshot=<unset> after=<unset>`.
- Shared-service probe: PID **5474**, launch **1**, `scene=probe`, screenshot
  and delay unset, `debuggable=false`.
- Same cached process: PID **5474**, launch **2**, scene, screenshot and delay
  all unset, `debuggable=false`.

Sokol's upstream `sokol_app.h` explicitly calls `exit(0)` in Android onDestroy.
Consequently an actual sokol activity destroy/relaunch resets the entire process;
claiming a same-process sokol relaunch would be false. The second harness tests
that extra shared-service guarantee on Android without changing sokol's lifecycle.
These are emulator service checks, not SM-T505 graphics/resume acceptance.
