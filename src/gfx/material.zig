//! Material seam for the sokol gfx backend (labelle-gfx#305, Phase 3 — the
//! FIRST sokol parity slice: per-sprite `flash` + `palette_swap`).
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
//! no/dead LUT (`aux_texture == 0`), or a full queue.

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
/// `core.materialCapabilities`. sokol implements `flash` + `palette_swap`;
/// `dissolve` / `outline` are not yet implemented and degrade to a plain
/// sprite. Advertising them here (rather than silently) lets a project that
/// declares an unsupported effect surface it at resolve time.
pub fn materialSupported(effect: MaterialEffect) bool {
    return switch (effect) {
        .flash, .palette_swap => true,
        .dissolve, .outline, .none => false,
    };
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

/// Fragment-stage uniform block, byte-identical to the shader's `u_material[2]`
/// (two vec4s). `color` = flash color (unused by palette); `params` =
/// (amount, scalar1, aux_count, 0) — flash reads `.x`, palette reads `.z`.
/// Matches the bgfx packing (`programs.zig submitMaterialTriangles`).
const MaterialFsParams = extern struct {
    color: [4]f32,
    params: [4]f32,
};

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

const ShaderSources = struct {
    vs: [*c]const u8,
    fs_flash: [*c]const u8,
    fs_palette: [*c]const u8,
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
            .metal = false,
        },
        .GLES3 => .{
            .vs = shaders.vs_glsl300es,
            .fs_flash = shaders.fs_flash_glsl300es,
            .fs_palette = shaders.fs_palette_glsl300es,
            .metal = false,
        },
        .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR => .{
            .vs = shaders.vs_metal,
            .fs_flash = shaders.fs_flash_metal,
            .fs_palette = shaders.fs_palette_metal,
            .metal = true,
        },
        // No HLSL / WGSL / SPIR-V dialect authored yet — degrade (documented).
        .D3D11, .WGPU, .VULKAN, .DUMMY => null,
    };
}

fn makeMaterialShader(srcs: ShaderSources, fs: [*c]const u8, palette: bool) sg.Shader {
    var desc: sg.ShaderDesc = .{};
    desc.label = if (palette) "material-palette" else "material-flash";
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

    // Fragment uniform block `u_material` = 2×vec4 (32 bytes), bind slot 0.
    desc.uniform_blocks[0].stage = .FRAGMENT;
    desc.uniform_blocks[0].size = @sizeOf(MaterialFsParams);
    desc.uniform_blocks[0].msl_buffer_n = 0;
    desc.uniform_blocks[0].glsl_uniforms[0] = .{
        .type = .FLOAT4,
        .array_count = 2,
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

    if (palette) {
        // LUT ramp at unit 1.
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

/// Lazily create the streamed vertex buffer + both effect programs on first
/// use. Idempotent. Sets `supported_backend` = false (and returns false) when
/// the live backend has no authored shader dialect, so callers degrade.
fn ensureInitialized() bool {
    if (initialized) return supported_backend;
    initialized = true;

    const srcs = pickSources() orelse {
        supported_backend = false;
        return false;
    };

    vbuf = sg.makeBuffer(.{
        .size = @sizeOf(MaterialVertex) * MAX_VERTS,
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "material-vbuf",
    });
    if (vbuf.id == 0) {
        supported_backend = false;
        return false;
    }

    const flash_shd = makeMaterialShader(srcs, srcs.fs_flash, false);
    const palette_shd = makeMaterialShader(srcs, srcs.fs_palette, true);
    if (flash_shd.id == 0 or palette_shd.id == 0) {
        supported_backend = false;
        return false;
    }
    flash_pip = makeMaterialPipeline(flash_shd);
    palette_pip = makeMaterialPipeline(palette_shd);
    if (flash_pip.id == 0 or palette_pip.id == 0) {
        supported_backend = false;
        return false;
    }

    supported_backend = true;
    return true;
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

    // Resolve the LUT for palette_swap. A zero/dead handle degrades to plain.
    var lut_view: sg.View = .{};
    var lut_smp: sg.Sampler = .{};
    if (material.effect == .palette_swap) {
        const lut_id = material.uniforms.aux_texture;
        const lut = lut_registry.lookup(lut_id) orelse {
            draw.drawTexturePro(texture, source, dest, origin, rotation, tint);
            return;
        };
        lut_view = lut.view;
        lut_smp = lut.smp;
    }

    // Backend has no shader dialect here, or GPU-object build failed → plain.
    if (!ensureInitialized()) {
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

    const base = pushQuad(corners, uv, r, g, b, a);
    queue[queue_len] = .{
        .base = base,
        .effect = material.effect,
        .fs = .{
            .color = .{ material.uniforms.r, material.uniforms.g, material.uniforms.b, material.uniforms.a },
            .params = .{ material.uniforms.scalar0, material.uniforms.scalar1, @floatFromInt(material.uniforms.aux_count), 0 },
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
// `MaterialUniforms.aux_texture` is a flat `u32` handle (contract shape). The
// sokol `Texture` carries its `sg.View`/`sg.Sampler` inline (no global texture
// pool like bgfx), so a caller that wants a palette LUT must register the LUT
// texture here and pass the returned id as `aux_texture`. `0` is reserved
// "none" and always degrades.

const LutEntry = struct { view: sg.View, smp: sg.Sampler };
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

/// Register a texture as a palette LUT and return its `aux_texture` handle
/// (1-based; `0` is never returned). Pass the result as
/// `MaterialUniforms.aux_texture` for a `palette_swap` draw. Idempotent-ish:
/// returns 0 when the slot table is full (caller then gets a plain sprite).
pub fn registerLut(lut: Texture) u32 {
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
        const pip = switch (d.effect) {
            .flash => flash_pip,
            .palette_swap => palette_pip,
            else => continue,
        };
        sg.applyPipeline(pip);

        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = vbuf;
        bindings.views[0] = d.tex_view;
        bindings.samplers[0] = d.tex_smp;
        if (d.effect == .palette_swap) {
            bindings.views[1] = d.lut_view;
            bindings.samplers[1] = d.lut_smp;
        }
        sg.applyBindings(bindings);

        var fs = d.fs;
        sg.applyUniforms(0, sg.asRange(&fs));

        sg.draw(d.base, 6, 1);
    }
}

// ── Tests (pure-CPU: capability gate + contract introspection) ───────────────

test "materialSupported: flash + palette_swap only" {
    try std.testing.expect(materialSupported(.flash));
    try std.testing.expect(materialSupported(.palette_swap));
    try std.testing.expect(!materialSupported(.dissolve));
    try std.testing.expect(!materialSupported(.outline));
    try std.testing.expect(!materialSupported(.none));
}

test "materialCapabilities advertises exactly flash + palette_swap" {
    // This module owns both `drawTextureProMaterial` + `materialSupported`
    // (re-exported verbatim by gfx.zig, the actual Impl), so the contract's
    // comptime introspection must resolve to our two effects.
    const caps = core.backend_contract.materialCapabilities(@This());
    try std.testing.expectEqual(@as(usize, 2), caps.effects.len);
    var has_flash = false;
    var has_palette = false;
    for (caps.effects) |e| {
        if (e == .flash) has_flash = true;
        if (e == .palette_swap) has_palette = true;
    }
    try std.testing.expect(has_flash and has_palette);
}

test "MaterialFsParams matches the shader uniform block size (2x vec4)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(MaterialFsParams));
}
