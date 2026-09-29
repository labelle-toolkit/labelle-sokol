//! SDL2 link wiring for the shared desktop gamepad source, with a clear
//! failure when SDL2 is needed but can't be found (RFC labelle-cli#471,
//! track S2).
//!
//! On a Windows target Zig has no default SDL2 search path (the MinGW
//! `windows-gnu` toolchain searches only the `-L` dirs it is given), so the
//! only way SDL2 is found is `LABELLE_SDL2_LIB` (or a working `pkg-config`).
//! Without it the old failure was a multi-line linker error ("unable to find
//! dynamic system library 'SDL2' ..."). Here the build checks up front and,
//! when SDL2 is missing, fails with ONE line instead — `missing_message`.
//!
//! The check only runs for a NATIVE Windows build (Windows target on a
//! Windows host of the same CPU arch), where the dirs Zig searches are known: the
//! `LABELLE_SDL2_LIB` dir this file adds, plus whatever the host's
//! `pkg-config` reports (Zig's own fallback, mirrored here). Everything else
//! (other targets, and cross-compiles to Windows, whose SDL2 may come from
//! paths or pkg-config setups this file can't see) keeps linking SDL2
//! exactly as before. A library dir a consumer adds to its own exe is not
//! visible here either; on Windows, point `LABELLE_SDL2_LIB` at it instead.
//!
//! The file is kept identical in labelle-bgfx, labelle-raylib and labelle-sokol.
const std = @import("std");
const builtin = @import("builtin");

/// The single line printed when SDL2 is needed but missing.
pub const missing_message = "SDL2 not found: set LABELLE_SDL2_LIB or use `.gamepad = .none`";

/// File names Zig 0.16 tries for `-lSDL2` in each library dir on a Windows
/// target (the MinGW devel package's `libSDL2.dll.a` is NOT among them, which
/// is why `labelle` copies `SDL2.dll` into the lib dir it provisions).
pub const windows_lib_names = [_][]const u8{ "SDL2.dll", "SDL2.lib", "libSDL2.a" };

/// How SDL2 will be resolved at link time — which code path `link` takes.
pub const Resolution = enum {
    /// Not a native Windows build: link SDL2 by name as before, no check.
    unchecked,
    /// Found in the `LABELLE_SDL2_LIB` dir.
    env_dir,
    /// `pkg-config` knows `sdl2`; Zig's `linkSystemLibrary` will use it.
    pkg_config,
    /// Nowhere Zig would look: fail the build with `missing_message`.
    missing,
};

/// Decide how SDL2 resolves. `probe` supplies the filesystem / pkg-config
/// lookups (real ones in `link`, fakes in the tests):
///   * `probe.hasFile(dir, name) bool`
///   * `probe.pkgConfigHasSdl2() bool`
pub fn resolve(native_windows: bool, env_lib: ?[]const u8, probe: anytype) Resolution {
    if (!native_windows) return .unchecked;
    if (env_lib) |dir| {
        if (dir.len != 0) {
            for (windows_lib_names) |name| {
                if (probe.hasFile(dir, name)) return .env_dir;
            }
        }
    }
    if (probe.pkgConfigHasSdl2()) return .pkg_config;
    return .missing;
}

pub const Options = struct {
    /// Whether this backend honours `LABELLE_SDL2_LIB` for this target
    /// (each backend keeps its existing gating rule).
    honor_env: bool,
};

/// Link SDL2 into `mod` (a module that imports the desktop gamepad source).
/// Adds `LABELLE_SDL2_LIB` as a library path when `opts.honor_env`, then
/// either links SDL2 or — native Windows build, SDL2 missing — makes every compile
/// that uses `mod` fail with `missing_message` instead of a linker error.
pub fn link(b: *std.Build, mod: *std.Build.Module, opts: Options) void {
    const target = mod.resolved_target orelse @panic("sdl2_link.link: module has no target");
    const env_lib: ?[]const u8 = if (opts.honor_env) b.graph.environ_map.get("LABELLE_SDL2_LIB") else null;
    if (env_lib) |p| {
        if (p.len != 0) mod.addLibraryPath(.{ .cwd_relative = p });
    }
    // Native = same OS AND arch as the build host: e.g. an aarch64-windows
    // build on an x86_64 Windows host is a cross-compile and is not checked.
    const native_windows = target.result.os.tag == .windows and builtin.target.os.tag == .windows and
        target.result.cpu.arch == builtin.target.cpu.arch;
    switch (resolve(native_windows, env_lib, RealProbe{ .b = b })) {
        .unchecked, .env_dir, .pkg_config => mod.linkSystemLibrary("SDL2", .{}),
        .missing => failOnUse(b, mod),
    }
}

/// Make any compile step that uses `mod` depend on a step that fails with
/// `missing_message`. A module has no step of its own, but a compile step
/// depends on the producer of every generated path in its modules — so the
/// failure is hung off a generated library dir. Only builds that actually
/// link the module fail (e.g. `--help`, or a step that doesn't use input,
/// still work), and SDL2 is not linked, so no linker error follows.
/// One gate per `std.Build`, shared by every module that needs it, so a
/// build that uses several such modules still prints the line once.
fn failOnUse(b: *std.Build, mod: *std.Build.Module) void {
    const Cache = struct {
        var owner: ?*std.Build = null;
        var gate: ?*std.Build.Step.WriteFile = null;
    };
    if (Cache.owner != b or Cache.gate == null) {
        const fail = b.addFail(missing_message);
        const gate = b.addWriteFiles();
        gate.step.dependOn(&fail.step);
        Cache.owner = b;
        Cache.gate = gate;
    }
    mod.addLibraryPath(Cache.gate.?.getDirectory());
}

const RealProbe = struct {
    b: *std.Build,

    pub fn hasFile(self: RealProbe, dir: []const u8, name: []const u8) bool {
        const io = self.b.graph.io;
        const path = self.b.pathJoin(&.{ dir, name });
        if (std.fs.path.isAbsolute(path)) {
            std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        } else {
            std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        }
        return true;
    }

    /// Mirrors Zig's own `linkSystemLibrary` fallback (it maps `-lSDL2` to
    /// the `sdl2` pkg-config package). Only runs when SDL2 wasn't found in
    /// `LABELLE_SDL2_LIB`, i.e. only on the path that would otherwise fail.
    pub fn pkgConfigHasSdl2(self: RealProbe) bool {
        const exe = self.b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
        var code: u8 = undefined;
        const out = self.b.runAllowFail(&.{ exe, "--exists", "sdl2" }, &code, .ignore) catch return false;
        self.b.allocator.free(out);
        return true;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const FakeProbe = struct {
    /// Dir that holds `file` (null = no dir holds anything).
    dir: ?[]const u8 = null,
    file: []const u8 = "SDL2.dll",
    pkg_config: bool = false,
    /// Counts lookups so tests can assert which checks ran.
    calls: *Calls,

    const Calls = struct { has_file: u32 = 0, pkg_config: u32 = 0 };

    pub fn hasFile(self: FakeProbe, dir: []const u8, name: []const u8) bool {
        self.calls.has_file += 1;
        const d = self.dir orelse return false;
        return std.mem.eql(u8, d, dir) and std.mem.eql(u8, self.file, name);
    }

    pub fn pkgConfigHasSdl2(self: FakeProbe) bool {
        self.calls.pkg_config += 1;
        return self.pkg_config;
    }
};

test "resolve: non-native-Windows builds (other targets, cross to Windows) are never checked" {
    var calls: FakeProbe.Calls = .{};
    try std.testing.expectEqual(Resolution.unchecked, resolve(false, null, FakeProbe{ .calls = &calls }));
    try std.testing.expectEqual(Resolution.unchecked, resolve(false, "/nowhere", FakeProbe{ .calls = &calls }));
    // No filesystem or pkg-config lookups at all off Windows.
    try std.testing.expectEqual(@as(u32, 0), calls.has_file);
    try std.testing.expectEqual(@as(u32, 0), calls.pkg_config);
}

test "resolve: SDL2 in LABELLE_SDL2_LIB wins without consulting pkg-config" {
    inline for (windows_lib_names) |name| {
        var calls: FakeProbe.Calls = .{};
        const probe: FakeProbe = .{ .dir = "C:/sdl2/lib", .file = name, .pkg_config = true, .calls = &calls };
        try std.testing.expectEqual(Resolution.env_dir, resolve(true, "C:/sdl2/lib", probe));
        try std.testing.expectEqual(@as(u32, 0), calls.pkg_config);
    }
}

test "resolve: an import lib alone is not enough (Zig does not search libSDL2.dll.a)" {
    var calls: FakeProbe.Calls = .{};
    const probe: FakeProbe = .{ .dir = "C:/sdl2/lib", .file = "libSDL2.dll.a", .calls = &calls };
    try std.testing.expectEqual(Resolution.missing, resolve(true, "C:/sdl2/lib", probe));
}

test "resolve: pkg-config is the fallback when the env dir has no SDL2" {
    var calls: FakeProbe.Calls = .{};
    const probe: FakeProbe = .{ .pkg_config = true, .calls = &calls };
    try std.testing.expectEqual(Resolution.pkg_config, resolve(true, "C:/empty", probe));
    try std.testing.expectEqual(@as(u32, windows_lib_names.len), calls.has_file);
    try std.testing.expectEqual(@as(u32, 1), calls.pkg_config);
}

test "resolve: forced missing case — env unset, empty, or pointing at an empty dir" {
    const envs = [_]?[]const u8{ null, "", "C:/empty" };
    for (envs) |env| {
        var calls: FakeProbe.Calls = .{};
        try std.testing.expectEqual(Resolution.missing, resolve(true, env, FakeProbe{ .calls = &calls }));
        // It reached the missing branch only after trying pkg-config.
        try std.testing.expectEqual(@as(u32, 1), calls.pkg_config);
    }
}

test "missing_message is one line naming both fixes" {
    try std.testing.expect(std.mem.indexOfScalar(u8, missing_message, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, missing_message, "LABELLE_SDL2_LIB") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_message, ".gamepad = .none") != null);
}

/// `zig build sdl2-link-check`: compiles a tiny binary for `target` through
/// the real `link` wiring, so CI can force the missing case (point
/// `LABELLE_SDL2_LIB` at an empty dir on Windows) and assert the build fails
/// with exactly `missing_message` — or, with SDL2 present, that it links.
/// `sdl_needed` is the backend's own "is the SDL gamepad source wired"
/// predicate, so `-Dgamepad_enabled=false` (`.gamepad = .none`) must build
/// with SDL2 absent.
pub fn addCheckStep(b: *std.Build, target: std.Build.ResolvedTarget, sdl_needed: bool, opts: Options) void {
    const step = b.step("sdl2-link-check", "Link tiny binaries against SDL2 via the backend's SDL2 wiring (fails with one line when SDL2 is missing)");
    // Two independent modules, like a real build's exe + host test module:
    // proves the missing-SDL2 line is still printed only once.
    for ([_][]const u8{ "sdl2-link-check", "sdl2-link-check-2" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path("sdl2_link.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        if (sdl_needed) link(b, mod, opts);
        const exe = b.addTest(.{ .name = name, .root_module = mod });
        step.dependOn(&exe.step);
    }
}
