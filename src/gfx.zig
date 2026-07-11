/// Sokol gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses sokol_gl for immediate-mode 2D drawing with real texture support.
///
/// This file is the public façade for the sokol gfx backend. The
/// implementation is split across `gfx/` submodules to keep each
/// concern below the 1000-line ceiling enforced by labelle-assembler#188:
///
///   - `gfx/types.zig`       — value types (Texture, Color, …) + color constants
///   - `gfx/state.zig`       — screen / design / camera state + NDC helpers
///   - `gfx/draw.zig`        — shape + sprite primitives (drawRectangle*, drawCircle, drawLine, drawTexturePro)
///   - `gfx/texture.zig`     — image decode (stb_image) + GPU upload
///   - `gfx/font_atlas.zig`  — embedded 8x8 bitmap font + drawText
///   - `gfx/font.zig`        — Phase 4 TTF/OTF font surface (stb_truetype)
///
/// The submodules are private file-system neighbours that nothing
/// outside this backend should `@import` directly — every consumer
/// goes through `b.dependency("labelle_sokol", ...).module("gfx")`,
/// which still points at this file.
// Contract-version tags (labelle-assembler#453 item 1). The assembler emits
// directional `@compileError` version asserts in the generated game's main.zig
// comparing these against labelle-core's `*_CONTRACT_VERSION` consts. v1 is the
// initial revision of each contract.
pub const targets_draw_contract: u32 = 1;
pub const targets_loader_contract: u32 = 1;

const types = @import("gfx/types.zig");
const state = @import("gfx/state.zig");
const draw = @import("gfx/draw.zig");
const texture = @import("gfx/texture.zig");
const font_atlas = @import("gfx/font_atlas.zig");
const font = @import("gfx/font.zig");
const material = @import("gfx/material.zig");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = types.Texture;
pub const Color = types.Color;
pub const Rectangle = types.Rectangle;
pub const Vector2 = types.Vector2;
pub const Camera2D = types.Camera2D;

// ── Color constants ────────────────────────────────────────────────────

pub const white = types.white;
pub const black = types.black;
pub const red = types.red;
pub const green = types.green;
pub const blue = types.blue;
pub const transparent = types.transparent;

pub const color = types.color;

// ── Screen / camera state ──────────────────────────────────────────────

pub const setApplyFit = state.setApplyFit;
pub const screenToDesign = state.screenToDesign;
pub const designToPhysical = state.designToPhysical;
pub const setScreenSize = state.setScreenSize;
pub const setDesignSize = state.setDesignSize;
pub const getDesignWidth = state.getDesignWidth;
pub const getDesignHeight = state.getDesignHeight;
pub const beginMode2D = state.beginMode2D;
pub const endMode2D = state.endMode2D;
pub const getScreenWidth = state.getScreenWidth;
pub const getScreenHeight = state.getScreenHeight;
pub const screenToWorld = state.screenToWorld;
pub const worldToScreen = state.worldToScreen;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub const drawTexturePro = draw.drawTexturePro;
pub const drawRectangleRec = draw.drawRectangleRec;
pub const drawRectanglePro = draw.drawRectanglePro;
pub const drawRectangleLinesEx = draw.drawRectangleLinesEx;
pub const drawCircle = draw.drawCircle;
pub const drawTriangle = draw.drawTriangle;
pub const drawPolygon = draw.drawPolygon;
pub const drawLine = draw.drawLine;
pub const drawText = font_atlas.drawText;

// ── Material seam (labelle-gfx#305, Phase 3 sokol parity slice 1) ───────
// Optional, `@hasDecl`-gated on the `core.Backend(Impl)` wrapper: per-sprite
// curated shader effects (`flash`, `palette_swap`). `materialSupported` is the
// effect-level capability gate; `drawTextureProMaterial` is the material-aware
// draw. See src/gfx/material.zig for the raw-sokol_gfx rationale (sokol_gl can't
// carry a custom fragment shader). `registerLut` maps a LUT texture to the flat
// `aux_texture` handle a `palette_swap` draw expects. `resetMaterials` /
// `flushMaterials` are the per-frame lifecycle hooks driven by window.zig.
pub const materialSupported = material.materialSupported;
pub const drawTextureProMaterial = material.drawTextureProMaterial;
pub const registerLut = material.registerLut;
pub const resetMaterials = material.reset;
pub const flushMaterials = material.flush;

// ── Texture loading / decoding ─────────────────────────────────────────

pub const DecodedImage = texture.DecodedImage;
pub const loadTexture = texture.loadTexture;
pub const decodeImage = texture.decodeImage;
pub const uploadTexture = texture.uploadTexture;
pub const unloadTexture = texture.unloadTexture;
// GPU-compressed (ASTC) upload — the labelle-gfx `loadTextureFromMemory` seam
// dispatches to these via `@hasDecl` when the blob is compressed. sokol only
// exposes ASTC 4×4, so non-4×4 blobs fall back to the CPU decode path (#341).
pub const isCompressed = texture.isCompressed;
pub const uploadCompressed = texture.uploadCompressed;
// Header-only dims for the async asset-catalog adapter (engine#450), which
// splits worker-thread decode from main-thread upload and so can't use the
// synchronous seam — it reads dims here to set DecodedImage before upload.
pub const compressedDims = texture.compressedDims;

// ── Phase 4 font surface (labelle-gfx#258, labelle-engine#448) ─────────

pub const CodepointRange = font.CodepointRange;
pub const Glyph = font.Glyph;
pub const CodepointEntry = font.CodepointEntry;
pub const KernPair = font.KernPair;
pub const FontBakeParams = font.FontBakeParams;
pub const DecodedFont = font.DecodedFont;
pub const FontAtlas = font.FontAtlas;
pub const decodeFont = font.decodeFont;
pub const uploadFontAtlas = font.uploadFontAtlas;
pub const unloadFontAtlas = font.unloadFontAtlas;

// ── Test aggregation ───────────────────────────────────────────────────
//
// The build.zig's `gfx_compile_check` runs `b.addTest({ .root_module =
// gfx_mod })` over this file. Zig's test discovery walks `@import`s
// from the root, so we need to reference each submodule here for
// their tests to be visible — re-exporting decls counts as a
// reference, so the `pub const` decls above already pull every
// submodule in. The explicit `_ = std.testing.refAllDecls(...)` line
// below makes the dependency on the test-bearing modules ironclad
// even if a future refactor stops re-exporting a submodule's public
// surface.
const std = @import("std");
test {
    std.testing.refAllDecls(font);
}
