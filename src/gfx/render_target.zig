//! Render-target sub-surface + full-screen post-fx passes for the sokol gfx
//! backend (labelle-gfx#305 Phase 3). The sokol half of the post-fx contract
//! (labelle-core `backend_contract`): the five render-target decls
//! (`createRenderTarget`/`beginRenderTarget`/`endRenderTarget`/`drawRenderTarget`/
//! `destroyRenderTarget`) + the post-fx primitive (`applyPostPass` /
//! `postPassSupported`). The gfx `PostFxDriver` (RFC §2.4) drives these: it
//! redirects the scene into one offscreen target, runs a two-buffer ping-pong of
//! `applyPostPass(src→dst)` hops, then composites the final target to the
//! backbuffer with `drawRenderTarget`.
//!
//! ── Why a DEFERRED plan (the sokol ordering wrinkle) ──────────────────────
//! bgfx implements this by switching the active VIEW id; all views execute at
//! `bgfx.frame()`, so `beginRenderTarget`/`applyPostPass` can run inline (they
//! just tag submissions). sokol is different in TWO ways that force a deferred
//! model here:
//!   1. Passes are REAL GPU passes (`sg.beginPass`/`endPass`) and CANNOT nest.
//!      But the driver calls `beginRenderTarget` from INSIDE the game's render,
//!      after `window.beginPass` has already opened the backbuffer pass.
//!   2. The scene rides sokol_gl (`draw.zig`), whose commands are recorded into a
//!      CPU buffer and rasterised by a SINGLE `sgl.draw()` at `window.flushScene`
//!      — and (verified against the pinned sokol_gl.h) sokol_gl only REWINDS that
//!      buffer at `sg.commit`, NOT at `sgl.draw`, so it can be flushed exactly
//!      once per frame.
//! So the render-target/post-fx calls here do NOT touch the GPU immediately; they
//! RECORD a per-frame PLAN (scene target + the ordered pass hops + the final
//! composite). `window.flushScene` — the one sgl-flush seam — EXECUTES the plan:
//! it ends the (empty) backbuffer pass, rasterises the scene (sgl + materials)
//! into the scene target, runs each post-fx pass in its own offscreen pass, then
//! reopens the backbuffer and composites the final target into it (leaving that
//! pass open for the GUI + `endFrame`, exactly like the non-post-fx path). The
//! net submission order == execution order, so the driver's ping-pong is correct
//! on sokol with NO driver change (proven by post_fx_integration_golden.zig).
//!
//! Gizmos (rendered after `g.render()` but before `flushScene`) ride the same sgl
//! buffer, so they land in the scene target and are post-processed too — a small
//! honest deviation from bgfx (where gizmos draw straight to the primary), noted
//! for a later slice; the GUI (imgui, drawn AFTER `flushScene`) is NOT
//! post-processed and composites on top as usual.
//!
//! ── Degrade, never crash ─────────────────────────────────────────────────
//! No shader dialect for the live backend (D3D11/WGPU/Vulkan) → the whole stack
//! is a no-op and the frame renders straight to the backbuffer. `color_grade`
//! with a zero/unregistered LUT degrades to a straight src→dst blit.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const core = @import("labelle-core");
const types = @import("types.zig");
const state = @import("state.zig");
const material = @import("material.zig");
const shaders = @import("post_fx_shaders.zig");

const Color = types.Color;
const Rectangle = types.Rectangle;

const PostPass = core.backend_contract.PostPass;
const PostPassKind = core.backend_contract.PostPassKind;
const RenderTargetId = core.backend_contract.RenderTargetId;

// ── Backend-facing capability (contract decl) ───────────────────────────────

/// Which curated post-fx passes this backend advertises (labelle-gfx#305). sokol
/// implements all four built-ins (bloom / vignette / color_grade / crt) via the
/// hand-authored dialects in `post_fx_shaders.zig`. Two-context honesty, mirroring
/// `material.materialSupported`:
///   - COMPTIME (`core.postFxCapabilities` introspection): report the STATIC
///     capability (the passes this backend implements at all) — it cannot call
///     the runtime `sg.queryBackend()`.
///   - RUNTIME (the gfx driver's per-pass skip): additionally require a shader
///     dialect for the LIVE backend, so a D3D11/WGPU/Vulkan build honestly
///     reports FALSE (→ the driver skips the pass) rather than claiming support
///     then no-op'ing.
pub fn postPassSupported(kind: PostPassKind) bool {
    switch (kind) {
        .bloom, .vignette, .color_grade, .crt => {},
    }
    if (@inComptime()) return true;
    return pickSources() != null;
}

// ── GPU objects: render targets ─────────────────────────────────────────────

const RenderTarget = struct {
    color_img: sg.Image = .{},
    depth_img: sg.Image = .{},
    color_att_view: sg.View = .{}, // color attachment (for sg.Attachments)
    depth_att_view: sg.View = .{}, // depth-stencil attachment
    tex_view: sg.View = .{}, // sampleable view of color_img (as `src`)
    smp: sg.Sampler = .{},
    attachments: sg.Attachments = .{},
    width: u16 = 0,
    height: u16 = 0,

    fn isValid(self: RenderTarget) bool {
        return self.color_img.id != 0;
    }
};

const MAX_TARGETS = 64;
var targets: [MAX_TARGETS]RenderTarget = [_]RenderTarget{.{}} ** MAX_TARGETS;
var target_count: u32 = 0;

fn validId(id: RenderTargetId) bool {
    return id >= 1 and id <= target_count and targets[id - 1].isValid();
}

/// Pick the pool slot a new render target should occupy: the first freed
/// (inactive) slot in `0..target_count`, else `target_count` (append/grow). Pure
/// — no GPU — so the slot-reuse discipline is unit-testable without a device.
fn pickSlot() u32 {
    var i: u32 = 0;
    while (i < target_count) : (i += 1) {
        if (!targets[i].isValid()) return i;
    }
    return target_count;
}

/// Create an offscreen render target `w`×`h`. Returns a 1-based handle, or `0`
/// (INVALID) on a bad size / pool exhaustion / sokol resource failure.
///
/// Colour/depth FORMAT comes from the live environment (P1 correctness): the
/// sgl / material / post-fx pipelines all leave their colour/depth formats
/// DEFAULT, so sokol resolves them from `sg.setup`'s environment defaults
/// (`queryDesc().environment.defaults`). The render-target image MUST carry that
/// SAME format or the pipeline↔attachment format check fails. On Metal the
/// environment resolves to BGRA8 (what this used to hard-code, so this is a
/// no-op there); on GLCORE/GLES3 the swapchain default is RGBA8, so hard-coding
/// BGRA8 would have mismatched — query-from-env fixes GL/GLES. Fall back to
/// BGRA8 / DEPTH_STENCIL if the environment ever reports `.DEFAULT`.
///
/// `sample_count = 1` is FORCED (P3): even when the app runs the swapchain at
/// MSAA (environment sample_count > 1), post-fx targets are sampled as plain
/// textures — a multisample colour image isn't directly sampleable without a
/// resolve — so the offscreen targets (and the offscreen post-fx pipelines, see
/// `makePipeline`) stay single-sample regardless of the swapchain's MSAA level.
///
/// Slot reuse: a freed (inactive) slot is reused before the pool grows, so a game
/// that dynamically creates/destroys render targets does NOT exhaust the pool via
/// churn — the hard `MAX_TARGETS` cap is only reached when that many are LIVE at
/// once (same slot-reuse discipline as the material seam's LUT registry).
pub fn createRenderTarget(w: u16, h: u16) RenderTargetId {
    if (w == 0 or h == 0) return 0;

    // Prefer a freed slot; only grow the pool (and hit the hard cap) when none is
    // free. Determined BEFORE allocating GPU resources so an exhausted pool fails
    // cheaply without creating (then having to destroy) images/views.
    const slot = pickSlot();
    if (slot == target_count and target_count >= MAX_TARGETS) {
        std.log.warn("labelle-sokol: render-target pool exhausted ({d} live); post-fx/offscreen create failed", .{MAX_TARGETS});
        return 0;
    }

    // Match the live environment's colour/depth formats so the DEFAULT-format
    // pipelines draw into this target without a format mismatch (see doc above).
    const env = sg.queryDesc().environment.defaults;
    const color_fmt: sg.PixelFormat = if (env.color_format == .DEFAULT) .BGRA8 else env.color_format;
    const depth_fmt: sg.PixelFormat = if (env.depth_format == .DEFAULT) .DEPTH_STENCIL else env.depth_format;

    var rt: RenderTarget = .{ .width = w, .height = h };
    rt.color_img = sg.makeImage(.{
        .width = w,
        .height = h,
        .pixel_format = color_fmt,
        .sample_count = 1, // forced single-sample — post-fx samples this as a texture
        .usage = .{ .color_attachment = true, .immutable = true },
    });
    if (rt.color_img.id == 0) return 0;
    rt.depth_img = sg.makeImage(.{
        .width = w,
        .height = h,
        .pixel_format = depth_fmt,
        .sample_count = 1, // must match the colour attachment's sample_count
        .usage = .{ .depth_stencil_attachment = true, .immutable = true },
    });
    if (rt.depth_img.id == 0) {
        sg.destroyImage(rt.color_img);
        return 0;
    }
    rt.color_att_view = sg.makeView(.{ .color_attachment = .{ .image = rt.color_img } });
    rt.depth_att_view = sg.makeView(.{ .depth_stencil_attachment = .{ .image = rt.depth_img } });
    rt.tex_view = sg.makeView(.{ .texture = .{ .image = rt.color_img } });
    rt.smp = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    if (rt.color_att_view.id == 0 or rt.depth_att_view.id == 0 or rt.tex_view.id == 0 or rt.smp.id == 0) {
        destroyResources(&rt);
        return 0;
    }
    rt.attachments.colors[0] = rt.color_att_view;
    rt.attachments.depth_stencil = rt.depth_att_view;

    targets[slot] = rt;
    if (slot == target_count) target_count += 1; // grew the pool
    return slot + 1; // 1-based handle
}

fn destroyResources(rt: *RenderTarget) void {
    if (rt.tex_view.id != 0) sg.destroyView(rt.tex_view);
    if (rt.color_att_view.id != 0) sg.destroyView(rt.color_att_view);
    if (rt.depth_att_view.id != 0) sg.destroyView(rt.depth_att_view);
    if (rt.smp.id != 0) sg.destroySampler(rt.smp);
    if (rt.color_img.id != 0) sg.destroyImage(rt.color_img);
    if (rt.depth_img.id != 0) sg.destroyImage(rt.depth_img);
    rt.* = .{};
}

/// Release render target `id`. Safe no-op on an unknown / already-freed / invalid
/// handle (the `validId` guard). `destroyResources` empties the slot and marks it
/// INACTIVE (`color_img.id == 0`), so a later `createRenderTarget` reuses it (see
/// its slot-reuse scan) — handles stay stable, the pool never churns. The tail is
/// additionally compacted below so the common create-two-then-destroy-two driver
/// lifecycle fully recovers the high-water mark.
pub fn destroyRenderTarget(id: RenderTargetId) void {
    if (!validId(id)) return;
    destroyResources(&targets[id - 1]);
    // Shrink the high-water mark when the tail is freed so the common
    // create-two-then-destroy-two driver lifecycle recovers slots.
    while (target_count > 0 and !targets[target_count - 1].isValid()) target_count -= 1;
}

// ── Per-frame deferred plan ──────────────────────────────────────────────────

const QueuedPass = struct { pass: PostPass, src: RenderTargetId, dst: RenderTargetId };
const MAX_QUEUED = 16;

var plan_active: bool = false;
var scene_target: RenderTargetId = 0;
var queued: [MAX_QUEUED]QueuedPass = undefined;
var queued_len: u32 = 0;
var composite_id: RenderTargetId = 0;
var composite_dest: Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
var composite_tint: Color = types.white;
var has_composite: bool = false;

/// Reset the per-frame plan. Called from `window.beginFrame` (mirrors
/// `resetMaterials`). Zero-cost on frames with no post-fx.
pub fn resetFrame() void {
    plan_active = false;
    scene_target = 0;
    queued_len = 0;
    composite_id = 0;
    has_composite = false;
}

/// Redirect the frame's scene into render target `id`. Records the plan; the
/// actual offscreen pass is opened at `window.flushScene` (see file header).
pub fn beginRenderTarget(id: RenderTargetId) void {
    if (!validId(id)) return;
    if (!ensureInitialized()) return; // no dialect → whole stack degrades to no-op
    plan_active = true;
    scene_target = id;
}

/// End the scene redirection. Deferred model → nothing to flush here (the scene
/// sgl buffer is drained once at `window.flushScene`); kept for the contract's
/// begin/end symmetry.
pub fn endRenderTarget() void {}

/// Queue ONE full-screen post-fx pass (sample `src`, write `dst`). Executed in
/// order at `window.flushScene`. No-op outside an active redirection.
pub fn applyPostPass(pass: PostPass, src: RenderTargetId, dst: RenderTargetId) void {
    if (!plan_active) return;
    if (!validId(src) or !validId(dst) or src == dst) return;
    if (queued_len >= MAX_QUEUED) return;
    queued[queued_len] = .{ .pass = pass, .src = src, .dst = dst };
    queued_len += 1;
}

/// Composite render target `id` into the backbuffer at `dest` (SCREEN space,
/// top-left, Y-down, pixels), modulated by `tint`. During a post-fx frame this is
/// the FINAL blit; it is recorded and executed after the pass chain.
///
/// v1 LIMITATION (P4, deferred model): this only composites WITHIN an active
/// post-fx plan (between `beginRenderTarget` and `window.flushScene`) — the
/// no-op guard below. It is recorded into the per-frame plan and drawn at
/// `flushScene`, so a caller that produced a target in an EARLIER frame and
/// wants to composite it standalone (no active plan) is NOT supported today:
/// there is no armed plan for `flushScene` to execute, and drawing immediately
/// would need to open the lazily-deferred backbuffer pass out of band (see
/// `window.flushScene`/`ensureBackbufferPass`). The only consumer — the gfx
/// `PostFxDriver` — always calls `beginRenderTarget` first, so the standalone
/// path is unexercised. If a future feature needs it, wire a window-side
/// "composite-only" seam rather than compositing inline here.
pub fn drawRenderTarget(id: RenderTargetId, dest: Rectangle, tint: Color) void {
    if (!plan_active) return;
    if (!validId(id)) return;
    composite_id = id;
    composite_dest = dest;
    composite_tint = tint;
    has_composite = true;
}

// ── Plan execution (driven by window.flushScene) ─────────────────────────────

/// True when a post-fx redirection is armed for this frame.
pub fn postFxActive() bool {
    return plan_active and validId(scene_target);
}

/// Open the offscreen pass the scene rasterises into (CLEAR to the standard
/// backdrop). `window.flushScene` calls this, then `sgl.draw()` + `flushMaterials()`
/// while it is the active pass, then `endScenePassAndApply`.
/// MSAA caveat (P3): the scene target is single-sample, and the post-fx pass
/// pipelines are forced single-sample to match. The scene itself, however, is
/// drawn here by sokol_gl + the material seam, whose pipelines still resolve
/// their sample_count from the environment. On a NON-MSAA swapchain everything
/// is single-sample and consistent (the only configuration the goldens cover).
/// Under swapchain MSAA the sgl/material pipelines would need single-sample
/// variants when redirected into an RT — a broader change outside the post-fx
/// seam, tracked as a follow-up; forcing the RT + post-fx pipelines to 1 here is
/// the post-fx-owned half of that fix.
pub fn beginScenePass() void {
    const rt = targets[scene_target - 1];
    var action: sg.PassAction = .{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 30.0 / 255.0, .g = 30.0 / 255.0, .b = 35.0 / 255.0, .a = 1.0 },
    };
    sg.beginPass(.{ .action = action, .attachments = rt.attachments });
}

/// End the scene pass and run the queued post-fx pass chain (each pass in its own
/// offscreen pass — submission order == execution order on sokol).
pub fn endScenePassAndApply() void {
    sg.endPass();
    var i: u32 = 0;
    while (i < queued_len) : (i += 1) executePass(queued[i]);
}

/// Draw the final composite into the CURRENT (backbuffer) pass. `window.flushScene`
/// reopens the backbuffer before calling this, and leaves it open for the GUI +
/// `endFrame`.
pub fn compositePostFx() void {
    if (!has_composite or !validId(composite_id)) return;
    const rt = targets[composite_id - 1];
    drawTextureQuad(blit_blend_pip, rt.tex_view, rt.smp, composite_dest, composite_tint, true);
}

fn executePass(q: QueuedPass) void {
    // Re-validate at EXECUTE time. `applyPostPass` validated `src`/`dst` when the
    // pass was QUEUED, but this runs later at `flushScene`; a target destroyed
    // between queue and flush (e.g. a mid-frame hook calling `destroyRenderTarget`)
    // would otherwise index a freed slot — a use-after-free. Skip the pass instead
    // of crashing; the ping-pong chain simply drops this hop.
    if (!validId(q.src) or !validId(q.dst)) return;
    const s = targets[q.src - 1];
    const d = targets[q.dst - 1];

    var action: sg.PassAction = .{};
    // CLEAR (not DONTCARE) the colour on purpose. The full-screen quad overwrites
    // every dst texel, so DONTCARE *should* suffice — but when the driver's two-
    // buffer ping-pong writes a target it earlier SAMPLED as a texture (a write-
    // after-read on the same image), a DONTCARE load let Metal's tile renderer
    // skip the load/sync and occasionally produced an uninitialised (magenta)
    // target. A CLEAR forces the tile to initialise + orders the pass after the
    // prior read, which — together with the golden's steady-state capture — makes
    // the reused-target chain deterministic. Depth/stencil stay DONTCARE (unused).
    action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
    action.depth = .{ .load_action = .DONTCARE };
    action.stencil = .{ .load_action = .DONTCARE };
    sg.beginPass(.{ .action = action, .attachments = d.attachments });
    defer sg.endPass();

    // color_grade with a zero/unregistered LUT degrades to a straight blit so the
    // ping-pong chain stays contiguous (never a black frame) — matches bgfx.
    if (q.pass.kind == .color_grade) {
        const lut = material.lookupLut(q.pass.uniforms.aux_texture);
        if (lut == null) {
            // The blit pipeline has NO uniform block → pass null params.
            drawFullscreen(blit_opaque_pip, s.tex_view, s.smp, null, null);
            return;
        }
        drawFullscreen(color_grade_pip, s.tex_view, s.smp, lut.?, makeParams(q.pass, d.width, d.height));
        return;
    }

    drawFullscreen(programFor(q.pass.kind), s.tex_view, s.smp, null, makeParams(q.pass, d.width, d.height));
}

fn programFor(kind: PostPassKind) sg.Pipeline {
    return switch (kind) {
        .bloom => bloom_pip,
        .vignette => vignette_pip,
        .color_grade => color_grade_pip,
        .crt => crt_pip,
    };
}

// ── Uniform block (fragment stage, 48 bytes = 3×vec4, matches `u_postfx[3]`) ──

const PostFxParams = extern struct {
    params: [4]f32, // scalar0..3
    color: [4]f32, // r, g, b, 0
    texel: [4]f32, // 1/w, 1/h, w, h
};

fn makeParams(pass: PostPass, w: u16, h: u16) PostFxParams {
    const u = pass.uniforms;
    const wf: f32 = @floatFromInt(@max(w, 1));
    const hf: f32 = @floatFromInt(@max(h, 1));
    return .{
        .params = .{ u.scalar0, u.scalar1, u.scalar2, u.scalar3 },
        .color = .{ u.r, u.g, u.b, 0 },
        .texel = .{ 1.0 / wf, 1.0 / hf, wf, hf },
    };
}

// ── Full-screen quad + textured-quad draw helpers ────────────────────────────

const PostVertex = extern struct { x: f32, y: f32, u: f32, v: f32, r: f32, g: f32, b: f32, a: f32 };

// The full-screen quad (NDC -1..1, UV 0..1, white), matching bgfx's
// `fullscreenQuad`. On a TOP-LEFT-origin backend (Metal/D3D) NDC-top(+1) → v=0,
// so a plain sample of a render-target texture writes an upright copy and each
// offscreen post-fx pass is memory-preserving.
//
// P2 (GL/GLES correctness): on a BOTTOM-LEFT-origin backend (GLCORE/GLES3) a
// render-target's texel row 0 is the BOTTOM, so sampling v=0 at NDC-top would
// vertically FLIP each pass — an ODD-length pass stack (e.g. a lone vignette)
// then samples upside-down. `fullscreenVerts(flip_v)` flips the sampled V on
// those backends so every offscreen pass stays memory-preserving (parity no
// longer matters), exactly like Metal; the final composite's own GL flip
// (`drawTextureQuad`) then handles the one backbuffer-orientation correction.
// This mirrors the fix codex flagged on bgfx (the caps `originBottomLeft`
// V-flip). Metal (top-left → flip_v=false) is byte-identical to before.
// Immutable → uploaded once, reused by every post-fx pass and the opaque blit.
fn fullscreenVerts(flip_v: bool) [6]PostVertex {
    const v_top: f32 = if (flip_v) 1 else 0;
    const v_bot: f32 = if (flip_v) 0 else 1;
    return .{
        .{ .x = -1, .y = 1, .u = 0, .v = v_top, .r = 1, .g = 1, .b = 1, .a = 1 }, // TL
        .{ .x = 1, .y = 1, .u = 1, .v = v_top, .r = 1, .g = 1, .b = 1, .a = 1 }, // TR
        .{ .x = 1, .y = -1, .u = 1, .v = v_bot, .r = 1, .g = 1, .b = 1, .a = 1 }, // BR
        .{ .x = -1, .y = 1, .u = 0, .v = v_top, .r = 1, .g = 1, .b = 1, .a = 1 }, // TL
        .{ .x = 1, .y = -1, .u = 1, .v = v_bot, .r = 1, .g = 1, .b = 1, .a = 1 }, // BR
        .{ .x = -1, .y = -1, .u = 0, .v = v_bot, .r = 1, .g = 1, .b = 1, .a = 1 }, // BL
    };
}

/// True on backends whose render-target textures are BOTTOM-LEFT origin
/// (GLCORE/GLES3). Drives both the offscreen post-fx V-flip (`fullscreenVerts`)
/// and the composite V-flip (`drawTextureQuad`). sokol reports this via
/// `queryFeatures().origin_top_left`.
fn originBottomLeft() bool {
    return !sg.queryFeatures().origin_top_left;
}

/// Bind `tex`/`smp` (+ optional `lut`) and draw the immutable full-screen quad
/// through `pip`. sokol requires the strict order applyPipeline → applyBindings →
/// applyUniforms → draw, so `uni` (the fragment uniform block, or null for the
/// blit pipeline which has none) is uploaded HERE, after the pipeline is bound.
fn drawFullscreen(pip: sg.Pipeline, tex: sg.View, smp: sg.Sampler, lut: ?material.LutEntry, uni: ?PostFxParams) void {
    sg.applyPipeline(pip);
    var bindings: sg.Bindings = .{};
    bindings.vertex_buffers[0] = fullscreen_vbuf;
    bindings.views[0] = tex;
    bindings.samplers[0] = smp;
    if (lut) |l| {
        bindings.views[1] = l.view;
        bindings.samplers[1] = l.smp;
    }
    sg.applyBindings(bindings);
    if (uni) |u| {
        var p = u;
        sg.applyUniforms(0, sg.asRange(&p));
    }
    sg.draw(0, 6, 1);
}

/// Draw render-target texture `tex` at screen-space `dest`, modulated by `tint`,
/// through `pip` (the alpha-blended blit) — the composite. Streams the 6 quad
/// verts into `composite_vbuf` (updated once per frame; the composite is the only
/// per-frame quad). `flip_gl_v` mirrors bgfx's `originBottomLeft` handling: GL
/// render-target textures are bottom-left origin, so V is flipped there to keep
/// the composited image upright; Metal / D3D sample straight.
fn drawTextureQuad(pip: sg.Pipeline, tex: sg.View, smp: sg.Sampler, dest: Rectangle, tint: Color, flip_gl_v: bool) void {
    const flip = flip_gl_v and originBottomLeft();
    const x0 = state.toNdcX(dest.x);
    const y0 = state.toNdcY(dest.y);
    const x1 = state.toNdcX(dest.x + dest.width);
    const y1 = state.toNdcY(dest.y + dest.height);
    const v_top: f32 = if (flip) 1 else 0;
    const v_bot: f32 = if (flip) 0 else 1;
    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;
    // corners: TL(x0,y0) TR(x1,y0) BR(x1,y1) BL(x0,y1); UV top=v_top bottom=v_bot.
    const verts = [6]PostVertex{
        .{ .x = x0, .y = y0, .u = 0, .v = v_top, .r = r, .g = g, .b = b, .a = a },
        .{ .x = x1, .y = y0, .u = 1, .v = v_top, .r = r, .g = g, .b = b, .a = a },
        .{ .x = x1, .y = y1, .u = 1, .v = v_bot, .r = r, .g = g, .b = b, .a = a },
        .{ .x = x0, .y = y0, .u = 0, .v = v_top, .r = r, .g = g, .b = b, .a = a },
        .{ .x = x1, .y = y1, .u = 1, .v = v_bot, .r = r, .g = g, .b = b, .a = a },
        .{ .x = x0, .y = y1, .u = 0, .v = v_bot, .r = r, .g = g, .b = b, .a = a },
    };
    sg.updateBuffer(composite_vbuf, sg.asRange(&verts));
    sg.applyPipeline(pip);
    var bindings: sg.Bindings = .{};
    bindings.vertex_buffers[0] = composite_vbuf;
    bindings.views[0] = tex;
    bindings.samplers[0] = smp;
    sg.applyBindings(bindings);
    sg.draw(0, 6, 1);
}

// ── Lazily-built pipelines / shaders / buffers ───────────────────────────────

var initialized: bool = false;
var supported_backend: bool = false;
var fullscreen_vbuf: sg.Buffer = .{};
var composite_vbuf: sg.Buffer = .{};
var bloom_pip: sg.Pipeline = .{};
var vignette_pip: sg.Pipeline = .{};
var color_grade_pip: sg.Pipeline = .{};
var crt_pip: sg.Pipeline = .{};
var blit_opaque_pip: sg.Pipeline = .{};
var blit_blend_pip: sg.Pipeline = .{};

const ShaderSources = struct {
    vs: [*c]const u8,
    fs_bloom: [*c]const u8,
    fs_vignette: [*c]const u8,
    fs_color_grade: [*c]const u8,
    fs_crt: [*c]const u8,
    fs_blit: [*c]const u8,
    metal: bool,
};

/// The hand-written shader dialect for the live backend, or null when this
/// backend has none yet (→ the whole post-fx stack degrades to no-op).
fn pickSources() ?ShaderSources {
    return switch (sg.queryBackend()) {
        .GLCORE => .{
            .vs = shaders.vs_glsl410,
            .fs_bloom = shaders.fs_bloom_glsl410,
            .fs_vignette = shaders.fs_vignette_glsl410,
            .fs_color_grade = shaders.fs_color_grade_glsl410,
            .fs_crt = shaders.fs_crt_glsl410,
            .fs_blit = shaders.fs_blit_glsl410,
            .metal = false,
        },
        .GLES3 => .{
            .vs = shaders.vs_glsl300es,
            .fs_bloom = shaders.fs_bloom_glsl300es,
            .fs_vignette = shaders.fs_vignette_glsl300es,
            .fs_color_grade = shaders.fs_color_grade_glsl300es,
            .fs_crt = shaders.fs_crt_glsl300es,
            .fs_blit = shaders.fs_blit_glsl300es,
            .metal = false,
        },
        .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR => .{
            .vs = shaders.vs_metal,
            .fs_bloom = shaders.fs_bloom_metal,
            .fs_vignette = shaders.fs_vignette_metal,
            .fs_color_grade = shaders.fs_color_grade_metal,
            .fs_crt = shaders.fs_crt_metal,
            .fs_blit = shaders.fs_blit_metal,
            .metal = true,
        },
        .D3D11, .WGPU, .VULKAN, .DUMMY => null,
    };
}

const ShaderOpts = struct { has_params: bool, has_lut: bool };

fn makeShader(srcs: ShaderSources, fs: [*c]const u8, label: [*c]const u8, opts: ShaderOpts) sg.Shader {
    var desc: sg.ShaderDesc = .{};
    desc.label = label;
    desc.vertex_func.source = srcs.vs;
    desc.fragment_func.source = fs;
    if (srcs.metal) {
        desc.vertex_func.entry = "main0";
        desc.fragment_func.entry = "main0";
    }
    desc.attrs[0] = .{ .base_type = .FLOAT, .glsl_name = "position" };
    desc.attrs[1] = .{ .base_type = .FLOAT, .glsl_name = "texcoord0" };
    desc.attrs[2] = .{ .base_type = .FLOAT, .glsl_name = "color0" };

    if (opts.has_params) {
        desc.uniform_blocks[0].stage = .FRAGMENT;
        desc.uniform_blocks[0].size = @sizeOf(PostFxParams);
        desc.uniform_blocks[0].msl_buffer_n = 0;
        desc.uniform_blocks[0].glsl_uniforms[0] = .{
            .type = .FLOAT4,
            .array_count = 3,
            .glsl_name = "u_postfx",
        };
    }

    desc.views[0].texture = .{ .stage = .FRAGMENT, .image_type = ._2D, .sample_type = .FLOAT, .msl_texture_n = 0 };
    desc.samplers[0] = .{ .stage = .FRAGMENT, .sampler_type = .FILTERING, .msl_sampler_n = 0 };
    desc.texture_sampler_pairs[0] = .{ .stage = .FRAGMENT, .view_slot = 0, .sampler_slot = 0, .glsl_name = "tex_smp" };

    if (opts.has_lut) {
        desc.views[1].texture = .{ .stage = .FRAGMENT, .image_type = ._2D, .sample_type = .FLOAT, .msl_texture_n = 1 };
        desc.samplers[1] = .{ .stage = .FRAGMENT, .sampler_type = .FILTERING, .msl_sampler_n = 1 };
        desc.texture_sampler_pairs[1] = .{ .stage = .FRAGMENT, .view_slot = 1, .sampler_slot = 1, .glsl_name = "lut_smp" };
    }
    return sg.makeShader(desc);
}

/// Build a post-fx pipeline. `offscreen` pipelines (the pass chain + the opaque
/// degrade blit) draw into single-sample render targets, so their sample_count is
/// FORCED to 1 (P3) to stay compatible under swapchain MSAA — matching the RT
/// images in `createRenderTarget`. The composite blit (`offscreen = false`) draws
/// into the backbuffer, so it leaves sample_count DEFAULT and sokol resolves it
/// from the environment (== the swapchain's MSAA level). On a non-MSAA swapchain
/// both resolve to 1, so `offscreen = true` is a no-op there (incl. Metal golden).
fn makePipeline(shader: sg.Shader, blend: bool, offscreen: bool) sg.Pipeline {
    var pdesc: sg.PipelineDesc = .{};
    pdesc.shader = shader;
    pdesc.label = "postfx-pipeline";
    pdesc.primitive_type = .TRIANGLES;
    pdesc.layout.attrs[0] = .{ .format = .FLOAT2, .offset = 0 };
    pdesc.layout.attrs[1] = .{ .format = .FLOAT2, .offset = 8 };
    pdesc.layout.attrs[2] = .{ .format = .FLOAT4, .offset = 16 };
    pdesc.layout.buffers[0].stride = @sizeOf(PostVertex);
    // Colour/depth FORMATS left DEFAULT so sokol resolves them from the
    // environment — the SAME formats the render targets now carry (they query the
    // same environment in `createRenderTarget`), so the pipeline draws into
    // offscreen RTs and the backbuffer alike. SAMPLE COUNT: offscreen → 1 (RTs are
    // single-sample); composite → DEFAULT (matches the backbuffer/swapchain MSAA).
    if (offscreen) pdesc.sample_count = 1;
    if (blend) {
        pdesc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
    }
    return sg.makePipeline(pdesc);
}

/// Lazily build the full-screen buffers + all six pipelines on first use.
/// Idempotent. Returns false (and sets `supported_backend=false`) when the live
/// backend has no authored dialect, so the whole stack degrades.
fn ensureInitialized() bool {
    if (initialized) return supported_backend;
    initialized = true;

    const srcs = pickSources() orelse {
        std.log.warn(
            "labelle-sokol: post-fx unavailable on backend {s} (no shader dialect); stack degrades to no-op",
            .{@tagName(sg.queryBackend())},
        );
        supported_backend = false;
        return false;
    };

    // Build the immutable full-screen quad with the sampled V flipped on
    // bottom-left-origin backends (GL/GLES) so each offscreen pass is
    // memory-preserving there — see `fullscreenVerts` (P2).
    const fs_verts = fullscreenVerts(originBottomLeft());
    fullscreen_vbuf = sg.makeBuffer(.{
        .usage = .{ .vertex_buffer = true, .immutable = true },
        .data = sg.asRange(&fs_verts),
        .label = "postfx-fullscreen-vbuf",
    });
    composite_vbuf = sg.makeBuffer(.{
        .size = @sizeOf(PostVertex) * 6,
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "postfx-composite-vbuf",
    });
    if (fullscreen_vbuf.id == 0 or composite_vbuf.id == 0) {
        cleanupFailedInit(&.{}, &.{});
        supported_backend = false;
        return false;
    }

    const shaders_arr = [_]sg.Shader{
        makeShader(srcs, srcs.fs_bloom, "postfx-bloom", .{ .has_params = true, .has_lut = false }),
        makeShader(srcs, srcs.fs_vignette, "postfx-vignette", .{ .has_params = true, .has_lut = false }),
        makeShader(srcs, srcs.fs_color_grade, "postfx-color-grade", .{ .has_params = true, .has_lut = true }),
        makeShader(srcs, srcs.fs_crt, "postfx-crt", .{ .has_params = true, .has_lut = false }),
        makeShader(srcs, srcs.fs_blit, "postfx-blit", .{ .has_params = false, .has_lut = false }),
    };
    for (shaders_arr) |s| {
        if (s.id == 0) {
            // Destroy the buffers + any shaders that DID create before bailing, so
            // a partial-build failure doesn't leak GPU resources.
            cleanupFailedInit(&shaders_arr, &.{});
            supported_backend = false;
            return false;
        }
    }
    const shd_bloom = shaders_arr[0];
    const shd_vignette = shaders_arr[1];
    const shd_color_grade = shaders_arr[2];
    const shd_crt = shaders_arr[3];
    const shd_blit = shaders_arr[4];

    // Offscreen pass pipelines (single-sample RTs, P3) vs the composite blit
    // (backbuffer, DEFAULT sample count == swapchain MSAA).
    bloom_pip = makePipeline(shd_bloom, false, true);
    vignette_pip = makePipeline(shd_vignette, false, true);
    color_grade_pip = makePipeline(shd_color_grade, false, true);
    crt_pip = makePipeline(shd_crt, false, true);
    blit_opaque_pip = makePipeline(shd_blit, false, true);
    blit_blend_pip = makePipeline(shd_blit, true, false);
    const pips_arr = [_]sg.Pipeline{ bloom_pip, vignette_pip, color_grade_pip, crt_pip, blit_opaque_pip, blit_blend_pip };
    for (pips_arr) |p| {
        if (p.id == 0) {
            // Destroy the buffers, shaders, and any pipelines built so far.
            cleanupFailedInit(&shaders_arr, &pips_arr);
            supported_backend = false;
            return false;
        }
    }

    supported_backend = true;
    return true;
}

/// Destroy the GPU resources an aborted `ensureInitialized` had created so far,
/// so a partial-build failure degrades cleanly WITHOUT leaking sg buffers /
/// shaders / pipelines. Resets the pipeline + buffer globals back to the empty
/// (not-initialised) state. Mirrors the material seam's partial-build cleanup.
fn cleanupFailedInit(shds: []const sg.Shader, pips: []const sg.Pipeline) void {
    for (pips) |p| if (p.id != 0) sg.destroyPipeline(p);
    for (shds) |s| if (s.id != 0) sg.destroyShader(s);
    if (fullscreen_vbuf.id != 0) sg.destroyBuffer(fullscreen_vbuf);
    if (composite_vbuf.id != 0) sg.destroyBuffer(composite_vbuf);
    fullscreen_vbuf = .{};
    composite_vbuf = .{};
    bloom_pip = .{};
    vignette_pip = .{};
    color_grade_pip = .{};
    crt_pip = .{};
    blit_opaque_pip = .{};
    blit_blend_pip = .{};
}

// ── Tests (pure-CPU: capability gate + contract introspection) ───────────────

test "postPassSupported advertises all four built-ins (comptime)" {
    try std.testing.expect(comptime postPassSupported(.bloom));
    try std.testing.expect(comptime postPassSupported(.vignette));
    try std.testing.expect(comptime postPassSupported(.color_grade));
    try std.testing.expect(comptime postPassSupported(.crt));
}

test "postFxCapabilities resolves to all four passes" {
    const caps = comptime core.backend_contract.postFxCapabilities(@This());
    try std.testing.expectEqual(@as(usize, 4), caps.passes.len);
}

test "render-target sub-surface is complete (all five decls present)" {
    try std.testing.expect(comptime core.backend_contract.hasRenderTargetSubSurface(@This()));
    try std.testing.expectEqual(@as(usize, 0), comptime core.backend_contract.missingRenderTargetDecls(@This()).len);
}

test "PostFxParams is 3 vec4 (48 bytes)" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(PostFxParams));
}

test "validId rejects 0 and out-of-range without touching GPU" {
    const saved = target_count;
    defer target_count = saved;
    target_count = 0;
    try std.testing.expect(!validId(0));
    try std.testing.expect(!validId(1));
}

test "pickSlot reuses a freed hole before growing the pool" {
    const saved_count = target_count;
    const saved = targets;
    defer {
        target_count = saved_count;
        targets = saved;
    }

    // Empty pool → append at 0.
    target_count = 0;
    try std.testing.expectEqual(@as(u32, 0), pickSlot());

    // Three live targets, no hole → append at the tail (grows the pool).
    target_count = 3;
    targets[0].color_img.id = 1;
    targets[1].color_img.id = 2;
    targets[2].color_img.id = 3;
    try std.testing.expectEqual(@as(u32, 3), pickSlot());

    // Free the MIDDLE one → the next create reuses that hole (no growth), so a
    // create/destroy-churn game never walks off the end of the pool.
    targets[1] = .{}; // color_img.id = 0 → inactive
    try std.testing.expectEqual(@as(u32, 1), pickSlot());

    // Refill the hole, free the TAIL → reuse the tail hole.
    targets[1].color_img.id = 9;
    targets[2] = .{};
    try std.testing.expectEqual(@as(u32, 2), pickSlot());
}
