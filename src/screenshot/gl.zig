//! OpenGL / GLES pixel readback for screenshot capture (labelle-assembler#213).
//!
//! Strategy: `glReadPixels` against the default framebuffer
//! (sokol_app binds framebuffer 0 for the swapchain pass).
//! `takeScreenshot` runs after `sg.commit()`, so the back buffer holds
//! the just-drawn frame.
//!
//! `glReadPixels` reads bottom-up (y=0 is the bottom row), but BMP is
//! also bottom-up — the encoder explicitly flips on write, which would
//! double-flip a GL readback. Compensate by flipping rows in place here
//! so the encoder's flip lands right-side-up.
//!
//! GLES restriction: `glReadPixels` is only guaranteed to support
//! `GL_RGBA` + `GL_UNSIGNED_BYTE` on default framebuffers (other
//! formats require ES extensions / are implementation-defined). Pick
//! the safe combo.

const std = @import("std");
const builtin = @import("builtin");

const GL_RGBA: u32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_PACK_ALIGNMENT: u32 = 0x0D05;

// IMPORTANT: do NOT declare the GL `extern fn` symbols at module scope.
// On macOS native (Metal-only) the OpenGL framework isn't linked, so
// module-scope extern declarations cause undefined-symbol failures at
// link time — even when the `sg.queryBackend()` switch in `window.zig`
// never dispatches to this file. The comptime gate on the *call site*
// is necessary but not sufficient: extern decls that are merely
// reachable from the module graph still get emitted by the linker.
// Declaring the externs inside the function body that uses them
// confines them to a translation unit that is only fully elaborated
// when `readback` is actually compiled, which in turn only happens
// when the call from `window.readbackGL` survives dead-code
// elimination on a GL-backed build. See labelle-assembler#222 (issue 3).

/// Read RGBA8 bytes from the default framebuffer into `out`
/// (`w * h * 4` bytes). Returns true on success.
pub fn readback(out: []u8, w: u32, h: u32) bool {
    // GL is unavailable on Darwin native builds (sokol drops the GL
    // backend in favour of Metal); the host swapchain has no OpenGL
    // context, so even if we wired the symbols in there's nothing to
    // read from. Bail early so the extern declarations below never
    // become reachable on Darwin and the linker never looks for
    // libGL / glReadPixels symbols.
    // Use `builtin.target.os.tag` (not `builtin.os.tag`) — the latter
    // resolves to the *host* OS and breaks cross-compilation to Darwin
    // from a non-Apple host. cursor[bot] caught this on PR #223.
    if (comptime builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        std.log.warn("screenshot: GL readback requested on Darwin (sokol uses Metal here)", .{});
        return false;
    }

    // Gate the extern decls themselves on the non-Darwin branch so they
    // are never part of the AST on Darwin builds. Zig elaborates the
    // extern symbols when their enclosing scope is analysed; keeping
    // them inside this `if` block (which is `comptime`-dead on Darwin)
    // is what actually prevents the linker references.
    const gl = struct {
        extern "c" fn glReadPixels(x: i32, y: i32, w: i32, h: i32, format: u32, type_: u32, data: ?*anyopaque) void;
        extern "c" fn glPixelStorei(pname: u32, param: i32) void;
        extern "c" fn glGetError() u32;
    };

    const total: usize = @as(usize, w) * @as(usize, h) * 4;
    if (out.len < total) {
        std.log.warn("screenshot: output buffer too small ({d} < {d})", .{ out.len, total });
        return false;
    }

    // Tight packing — otherwise drivers may pad rows to 4-byte alignment
    // for non-multiple-of-4 widths and corrupt the layout we hand to BMP.
    gl.glPixelStorei(GL_PACK_ALIGNMENT, 1);

    gl.glReadPixels(0, 0, @intCast(w), @intCast(h), GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
    const err = gl.glGetError();
    if (err != 0) {
        std.log.warn("screenshot: glReadPixels failed (GL error 0x{x})", .{err});
        return false;
    }

    // GL is bottom-up; the BMP encoder also flips on write. Pre-flip
    // the rows so the encoder's flip lands right-side-up.
    flipRowsInPlace(out, w, h);
    return true;
}

fn flipRowsInPlace(buf: []u8, w: u32, h: u32) void {
    const stride: usize = @as(usize, w) * 4;
    var top: u32 = 0;
    var bot: u32 = h - 1;
    // Small fixed scratch + chunked swap: works at full `@memcpy` speed
    // for any width without a slow byte-wise fallback, and keeps the
    // stack footprint tiny (16 KiB previously, 1 KiB now).
    var scratch: [1024]u8 = undefined;
    while (top < bot) : ({
        top += 1;
        bot -= 1;
    }) {
        const top_off = @as(usize, top) * stride;
        const bot_off = @as(usize, bot) * stride;
        var chunk_offset: usize = 0;
        while (chunk_offset < stride) {
            const chunk_len = @min(stride - chunk_offset, scratch.len);
            const t_slice = buf[top_off + chunk_offset ..][0..chunk_len];
            const b_slice = buf[bot_off + chunk_offset ..][0..chunk_len];
            @memcpy(scratch[0..chunk_len], t_slice);
            @memcpy(t_slice, b_slice);
            @memcpy(b_slice, scratch[0..chunk_len]);
            chunk_offset += chunk_len;
        }
    }
}
