const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android });
    const dep = b.dependency("labelle_android", .{ .target = target, .optimize = .Debug });
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{.{ .name = "labelle_android", .module = dep.module("labelle_android") }},
    });
    const ndk = @import("labelle_android").addAndroidSysroot(b, mod, target);
    const lib = b.addLibrary(.{ .name = "probe", .linkage = .dynamic, .root_module = mod });
    const libc = b.addWriteFiles().add("libc.txt", b.fmt("include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", .{ ndk.inc_common, ndk.inc_arch, ndk.lib_path }));
    lib.setLibCFile(libc);
    b.installArtifact(lib);
}
