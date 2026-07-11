//! Hand-authored shader sources for the material seam (labelle-gfx#305).
//!
//! Unlike the sprite path — which rides sokol_gl's FIXED built-in shader —
//! material effects need a CUSTOM fragment shader, so they drop to raw
//! sokol_gfx (`sg_shader` / `sg_pipeline` / `sg_draw`). This repo has NO
//! sokol-shdc codegen step, so the shader sources are written BY HAND here,
//! one dialect per backend, and selected at runtime on `sg.queryBackend()`
//! (mirroring how sokol_gl.h itself ships per-backend shader variants).
//!
//! Only the dialects a shipping/CI target actually runs are provided:
//!   - GLSL 410      → desktop GL (`GLCORE`, Linux/Windows dev + CI `zig build test`)
//!   - GLSL 300 es   → GLES3 (Android / WebGL2)
//!   - MSL           → Metal (`METAL_*`, the macOS headless golden runs here)
//! D3D11 / WGPU / Vulkan have no source here yet and DEGRADE to a plain sprite
//! (see `material.zig` `pickSources`) — a quality drop, never a crash. Adding
//! those dialects is a mechanical follow-up (write the HLSL/WGSL string).
//!
//! The effect MATH mirrors the bgfx reference (labelle-bgfx v0.10.0
//! `src/shaders/fs_flash.sc` + `fs_palette.sc`) so the eventual cross-backend
//! SSIM parity check can pass:
//!   flash:        rgb = mix(sprite.rgb, u_material_color.rgb, amount); a = sprite.a
//!   palette_swap: k = round(raw.r*255); lut = s_lut[(k+0.5)/count]; out = vec4(lut.rgb, raw.a) * tint
//!
//! Uniform block (fragment stage, 32 bytes, matches `MaterialFsParams`):
//!   u_material[0] = color  (r,g,b,a)          — flash color; unused by palette
//!   u_material[1] = params (amount, _, count) — flash: .x=amount; palette: .z=aux_count

// ── Vertex shaders (shared by both effects — a pure passthrough; positions
//    arrive already in NDC, computed CPU-side in material.zig) ──────────────

pub const vs_glsl410 =
    \\#version 410
    \\layout(location = 0) in vec2 position;
    \\layout(location = 1) in vec2 texcoord0;
    \\layout(location = 2) in vec4 color0;
    \\layout(location = 0) out vec2 uv;
    \\layout(location = 1) out vec4 color;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = texcoord0;
    \\    color = color0;
    \\}
;

pub const vs_glsl300es =
    \\#version 300 es
    \\in vec2 position;
    \\in vec2 texcoord0;
    \\in vec4 color0;
    \\out vec2 uv;
    \\out vec4 color;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = texcoord0;
    \\    color = color0;
    \\}
;

pub const vs_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct main0_out {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\    float4 gl_Position [[position]];
    \\};
    \\struct main0_in {
    \\    float2 position [[attribute(0)]];
    \\    float2 texcoord0 [[attribute(1)]];
    \\    float4 color0 [[attribute(2)]];
    \\};
    \\vertex main0_out main0(main0_in in [[stage_in]]) {
    \\    main0_out out = {};
    \\    out.gl_Position = float4(in.position, 0.0, 1.0);
    \\    out.uv = in.texcoord0;
    \\    out.color = in.color0;
    \\    return out;
    \\}
;

// ── flash fragment shaders ────────────────────────────────────────────────

pub const fs_flash_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_material[2];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv) * color;
    \\    float amount = clamp(u_material[1].x, 0.0, 1.0);
    \\    vec3 rgb = mix(texel.rgb, u_material[0].rgb, amount);
    \\    frag_color = vec4(rgb, texel.a);
    \\}
;

pub const fs_flash_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_material[2];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv) * color;
    \\    float amount = clamp(u_material[1].x, 0.0, 1.0);
    \\    vec3 rgb = mix(texel.rgb, u_material[0].rgb, amount);
    \\    frag_color = vec4(rgb, texel.a);
    \\}
;

pub const fs_flash_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct mat_params { float4 color; float4 params; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant mat_params& m [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    float4 texel = tex.sample(smp, in.uv) * in.color;
    \\    float amount = clamp(m.params.x, 0.0, 1.0);
    \\    float3 rgb = mix(texel.rgb, m.color.rgb, amount);
    \\    out.frag_color = float4(rgb, texel.a);
    \\    return out;
    \\}
;

// ── palette_swap fragment shaders ─────────────────────────────────────────

pub const fs_palette_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_material[2];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec4 raw = texture(tex_smp, uv);
    \\    float count = max(u_material[1].z, 1.0);
    \\    float k = floor(raw.r * 255.0 + 0.5);
    \\    float u = (k + 0.5) / count;
    \\    vec4 lut = texture(lut_smp, vec2(u, 0.5));
    \\    frag_color = vec4(lut.rgb, raw.a) * color;
    \\}
;

pub const fs_palette_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_material[2];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec4 raw = texture(tex_smp, uv);
    \\    float count = max(u_material[1].z, 1.0);
    \\    float k = floor(raw.r * 255.0 + 0.5);
    \\    float u = (k + 0.5) / count;
    \\    vec4 lut = texture(lut_smp, vec2(u, 0.5));
    \\    frag_color = vec4(lut.rgb, raw.a) * color;
    \\}
;

pub const fs_palette_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct mat_params { float4 color; float4 params; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant mat_params& m [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]],
    \\        texture2d<float> lut [[texture(1)]],
    \\        sampler lsmp [[sampler(1)]]) {
    \\    main0_out out = {};
    \\    float4 raw = tex.sample(smp, in.uv);
    \\    float count = max(m.params.z, 1.0);
    \\    float k = floor(raw.r * 255.0 + 0.5);
    \\    float u = (k + 0.5) / count;
    \\    float4 lutc = lut.sample(lsmp, float2(u, 0.5));
    \\    out.frag_color = float4(lutc.rgb, raw.a) * in.color;
    \\    return out;
    \\}
;
