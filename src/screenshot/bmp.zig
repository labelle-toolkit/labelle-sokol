//! BMP screenshot encoder.
//!
//! Vendored from `labelle-gfx/src/window_utils.zig` (the `Screenshot.writeBmp`
//! helper). Each labelle-assembler backend is shipped as a self-contained
//! Zig package without a `labelle-gfx` dependency — adding one for a 60-line
//! pure-std encoder would widen the dep graph far more than the encoder is
//! worth. If/when the BMP writer grows (PNG support, etc.) the right move
//! is to extract it to its own tiny sub-package both `labelle-gfx` and the
//! backends can depend on; until then keep this copy in sync by hand.
//!
//! Tracker: labelle-assembler#213 (per-backend sokol screenshot).
//!
//! Input pixel layout: tightly-packed RGBA8 (R,G,B,A order), top-down
//! (row 0 is the top of the image). BMP is bottom-up + BGR, so the writer
//! handles both the row-flip and the channel swizzle.
//!
//! File I/O: Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`,
//! which threads an `Io` parameter through every call site. The screenshot
//! path is invoked from a deep callback (`window.takeScreenshot`) that has
//! no `Io` in scope; rather than rewire it for one 60-line writer we use
//! libc `fopen` / `fwrite` / `fclose` here, mirroring the same approach
//! used in `gfx/texture.zig` and `audio/legacy.zig` for the legacy
//! path-based loaders. The consuming `window` module sets `link_libc = true`
//! in `backends/sokol/build.zig`, so libc is already on the link line.

const std = @import("std");

/// Open `path` (UTF-8), write `data` verbatim, close. Returns
/// `error.FileWriteFailed` on any libc-level failure. Allocates a
/// null-terminated copy of the path because `fopen` is C and needs a
/// `[*:0]const u8`; freed before return. Uses the caller's allocator
/// rather than `std.heap.page_allocator` so the call site controls the
/// allocation strategy (matches the existing `allocator` param threaded
/// through `writeBmp` / `writeBmpFromBgra`).
fn writeBytesViaLibc(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.FileWriteFailed;
    defer _ = std.c.fclose(fp);
    if (std.c.fwrite(data.ptr, 1, data.len, fp) != data.len) return error.FileWriteFailed;
}

/// Write `pixels` (RGBA8, top-down, `width * height * 4` bytes) to `path`
/// as a 24-bit BMP. `allocator` is used only for the single output buffer
/// and freed before return.
pub fn writeBmp(
    allocator: std.mem.Allocator,
    path: []const u8,
    pixels: []const u8,
    width: u32,
    height: u32,
) !void {
    const row_size = width * 3;
    const padding: u32 = (4 - (row_size % 4)) % 4;
    const padded_row = row_size + padding;
    const pixel_data_size = padded_row * height;
    const file_size: u32 = 54 + pixel_data_size;

    var data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    // BMP header (14 bytes)
    data[0] = 'B';
    data[1] = 'M';
    writeU32LE(data[2..6], file_size);
    writeU32LE(data[6..10], 0); // reserved
    writeU32LE(data[10..14], 54); // pixel data offset

    // DIB header (40 bytes)
    writeU32LE(data[14..18], 40); // header size
    writeU32LE(data[18..22], width);
    writeU32LE(data[22..26], height);
    writeU16LE(data[26..28], 1); // color planes
    writeU16LE(data[28..30], 24); // bits per pixel
    writeU32LE(data[30..34], 0); // no compression
    writeU32LE(data[34..38], pixel_data_size);
    writeU32LE(data[38..42], 2835); // h resolution (~72 DPI)
    writeU32LE(data[42..46], 2835); // v resolution
    writeU32LE(data[46..50], 0); // colors
    writeU32LE(data[50..54], 0); // important colors

    // Pixel data — BMP rows are bottom-up; channels are BGR.
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row = (height - 1 - y) * width * 4;
        const dst_row = 54 + y * padded_row;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_idx = src_row + x * 4;
            const dst_idx = dst_row + x * 3;
            data[dst_idx + 0] = pixels[src_idx + 2]; // B
            data[dst_idx + 1] = pixels[src_idx + 1]; // G
            data[dst_idx + 2] = pixels[src_idx + 0]; // R
        }
        var p: u32 = 0;
        while (p < padding) : (p += 1) {
            data[dst_row + row_size + p] = 0;
        }
    }

    try writeBytesViaLibc(allocator, path, data);
}

/// BGRA8 variant — same layout as the RGBA writer except channels 0/2 are
/// already swapped on input. Used by the Metal/D3D11 paths, whose native
/// swapchain pixel format is BGRA8Unorm and which produce BGRA bytes
/// directly from the blit/copy. Skipping a software swizzle pass keeps
/// the readback hot loop tight.
pub fn writeBmpFromBgra(
    allocator: std.mem.Allocator,
    path: []const u8,
    pixels: []const u8,
    width: u32,
    height: u32,
) !void {
    const row_size = width * 3;
    const padding: u32 = (4 - (row_size % 4)) % 4;
    const padded_row = row_size + padding;
    const pixel_data_size = padded_row * height;
    const file_size: u32 = 54 + pixel_data_size;

    var data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    data[0] = 'B';
    data[1] = 'M';
    writeU32LE(data[2..6], file_size);
    writeU32LE(data[6..10], 0);
    writeU32LE(data[10..14], 54);

    writeU32LE(data[14..18], 40);
    writeU32LE(data[18..22], width);
    writeU32LE(data[22..26], height);
    writeU16LE(data[26..28], 1);
    writeU16LE(data[28..30], 24);
    writeU32LE(data[30..34], 0);
    writeU32LE(data[34..38], pixel_data_size);
    writeU32LE(data[38..42], 2835);
    writeU32LE(data[42..46], 2835);
    writeU32LE(data[46..50], 0);
    writeU32LE(data[50..54], 0);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row = (height - 1 - y) * width * 4;
        const dst_row = 54 + y * padded_row;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_idx = src_row + x * 4;
            const dst_idx = dst_row + x * 3;
            data[dst_idx + 0] = pixels[src_idx + 0]; // B (already)
            data[dst_idx + 1] = pixels[src_idx + 1]; // G
            data[dst_idx + 2] = pixels[src_idx + 2]; // R
        }
        var p: u32 = 0;
        while (p < padding) : (p += 1) {
            data[dst_row + row_size + p] = 0;
        }
    }

    try writeBytesViaLibc(allocator, path, data);
}

fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn writeU16LE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
}
