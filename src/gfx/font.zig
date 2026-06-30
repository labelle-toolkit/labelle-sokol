/// Phase 4 TTF/OTF font surface (labelle-gfx#258, labelle-engine#448).
///
/// Decode/upload split mirrors the image path: pure CPU bake in
/// `decodeFont` (worker-thread safe — stb_truetype only touches its
/// own context + the allocator-owned bitmap buffer), GPU upload in
/// `uploadFontAtlas` on the main thread (calls `sg.makeImage`).
///
/// Types are `extern struct` so the assembler's `writeFontBackendWiring`
/// field-by-field copy into `engine.DecodedFont` lands on a stable memory
/// layout. Field shape is identical to `labelle-gfx`'s `backend.zig`
/// definitions — the gfx wrapper exposes `FontAtlas` via `@hasDecl(Impl,
/// "FontAtlas")`, so declaring these as top-level `pub` opts this backend
/// in to the font traits.
const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const texture_mod = @import("texture.zig");

// stb_truetype lives in the same shimmed translate-c invocation as
// stb_image — single `@cImport` keeps the two header sets sharing one
// translated set of C declarations.
const stbtt = texture_mod.stbi;

pub const CodepointRange = extern struct {
    first: u32,
    last: u32,
};

pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,
    xoff: f32,
    yoff: f32,
    advance: f32,
};

pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};

pub const FontBakeParams = struct {
    pixel_height: f32 = 16,
    ranges: []const CodepointRange = &.{.{ .first = 0x20, .last = 0x7F }},
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// CPU-decoded font atlas. All four slices are allocator-owned —
/// the caller frees them on BOTH success and discard paths (same
/// contract as `DecodedImage.pixels`). Field layout matches
/// `labelle-gfx`'s `DecodedFont` exactly so the assembler's
/// `writeFontBackendWiring` field-by-field copy lands cleanly.
pub const DecodedFont = struct {
    bitmap: []u8,
    width: u32,
    height: u32,
    glyphs: []Glyph,
    codepoint_index: []const CodepointEntry,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    line_height: f32,
    kerning: []const KernPair,
};

/// GPU-side font atlas handle. The R8 alpha bitmap from `decodeFont`
/// becomes a sokol `sg.Image`; the renderer samples it with whatever
/// sampler it already keeps around for text rendering. `width`/`height`
/// are stored alongside the image so the renderer can compute
/// normalised UVs from the glyph's pixel-space rect without poking
/// sokol_gfx for image metadata.
pub const FontAtlas = extern struct {
    image: sg.Image,
    width: u32,
    height: u32,
};

/// Pure CPU bake — runs on the asset worker thread.
///
/// Design: `stbtt_PackBegin` + `stbtt_PackFontRange` (one call per
/// `CodepointRange`) + `stbtt_PackEnd`. We picked the pack API over
/// `stbtt_BakeFontBitmap` because the pack path:
///   1. Honors multiple non-contiguous codepoint ranges (e.g.
///      ASCII + Latin-1 supplement) without re-walking the font for
///      each range.
///   2. Uses skyline packing — denser than BakeFontBitmap's left-to-
///      right strip pack, which matters once a project bakes more
///      than a couple of ranges into one atlas.
///   3. Supports oversampling via `stbtt_PackSetOversampling` (we
///      leave it at the default 1× for now — a future PR can expose
///      it through `FontBakeParams`).
///
/// All four output slices (`bitmap`, `glyphs`, `codepoint_index`,
/// `kerning`) come from `allocator` so the caller can free them
/// through the same allocator on both success and discard.
pub fn decodeFont(
    file_type: [:0]const u8,
    data: []const u8,
    params: *const FontBakeParams,
    allocator: std.mem.Allocator,
) !DecodedFont {
    // stb_truetype handles both .ttf and .otf transparently — the
    // CFF (OTF) outline path was added upstream long ago. We accept
    // both extensions and don't dispatch on `file_type` further.
    _ = file_type;

    if (data.len == 0) return error.FontDecodeFailed;
    if (params.atlas_width == 0 or params.atlas_height == 0) return error.FontDecodeFailed;

    // Initialise the font info first — we need vertical metrics +
    // kerning out-of-band from the packed glyph data. `font_index = 0`
    // because TTC (font collection) support is not on the Phase 4 roadmap.
    var font_info: stbtt.stbtt_fontinfo = undefined;
    const offset = stbtt.stbtt_GetFontOffsetForIndex(@ptrCast(data.ptr), 0);
    if (offset < 0) return error.FontDecodeFailed;
    if (stbtt.stbtt_InitFont(&font_info, @ptrCast(data.ptr), offset) == 0) {
        return error.FontDecodeFailed;
    }

    // R8 alpha atlas — `sg.PixelFormat.R8` on the upload side. We
    // allocate the bitmap from `allocator` so the caller frees it on
    // both the success and discard paths (mirroring `decodeImage`).
    const atlas_w: usize = params.atlas_width;
    const atlas_h: usize = params.atlas_height;
    // Guard against 32-bit (incl. wasm32) `usize` wraparound on the
    // bitmap size multiply — a wrap would alloc an undersized buffer
    // that the C packer happily writes past.
    const bitmap_len = std.math.mul(usize, atlas_w, atlas_h) catch return error.FontAtlasTooLarge;
    const bitmap = try allocator.alloc(u8, bitmap_len);
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0);

    var pack_ctx: stbtt.stbtt_pack_context = undefined;
    if (stbtt.stbtt_PackBegin(
        &pack_ctx,
        bitmap.ptr,
        @intCast(atlas_w),
        @intCast(atlas_h),
        0, // stride = 0 → tightly packed
        1, // 1px padding for bilinear filtering safety
        null,
    ) == 0) {
        return error.FontDecodeFailed;
    }
    defer stbtt.stbtt_PackEnd(&pack_ctx);

    // Default oversampling. A future revision can expose this via
    // FontBakeParams; for now we match the engine's expectation of
    // crisp pixel-aligned glyphs at the requested pixel_height.
    stbtt.stbtt_PackSetOversampling(&pack_ctx, 1, 1);

    // Normalise the ranges slice: an empty slice means "default
    // ASCII printable" per the engine contract.
    const effective_ranges: []const CodepointRange = if (params.ranges.len == 0)
        &[_]CodepointRange{.{ .first = 0x20, .last = 0x7F }}
    else
        params.ranges;

    // Count total glyphs across all ranges so we can allocate the
    // dense `glyphs` and `codepoint_index` arrays up-front. Ranges
    // are half-open [first, last) per the labelle-gfx contract —
    // matching CodepointRange's documented shape (see
    // `labelle-gfx/src/backend.zig:33`).
    var total_glyphs: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        total_glyphs += @intCast(r.last - r.first);
    }
    if (total_glyphs == 0) return error.FontDecodeFailed;

    // Temporary stbtt packed-char array shared across ranges — we
    // can pack each range straight into a contiguous block so the
    // unpack loop below maps 1:1 into our `Glyph` array.
    const packed_chars = try allocator.alloc(stbtt.stbtt_packedchar, total_glyphs);
    defer allocator.free(packed_chars);

    const glyphs = try allocator.alloc(Glyph, total_glyphs);
    errdefer allocator.free(glyphs);

    const codepoint_index = try allocator.alloc(CodepointEntry, total_glyphs);
    errdefer allocator.free(codepoint_index);

    var write_idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: c_int = @intCast(r.last - r.first);
        const ok = stbtt.stbtt_PackFontRange(
            &pack_ctx,
            @ptrCast(data.ptr),
            0,
            params.pixel_height,
            @intCast(r.first),
            count,
            &packed_chars[write_idx],
        );
        if (ok == 0) {
            // Partial-pack failures usually mean "atlas too small";
            // bubble it up as a decode error so the catalog reports
            // a clean error to the game. `glyphs` and `codepoint_index`
            // have `errdefer allocator.free(...)` at their alloc sites
            // (above) so we let those fire — manually freeing here
            // would double-free.
            return error.FontAtlasTooSmall;
        }
        write_idx += @intCast(count);
    }

    // Unpack stbtt_packedchar → our extern Glyph, and build the
    // codepoint_index in lock-step. Ranges are emitted in the order
    // the caller listed them; the codepoint_index needs to be
    // sorted by codepoint for the renderer's binary search. We
    // assume caller-supplied ranges are already sorted and
    // non-overlapping — matches the labelle-gfx default ranges + the
    // engine's own bake helpers, and a sort-by-codepoint here would
    // duplicate work for the common case.
    var idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: u32 = r.last - r.first;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const pc = packed_chars[idx];
            glyphs[idx] = .{
                .u0 = pc.x0,
                .v0 = pc.y0,
                .u1 = pc.x1,
                .v1 = pc.y1,
                .xoff = pc.xoff,
                .yoff = pc.yoff,
                .advance = pc.xadvance,
            };
            codepoint_index[idx] = .{
                .codepoint = r.first + i,
                .glyph_index = @intCast(idx),
            };
            idx += 1;
        }
    }

    // Vertical metrics — stbtt returns them in font design units;
    // multiply by the scale-for-pixel-height so the renderer can
    // use them directly in pixels at the baked size.
    var ascent_i: c_int = 0;
    var descent_i: c_int = 0;
    var line_gap_i: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent_i, &descent_i, &line_gap_i);
    const scale: f32 = stbtt.stbtt_ScaleForPixelHeight(&font_info, params.pixel_height);
    const ascent: f32 = @as(f32, @floatFromInt(ascent_i)) * scale;
    const descent: f32 = @as(f32, @floatFromInt(descent_i)) * scale;
    const line_gap: f32 = @as(f32, @floatFromInt(line_gap_i)) * scale;
    const line_height: f32 = ascent - descent + line_gap;

    // Kerning — extract the whole table in one pass via
    // `stbtt_GetKerningTable`. The previous double-loop over
    // `codepoint_index` called `stbtt_GetCodepointKernAdvance` N²
    // times (~9K calls for ASCII; quadratic for larger ranges).
    // The new path is O(N + K) where N is the baked codepoint set
    // and K is the font's stored kerning pair count.
    //
    // The kerning table stores GLYPH INDICES, not codepoints, so we
    // build a `glyph_index → codepoint` map by walking the baked
    // codepoints once and resolving each via `stbtt_FindGlyphIndex`.
    // Pairs that reference glyphs outside the baked set are dropped.
    var kern_list = std.array_list.Aligned(KernPair, null).empty;
    errdefer kern_list.deinit(allocator);

    const pair_count_i = stbtt.stbtt_GetKerningTableLength(&font_info);
    if (pair_count_i > 0) {
        const pair_count: usize = @intCast(pair_count_i);

        // glyph-index → codepoint map for the baked set. Two parallel
        // slices sorted by glyph_index, queried with `std.sort.binarySearch`
        // so per-pair lookup is O(log N) rather than O(N).
        const GlyphMapEntry = struct { glyph: i32, codepoint: u32 };
        const map = try allocator.alloc(GlyphMapEntry, codepoint_index.len);
        defer allocator.free(map);
        for (codepoint_index, 0..) |entry, mi| {
            const gi = stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.codepoint));
            map[mi] = .{ .glyph = gi, .codepoint = entry.codepoint };
        }
        std.mem.sort(GlyphMapEntry, map, {}, struct {
            fn lessThan(_: void, a: GlyphMapEntry, b: GlyphMapEntry) bool {
                return a.glyph < b.glyph;
            }
        }.lessThan);

        const lookup = struct {
            fn find(slice: []const GlyphMapEntry, glyph: i32) ?u32 {
                var lo: usize = 0;
                var hi: usize = slice.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (slice[mid].glyph < glyph) {
                        lo = mid + 1;
                    } else if (slice[mid].glyph > glyph) {
                        hi = mid;
                    } else {
                        return slice[mid].codepoint;
                    }
                }
                return null;
            }
        }.find;

        const table = try allocator.alloc(stbtt.stbtt_kerningentry, pair_count);
        defer allocator.free(table);
        const written = stbtt.stbtt_GetKerningTable(&font_info, table.ptr, @intCast(pair_count));
        const written_n: usize = if (written < 0) 0 else @intCast(written);
        for (table[0..written_n]) |entry| {
            if (entry.advance == 0) continue;
            const first_cp = lookup(map, entry.glyph1) orelse continue;
            const second_cp = lookup(map, entry.glyph2) orelse continue;
            try kern_list.append(allocator, .{
                .first = first_cp,
                .second = second_cp,
                .advance = @as(f32, @floatFromInt(entry.advance)) * scale,
            });
        }
    }
    const kerning = try kern_list.toOwnedSlice(allocator);

    return .{
        .bitmap = bitmap,
        .width = params.atlas_width,
        .height = params.atlas_height,
        .glyphs = glyphs,
        .codepoint_index = codepoint_index,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .line_height = line_height,
        .kerning = kerning,
    };
}

/// Main/GL-thread GPU upload. Creates a single-channel `R8` sokol
/// image. Does NOT free `decoded.bitmap` — caller owns it (same
/// contract as `uploadTexture`).
pub fn uploadFontAtlas(decoded: DecodedFont) !FontAtlas {
    var img_desc: sg.ImageDesc = .{
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .pixel_format = .R8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = decoded.bitmap.ptr,
        .size = decoded.bitmap.len,
    };

    const img = sg.makeImage(img_desc);
    if (img.id == 0) return error.FontUploadFailed;

    return .{
        .image = img,
        .width = decoded.width,
        .height = decoded.height,
    };
}

/// Counterpart to `uploadFontAtlas`. Idempotent on a zero handle so
/// the catalog's discard path can call it without checking.
pub fn unloadFontAtlas(atlas: FontAtlas) void {
    if (atlas.image.id != 0) {
        sg.destroyImage(atlas.image);
    }
}

// ── Font tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeFont rejects empty data" {
    const empty: []const u8 = &.{};
    const params = FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", empty, &params, testing.allocator));
}

test "decodeFont rejects zero-sized atlas" {
    // Non-empty data so we exercise the dimensions check, not the
    // empty-data fast path. Bytes don't need to be a valid TTF — the
    // dimension guard fires before `stbtt_InitFont`.
    const fake = "not-a-real-ttf";
    const params = FontBakeParams{ .atlas_width = 0, .atlas_height = 128 };
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", fake, &params, testing.allocator));
}

test "decodeFont surfaces FontDecodeFailed on garbage input" {
    // 1KB of random-ish bytes — `stbtt_InitFont` should reject the
    // missing TTF magic. This is the user-facing failure mode for
    // an asset with the wrong extension or a corrupted file.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    const params = FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", &fake, &params, testing.allocator));
}
