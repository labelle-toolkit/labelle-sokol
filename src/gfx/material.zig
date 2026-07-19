//! Material seam for the sokol gfx backend (labelle-gfx#305, Phase 3 — the
//! FULL curated set: per-sprite `flash`, `palette_swap`, `dissolve`, `outline`).
//!
//! ── Why this can't ride sokol_gl ─────────────────────────────────────────
//! Sprites in this backend draw through sokol_gl (`draw.zig`), whose FRAGMENT
//! shader is FIXED (sokol_gl ignores the `.shader` field of any pipeline you
//! hand it — see sokol_gl.h `sgl_make_pipeline` docs). A material effect IS a
//! custom fragment shader, so it cannot go through sokol_gl at all. This module
//! drops to raw sokol_gfx: its own `sg.Shader` + `sg.Pipeline` per effect, a
//! streamed vertex buffer, and explicit `sg.draw` calls.
//!
//! ── Compositing / z-order (honest limitation of slice 1) ─────────────────
//! sokol_gl records the whole frame's sprites into a CPU command buffer and
//! flushes them in ONE `sgl.draw()` (which only rewinds on `sg_commit`, so a
//! partial mid-frame flush would double-paint — see window.zig `endFrame`). A
//! raw-`sg` material draw therefore can't be interleaved at its exact z-index
//! inside that batch. Instead material draws are QUEUED and replayed by
//! `flush()` immediately AFTER `sgl.draw()` in `window.flushScene()`, so they
//! composite ON TOP of the sprite batch. For the common case (a flashing /
//! recoloured foreground character) that is the right layer; true per-sprite
//! interleaving needs the sprite path itself moved off sokol_gl and is out of
//! scope for this slice (tracked for a later slice alongside render targets).
//!
//! ── Degrade, never crash ─────────────────────────────────────────────────
//! `drawTextureProMaterial` falls back to a plain `drawTexturePro` (via
//! sokol_gl) whenever it cannot honour the effect: an unsupported effect, a
//! backend with no shader dialect here (D3D11/WGPU/Vulkan), `palette_swap` with
//! no/dead LUT (`aux_texture == 0`), a PER-EFFECT pipeline that failed to build
//! on this driver (the other effects keep working — bgfx per-effect isolation
//! parity), or a full queue. `dissolve` NEVER degrades on a missing noise
//! texture: `aux_texture == 0`/dead falls back to the built-in procedural noise
//! (bgfx parity — never a black quad, never a plain sprite).

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const core = @import("labelle-core");
const types = @import("types.zig");
const state = @import("state.zig");
const draw = @import("draw.zig");
const shaders = @import("material_shaders.zig");

const Texture = types.Texture;
const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;

const MaterialEffect = core.backend_contract.MaterialEffect;
const MaterialUniforms = core.backend_contract.MaterialUniforms;
const Material = core.backend_contract.Material;

// ── Backend-facing capability (contract decl) ───────────────────────────────

/// Effect-level capability gate consumed by `core.Backend(Impl)` and
/// `core.materialCapabilities`. sokol implements the FULL curated set —
/// `flash`, `palette_swap`, `dissolve`, `outline`; only `none` (the no-material
/// fast path) reports false.
///
/// Two-context honesty:
///   - COMPTIME (the contract's `materialCapabilities` introspection, which
///     evaluates this in a `comptime` block): report the STATIC capability —
///     the effects this backend implements at all. It CANNOT call
///     `sg.queryBackend()` (a runtime C call), and the manifest / capability
///     mirror wants the backend-agnostic answer anyway.
///   - RUNTIME (the per-draw `core.Backend(Impl)` gate): additionally require a
///     shader dialect for the LIVE graphics backend. `pickSources()` returns
///     null on `D3D11` / `WGPU` / `VULKAN` (no hand-authored dialect yet), so
///     every effect on those backends reports FALSE — honest, rather than
///     claiming support then silently degrading to a plain sprite. (A single
///     effect whose PIPELINE failed to build on an otherwise-supported backend
///     is finer-grained still — gated per-draw via `effectReady`, bgfx parity.)
pub fn materialSupported(effect: MaterialEffect) bool {
    const implemented = switch (effect) {
        .flash, .palette_swap, .dissolve, .outline => true,
        .none => false,
    };
    if (!implemented) return false;
    if (@inComptime()) return true;
    // Runtime: honest about the live backend's dialect availability.
    return pickSources() != null;
}

// ── Vertex + uniform layout ─────────────────────────────────────────────────

const MaterialVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Fragment-stage uniform block. flash/palette declare `u_material[2]` (the
/// first two vec4s, 32 bytes — `flush` uploads only that prefix, keeping those
/// shaders byte-identical to slice 1); dissolve/outline declare `u_material[4]`
/// (all 64 bytes). Matches the bgfx uniform packing
/// (`programs.zig submitMaterialTriangles`):
///   color  = MaterialUniforms r,g,b,a (flash colour / dissolve burn-edge glow
///            / outline colour; unused by palette)
///   params = (scalar0, scalar1, aux_count, use_noise) — flash: .x=amount;
///            palette: .z=count; dissolve: .x=threshold .y=edge_width
///            .w=1 when a noise texture is bound at unit 1; outline:
///            .x=thickness(px) .y=softness
///   texel  = (1/w, 1/h, w, h) — sprite texture pixel size (outline px→UV)
///   rect   = (u0, v0, u1, v1) — the source frame in whole-atlas UV space
///            ((0,0,1,1) for a standalone texture); dissolve's sprite-local
///            noise remap + outline's per-frame tap gate
const MaterialFsParams = extern struct {
    color: [4]f32,
    params: [4]f32,
    texel: [4]f32 = .{ 0, 0, 0, 0 },
    rect: [4]f32 = .{ 0, 0, 1, 1 },
};

/// Byte size of the uniform block `effect`'s shader declares (see above).
fn uniformSize(effect: MaterialEffect) usize {
    return switch (effect) {
        .dissolve, .outline => @sizeOf(MaterialFsParams), // u_material[4]
        else => 2 * @sizeOf([4]f32), // u_material[2] prefix
    };
}

// One deferred material draw: its 6 NDC vertices (two triangles) + everything
// `flush()` needs to bind. Handles (views/samplers) stay valid for the frame.
const QueuedDraw = struct {
    base: u32,
    effect: MaterialEffect,
    fs: MaterialFsParams,
    tex_view: sg.View,
    tex_smp: sg.Sampler,
    lut_view: sg.View,
    lut_smp: sg.Sampler,
};

// Per-frame capacity. Overflow degrades to a plain sprite (never a crash /
// never a realloc mid-frame). 1024 material sprites/frame is far above any
// realistic count (flashes/recolours are a small subset of a scene).
const MAX_DRAWS = 1024;
const MAX_VERTS = MAX_DRAWS * 6;

var vertices: [MAX_VERTS]MaterialVertex = undefined;
var vert_count: u32 = 0;
var queue: [MAX_DRAWS]QueuedDraw = undefined;
var queue_len: u32 = 0;

// ── Lazily-built GPU objects ────────────────────────────────────────────────

var initialized: bool = false;
var supported_backend: bool = false;
var vbuf: sg.Buffer = .{};
var flash_pip: sg.Pipeline = .{};
var palette_pip: sg.Pipeline = .{};
var dissolve_pip: sg.Pipeline = .{};
var outline_pip: sg.Pipeline = .{};
// Per-effect readiness (bgfx per-effect isolation parity, #49 finding A): a
// shader/pipeline build failure in ONE effect (e.g. a driver rejecting
// fs_outline) leaves the OTHERS valid — only the failed effect degrades to a
// plain sprite, never the whole seam. Indexed by `effectIndex`.
var effect_ready = [4]bool{ false, false, false, false };

fn effectIndex(effect: MaterialEffect) ?usize {
    return switch (effect) {
        .flash => 0,
        .palette_swap => 1,
        .dissolve => 2,
        .outline => 3,
        else => null,
    };
}

/// True when `effect`'s pipeline built + validated on this driver (and the
/// shared vertex buffer exists). Per-draw gate — see `effect_ready`.
fn effectReady(effect: MaterialEffect) bool {
    const i = effectIndex(effect) orelse return false;
    return supported_backend and effect_ready[i];
}

const ShaderSources = struct {
    vs: [*c]const u8,
    fs_flash: [*c]const u8,
    fs_palette: [*c]const u8,
    fs_dissolve: [*c]const u8,
    fs_outline: [*c]const u8,
    metal: bool,
};

/// Pick the hand-written shader dialect for the live backend, or null when this
/// backend has none yet (→ the whole material path degrades to plain sprites).
fn pickSources() ?ShaderSources {
    return switch (sg.queryBackend()) {
        .GLCORE => .{
            .vs = shaders.vs_glsl410,
            .fs_flash = shaders.fs_flash_glsl410,
            .fs_palette = shaders.fs_palette_glsl410,
            .fs_dissolve = shaders.fs_dissolve_glsl410,
            .fs_outline = shaders.fs_outline_glsl410,
            .metal = false,
        },
        .GLES3 => .{
            .vs = shaders.vs_glsl300es,
            .fs_flash = shaders.fs_flash_glsl300es,
            .fs_palette = shaders.fs_palette_glsl300es,
            .fs_dissolve = shaders.fs_dissolve_glsl300es,
            .fs_outline = shaders.fs_outline_glsl300es,
            .metal = false,
        },
        .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR => .{
            .vs = shaders.vs_metal,
            .fs_flash = shaders.fs_flash_metal,
            .fs_palette = shaders.fs_palette_metal,
            .fs_dissolve = shaders.fs_dissolve_metal,
            .fs_outline = shaders.fs_outline_metal,
            .metal = true,
        },
        // No HLSL / WGSL / SPIR-V dialect authored yet — degrade (documented).
        .D3D11, .WGPU, .VULKAN, .DUMMY => null,
    };
}

/// Per-effect shader-shape knobs for `makeMaterialShader`.
const ShaderShape = struct {
    label: [*c]const u8,
    /// Declares the unit-1 aux sampler pair (`lut_smp`): the LUT ramp for
    /// palette_swap, the (optional) noise texture for dissolve.
    aux: bool,
    /// `u_material` vec4 count: 2 for flash/palette, 4 for dissolve/outline
    /// (which add texel + rect). MUST match the shader's declared array size.
    vec4_count: u16,
};

fn makeMaterialShader(srcs: ShaderSources, fs: [*c]const u8, shape: ShaderShape) sg.Shader {
    var desc: sg.ShaderDesc = .{};
    desc.label = shape.label;
    desc.vertex_func.source = srcs.vs;
    desc.fragment_func.source = fs;
    if (srcs.metal) {
        desc.vertex_func.entry = "main0";
        desc.fragment_func.entry = "main0";
    }

    // Vertex attributes — match MaterialVertex + the shader `location`s.
    desc.attrs[0] = .{ .base_type = .FLOAT, .glsl_name = "position" };
    desc.attrs[1] = .{ .base_type = .FLOAT, .glsl_name = "texcoord0" };
    desc.attrs[2] = .{ .base_type = .FLOAT, .glsl_name = "color0" };

    // Fragment uniform block `u_material` = vec4_count×vec4, bind slot 0.
    desc.uniform_blocks[0].stage = .FRAGMENT;
    desc.uniform_blocks[0].size = @as(u32, shape.vec4_count) * @sizeOf([4]f32);
    desc.uniform_blocks[0].msl_buffer_n = 0;
    desc.uniform_blocks[0].glsl_uniforms[0] = .{
        .type = .FLOAT4,
        .array_count = shape.vec4_count,
        .glsl_name = "u_material",
    };

    // Sprite texture at unit 0.
    desc.views[0].texture = .{
        .stage = .FRAGMENT,
        .image_type = ._2D,
        .sample_type = .FLOAT,
        .msl_texture_n = 0,
    };
    desc.samplers[0] = .{ .stage = .FRAGMENT, .sampler_type = .FILTERING, .msl_sampler_n = 0 };
    desc.texture_sampler_pairs[0] = .{
        .stage = .FRAGMENT,
        .view_slot = 0,
        .sampler_slot = 0,
        .glsl_name = "tex_smp",
    };

    if (shape.aux) {
        // Aux texture at unit 1 (palette LUT ramp / dissolve noise).
        desc.views[1].texture = .{
            .stage = .FRAGMENT,
            .image_type = ._2D,
            .sample_type = .FLOAT,
            .msl_texture_n = 1,
        };
        desc.samplers[1] = .{ .stage = .FRAGMENT, .sampler_type = .FILTERING, .msl_sampler_n = 1 };
        desc.texture_sampler_pairs[1] = .{
            .stage = .FRAGMENT,
            .view_slot = 1,
            .sampler_slot = 1,
            .glsl_name = "lut_smp",
        };
    }

    return sg.makeShader(desc);
}

fn makeMaterialPipeline(shader: sg.Shader) sg.Pipeline {
    var pdesc: sg.PipelineDesc = .{};
    pdesc.shader = shader;
    pdesc.label = "material-pipeline";
    pdesc.primitive_type = .TRIANGLES;
    pdesc.layout.attrs[0] = .{ .format = .FLOAT2, .offset = 0 };
    pdesc.layout.attrs[1] = .{ .format = .FLOAT2, .offset = 8 };
    pdesc.layout.attrs[2] = .{ .format = .FLOAT4, .offset = 16 };
    pdesc.layout.buffers[0].stride = @sizeOf(MaterialVertex);
    // Alpha blend — same factors as window.zig's `alpha_pipeline` so material
    // sprites composite exactly like plain sprites. Color/depth formats + sample
    // count are left DEFAULT so sokol resolves them from the environment (the
    // same way sokol_gl builds its own pipelines), keeping the pipeline
    // compatible with both the swapchain pass and the headless offscreen pass.
    pdesc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    return sg.makePipeline(pdesc);
}

/// Build ONE effect's shader + pipeline; returns the pipeline and whether it
/// validated. A compile/link failure on this driver leaves a FAILED-state
/// resource, which we detect via `sg.queryShaderState`/`queryPipelineState`
/// (a dead-pool `id == 0` also reads as not-VALID) — the failed effect's
/// resources are destroyed and it alone degrades (bgfx parity).
fn buildEffectPipeline(srcs: ShaderSources, fs: [*c]const u8, shape: ShaderShape) struct { pip: sg.Pipeline, ok: bool } {
    const shd = makeMaterialShader(srcs, fs, shape);
    if (shd.id == 0 or sg.queryShaderState(shd) != .VALID) {
        if (shd.id != 0) sg.destroyShader(shd);
        return .{ .pip = .{}, .ok = false };
    }
    const pip = makeMaterialPipeline(shd);
    if (pip.id == 0 or sg.queryPipelineState(pip) != .VALID) {
        if (pip.id != 0) sg.destroyPipeline(pip);
        sg.destroyShader(shd);
        return .{ .pip = .{}, .ok = false };
    }
    return .{ .pip = pip, .ok = true };
}

/// Lazily create the streamed vertex buffer + the four effect pipelines on
/// first use. Idempotent. Sets `supported_backend` = false (and returns false)
/// when the live backend has no authored shader dialect or the SHARED vertex
/// buffer can't be created, so callers degrade. Each effect pipeline is built
/// INDEPENDENTLY (bgfx #49 per-effect isolation): one failing leaves the others
/// valid, gated per-draw by `effectReady`.
fn ensureInitialized() bool {
    if (initialized) return supported_backend;
    initialized = true;

    const srcs = pickSources() orelse {
        // No hand-authored dialect for the live backend (D3D11/WGPU/Vulkan yet).
        // `materialSupported` already reports false at runtime, but warn once in
        // case a direct caller (a test / the golden) reaches here — so the
        // degrade-to-plain-sprite is never SILENT.
        std.log.warn(
            "labelle-sokol: material effects unavailable on backend {s} (no shader dialect); drawing plain sprites",
            .{@tagName(sg.queryBackend())},
        );
        supported_backend = false;
        return false;
    };

    // The one SHARED hard dependency: every material draw streams through this
    // buffer, so failing it degrades the whole seam (mirrors bgfx's shared
    // uniforms being the only all-effects-fatal failure).
    vbuf = sg.makeBuffer(.{
        .size = @sizeOf(MaterialVertex) * MAX_VERTS,
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "material-vbuf",
    });
    if (vbuf.id == 0) {
        supported_backend = false;
        return false;
    }

    const flash_b = buildEffectPipeline(srcs, srcs.fs_flash, .{ .label = "material-flash", .aux = false, .vec4_count = 2 });
    const palette_b = buildEffectPipeline(srcs, srcs.fs_palette, .{ .label = "material-palette", .aux = true, .vec4_count = 2 });
    const dissolve_b = buildEffectPipeline(srcs, srcs.fs_dissolve, .{ .label = "material-dissolve", .aux = true, .vec4_count = 4 });
    const outline_b = buildEffectPipeline(srcs, srcs.fs_outline, .{ .label = "material-outline", .aux = false, .vec4_count = 4 });
    flash_pip = flash_b.pip;
    palette_pip = palette_b.pip;
    dissolve_pip = dissolve_b.pip;
    outline_pip = outline_b.pip;
    effect_ready = .{ flash_b.ok, palette_b.ok, dissolve_b.ok, outline_b.ok };

    if (!flash_b.ok or !palette_b.ok or !dissolve_b.ok or !outline_b.ok) {
        std.log.warn(
            "labelle-sokol: some material pipelines failed to build; those effects degrade to plain sprites (flash={} palette_swap={} dissolve={} outline={})",
            .{ flash_b.ok, palette_b.ok, dissolve_b.ok, outline_b.ok },
        );
    }

    // The seam is armed if ANY effect built (per-effect gating handles the rest).
    supported_backend = flash_b.ok or palette_b.ok or dissolve_b.ok or outline_b.ok;
    return supported_backend;
}

// ── UV helpers (identical convention to draw.zig drawTexturePro) ─────────────

const Uv = struct { u0: f32, u1: f32, v0: f32, v1: f32 };

fn computeUv(texture: Texture, source: Rectangle) Uv {
    const tex_w: f32 = @floatFromInt(texture.width);
    const tex_h: f32 = @floatFromInt(texture.height);
    const sw_abs = @abs(source.width);
    const sh_abs = @abs(source.height);
    const flip_x = source.width < 0;
    const flip_y = source.height < 0;
    const u_left = source.x / tex_w;
    const u_right = (source.x + sw_abs) / tex_w;
    const v_top = source.y / tex_h;
    const v_bottom = (source.y + sh_abs) / tex_h;
    return .{
        .u0 = if (flip_x) u_right else u_left,
        .u1 = if (flip_x) u_left else u_right,
        .v0 = if (flip_y) v_bottom else v_top,
        .v1 = if (flip_y) v_top else v_bottom,
    };
}

fn pushQuad(corners: [4][2]f32, uv: Uv, r: f32, g: f32, b: f32, a: f32) u32 {
    const base = vert_count;
    // corners: 0=TL 1=TR 2=BR 3=BL. UVs: TL=(u0,v0) TR=(u1,v0) BR=(u1,v1) BL=(u0,v1)
    const cu = [4]f32{ uv.u0, uv.u1, uv.u1, uv.u0 };
    const cv = [4]f32{ uv.v0, uv.v0, uv.v1, uv.v1 };
    const idx = [6]usize{ 0, 1, 2, 0, 2, 3 };
    for (idx) |i| {
        vertices[vert_count] = .{
            .x = corners[i][0],
            .y = corners[i][1],
            .u = cu[i],
            .v = cv[i],
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
        vert_count += 1;
    }
    return base;
}

// ── Public: material sprite draw (contract decl on the gfx Impl) ─────────────

/// Material-aware sprite draw — the sokol impl of labelle-core's optional
/// `drawTextureProMaterial` contract (labelle-gfx#305). Same quad math as
/// `draw.drawTexturePro`, but the sprite is DEFERRED into a material queue and
/// drawn (at `flush()`) through the effect's custom raw-`sg` program with the
/// `MaterialUniforms` uploaded as a fragment uniform block. Degrades to a plain
/// `drawTexturePro` (sokol_gl, drawn in z-order) on any unsupported condition.
pub fn drawTextureProMaterial(
    texture: Texture,
    source: Rectangle,
    dest: Rectangle,
    origin: Vector2,
    rotation: f32,
    tint: Color,
    material: Material,
) void {
    if (texture.width == 0 or texture.height == 0) return;

    // Effect this module can't honour → plain sprite (belt-and-braces; the core
    // wrapper already gates on materialSupported).
    if (!materialSupported(material.effect)) {
        draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
        return;
    }

    // Resolve the unit-1 aux texture. `palette_swap`: the LUT ramp — a zero/dead
    // handle degrades to plain (RFC §3). `dissolve`: the OPTIONAL noise texture —
    // a zero/dead/unknown handle falls back to the built-in procedural noise
    // (never degrades; bgfx parity), binding the sprite's OWN texture as a
    // harmless dummy so unit 1 is never an unbound-sampler read. `use_noise`
    // becomes params.w (the shader's procedural/texture selector).
    var lut_view: sg.View = .{};
    var lut_smp: sg.Sampler = .{};
    var use_noise: f32 = 0;
    switch (material.effect) {
        .palette_swap => {
            const lut_id = material.uniforms.aux_texture;
            const lut = lut_registry.lookup(lut_id) orelse {
                draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
                return;
            };
            lut_view = lut.view;
            lut_smp = lut.smp;
        },
        .dissolve => {
            if (lut_registry.lookup(material.uniforms.aux_texture)) |noise| {
                lut_view = noise.view;
                lut_smp = noise.smp;
                use_noise = 1;
            } else {
                lut_view = texture.view; // valid dummy; shader ignores it (params.w = 0)
                lut_smp = texture.smp;
            }
        },
        else => {},
    }

    // Backend has no shader dialect here, or GPU-object build failed → plain.
    if (!ensureInitialized()) {
        draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
        return;
    }

    // Per-effect runtime gate (bgfx per-effect isolation parity): THIS effect's
    // pipeline may have failed to build on this driver while the others are
    // fine. Degrade only the failed effect to a plain sprite.
    if (!effectReady(material.effect)) {
        draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
        return;
    }

    // Queue / vertex-buffer full → plain (never realloc mid-frame).
    if (queue_len >= MAX_DRAWS or vert_count + 6 > MAX_VERTS) {
        draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
        return;
    }

    const uv = computeUv(texture, source);
    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Build the four NDC corners, mirroring draw.drawTexturePro exactly so a
    // material sprite lands pixel-for-pixel where a plain one would.
    var corners: [4][2]f32 = undefined;
    if (rotation != 0) {
        const dx = dest.x;
        const dy = dest.y;
        const pivot_x = state.toNdcX(dx);
        const pivot_y = state.toNdcY(dy);
        const ndc_w = state.toNdcX(dx + dest.width) - state.toNdcX(dx);
        const ndc_h = state.toNdcY(dy) - state.toNdcY(dy + dest.height);
        const ndc_ox = state.toNdcX(dx + origin.x) - state.toNdcX(dx);
        const ndc_oy = state.toNdcY(dy) - state.toNdcY(dy + origin.y);
        const ang = rotation * std.math.pi / 180.0;
        const c = @cos(ang);
        const s = @sin(ang);
        // Local quad (matches the sgl path): TL(0,0) TR(w,0) BR(w,-h) BL(0,-h).
        const local = [4][2]f32{ .{ 0, 0 }, .{ ndc_w, 0 }, .{ ndc_w, -ndc_h }, .{ 0, -ndc_h } };
        for (local, 0..) |p, i| {
            // translate(-ndc_ox, +ndc_oy) → rotate → translate(pivot)
            const lx = p[0] - ndc_ox;
            const ly = p[1] + ndc_oy;
            corners[i] = .{ pivot_x + (lx * c - ly * s), pivot_y + (lx * s + ly * c) };
        }
    } else {
        const dx = dest.x - origin.x;
        const dy = dest.y - origin.y;
        const x0 = state.toNdcX(dx);
        const y0 = state.toNdcY(dy);
        const x1 = state.toNdcX(dx + dest.width);
        const y1 = state.toNdcY(dy + dest.height);
        corners = .{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    }

    // The sprite's source frame in whole-atlas UV space (u0, v0, u1, v1) →
    // `u_material[3]`. labelle sprites are atlas SUB-RECTS: dissolve remaps the
    // atlas UV to sprite-local (per-frame-consistent noise scale) and outline
    // gates its neighbour taps to this rect so it can't dilate an adjacent
    // frame's content. Absolute extents (|w|, |h|) so the flip convention
    // (negative source.width/height) doesn't invert the bounds. (0,0,1,1) for a
    // standalone texture. Mirrors bgfx `texture.drawTextureProMaterial`.
    //
    // KNOWN LIMITATION (bgfx parity, documented there as #4): the outline draws
    // through the normal sprite quad, so it only appears WITHIN `dest` — a
    // tightly-cropped frame whose opaque pixels reach the frame edge has its
    // outward outline clipped at the frame boundary. Full outward outline needs
    // quad expansion — a P3 follow-up on both backends.
    const tw: f32 = @floatFromInt(texture.width);
    const th: f32 = @floatFromInt(texture.height);
    const rect = [4]f32{
        source.x / tw,
        source.y / th,
        (source.x + @abs(source.width)) / tw,
        (source.y + @abs(source.height)) / th,
    };

    const base = pushQuad(corners, uv, r, g, b, a);
    queue[queue_len] = .{
        .base = base,
        .effect = material.effect,
        .fs = .{
            .color = .{ material.uniforms.r, material.uniforms.g, material.uniforms.b, material.uniforms.a },
            .params = .{ material.uniforms.scalar0, material.uniforms.scalar1, @floatFromInt(material.uniforms.aux_count), use_noise },
            .texel = .{ 1.0 / @max(tw, 1), 1.0 / @max(th, 1), @max(tw, 1), @max(th, 1) },
            .rect = rect,
        },
        .tex_view = texture.view,
        .tex_smp = texture.smp,
        .lut_view = lut_view,
        .lut_smp = lut_smp,
    };
    queue_len += 1;
}

// ── LUT registry (maps a flat aux_texture handle → sokol view/sampler) ───────
//
// ⚠ KNOWN PORTABILITY GAP (labelle-gfx#305, slice-1, to reconcile in a follow-up):
// the contract says `MaterialUniforms.aux_texture` is a backend TEXTURE HANDLE —
// bgfx uses it as a direct texture-pool id, so a portable game sets
// `aux_texture = lutTexture.id` and it "just works". sokol has NO global texture
// pool: its `Texture` carries `sg.View`/`sg.Sampler` INLINE, and there is no
// id→(view,sampler) reverse map, so a raw texture id can't be resolved to the
// bindable handles a draw needs. As a bridge, a palette_swap caller on sokol must
// FIRST call `gfx.registerLut(lutTexture)` and pass the returned 1-based handle as
// `aux_texture` — and a dissolve caller wanting a CUSTOM noise texture registers
// it the same way (an unregistered/zero dissolve handle is NOT a degrade: it
// falls back to the built-in procedural noise). That extra call is a
// sokol-specific divergence from the contract — a game written straight to the
// contract (setting `aux_texture = lut.id`) will degrade to a plain sprite on
// sokol for palette_swap / render procedural noise for dissolve (never crash: an
// unknown handle just misses the registry). The clean fix (a follow-up) is a
// global texture registry populated at `uploadTexture`/torn down at
// `unloadTexture`, so `aux_texture = lut.id` resolves directly like bgfx;
// deferred here to keep this slice bounded (it needs upload/unload lifetime
// wiring in texture.zig). `0` is reserved "none": palette degrades, dissolve
// goes procedural.

pub const LutEntry = struct { view: sg.View, smp: sg.Sampler };
var lut_slots: [256]LutEntry = undefined;
var lut_count: u32 = 0;

const lut_registry = struct {
    fn lookup(id: u32) ?LutEntry {
        if (id == 0 or id > lut_count or id > lut_slots.len) return null;
        const e = lut_slots[id - 1];
        if (e.view.id == 0) return null;
        return e;
    }
};

/// Resolve a registered LUT handle (from `registerLut`) to its bindable
/// view/sampler, or null for `0`/unknown. Shared with the post-fx seam
/// (render_target.zig): the `color_grade` pass resolves its `aux_texture` LUT
/// through the SAME registry a `palette_swap` material draw uses.
pub fn lookupLut(id: u32) ?LutEntry {
    return lut_registry.lookup(id);
}

/// Register a texture as a palette LUT and return its `aux_texture` handle
/// (1-based; `0` is never returned). Pass the result as
/// `MaterialUniforms.aux_texture` for a `palette_swap` draw.
///
/// IDEMPOTENT: re-registering an already-registered LUT returns the SAME handle
/// rather than burning a new slot — a game that re-registers per frame or on
/// asset reload can't exhaust the fixed table. Dedup is by the sokol view id
/// (`lut.view.id`), the stable identifier of the GPU texture view. Only a
/// genuinely-new LUT consumes a slot; returns `0` (→ plain-sprite degrade) once
/// the table is full of DISTINCT LUTs.
pub fn registerLut(lut: Texture) u32 {
    // A zero/dead view can't be looked up later (`lut_registry.lookup` rejects
    // `view.id == 0`), so never register it — signal degrade.
    if (lut.view.id == 0) return 0;
    // Dedup: return the existing 1-based handle if this view is already stored.
    var i: u32 = 0;
    while (i < lut_count) : (i += 1) {
        if (lut_slots[i].view.id == lut.view.id) return i + 1;
    }
    if (lut_count >= lut_slots.len) return 0;
    lut_slots[lut_count] = .{ .view = lut.view, .smp = lut.smp };
    lut_count += 1;
    return lut_count; // 1-based handle
}

// ── Frame lifecycle (called by window.zig) ───────────────────────────────────

/// Reset the per-frame material queue. Called from `window.beginFrame`.
pub fn reset() void {
    vert_count = 0;
    queue_len = 0;
}

/// Replay every queued material sprite through its raw-`sg` program. MUST be
/// called inside the active render pass, right AFTER `sgl.draw()` (see the
/// z-order note at the top of this file). No-op when nothing was queued.
pub fn flush() void {
    if (queue_len == 0) return;
    if (!supported_backend) return; // never armed (all draws already degraded)

    // One upload per frame (sokol allows sg_update_buffer inside a pass, but
    // only once per buffer per frame — same contract sokol_gl relies on).
    sg.updateBuffer(vbuf, sg.asRange(vertices[0..vert_count]));

    var i: u32 = 0;
    while (i < queue_len) : (i += 1) {
        const d = queue[i];
        if (!effectReady(d.effect)) continue; // defensive; the draw site gated
        const pip = switch (d.effect) {
            .flash => flash_pip,
            .palette_swap => palette_pip,
            .dissolve => dissolve_pip,
            .outline => outline_pip,
            else => continue,
        };
        sg.applyPipeline(pip);

        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = vbuf;
        bindings.views[0] = d.tex_view;
        bindings.samplers[0] = d.tex_smp;
        // palette_swap + dissolve sample the aux texture at unit 1 (`lut_smp`):
        // the LUT ramp / the noise texture (or the sprite's own texture as the
        // procedural-path dummy — always a VALID view, see the draw site).
        if (d.effect == .palette_swap or d.effect == .dissolve) {
            bindings.views[1] = d.lut_view;
            bindings.samplers[1] = d.lut_smp;
        }
        sg.applyBindings(bindings);

        // Upload exactly the block size THIS effect's shader declares:
        // u_material[2] (32-byte prefix) for flash/palette, u_material[4]
        // (full 64) for dissolve/outline. sokol validates the range size
        // against the declared uniform-block size, so this must match.
        var fs = d.fs;
        sg.applyUniforms(0, .{ .ptr = &fs, .size = uniformSize(d.effect) });

        sg.draw(d.base, 6, 1);
    }
}

// ── Tests (pure-CPU: capability gate + contract introspection) ───────────────

test "materialSupported: the full curated set (only none is false)" {
    try std.testing.expect(materialSupported(.flash));
    try std.testing.expect(materialSupported(.palette_swap));
    try std.testing.expect(materialSupported(.dissolve));
    try std.testing.expect(materialSupported(.outline));
    try std.testing.expect(!materialSupported(.none));
}

test "materialCapabilities advertises all four curated effects" {
    // This module owns both `drawTextureProMaterial` + `materialSupported`
    // (re-exported verbatim by gfx.zig, the actual Impl), so the contract's
    // comptime introspection must resolve to the full curated set.
    const caps = core.backend_contract.materialCapabilities(@This());
    try std.testing.expectEqual(@as(usize, 4), caps.effects.len);
    var has = [4]bool{ false, false, false, false };
    for (caps.effects) |e| {
        switch (e) {
            .flash => has[0] = true,
            .palette_swap => has[1] = true,
            .dissolve => has[2] = true,
            .outline => has[3] = true,
            else => {},
        }
    }
    try std.testing.expect(has[0] and has[1] and has[2] and has[3]);
}

test "MaterialFsParams matches the shader uniform block sizes" {
    // Full block (dissolve/outline `u_material[4]`) = 64 bytes; the
    // flash/palette prefix (`u_material[2]`) = 32.
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(MaterialFsParams));
    try std.testing.expectEqual(@as(usize, 64), uniformSize(.dissolve));
    try std.testing.expectEqual(@as(usize, 64), uniformSize(.outline));
    try std.testing.expectEqual(@as(usize, 32), uniformSize(.flash));
    try std.testing.expectEqual(@as(usize, 32), uniformSize(.palette_swap));
    // The prefix layout the 32-byte upload relies on: color at 0, params at 16.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MaterialFsParams, "color"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(MaterialFsParams, "params"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(MaterialFsParams, "texel"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(MaterialFsParams, "rect"));
}

test "registerLut is idempotent per view id; distinct views get distinct handles" {
    // Isolate from any other test's registrations.
    lut_count = 0;
    const a = Texture{ .view = .{ .id = 42 } };
    const b = Texture{ .view = .{ .id = 99 } };

    const ha = registerLut(a);
    try std.testing.expect(ha != 0);
    // Re-registering the SAME view returns the SAME handle (no new slot).
    try std.testing.expectEqual(ha, registerLut(a));
    try std.testing.expectEqual(@as(u32, 1), lut_count);

    // A DIFFERENT view gets a fresh handle.
    const hb = registerLut(b);
    try std.testing.expect(hb != ha and hb != 0);
    try std.testing.expectEqual(@as(u32, 2), lut_count);
    try std.testing.expectEqual(hb, registerLut(b));
    try std.testing.expectEqual(@as(u32, 2), lut_count);

    // A dead (id==0) view never registers → degrade signal.
    try std.testing.expectEqual(@as(u32, 0), registerLut(Texture{ .view = .{ .id = 0 } }));

    lut_count = 0; // leave global state clean for other tests
}
