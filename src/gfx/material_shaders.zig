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
//! The effect MATH mirrors the bgfx reference (labelle-bgfx v0.12.0
//! `src/shaders/fs_flash.sc` / `fs_palette.sc` / `fs_dissolve.sc` /
//! `fs_outline.sc`) so the cross-backend parity check can pass:
//!   flash:        rgb = mix(sprite.rgb, u_material_color.rgb, amount); a = sprite.a
//!   palette_swap: k = round(raw.r*255); lut = s_lut[(k+0.5)/count]; out = vec4(lut.rgb, raw.a) * tint
//!   dissolve:     noise-gated burn-away (procedural value-noise or a bound
//!                 noise texture at unit 1) + a fwidth-sized burn-edge glow
//!   outline:      8-tap single-ring alpha dilation, feathered by softness,
//!                 straight-alpha sprite-over-outline composite
//!
//! The dissolve/outline sources are ports of bgfx origin/main's final shaders,
//! which BAKE IN the post-#49 review fixes — do not "simplify" them back:
//!   - outline: no double-(1−As) attenuation on anti-aliased edges; silhouette
//!     keyed off INTRINSIC texel alpha (no tint) so a faded sprite's interior is
//!     never tinted by the outline colour, with the tint fade applied ONCE to
//!     the whole composite; per-frame tap gating via u_material rect so an
//!     atlas neighbour's content can't bleed into the outline.
//!   - dissolve: sprite-LOCAL noise UV (per-frame-consistent cell size on atlas
//!     sub-rects); full clear at threshold==1 (inclusive-step boundary); zero
//!     burn glow at threshold∈{0,1} via the EDGE_EPS edge_gate.
//!
//! Uniform block (fragment stage, matches `MaterialFsParams`):
//!   flash / palette_swap declare `u_material[2]` (32 bytes):
//!     u_material[0] = color  (r,g,b,a)          — flash color; unused by palette
//!     u_material[1] = params (amount, _, count) — flash: .x=amount; palette: .z=aux_count
//!   dissolve / outline declare `u_material[4]` (64 bytes; first two as above):
//!     u_material[1] = params (scalar0, scalar1, aux_count, use_noise_tex)
//!                     dissolve: .x=threshold .y=edge_width .w=1 when a noise
//!                     texture is bound at unit 1 (else procedural)
//!                     outline:  .x=thickness(px) .y=softness
//!     u_material[2] = texel  (1/w, 1/h, w, h)   — sprite texture pixel size
//!                     (outline: px thickness → UV offset)
//!     u_material[3] = rect   (u0, v0, u1, v1)   — the sprite's source frame in
//!                     whole-atlas UV space ((0,0,1,1) for a standalone texture);
//!                     dissolve remaps to sprite-local UV, outline gates taps

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

// ── dissolve fragment shaders ─────────────────────────────────────────────
//
// Port of bgfx `fs_dissolve.sc` (origin/main, all #49 fixes baked in). A
// noise-gated burn-away: texels whose noise falls below the threshold vanish
// (alpha 0); survivors just past the front get a burn-edge glow whose band is
// sized in SCREEN px via fwidth(n) * edge_width. Noise is sampled at the
// sprite-LOCAL UV (frame sub-rect remapped to 0..1 via u_material[3]) so the
// cell size is per-frame-consistent on atlas sub-rects. `u_material[1].w`
// selects the bound noise texture at unit 1 (lut_smp) over the built-in
// procedural value-noise; the Zig side ALWAYS binds a valid texture at unit 1
// (the sprite's own texture as a dummy on the procedural path). Endpoint math:
// full clear at threshold==1, pixel-identical to a plain sprite at threshold==0
// (the EDGE_EPS edge_gate zeroes the glow at both endpoints).

pub const fs_dissolve_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_material[4];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\float dissolve_hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
    \\}
    \\float dissolve_noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float a = dissolve_hash(i);
    \\    float b = dissolve_hash(i + vec2(1.0, 0.0));
    \\    float c = dissolve_hash(i + vec2(0.0, 1.0));
    \\    float d = dissolve_hash(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    \\}
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv) * color;
    \\    vec2 local = (uv - u_material[3].xy) / max(u_material[3].zw - u_material[3].xy, vec2(1e-6, 1e-6));
    \\    float n = mix(dissolve_noise(local * 9.0), texture(lut_smp, local).r, step(0.5, u_material[1].w));
    \\    float threshold = u_material[1].x;
    \\    float reveal = n - threshold;
    \\    float band = max(fwidth(n) * u_material[1].y, 1e-4);
    \\    float alive = step(0.0, reveal) * (1.0 - step(1.0, threshold));
    \\    float front = 1.0 - smoothstep(0.0, band, max(reveal, 0.0));
    \\    float edge_gate = smoothstep(0.0, 0.03, threshold) * smoothstep(0.0, 0.03, 1.0 - threshold);
    \\    float edge = front * edge_gate;
    \\    vec3 rgb = mix(texel.rgb, u_material[0].rgb, edge);
    \\    frag_color = vec4(rgb, texel.a * alive);
    \\}
;

pub const fs_dissolve_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_material[4];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\float dissolve_hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
    \\}
    \\float dissolve_noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float a = dissolve_hash(i);
    \\    float b = dissolve_hash(i + vec2(1.0, 0.0));
    \\    float c = dissolve_hash(i + vec2(0.0, 1.0));
    \\    float d = dissolve_hash(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    \\}
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv) * color;
    \\    vec2 local = (uv - u_material[3].xy) / max(u_material[3].zw - u_material[3].xy, vec2(1e-6, 1e-6));
    \\    float n = mix(dissolve_noise(local * 9.0), texture(lut_smp, local).r, step(0.5, u_material[1].w));
    \\    float threshold = u_material[1].x;
    \\    float reveal = n - threshold;
    \\    float band = max(fwidth(n) * u_material[1].y, 1e-4);
    \\    float alive = step(0.0, reveal) * (1.0 - step(1.0, threshold));
    \\    float front = 1.0 - smoothstep(0.0, band, max(reveal, 0.0));
    \\    float edge_gate = smoothstep(0.0, 0.03, threshold) * smoothstep(0.0, 0.03, 1.0 - threshold);
    \\    float edge = front * edge_gate;
    \\    vec3 rgb = mix(texel.rgb, u_material[0].rgb, edge);
    \\    frag_color = vec4(rgb, texel.a * alive);
    \\}
;

pub const fs_dissolve_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct mat_params { float4 color; float4 params; float4 texel; float4 rect; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\static inline float dissolve_hash(float2 p) {
    \\    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
    \\}
    \\static inline float dissolve_noise(float2 p) {
    \\    float2 i = floor(p);
    \\    float2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float a = dissolve_hash(i);
    \\    float b = dissolve_hash(i + float2(1.0, 0.0));
    \\    float c = dissolve_hash(i + float2(0.0, 1.0));
    \\    float d = dissolve_hash(i + float2(1.0, 1.0));
    \\    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    \\}
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant mat_params& m [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]],
    \\        texture2d<float> lut [[texture(1)]],
    \\        sampler lsmp [[sampler(1)]]) {
    \\    main0_out out = {};
    \\    float4 texel = tex.sample(smp, in.uv) * in.color;
    \\    float2 local = (in.uv - m.rect.xy) / max(m.rect.zw - m.rect.xy, float2(1e-6, 1e-6));
    \\    float n = mix(dissolve_noise(local * 9.0), lut.sample(lsmp, local).r, step(0.5, m.params.w));
    \\    float threshold = m.params.x;
    \\    float reveal = n - threshold;
    \\    float band = max(fwidth(n) * m.params.y, 1e-4);
    \\    float alive = step(0.0, reveal) * (1.0 - step(1.0, threshold));
    \\    float front = 1.0 - smoothstep(0.0, band, max(reveal, 0.0));
    \\    float edge_gate = smoothstep(0.0, 0.03, threshold) * smoothstep(0.0, 0.03, 1.0 - threshold);
    \\    float edge = front * edge_gate;
    \\    float3 rgb = mix(texel.rgb, m.color.rgb, edge);
    \\    out.frag_color = float4(rgb, texel.a * alive);
    \\    return out;
    \\}
;

// ── outline fragment shaders ──────────────────────────────────────────────
//
// Port of bgfx `fs_outline.sc` (origin/main, all #49 fixes baked in). An
// alpha-dilated silhouette: an 8-tap single ring (N/S/E/W + 4 diagonals) at the
// thickness radius, feathered by softness. Thickness is interpreted in SOURCE
// texel space (u_material[2].xy = 1/w,1/h) — exact at 1:1, an approximation
// when scaled (documented tradeoff, same as bgfx). Each tap is gated to the
// frame rect u_material[3] so the outline can't dilate a neighbouring atlas
// frame's content. The silhouette + ring key off the sprite's INTRINSIC alpha
// (no tint), the sprite composites over the outline A-over-B in straight alpha
// (`outline_a` ALREADY carries Ao·(1−As) — do not multiply by (1−As) again),
// and the tint fade (color.a) applies ONCE to the whole composite, so a faded
// sprite fades its outline too without the outline tinting the interior.
// LIMITATION (documented, bgfx parity): the outline draws WITHIN the sprite's
// dest quad only — a frame whose opaque pixels reach the frame edge has its
// outward outline clipped there (full outward outline = quad expansion, a P3
// follow-up).

pub const fs_outline_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_material[4];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\float outline_tap(vec2 p) {
    \\    return step(u_material[3].x, p.x) * step(p.x, u_material[3].z)
    \\         * step(u_material[3].y, p.y) * step(p.y, u_material[3].w)
    \\         * texture(tex_smp, p).a;
    \\}
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv);
    \\    float src_a = texel.a;
    \\    vec3 sprite_rgb = texel.rgb * color.rgb;
    \\    vec2 px = u_material[2].xy * u_material[1].x;
    \\    float diag = 0.70710678;
    \\    float ring = 0.0;
    \\    ring = max(ring, outline_tap(uv + vec2( px.x, 0.0)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x, 0.0)));
    \\    ring = max(ring, outline_tap(uv + vec2(0.0,  px.y)));
    \\    ring = max(ring, outline_tap(uv + vec2(0.0, -px.y)));
    \\    ring = max(ring, outline_tap(uv + vec2( px.x * diag,  px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x * diag,  px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2( px.x * diag, -px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x * diag, -px.y * diag)));
    \\    float hard = step(0.5, ring);
    \\    float soft = smoothstep(0.0, 1.0, ring);
    \\    float coverage = mix(hard, soft, clamp(u_material[1].y, 0.0, 1.0));
    \\    float outline_a = u_material[0].a * coverage * (1.0 - src_a);
    \\    float comp_a = src_a + outline_a;
    \\    vec3 comp_pre = sprite_rgb * src_a + u_material[0].rgb * outline_a;
    \\    vec3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : vec3(0.0);
    \\    frag_color = vec4(comp_rgb, comp_a * color.a);
    \\}
;

pub const fs_outline_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_material[4];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\float outline_tap(vec2 p) {
    \\    return step(u_material[3].x, p.x) * step(p.x, u_material[3].z)
    \\         * step(u_material[3].y, p.y) * step(p.y, u_material[3].w)
    \\         * texture(tex_smp, p).a;
    \\}
    \\void main() {
    \\    vec4 texel = texture(tex_smp, uv);
    \\    float src_a = texel.a;
    \\    vec3 sprite_rgb = texel.rgb * color.rgb;
    \\    vec2 px = u_material[2].xy * u_material[1].x;
    \\    float diag = 0.70710678;
    \\    float ring = 0.0;
    \\    ring = max(ring, outline_tap(uv + vec2( px.x, 0.0)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x, 0.0)));
    \\    ring = max(ring, outline_tap(uv + vec2(0.0,  px.y)));
    \\    ring = max(ring, outline_tap(uv + vec2(0.0, -px.y)));
    \\    ring = max(ring, outline_tap(uv + vec2( px.x * diag,  px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x * diag,  px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2( px.x * diag, -px.y * diag)));
    \\    ring = max(ring, outline_tap(uv + vec2(-px.x * diag, -px.y * diag)));
    \\    float hard = step(0.5, ring);
    \\    float soft = smoothstep(0.0, 1.0, ring);
    \\    float coverage = mix(hard, soft, clamp(u_material[1].y, 0.0, 1.0));
    \\    float outline_a = u_material[0].a * coverage * (1.0 - src_a);
    \\    float comp_a = src_a + outline_a;
    \\    vec3 comp_pre = sprite_rgb * src_a + u_material[0].rgb * outline_a;
    \\    vec3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : vec3(0.0);
    \\    frag_color = vec4(comp_rgb, comp_a * color.a);
    \\}
;

pub const fs_outline_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct mat_params { float4 color; float4 params; float4 texel; float4 rect; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\static inline float outline_tap(float2 p, float4 rect,
    \\        texture2d<float> tex, sampler smp) {
    \\    return step(rect.x, p.x) * step(p.x, rect.z)
    \\         * step(rect.y, p.y) * step(p.y, rect.w)
    \\         * tex.sample(smp, p).a;
    \\}
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant mat_params& m [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    float4 texel = tex.sample(smp, in.uv);
    \\    float src_a = texel.a;
    \\    float3 sprite_rgb = texel.rgb * in.color.rgb;
    \\    float2 px = m.texel.xy * m.params.x;
    \\    float diag = 0.70710678;
    \\    float ring = 0.0;
    \\    ring = max(ring, outline_tap(in.uv + float2( px.x, 0.0), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2(-px.x, 0.0), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2(0.0,  px.y), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2(0.0, -px.y), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2( px.x * diag,  px.y * diag), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2(-px.x * diag,  px.y * diag), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2( px.x * diag, -px.y * diag), m.rect, tex, smp));
    \\    ring = max(ring, outline_tap(in.uv + float2(-px.x * diag, -px.y * diag), m.rect, tex, smp));
    \\    float hard = step(0.5, ring);
    \\    float soft = smoothstep(0.0, 1.0, ring);
    \\    float coverage = mix(hard, soft, clamp(m.params.y, 0.0, 1.0));
    \\    float outline_a = m.color.a * coverage * (1.0 - src_a);
    \\    float comp_a = src_a + outline_a;
    \\    float3 comp_pre = sprite_rgb * src_a + m.color.rgb * outline_a;
    \\    float3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : float3(0.0);
    \\    out.frag_color = float4(comp_rgb, comp_a * in.color.a);
    \\    return out;
    \\}
;
