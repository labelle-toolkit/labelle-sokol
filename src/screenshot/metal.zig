//! Metal pixel readback for screenshot capture (labelle-assembler#213).
//!
//! Strategy: grab a source `MTLTexture`, blit it into a freshly-allocated
//! MTLBuffer with storageModeShared (macOS) / storageModeManaged +
//! synchronize (iOS), then read bytes. Two entry points share the
//! `blitTextureToBuffer` core:
//!   - `readback` (windowed): source = current `CAMetalDrawable.texture`.
//!   - `readbackFromTexture` (headless, assembler#368): source = the
//!     offscreen color attachment sokol-gfx rendered into, since the
//!     swapchain drawable is invalid when sokol_app never ran.
//! Both source textures are BGRA8Unorm — we copy bytes verbatim and let
//! `screenshot.bmp.writeBmpFromBgra` skip the swizzle.
//!
//! Called from `window.takeScreenshot` AFTER `window.endFrame()`, which
//! ends with `sg.commit()` — the GPU queue has already submitted the
//! draw, and `sapp_metal_get_current_drawable` still points at the
//! frame's drawable until the next `frame_cb` begins. The blit encoder
//! we build here therefore runs against the just-presented texture.
//!
//! All libobjc plumbing lives behind explicit `@extern` declarations
//! so this file compiles cleanly on Darwin only (the wrapper in
//! `window.zig` gates the call on `comptime is_darwin`).

const std = @import("std");

// ── libobjc + Metal selector setup ────────────────────────────────────
// sokol_app.h exposes the current drawable as `const void*`; cast it
// back to an objc `id` (which `?*anyopaque` already models).
//
// NOTE (labelle-assembler#222 issue 2): `_sapp_metal_get_current_drawable`
// is NOT yet exported from the sokol-zig fork pinned by the current
// release. Until that fork patch lands, declaring this `extern fn` at
// module scope causes an undefined-symbol error at link time on macOS
// builds — even though `readback` is only called when the active
// graphics backend is Metal. The extern declaration alone is enough to
// pull the unresolved symbol into the executable's link line.
//
// Mitigation: the extern lives INSIDE `readback` (and `readback` is
// hard-stubbed to return `false` until the fork patch ships). When the
// pending fork patch + sokol pin bump lands in a follow-up, restore the
// real readback body by deleting the early-return stub and the inline
// `extern fn` declarations move back out to module scope.
extern fn sel_registerName(name: [*:0]const u8) callconv(.c) ?*anyopaque;
const msgSend_void = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);
const msgSend_id = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
const msgSend_buf = @extern(
    *const fn (dev: ?*anyopaque, sel: ?*anyopaque, length: usize, opts: u64) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
const msgSend_contents = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
// Metal's `copyFromTexture:...sourceOrigin:sourceSize:...` takes MTLOrigin
// and MTLSize structs BY VALUE. They are each three NSUInteger fields →
// 24 bytes on 64-bit Darwin. Flattening them into six individual usize
// args (as an earlier revision did) does NOT match the platform ABI:
//   - ARM64 (AAPCS64 / Darwin): aggregates > 16 bytes are passed in memory
//     (copied to the stack at the next 8-byte-aligned offset), not in
//     six separate GPRs.
//   - x86_64 SysV: aggregates > 16 bytes are also passed via memory.
// Either way the callee reads each struct as a contiguous 24-byte chunk,
// so we must declare them as `extern struct`s and pass them by value to
// generate the correct argument layout.
const MTLOrigin = extern struct {
    x: usize,
    y: usize,
    z: usize,
};
const MTLSize = extern struct {
    width: usize,
    height: usize,
    depth: usize,
};
const msgSend_copy = @extern(
    *const fn (
        encoder: ?*anyopaque,
        sel: ?*anyopaque,
        tex: ?*anyopaque,
        slice: usize,
        level: usize,
        origin: MTLOrigin,
        size: MTLSize,
        buf: ?*anyopaque,
        offset: usize,
        bytes_per_row: usize,
        bytes_per_image: usize,
    ) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);
const msgSend_sync = @extern(
    *const fn (
        encoder: ?*anyopaque,
        sel: ?*anyopaque,
        buf: ?*anyopaque,
    ) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);

// Storage modes — values are stable Metal enum constants.
const MTLResourceStorageModeShared: u64 = 0 << 4;
const MTLResourceStorageModeManaged: u64 = 1 << 4;

const is_macos = @import("builtin").target.os.tag == .macos;

// labelle-assembler#222 issue 2: the sokol-zig fork now exports
// `_sapp_metal_get_current_drawable` (see labelle-toolkit/sokol-zig#1,
// merged at 887b30f). With the pin bump in `backends/sokol/build.zig.zon`
// to that commit, the readback body is live. Keeping this as a comptime
// flag (rather than ripping the gate) preserves the compile-time switch
// for any future fork-rollback scenario and documents the link-edge
// where the symbol becomes mandatory.
const fork_exports_drawable: bool = true;

/// Read the contents of the current swapchain drawable's texture into `out`
/// (RGBA-sized buffer, w*h*4 bytes). Returns true on success, false on any
/// readback step that can fail (no drawable, alloc failure, etc.).
///
/// `out` receives BGRA bytes on success — see `bmp.writeBmpFromBgra`.
/// `mtl_device` is the MTLDevice pointer (from `window.metalDevice()`).
///
/// Windowed path: source the texture from the current `CAMetalDrawable`.
pub fn readback(out: []u8, w: u32, h: u32, mtl_device: ?*const anyopaque) bool {
    if (comptime !fork_exports_drawable) {
        // STUB path retained for compile-time rollback safety. The
        // live branch below requires the sokol-zig fork pin to export
        // `_sapp_metal_get_current_drawable` (assembler#222 issue 2).
        std.log.warn(
            "screenshot: Metal readback disabled (fork_exports_drawable=false)",
            .{},
        );
        return false;
    }

    // Keep the extern declaration *inside* the function body so the
    // symbol only enters the linker's search graph when the
    // `fork_exports_drawable` branch above is alive. Use `extern "c"`
    // (not bare `extern`) — the `"c"` is the canonical stdlib pattern
    // for libc-resolved symbols and works across platforms (Windows
    // MSVC included), matching `std.c.fopen` and friends.
    const sapp_metal_get_current_drawable = (struct {
        extern "c" fn sapp_metal_get_current_drawable() ?*const anyopaque;
    }).sapp_metal_get_current_drawable;

    const drawable = @as(?*anyopaque, @constCast(sapp_metal_get_current_drawable())) orelse {
        std.log.warn("screenshot: no current drawable (frame not rendered?)", .{});
        return false;
    };

    const sel_texture = sel_registerName("texture");
    const texture = msgSend_id(drawable, sel_texture) orelse {
        std.log.warn("screenshot: drawable has no texture", .{});
        return false;
    };
    return blitTextureToBuffer(out, w, h, mtl_device, texture);
}

/// Headless path (labelle-assembler#368): read back from a caller-supplied
/// offscreen `MTLTexture*` (the headless fallback color attachment) instead
/// of the window swapchain — sokol_app never ran, so the swapchain drawable
/// is invalid and `sapp_metal_get_current_drawable` aborts on `!_sapp.valid`.
///
/// The offscreen image is created BGRA8 (matching the swapchain format), so
/// `out` again receives BGRA bytes — see `bmp.writeBmpFromBgra`.
pub fn readbackFromTexture(
    out: []u8,
    w: u32,
    h: u32,
    mtl_device: ?*const anyopaque,
    texture: ?*const anyopaque,
) bool {
    const tex = @as(?*anyopaque, @constCast(texture)) orelse {
        std.log.warn("screenshot: headless offscreen texture is null", .{});
        return false;
    };
    return blitTextureToBuffer(out, w, h, mtl_device, tex);
}

/// Shared blit core: copy `texture` into a freshly-allocated shared
/// MTLBuffer, wait for completion, and memcpy `w*h*4` bytes into `out`.
/// `out` receives the texture's native bytes verbatim (BGRA8 for both the
/// swapchain drawable and the BGRA8 offscreen attachment).
fn blitTextureToBuffer(out: []u8, w: u32, h: u32, mtl_device: ?*const anyopaque, texture: ?*anyopaque) bool {
    const device = @as(?*anyopaque, @constCast(mtl_device)) orelse {
        std.log.warn("screenshot: Metal device unavailable", .{});
        return false;
    };

    const sel_release = sel_registerName("release");
    const sel_newCommandQueue = sel_registerName("newCommandQueue");
    const sel_commandBuffer = sel_registerName("commandBuffer");
    const sel_blitCommandEncoder = sel_registerName("blitCommandEncoder");
    const sel_endEncoding = sel_registerName("endEncoding");
    const sel_commit = sel_registerName("commit");
    const sel_waitUntilCompleted = sel_registerName("waitUntilCompleted");
    const sel_newBufferWithLength = sel_registerName("newBufferWithLength:options:");
    const sel_contents = sel_registerName("contents");
    const sel_copyFromTexture = sel_registerName(
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
    );
    const sel_synchronizeResource = sel_registerName("synchronizeResource:");

    const bytes_per_row: usize = @as(usize, w) * 4;
    const total: usize = bytes_per_row * @as(usize, h);
    if (out.len < total) {
        std.log.warn("screenshot: output buffer too small ({d} < {d})", .{ out.len, total });
        return false;
    }

    // macOS: storageModeShared so CPU + GPU view the same backing store
    // (no manual synchronize call needed). iOS: storageModeManaged isn't
    // valid on iOS at all (Shared is the only CPU-visible mode), so use
    // Shared everywhere — the synchronize call is then a no-op but kept
    // gated under is_macos so the macOS path doesn't pay for it.
    const storage_mode = MTLResourceStorageModeShared;

    const buffer = msgSend_buf(device, sel_newBufferWithLength, total, storage_mode) orelse {
        std.log.warn("screenshot: newBufferWithLength failed", .{});
        return false;
    };
    defer msgSend_void(buffer, sel_release);

    const queue = msgSend_id(device, sel_newCommandQueue) orelse {
        std.log.warn("screenshot: newCommandQueue failed", .{});
        return false;
    };
    defer msgSend_void(queue, sel_release);

    const cmd_buf = msgSend_id(queue, sel_commandBuffer) orelse {
        std.log.warn("screenshot: commandBuffer failed", .{});
        return false;
    };
    // commandBuffer is autoreleased — don't release manually.

    const blit = msgSend_id(cmd_buf, sel_blitCommandEncoder) orelse {
        std.log.warn("screenshot: blitCommandEncoder failed", .{});
        return false;
    };

    msgSend_copy(
        blit,
        sel_copyFromTexture,
        texture,
        0, // sourceSlice
        0, // sourceLevel
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .width = @as(usize, w), .height = @as(usize, h), .depth = 1 },
        buffer,
        0, // dest offset
        bytes_per_row,
        total,
    );

    // On macOS with storageModeManaged the GPU's write must be flushed
    // back to CPU-visible memory via synchronizeResource: before reading.
    // Shared mode skips this — left in place as a comment-only marker
    // in case we revisit Managed-mode for cross-process readback.
    if (is_macos) {
        // No-op for Shared; would be required for Managed.
        _ = sel_synchronizeResource;
    }

    msgSend_void(blit, sel_endEncoding);
    msgSend_void(cmd_buf, sel_commit);
    msgSend_void(cmd_buf, sel_waitUntilCompleted);

    const contents = msgSend_contents(buffer, sel_contents) orelse {
        std.log.warn("screenshot: buffer.contents returned null", .{});
        return false;
    };
    const src_bytes: [*]const u8 = @ptrCast(contents);
    @memcpy(out[0..total], src_bytes[0..total]);
    return true;
}
