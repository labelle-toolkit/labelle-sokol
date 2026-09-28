# Sokol iOS build fixture

A minimal project (one rectangle, `.gamepad = .none`) that builds the sokol
backend for iOS. It pins the backend to this checkout (`local:../..`) and
released core/engine/gfx. The `ios-build` CI job (RFC labelle-cli#471 I0) runs
the released assembler on a clean macOS runner:

```sh
labelle-assembler install --project-root .
labelle-assembler generate --project-root . --platform ios
cd .labelle/sokol_ios
zig build -Doptimize=ReleaseFast                  # aarch64-ios-simulator on Apple Silicon
zig build -Doptimize=ReleaseFast -Ddevice=true    # aarch64-ios, compile-only
```

The generated build resolves the SDK with `xcrun` (`backend.hook.zig`), so it
needs Xcode with its license accepted. Both builds write `zig-out/bin/game`.
Nothing is signed, wrapped in a `.app` or launched: that is the labelle-ios
provider's job (#471 I1).
