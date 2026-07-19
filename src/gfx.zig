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
const render_target = @import("gfx/render_target.zig");

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

// ── Material seam (labelle-gfx#305, Phase 3 — full curated set) ─────────
// Optional, `@hasDecl`-gated on the `core.Backend(Impl)` wrapper: per-sprite
// curated shader effects (`flash`, `palette_swap`, `dissolve`, `outline`).
// `materialSupported` is the effect-level capability gate;
// `drawTextureProMaterial` is the material-aware draw. See src/gfx/material.zig
// for the raw-sokol_gfx rationale (sokol_gl can't carry a custom fragment
// shader). `registerLut` maps an aux texture (palette LUT ramp / optional
// dissolve noise texture) to the flat `aux_texture` handle a material draw
// expects. `resetMaterials` / `flushMaterials` are the per-frame lifecycle
// hooks driven by window.zig.
//
// Version gate: the assembler UNIFIES the *game's* labelle-core onto every
// backend module (backend_gfx included — see the Android build's single
// `-Mlabelle-core` shared by `--dep labelle-core` on backend_gfx), so THIS
// module must compile against whatever core the game pins, NOT this repo's own
// pin. The material seam types (`MaterialEffect` / `Material` / `MaterialUniforms`)
// only exist in core >= v1.25.0, so a game on an older core (e.g. an Android
// example still on 1.24.0) would otherwise fail to resolve them and break the
// build. `has_material` gates the whole seam: when the linked core predates it,
// every re-export collapses to a no-op and `material.zig`'s body (which
// references `core.backend_contract.MaterialEffect`) is never analyzed. A game
// on an old core simply gets no materials — a quality degradation, never a
// compile error. (bgfx does not gate today; it just isn't CI-built against an
// old-core Android example that would trip it.)
const core = @import("labelle-core");
const has_material = @hasDecl(core.backend_contract, "MaterialEffect");
pub const materialSupported = if (has_material) material.materialSupported else {};
pub const drawTextureProMaterial = if (has_material) material.drawTextureProMaterial else {};
pub const registerLut = if (has_material) material.registerLut else {};
pub fn resetMaterials() void {
    if (has_material) material.reset();
}
pub fn flushMaterials() void {
    if (has_material) material.flush();
}

// ── Render-target sub-surface + post-fx seam (labelle-gfx#305, Phase 3) ──────
// Optional, gated on `@hasDecl(core.backend_contract, "PostPass")` (core >=
// v1.26.0) exactly like the material seam above: a game on an older core simply
// gets no render targets / post-fx (the whole stack becomes the straight-to-
// backbuffer path in the gfx `PostFxDriver`), never a compile error. When gated
// ON, gfx.zig re-exports render_target.zig's five render-target contract decls +
// `applyPostPass`/`postPassSupported` so `core.Backend(Impl)` picks them up (all
// five present ⇒ `hasRenderTargetSubSurface`), plus the window-facing per-frame
// hooks the frame host drives (`resetRenderTargets` at beginFrame; the deferred
// plan executed at flushScene). See src/gfx/render_target.zig for the deferred-
// plan rationale (sokol passes can't nest + the single sgl flush).
const has_post_fx = @hasDecl(core.backend_contract, "PostPass");
// Re-export the contract value types so callers (goldens, the engine) name them
// through `gfx.*` without importing labelle-core directly — mirroring the bgfx
// backend. Gated: on an older core these resolve to `void`.
pub const PostPass = if (has_post_fx) core.backend_contract.PostPass else void;
pub const PostPassKind = if (has_post_fx) core.backend_contract.PostPassKind else void;
pub const PostPassUniforms = if (has_post_fx) core.backend_contract.PostPassUniforms else void;
pub const RenderTargetId = if (has_post_fx) core.backend_contract.RenderTargetId else void;
/// The invalid render-target handle (`createRenderTarget` returns this on failure).
pub const INVALID_RENDER_TARGET: if (has_post_fx) core.backend_contract.RenderTargetId else u32 = 0;
pub const createRenderTarget = if (has_post_fx) render_target.createRenderTarget else {};
pub const beginRenderTarget = if (has_post_fx) render_target.beginRenderTarget else {};
pub const endRenderTarget = if (has_post_fx) render_target.endRenderTarget else {};
pub const drawRenderTarget = if (has_post_fx) render_target.drawRenderTarget else {};
pub const destroyRenderTarget = if (has_post_fx) render_target.destroyRenderTarget else {};
pub const applyPostPass = if (has_post_fx) render_target.applyPostPass else {};
pub const postPassSupported = if (has_post_fx) render_target.postPassSupported else {};

/// Reset the per-frame post-fx plan. Driven by `window.beginFrame`.
pub fn resetRenderTargets() void {
    if (has_post_fx) render_target.resetFrame();
}
/// True when a post-fx redirection is armed this frame (`window.flushScene`).
pub fn postFxActive() bool {
    return if (has_post_fx) render_target.postFxActive() else false;
}
/// Open the offscreen scene pass (`window.flushScene`, before the sgl flush).
pub fn beginPostFxScenePass() void {
    if (has_post_fx) render_target.beginScenePass();
}
/// End the scene pass + run the queued post-fx pass chain (`window.flushScene`).
pub fn endPostFxScenePassAndApply() void {
    if (has_post_fx) render_target.endScenePassAndApply();
}
/// Composite the final target into the (reopened) backbuffer (`window.flushScene`).
pub fn compositePostFx() void {
    if (has_post_fx) render_target.compositePostFx();
}

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
