//! sokol backend build hook (manifest-v2, epic labelle-assembler#453 / #461) —
//! the DEDICATED hook file the v2 manifest points at via
//! `.build_hook = "backend.hook.zig"` (design §3/§4). It is NOT sokol's own
//! `build.zig`: that file re-exports `pub const emLinkStep = @import("sokol").emLinkStep;`
//! at top level, and `"sokol"` is a name resolvable only inside the labelle_sokol
//! package build context — absent from the generated ROOT package the assembler
//! imports the hook into. So the hook makes NO package-local import assumptions:
//! it may `@import("std")` (and `@import("builtin")` for the host tag) and take
//! everything else through the hook context.
//!
//! ## android + ios are the HOOK-BEARING conversions
//!
//! DESKTOP has no residual: it is fully declarative and `.target = .native`
//! resolves without a hook, so the assembler never invokes this hook on a
//! desktop build. ANDROID and IOS each exercise BOTH hook phases:
//!
//!   * `resolve_target` — runs BEFORE any `b.dependency` and produces the
//!     platform `ResolvedTarget`. Android: from `-Demulator`/`-Dandroid_arch` +
//!     host arch, reproducing the enum path's `header_android` target-resolution
//!     block. iOS: runs `xcrun` SDK-path discovery + device/simulator selection
//!     from `-Ddevice` + host arch, reproducing the enum path's `header_ios`
//!     build-fn head — and it ALSO returns the iOS SDK path, because plugin
//!     `b.dependency` calls consume it and it therefore MUST be resolved before
//!     ANY dependency (design §4 review-correction #6).
//!   * `post_wire` — runs AFTER the generic module/artifact/system-lib wiring and
//!     supplements the graph with the residual the manifest cannot express
//!     statically. Android (design §2 residual (a)): NDK sysroot detection + the
//!     `addSystemIncludePath`/`addLibraryPath` calls that consume it + the
//!     `libc.txt` generation. iOS (design §2 residual (b)): the `configureSdkPaths`
//!     / `addExeSdkPaths` calls that consume the SDK path resolved in
//!     `resolve_target`. The iOS frameworks + `link_libc` are DECLARATIVE
//!     (`.frameworks.ios`), emitted by the assembler, NOT here.
//!
//! ## wasm is the emcc residual (design §2 (c))
//!
//! wasm has NO `resolve_target` (its target is the STATIC `.triple`
//! "wasm32-emscripten", design §3, resolved directly in the generated build.zig).
//! Its `post_wire` .wasm arm supplies design §2 residual (c): the Emscripten
//! `emcc` link step (enum `.link_sokol_wasm`) plus the install/run wiring (enum
//! `.wasm_footer`). The enum path reaches emcc via
//! `@import("labelle_sokol").emLinkStep` — but the hook is std-only and CANNOT
//! import the provider package, so `emLinkStep` is reconstructed here
//! (`emLinkStep` below) from ONLY `std.Build` + the emsdk dependency, which the
//! hook resolves via `b.dependency("emsdk", .{})`. That call is why the manifest
//! declares `.platforms.wasm.root_build_deps = emsdk` and the assembler emits
//! emsdk into the generated `build.zig.zon` (design §3 `RootBuildDep`). Because
//! `post_wire` returns `void` it also owns the install/run wiring (the enum
//! `emcc_step` local cannot escape a void hook back to the build fn), so the v2
//! wasm path does NOT emit the `.wasm_footer`/packager `.web` block.
//!
//! The generated v2 build.zig `@import`s this file (as a sibling
//! `backend_build_hook.zig`) and calls the two functions; that import is the
//! design's "assembler imports the hook into the generated root package" (§3).
//! The whole v2 route is gated-dark (opt-in via the assembler's
//! `backend_manifest_name`), so android/ios/wasm are exercised through the
//! golden-cell + hook gates, not a production android/ios/wasm build.

const std = @import("std");
const builtin = @import("builtin");

/// Versioned with the hook ABI (design §4). Asserted `== HOOK_ABI_VERSION` by the
/// assembler before the hook is ever called; matches
/// `manifest_v2.HOOK_ABI_VERSION`.
pub const HOOK_ABI_VERSION: u8 = 2;

/// The platform tag the hook branches on. Mirrors `config.Platform` structurally
/// so the hook needs no assembler import.
pub const Platform = enum { desktop, ios, android, wasm };

/// Error surface for the pure decision helpers (so they stay unit-testable
/// without a live `*std.Build` and without an uncatchable `@panic`). The
/// `resolve_target`/`post_wire` entry points turn these into a `@panic` at the
/// call site — a misconfiguration is a hard build error, not a recoverable one —
/// but the underlying logic is exercised through the error return in tests.
pub const HookError = error{
    /// `-Dandroid_arch=<v>` was neither arm64/aarch64 nor x86_64/x64.
    InvalidAndroidArch,
    /// `ctx.android_target_sdk` was null on an Android build. The assembler MUST
    /// populate it (from `cfg.android.target_sdk_version`, always a concrete
    /// value) — a null is an assembler bug, and a silent `orelse 34` would emit a
    /// wrong `usr/lib/<triple>/34` path while appearing to honor the user's
    /// `target_sdk_version` (design §4 review-correction #6). So this is a hard
    /// error, never a default.
    AndroidTargetSdkRequired,
    /// `ctx.ios_sdk_path` was null on an iOS build. `resolve_target` resolves it
    /// (via xcrun) BEFORE any dependency and the assembler threads it into the
    /// `post_wire` context, so a null here is an assembler bug — a hard error,
    /// never a silent skip that would leave the SDK include/lib paths unset.
    IosSdkPathRequired,
};

// ── resolve_target (design §4) — runs BEFORE any b.dependency ──────────────

/// What the pre-dependency `resolve_target` phase returns: the `ResolvedTarget`
/// every subsequent `b.dependency` (backend + plugins) consumes, plus the iOS SDK
/// path plugin dependency calls need (null on non-iOS). Android carries only the
/// target; the NDK sysroot is detected later in `post_wire` (it is not needed
/// before the dependency calls).
pub const ResolvedTargetInfo = struct {
    target: std.Build.ResolvedTarget,
    ios_sdk_path: ?[]const u8 = null,
};

/// Context handed to `resolve_target`. Only the platform is needed today; kept a
/// struct so future fields (e.g. an explicit device/simulator override for iOS)
/// are additive.
pub const ResolveContext = struct {
    platform: Platform,
};

/// PURE arch selection — the testable core of the android target resolution.
/// `-Dandroid_arch` wins when set (arm64|x86_64); otherwise `-Demulator` picks
/// the host-matching arch (arm64 on Apple Silicon, x86_64 on Intel); otherwise
/// arm64. Returns an error on an unknown explicit arch so the caller can decide
/// whether to panic (build) or assert (test).
pub fn selectAndroidArch(
    host_arch: std.Target.Cpu.Arch,
    emulator_mode: bool,
    arch_opt: ?[]const u8,
) HookError!std.Target.Cpu.Arch {
    if (arch_opt) |name| {
        if (std.mem.eql(u8, name, "arm64") or std.mem.eql(u8, name, "aarch64")) return .aarch64;
        if (std.mem.eql(u8, name, "x86_64") or std.mem.eql(u8, name, "x64")) return .x86_64;
        return HookError.InvalidAndroidArch;
    }
    const emulator_arch: std.Target.Cpu.Arch = switch (host_arch) {
        .aarch64 => .aarch64,
        else => .x86_64,
    };
    return if (emulator_mode) emulator_arch else .aarch64;
}

/// PURE NDK triple mapping. The `usr/include/<triple>` and
/// `usr/lib/<triple>/<api>` NDK paths are keyed by this.
pub fn ndkArchTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        // resolve_target only ever produces the two arches above; a third would
        // be an assembler bug, not a user error.
        else => "aarch64-linux-android",
    };
}

// ── iOS target/SDK resolution (design §4) — pure decision helpers ──────────

/// PURE SDK-name selection: `-Ddevice` picks the device SDK (`iphoneos`), else
/// the simulator SDK (`iphonesimulator`). The value is passed to
/// `xcrun --sdk <name> --show-sdk-path`.
pub fn iosSdkName(device_mode: bool) []const u8 {
    return if (device_mode) "iphoneos" else "iphonesimulator";
}

/// A resolved iOS target QUERY — the pure decision output of `selectIosTarget`,
/// turned into a `std.Target.Query` by `resolve_target`. Kept as data (not a live
/// `ResolvedTarget`) so the device/simulator/host-arch branch is unit-testable
/// without a `*std.Build`.
pub const IosTargetSpec = struct {
    cpu_arch: std.Target.Cpu.Arch,
    /// `.simulator` for a simulator build; null for a physical device (which
    /// takes the default iOS abi).
    abi: ?std.Target.Abi,
    /// Apple-Silicon simulator needs an explicit `apple_a14` cpu model; device +
    /// Intel-simulator do not.
    apple_a14: bool,
};

/// PURE iOS target selection. `-Ddevice` → `aarch64-ios`; simulator on an Intel
/// host → `x86_64-ios-simulator`; simulator on an Apple-Silicon host →
/// `aarch64-ios-simulator` + `apple_a14`. Names no backend, so it is the
/// assembler-generic default (design §4).
pub fn selectIosTarget(device_mode: bool, host_arch: std.Target.Cpu.Arch) IosTargetSpec {
    if (device_mode) return .{ .cpu_arch = .aarch64, .abi = null, .apple_a14 = false };
    if (host_arch == .x86_64) return .{ .cpu_arch = .x86_64, .abi = .simulator, .apple_a14 = false };
    return .{ .cpu_arch = .aarch64, .abi = .simulator, .apple_a14 = true };
}

/// Get the iOS SDK path via `xcrun`. Mirrors the enum path's `header_ios` SDK
/// discovery so the residual behaves identically. Runs BEFORE any `b.dependency`
/// (its result feeds plugin dependency calls) and constructs no graph nodes.
/// Returns null when Xcode/xcrun is unavailable so the caller can panic with a
/// readable message.
fn getIosSdkPath(b: *std.Build, sdk_name: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (result.term == .Exited and result.term.Exited == 0) {
        const path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (path.len == 0) return null;
        return b.allocator.dupe(u8, path) catch null;
    }
    return null;
}

/// Produce the android/ios `ResolvedTarget`. Runs before any `b.dependency`, so
/// it constructs no graph nodes.
pub fn resolve_target(b: *std.Build, ctx: ResolveContext) ResolvedTargetInfo {
    switch (ctx.platform) {
        .ios => {
            // `xcrun` SDK discovery + device/simulator selection, BEFORE any
            // b.dependency (the SDK path feeds plugin dependency calls — §4).
            const device_mode = b.option(bool, "device", "Build for iOS device instead of simulator") orelse false;
            const sdk_name = iosSdkName(device_mode);
            const sdk_path = getIosSdkPath(b, sdk_name) orelse
                @panic("Could not find iOS SDK. Is Xcode installed?");

            const spec = selectIosTarget(device_mode, b.graph.host.result.cpu.arch);
            var query: std.Target.Query = .{ .cpu_arch = spec.cpu_arch, .os_tag = .ios };
            if (spec.abi) |abi| query.abi = abi;
            if (spec.apple_a14) query.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a14 };
            return .{ .target = b.resolveTargetQuery(query), .ios_sdk_path = sdk_path };
        },
        .android => {
            const emulator_mode = b.option(bool, "emulator", "Build for Android emulator (x86_64 on Intel Mac, arm64 on Apple Silicon)") orelse false;
            const android_arch_opt = b.option([]const u8, "android_arch", "Android target arch (arm64|x86_64). Overrides -Demulator when set.");
            const android_arch = selectAndroidArch(b.graph.host.result.cpu.arch, emulator_mode, android_arch_opt) catch {
                std.debug.print("build.zig: unknown -Dandroid_arch value (expected arm64 or x86_64)\n", .{});
                @panic("invalid android_arch");
            };
            return .{ .target = b.resolveTargetQuery(.{
                .cpu_arch = android_arch,
                .os_tag = .linux,
                .abi = .android,
            }) };
        },
        // desktop=.native and wasm=.triple resolve their target without a hook,
        // so resolve_target is never called for them.
        else => @panic("resolve_target: only ios/android use resolved targets"),
    }
}

// ── post_wire (design §4) — runs AFTER generic wiring ──────────────────────

/// `post_wire` context (design §4). Every field is valid because `post_wire` runs
/// strictly AFTER `b.dependency` and after the root exe/lib is created. Kept
/// structurally in sync with `manifest_v2.HookContext`.
pub const HookContext = struct {
    manifest_version: u8,
    backend_dep: *std.Build.Dependency,
    root_module: *std.Build.Module,
    root_artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    ios_sdk_path: ?[]const u8,
    android_target_sdk: ?u32,
};

/// REQUIRED android SDK accessor — the testable enforcement of "no silent 34
/// default" (design §4 review-correction #6). Returns an error on null so the
/// error path is unit-testable; `post_wire` turns it into a `@panic`.
pub fn requireAndroidSdk(ctx: HookContext) HookError!u32 {
    return ctx.android_target_sdk orelse HookError.AndroidTargetSdkRequired;
}

/// REQUIRED iOS SDK-path accessor — the testable enforcement of "the SDK path
/// resolved in `resolve_target` is threaded into `post_wire`". Returns an error on
/// null so the error path is unit-testable; `post_wire` turns it into a `@panic`.
pub fn requireIosSdk(ctx: HookContext) HookError![]const u8 {
    return ctx.ios_sdk_path orelse HookError.IosSdkPathRequired;
}

/// PURE libc.txt body builder. Zig does not bundle Android libc, so the generated
/// `.so` build needs a `libc.txt` pointing the compiler at the NDK sysroot. Takes
/// pre-joined paths so it is unit-testable without a `*std.Build`; `post_wire`
/// joins the paths via `b.pathJoin` and calls this. Caller owns the returned slice.
pub fn libcTxt(
    allocator: std.mem.Allocator,
    include_dir: []const u8,
    sys_include_dir: []const u8,
    crt_dir: []const u8,
) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "include_dir=",     include_dir,     "\n",
        "sys_include_dir=", sys_include_dir, "\n",
        "crt_dir=",         crt_dir,         "\n",
        "msvc_lib_dir=\n",
        "kernel32_lib_dir=\n",
        "gcc_dir=\n",
    });
}

/// Detect the Android NDK sysroot. Mirrors the enum path's `header_android` so the
/// residual behaves identically — env lookups go through `b.graph.environ_map`, FS
/// probes through `std.Io.Dir.cwd().access(io, ...)` (Zig 0.16 removed the older
/// APIs).
fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const sysroot = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
            return sysroot;
        } else |_| {}
    }
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        // Collect every version dir together with WHETHER it actually has a
        // usable sysroot, then pick the greatest VALID one. A stray/partial NDK
        // install (or a lexicographically-greater dir with no sysroot) must NOT
        // shadow an older, valid NDK — checking validity only AFTER picking the
        // greatest dir made us miss it and panic.
        var candidates: std.ArrayList(NdkCandidate) = .empty;
        defer {
            for (candidates.items) |c| b.allocator.free(c.name);
            candidates.deinit(b.allocator);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = b.allocator.dupe(u8, entry.name) catch continue;
            const sysroot = b.pathJoin(&.{ ndk_dir, name, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
            const has_sysroot = if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| true else |_| false;
            candidates.append(b.allocator, .{ .name = name, .has_sysroot = has_sysroot }) catch {
                b.allocator.free(name);
                continue;
            };
        }
        if (selectGreatestValidNdk(candidates.items)) |version| {
            return b.pathJoin(&.{ ndk_dir, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        }
    }
    return null;
}

/// A candidate `$ANDROID_HOME/ndk/<name>` dir paired with whether its
/// `toolchains/llvm/prebuilt/<host>/sysroot` actually exists.
const NdkCandidate = struct { name: []const u8, has_sysroot: bool };

/// Pick the lexicographically-greatest NDK version dir that HAS a valid sysroot.
/// Validity is part of the selection (not an after-the-fact check on the greatest
/// dir), so a stray/partial install can't shadow an older valid NDK. Returns a
/// borrowed slice from `candidates` or null when none valid.
fn selectGreatestValidNdk(candidates: []const NdkCandidate) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (candidates) |c| {
        if (!c.has_sysroot) continue;
        if (best) |prev| {
            if (std.mem.order(u8, c.name, prev) == .gt) best = c.name;
        } else {
            best = c.name;
        }
    }
    return best;
}

fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

// ── wasm emcc residual (design §2 (c)) — the emLinkStep reconstruction ──────
//
// The enum path links wasm via `@import("labelle_sokol").emLinkStep`, which
// re-exports sokol-zig's `emLinkStep`. The hook is std-only and cannot import the
// provider package, so the step is reconstructed here from ONLY `std.Build` + the
// emsdk dependency. This is a faithful port of sokol-zig's `emLinkStep` (which is
// itself pure `std.Build` — it locates `emcc` through `emsdk.path(...)` and shells
// out), so the emitted emcc command line matches the enum path. The emsdk
// dependency is resolved by `b.dependency` (declared as a root build dep via the
// manifest's `.root_build_deps`).

/// The C-stack bump the sokol wasm build needs — Emscripten defaults to a 64 KB
/// stack, which the engine's scene-load + atlas-decode path overflows into the
/// WASM `.data` segment (labelle-cli#201). Mirrors the enum `.link_sokol_wasm`
/// `extra_args`. Kept a named constant so the residual decision is unit-testable
/// without a live `*std.Build`.
pub const wasm_stack_size_arg = "-sSTACK_SIZE=512KB";

/// Options for `emLinkStep` — the subset of sokol-zig's `EmLinkOptions` the wasm
/// residual sets. Uses only `std.Build`/`std.builtin` types so the hook stays
/// provider-import-free.
pub const EmLinkOptions = struct {
    optimize: std.builtin.OptimizeMode,
    /// The Zig code compiled to a static lib that emcc links into the module.
    lib_main: *std.Build.Step.Compile,
    /// The emsdk dependency, resolved by the caller via `b.dependency("emsdk", .{})`.
    emsdk: *std.Build.Dependency,
    release_use_closure: bool = true,
    release_use_lto: bool = true,
    use_webgl2: bool = false,
    use_filesystem: bool = true,
    shell_file_path: ?std.Build.LazyPath = null,
    extra_args: []const []const u8 = &.{},
};

/// Path to an emscripten tool (e.g. `emcc`) inside the resolved emsdk dependency.
/// Mirrors sokol-zig's `emTool`/`emSdkLazyPath`.
fn emTool(b: *std.Build, emsdk: *std.Build.Dependency, tool: []const u8) std.Build.LazyPath {
    return emsdk.path(b.fmt("upstream/emscripten/{s}", .{tool}));
}

/// Reconstruction of sokol-zig's `emLinkStep` using only `std.Build` + the emsdk
/// dependency. Builds the `emcc` shell-out that links `lib_main` (and its
/// transitive static libs, e.g. `sokol_clib`) into the `.html`/`.wasm`/`.js`
/// module and installs them under `web/`. Returns the install step so the caller
/// can wire it into `b.getInstallStep()` + the run step.
pub fn emLinkStep(b: *std.Build, options: EmLinkOptions) *std.Build.Step.InstallDir {
    // Pass emcc as a LazyPath via addFileArg so the emsdk path resolves lazily at
    // step-execution time — NOT eagerly at build-configuration time. Calling
    // `.getPath(b)` here would force resolution during configure and break lazy
    // evaluation. `Run.create` + `addFileArg` is the lazy-safe form; the step name
    // "emcc" also hides the resolved path in the log.
    const emcc = std.Build.Step.Run.create(b, "emcc");
    emcc.addFileArg(emTool(b, options.emsdk, "emcc"));
    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" });
    } else {
        // Non-Debug: optimize. Disable assertions for the fastest/smallest builds,
        // but KEEP them for ReleaseSafe (a safety build).
        if (options.optimize != .ReleaseSafe) emcc.addArg("-sASSERTIONS=0");
        if (options.optimize == .ReleaseSmall) {
            emcc.addArg("-Oz");
        } else {
            emcc.addArg("-O3");
        }
        if (options.release_use_lto) emcc.addArg("-flto");
        if (options.release_use_closure) emcc.addArgs(&.{ "--closure", "1" });
    }
    if (options.use_webgl2) emcc.addArg("-sUSE_WEBGL2=1");
    if (!options.use_filesystem) emcc.addArg("-sNO_FILESYSTEM=1");
    if (options.shell_file_path) |shell_file_path| {
        emcc.addPrefixedFileArg("--shell-file=", shell_file_path);
    }
    for (options.extra_args) |arg| emcc.addArg(arg);

    // The main lib, then every static-lib dependency (e.g. sokol_clib).
    emcc.addArtifactArg(options.lib_main);
    for (options.lib_main.getCompileDependencies(false)) |item| {
        if (item.kind == .lib) emcc.addArtifactArg(item);
    }
    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.lib_main.name}));

    // emcc emits 3 files (.html/.wasm/.js) into out_file's dir → install to web/.
    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

/// Runs AFTER the generic module/artifact/system-lib/framework wiring, to
/// supplement the graph with the residual the manifest cannot express statically
/// (design §2). DESKTOP is empty (no residual). ANDROID does the NDK sysroot
/// include/lib paths + libc.txt (the generic parts — `linkLibrary`,
/// `linkSystemLibrary`, `link_libc`, artifact `.pic` — are emitted declaratively
/// by the assembler from the manifest, NOT here). iOS consumes the resolved SDK
/// path; wasm runs the emcc link step.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .desktop => {}, // fully declarative — no residual
        .android => {
            const sysroot = getAndroidNdkSysroot(b) orelse
                @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
            // REQUIRED — no `orelse 34` fallback (design §4 review-correction #6).
            const api = requireAndroidSdk(ctx) catch
                @panic("android_target_sdk must be populated for Android builds");
            const triple = ndkArchTriple(ctx.target.result.cpu.arch);
            const api_str = b.fmt("{d}", .{api});

            const include_dir = b.pathJoin(&.{ sysroot, "usr/include" });
            const sys_include_dir = b.pathJoin(&.{ sysroot, "usr/include", triple });
            const crt_dir = b.pathJoin(&.{ sysroot, "usr/lib", triple, api_str });

            // C header include paths on the sokol_clib archive (the .pic on it is
            // set declaratively by the assembler).
            const clib = ctx.backend_dep.artifact("sokol_clib");
            clib.root_module.addSystemIncludePath(.{ .cwd_relative = include_dir });
            clib.root_module.addSystemIncludePath(.{ .cwd_relative = sys_include_dir });

            // Per-API NDK library path + libc.txt on the .so root.
            ctx.root_artifact.root_module.addLibraryPath(.{ .cwd_relative = crt_dir });
            const libc_content = libcTxt(b.allocator, include_dir, sys_include_dir, crt_dir) catch @panic("OOM");
            const android_libc = b.addWriteFiles();
            ctx.root_artifact.setLibCFile(android_libc.add("android-libc.txt", libc_content));
        },
        .ios => {
            // Consume the SDK path resolved in `resolve_target` (design §2
            // residual (b)) — the iOS frameworks + `link_libc` are DECLARATIVE
            // (`.frameworks.ios`), emitted by the assembler, NOT here. REQUIRED:
            // a null is an assembler bug (resolve_target always resolves it), so
            // this panics rather than silently skipping the SDK paths.
            const sdk_path = requireIosSdk(ctx) catch
                @panic("ios_sdk_path must be populated for iOS builds");

            // C-header compilation on the backend's clib archive.
            const clib = ctx.backend_dep.artifact("sokol_clib");
            clib.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) });
            clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
            clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/SubFrameworks" }) });

            // Exe SDK library + framework search paths.
            ctx.root_artifact.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) });
            ctx.root_artifact.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
        },
        .wasm => {
            // Residual (c): the Emscripten emcc link step + install/run wiring
            // (enum `.link_sokol_wasm` + `.wasm_footer`). emsdk is resolved via
            // `b.dependency` — declared as a root build dep by the manifest's
            // `.root_build_deps` and emitted into the generated build.zig.zon.
            // The declarative `linkLibrary(sokol_clib)` is emitted by the
            // assembler BEFORE this call; emcc scans the lib's transitive static
            // deps, so `sokol_clib` lands on the emcc command line here.
            const emsdk = b.dependency("emsdk", .{});
            const install = emLinkStep(b, .{
                .optimize = ctx.optimize,
                .lib_main = ctx.root_artifact,
                .emsdk = emsdk,
                .shell_file_path = null,
                .use_webgl2 = true,
                .release_use_closure = false,
                .extra_args = &.{wasm_stack_size_arg},
            });
            // `post_wire` is void, so the enum `emcc_step` local cannot escape to
            // the build fn for a packager footer — the hook wires install/run
            // itself (enum `.wasm_footer`).
            b.getInstallStep().dependOn(&install.step);
            const run_step = b.step("run", "Serve WASM build");
            run_step.dependOn(&install.step);
        },
    }
}

// ============================================================================
// Tests — the PURE residual/decision helpers (design §7 "run the hook").
//
// These assert the residual DECISIONS (arch selection, NDK triple, required-SDK
// enforcement, libc.txt body, wasm stack bump, iOS target/SDK selection). The
// live-graph functions `resolve_target`/`post_wire` are typechecked against the
// real `std.Build` API by compiling this file — a compile-level gate that a
// residual API call (addLibraryPath/setLibCFile/linkSystemLibrary/…) stays valid.
// ============================================================================

const testing = std.testing;

test "selectAndroidArch: explicit -Dandroid_arch wins (both spellings)" {
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, "arm64"));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, true, "aarch64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, false, "x86_64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, true, "x64"));
}

test "selectAndroidArch: emulator picks host arch; default is arm64" {
    // No explicit arch, emulator on → host-matching.
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, true, null));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.x86_64, true, null));
    // No explicit arch, no emulator → arm64 device default regardless of host.
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, false, null));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, null));
}

test "selectAndroidArch: unknown explicit arch is an error, not a silent default" {
    try testing.expectError(HookError.InvalidAndroidArch, selectAndroidArch(.aarch64, false, "riscv64"));
}

test "ndkArchTriple: the two resolvable arches map to the NDK triples" {
    try testing.expectEqualStrings("aarch64-linux-android", ndkArchTriple(.aarch64));
    try testing.expectEqualStrings("x86_64-linux-android", ndkArchTriple(.x86_64));
}

test "requireAndroidSdk: present value is returned; null is a hard error (no 34 default)" {
    const base: HookContext = .{
        .manifest_version = HOOK_ABI_VERSION,
        .backend_dep = undefined,
        .root_module = undefined,
        .root_artifact = undefined,
        .target = undefined,
        .optimize = .Debug,
        .platform = .android,
        .ios_sdk_path = null,
        .android_target_sdk = 30,
    };
    try testing.expectEqual(@as(u32, 30), try requireAndroidSdk(base));

    var missing = base;
    missing.android_target_sdk = null;
    try testing.expectError(HookError.AndroidTargetSdkRequired, requireAndroidSdk(missing));
}

test "libcTxt: body points the compiler at the NDK sysroot (matches the enum block)" {
    const out = try libcTxt(
        testing.allocator,
        "/ndk/sysroot/usr/include",
        "/ndk/sysroot/usr/include/aarch64-linux-android",
        "/ndk/sysroot/usr/lib/aarch64-linux-android/34",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "include_dir=/ndk/sysroot/usr/include\n" ++
            "sys_include_dir=/ndk/sysroot/usr/include/aarch64-linux-android\n" ++
            "crt_dir=/ndk/sysroot/usr/lib/aarch64-linux-android/34\n" ++
            "msvc_lib_dir=\n" ++
            "kernel32_lib_dir=\n" ++
            "gcc_dir=\n",
        out,
    );
}

test "HOOK_ABI_VERSION is 2 (matches manifest_v2)" {
    try testing.expectEqual(@as(u8, 2), HOOK_ABI_VERSION);
}

test "wasm_stack_size_arg matches the enum .link_sokol_wasm 512 KB stack bump" {
    // The wasm emcc residual (design §2 (c)) must reproduce the enum path's
    // `-sSTACK_SIZE=512KB` or the engine's atlas-decode path corrupts the WASM
    // `.data` segment (labelle-cli#201). The `emLinkStep` reconstruction itself is
    // typechecked against std.Build by compiling this file; this pins the one pure
    // decision it carries.
    try testing.expectEqualStrings("-sSTACK_SIZE=512KB", wasm_stack_size_arg);
}

test "iosSdkName: -Ddevice picks iphoneos, else iphonesimulator" {
    try testing.expectEqualStrings("iphoneos", iosSdkName(true));
    try testing.expectEqualStrings("iphonesimulator", iosSdkName(false));
}

test "selectIosTarget: device is aarch64-ios (no simulator abi, no apple_a14)" {
    // -Ddevice → aarch64-ios regardless of host arch.
    const dev_on_intel = selectIosTarget(true, .x86_64);
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, dev_on_intel.cpu_arch);
    try testing.expectEqual(@as(?std.Target.Abi, null), dev_on_intel.abi);
    try testing.expectEqual(false, dev_on_intel.apple_a14);

    const dev_on_arm = selectIosTarget(true, .aarch64);
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, dev_on_arm.cpu_arch);
    try testing.expectEqual(@as(?std.Target.Abi, null), dev_on_arm.abi);
    try testing.expectEqual(false, dev_on_arm.apple_a14);
}

test "selectIosTarget: simulator arch follows the host (Intel x86_64, Apple-Silicon aarch64+apple_a14)" {
    // Intel host simulator → x86_64-ios-simulator, no apple_a14.
    const sim_intel = selectIosTarget(false, .x86_64);
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, sim_intel.cpu_arch);
    try testing.expectEqual(@as(?std.Target.Abi, .simulator), sim_intel.abi);
    try testing.expectEqual(false, sim_intel.apple_a14);

    // Apple-Silicon host simulator → aarch64-ios-simulator + apple_a14.
    const sim_arm = selectIosTarget(false, .aarch64);
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, sim_arm.cpu_arch);
    try testing.expectEqual(@as(?std.Target.Abi, .simulator), sim_arm.abi);
    try testing.expectEqual(true, sim_arm.apple_a14);
}

test "requireIosSdk: present path is returned; null is a hard error (no silent skip)" {
    const base: HookContext = .{
        .manifest_version = HOOK_ABI_VERSION,
        .backend_dep = undefined,
        .root_module = undefined,
        .root_artifact = undefined,
        .target = undefined,
        .optimize = .Debug,
        .platform = .ios,
        .ios_sdk_path = "/Xcode/iPhoneSimulator.sdk",
        .android_target_sdk = null,
    };
    try testing.expectEqualStrings("/Xcode/iPhoneSimulator.sdk", try requireIosSdk(base));

    var missing = base;
    missing.ios_sdk_path = null;
    try testing.expectError(HookError.IosSdkPathRequired, requireIosSdk(missing));
}

test "selectGreatestValidNdk: a stray dir doesn't shadow a valid older NDK" {
    // "27.0.0" sorts greatest but has NO sysroot (stray/partial install); the
    // greatest VALID dir is "26.1.10909125" — the old "greatest dir then check"
    // logic would have picked 27 and missed it.
    const c1 = [_]NdkCandidate{
        .{ .name = "25.2.9519653", .has_sysroot = true },
        .{ .name = "26.1.10909125", .has_sysroot = true },
        .{ .name = "27.0.0", .has_sysroot = false },
    };
    try testing.expectEqualStrings("26.1.10909125", selectGreatestValidNdk(&c1).?);

    // All valid → the greatest is chosen.
    const c2 = [_]NdkCandidate{
        .{ .name = "25.2.9519653", .has_sysroot = true },
        .{ .name = "26.1.10909125", .has_sysroot = true },
    };
    try testing.expectEqualStrings("26.1.10909125", selectGreatestValidNdk(&c2).?);

    // No valid candidate → null (caller then falls through / panics upstream).
    const c3 = [_]NdkCandidate{
        .{ .name = "27.0.0", .has_sysroot = false },
    };
    try testing.expectEqual(@as(?[]const u8, null), selectGreatestValidNdk(&c3));

    // Empty set → null.
    try testing.expectEqual(@as(?[]const u8, null), selectGreatestValidNdk(&.{}));
}
