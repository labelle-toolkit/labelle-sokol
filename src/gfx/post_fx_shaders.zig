//! Hand-authored shader sources for the sokol post-fx seam (labelle-gfx#305
//! Phase 3 — render-target sub-surface + full-screen post-fx passes).
//!
//! Like the material seam (material_shaders.zig), the post-fx passes need CUSTOM
//! fragment shaders, so they drop to raw sokol_gfx: their own `sg.Shader` +
//! `sg.Pipeline` per pass, drawn as a FULL-SCREEN triangle-list quad that samples
//! one render target's colour texture (`src`) and writes another (`dst`). There
//! is NO sokol-shdc codegen step here, so every dialect is written BY HAND and
//! selected at runtime on `sg.queryBackend()` (mirroring sokol_gl.h's own
//! per-backend shader variants). Only the dialects a shipping/CI target runs are
//! provided:
//!   - GLSL 410     → desktop GL (`GLCORE`)
//!   - GLSL 300 es  → GLES3 (Android / WebGL2)
//!   - MSL          → Metal (`METAL_*`, the macOS headless golden runs here)
//! D3D11 / WGPU / Vulkan have no source yet → the whole post-fx stack degrades to
//! a no-op (straight-to-backbuffer), never a crash.
//!
//! The effect MATH mirrors the bgfx reference (labelle-bgfx feat/305-bgfx-postfx
//! `src/shaders/fs_{bloom,vignette,color_grade,crt}.sc`) so the eventual
//! cross-backend SSIM parity check can pass. The flat `PostPassUniforms` are
//! marshalled into three shared `vec4`s (RFC §2.2, same packing as bgfx's
//! `submitPostPass`):
//!   u_postfx[0] = params = (scalar0, scalar1, scalar2, scalar3)
//!   u_postfx[1] = color  = (r, g, b, 0)                        — vignette tint
//!   u_postfx[2] = texel  = (1/w, 1/h, w, h)                    — dst pixel size
//! `color_grade` additionally binds its LUT strip (256×16, a 16×16×16 cube
//! unrolled horizontally) at texture unit 1.
//!
//! The `blit` program is a plain textured passthrough (`tex * vertex_color`): it
//! backs BOTH `drawRenderTarget` (the final composite, tinted) and the
//! `color_grade`-with-no-LUT degrade (an identity src→dst copy).

// ── Vertex shaders (shared by every pass + the blit — a pure passthrough;
//    positions arrive already in NDC, computed CPU-side in render_target.zig) ──

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

// ── blit / composite fragment shaders (tex * vertex_color) ──────────────────

pub const fs_blit_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    frag_color = texture(tex_smp, uv) * color;
    \\}
;

pub const fs_blit_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = texture(tex_smp, uv) * color;
    \\}
;

pub const fs_blit_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    out.frag_color = tex.sample(smp, in.uv) * in.color;
    \\    return out;
    \\}
;

// ── bloom fragment shaders ──────────────────────────────────────────────────
// 5×5 bright-pass + Gaussian accumulate, added back over the base scene.
//   u_postfx[0] = (threshold, intensity, radius, _)   u_postfx[2].xy = 1/size

pub const fs_bloom_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec3 base = texture(tex_smp, uv).rgb;
    \\    float threshold = u_postfx[0].x;
    \\    vec2 step_uv = u_postfx[2].xy * max(u_postfx[0].z, 0.0);
    \\    vec3 sum = vec3(0.0);
    \\    float wsum = 0.0;
    \\    for (int y = -2; y <= 2; y++) {
    \\        for (int x = -2; x <= 2; x++) {
    \\            vec2 off = vec2(float(x), float(y)) * step_uv;
    \\            vec3 c = texture(tex_smp, uv + off).rgb;
    \\            float luma = dot(c, vec3(0.299, 0.587, 0.114));
    \\            float bright = max(luma - threshold, 0.0);
    \\            float w = exp(-0.5 * float(x * x + y * y));
    \\            sum += c * bright * w;
    \\            wsum += w;
    \\        }
    \\    }
    \\    vec3 bloom = sum / max(wsum, 0.0001);
    \\    frag_color = vec4(base + bloom * u_postfx[0].y, 1.0);
    \\}
;

pub const fs_bloom_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec3 base = texture(tex_smp, uv).rgb;
    \\    float threshold = u_postfx[0].x;
    \\    vec2 step_uv = u_postfx[2].xy * max(u_postfx[0].z, 0.0);
    \\    vec3 sum = vec3(0.0);
    \\    float wsum = 0.0;
    \\    for (int y = -2; y <= 2; y++) {
    \\        for (int x = -2; x <= 2; x++) {
    \\            vec2 off = vec2(float(x), float(y)) * step_uv;
    \\            vec3 c = texture(tex_smp, uv + off).rgb;
    \\            float luma = dot(c, vec3(0.299, 0.587, 0.114));
    \\            float bright = max(luma - threshold, 0.0);
    \\            float w = exp(-0.5 * float(x * x + y * y));
    \\            sum += c * bright * w;
    \\            wsum += w;
    \\        }
    \\    }
    \\    vec3 bloom = sum / max(wsum, 0.0001);
    \\    frag_color = vec4(base + bloom * u_postfx[0].y, 1.0);
    \\}
;

pub const fs_bloom_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct pfx { float4 params; float4 color; float4 texel; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant pfx& u [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    float3 base = tex.sample(smp, in.uv).rgb;
    \\    float threshold = u.params.x;
    \\    float2 step_uv = u.texel.xy * max(u.params.z, 0.0);
    \\    float3 sum = float3(0.0);
    \\    float wsum = 0.0;
    \\    for (int y = -2; y <= 2; y++) {
    \\        for (int x = -2; x <= 2; x++) {
    \\            float2 off = float2(float(x), float(y)) * step_uv;
    \\            float3 c = tex.sample(smp, in.uv + off).rgb;
    \\            float luma = dot(c, float3(0.299, 0.587, 0.114));
    \\            float bright = max(luma - threshold, 0.0);
    \\            float w = exp(-0.5 * float(x * x + y * y));
    \\            sum += c * bright * w;
    \\            wsum += w;
    \\        }
    \\    }
    \\    float3 bloom = sum / max(wsum, 0.0001);
    \\    out.frag_color = float4(base + bloom * u.params.y, 1.0);
    \\    return out;
    \\}
;

// ── vignette fragment shaders ───────────────────────────────────────────────
//   u_postfx[0] = (intensity, radius, softness, _)   u_postfx[1].rgb = tint

pub const fs_vignette_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec3 base = texture(tex_smp, uv).rgb;
    \\    vec2 d = uv - vec2(0.5, 0.5);
    \\    float dist = length(d) * 1.41421356;
    \\    float edge = smoothstep(u_postfx[0].y, u_postfx[0].y + max(u_postfx[0].z, 0.0001), dist);
    \\    vec3 col = mix(base, u_postfx[1].rgb, edge * clamp(u_postfx[0].x, 0.0, 1.0));
    \\    frag_color = vec4(col, 1.0);
    \\}
;

pub const fs_vignette_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec3 base = texture(tex_smp, uv).rgb;
    \\    vec2 d = uv - vec2(0.5, 0.5);
    \\    float dist = length(d) * 1.41421356;
    \\    float edge = smoothstep(u_postfx[0].y, u_postfx[0].y + max(u_postfx[0].z, 0.0001), dist);
    \\    vec3 col = mix(base, u_postfx[1].rgb, edge * clamp(u_postfx[0].x, 0.0, 1.0));
    \\    frag_color = vec4(col, 1.0);
    \\}
;

pub const fs_vignette_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct pfx { float4 params; float4 color; float4 texel; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant pfx& u [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    float3 base = tex.sample(smp, in.uv).rgb;
    \\    float2 d = in.uv - float2(0.5, 0.5);
    \\    float dist = length(d) * 1.41421356;
    \\    float edge = smoothstep(u.params.y, u.params.y + max(u.params.z, 0.0001), dist);
    \\    float3 col = mix(base, u.color.rgb, edge * clamp(u.params.x, 0.0, 1.0));
    \\    out.frag_color = float4(col, 1.0);
    \\    return out;
    \\}
;

// ── color_grade fragment shaders ────────────────────────────────────────────
// 16×16×16 cube unrolled to a 256×16 strip. Blue selects the slice (linearly
// interpolated), red the x-in-slice, green the y.  u_postfx[0].x = strength.

pub const fs_color_grade_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_postfx[3];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec3 c = clamp(texture(tex_smp, uv).rgb, 0.0, 1.0);
    \\    float N = 16.0;
    \\    float blue = c.b * (N - 1.0);
    \\    float slice0 = floor(blue);
    \\    float f = blue - slice0;
    \\    float xr = c.r * (N - 1.0) / (N * N) + 0.5 / (N * N);
    \\    float yg = c.g * (N - 1.0) / N + 0.5 / N;
    \\    vec3 g0 = texture(lut_smp, vec2(slice0 / N + xr, yg)).rgb;
    \\    vec3 g1 = texture(lut_smp, vec2((slice0 + 1.0) / N + xr, yg)).rgb;
    \\    vec3 graded = mix(g0, g1, f);
    \\    frag_color = vec4(mix(c, graded, clamp(u_postfx[0].x, 0.0, 1.0)), 1.0);
    \\}
;

pub const fs_color_grade_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform sampler2D lut_smp;
    \\uniform vec4 u_postfx[3];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec3 c = clamp(texture(tex_smp, uv).rgb, 0.0, 1.0);
    \\    float N = 16.0;
    \\    float blue = c.b * (N - 1.0);
    \\    float slice0 = floor(blue);
    \\    float f = blue - slice0;
    \\    float xr = c.r * (N - 1.0) / (N * N) + 0.5 / (N * N);
    \\    float yg = c.g * (N - 1.0) / N + 0.5 / N;
    \\    vec3 g0 = texture(lut_smp, vec2(slice0 / N + xr, yg)).rgb;
    \\    vec3 g1 = texture(lut_smp, vec2((slice0 + 1.0) / N + xr, yg)).rgb;
    \\    vec3 graded = mix(g0, g1, f);
    \\    frag_color = vec4(mix(c, graded, clamp(u_postfx[0].x, 0.0, 1.0)), 1.0);
    \\}
;

pub const fs_color_grade_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct pfx { float4 params; float4 color; float4 texel; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant pfx& u [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]],
    \\        texture2d<float> lut [[texture(1)]],
    \\        sampler lsmp [[sampler(1)]]) {
    \\    main0_out out = {};
    \\    float3 c = clamp(tex.sample(smp, in.uv).rgb, 0.0, 1.0);
    \\    float N = 16.0;
    \\    float blue = c.b * (N - 1.0);
    \\    float slice0 = floor(blue);
    \\    float f = blue - slice0;
    \\    float xr = c.r * (N - 1.0) / (N * N) + 0.5 / (N * N);
    \\    float yg = c.g * (N - 1.0) / N + 0.5 / N;
    \\    float3 g0 = lut.sample(lsmp, float2(slice0 / N + xr, yg)).rgb;
    \\    float3 g1 = lut.sample(lsmp, float2((slice0 + 1.0) / N + xr, yg)).rgb;
    \\    float3 graded = mix(g0, g1, f);
    \\    out.frag_color = float4(mix(c, graded, clamp(u.params.x, 0.0, 1.0)), 1.0);
    \\    return out;
    \\}
;

// ── crt fragment shaders ────────────────────────────────────────────────────
//   u_postfx[0] = (curvature, scanline, mask, aberration)  u_postfx[2].zw = (w,h)

pub const fs_crt_glsl410 =
    \\#version 410
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 0) out vec4 frag_color;
    \\void main() {
    \\    vec2 cc = uv - vec2(0.5, 0.5);
    \\    float r2 = dot(cc, cc);
    \\    vec2 warp = uv + cc * r2 * u_postfx[0].x;
    \\    float ab = u_postfx[0].w;
    \\    vec3 col;
    \\    col.r = texture(tex_smp, warp + vec2(ab, 0.0)).r;
    \\    col.g = texture(tex_smp, warp).g;
    \\    col.b = texture(tex_smp, warp - vec2(ab, 0.0)).b;
    \\    float inside = step(0.0, warp.x) * step(warp.x, 1.0) * step(0.0, warp.y) * step(warp.y, 1.0);
    \\    col *= inside;
    \\    float lines = 0.5 + 0.5 * abs(sin(warp.y * u_postfx[2].w * 3.14159265));
    \\    float scan = mix(1.0, lines, clamp(u_postfx[0].y, 0.0, 1.0));
    \\    float stripe = 0.6 + 0.4 * step(0.5, fract(warp.x * u_postfx[2].z / 3.0));
    \\    float m = mix(1.0, stripe, clamp(u_postfx[0].z, 0.0, 1.0));
    \\    frag_color = vec4(col * scan * m, 1.0);
    \\}
;

pub const fs_crt_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D tex_smp;
    \\uniform vec4 u_postfx[3];
    \\in vec2 uv;
    \\in vec4 color;
    \\out vec4 frag_color;
    \\void main() {
    \\    vec2 cc = uv - vec2(0.5, 0.5);
    \\    float r2 = dot(cc, cc);
    \\    vec2 warp = uv + cc * r2 * u_postfx[0].x;
    \\    float ab = u_postfx[0].w;
    \\    vec3 col;
    \\    col.r = texture(tex_smp, warp + vec2(ab, 0.0)).r;
    \\    col.g = texture(tex_smp, warp).g;
    \\    col.b = texture(tex_smp, warp - vec2(ab, 0.0)).b;
    \\    float inside = step(0.0, warp.x) * step(warp.x, 1.0) * step(0.0, warp.y) * step(warp.y, 1.0);
    \\    col *= inside;
    \\    float lines = 0.5 + 0.5 * abs(sin(warp.y * u_postfx[2].w * 3.14159265));
    \\    float scan = mix(1.0, lines, clamp(u_postfx[0].y, 0.0, 1.0));
    \\    float stripe = 0.6 + 0.4 * step(0.5, fract(warp.x * u_postfx[2].z / 3.0));
    \\    float m = mix(1.0, stripe, clamp(u_postfx[0].z, 0.0, 1.0));
    \\    frag_color = vec4(col * scan * m, 1.0);
    \\}
;

pub const fs_crt_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct pfx { float4 params; float4 color; float4 texel; };
    \\struct main0_out { float4 frag_color [[color(0)]]; };
    \\struct main0_in {
    \\    float2 uv [[user(locn0)]];
    \\    float4 color [[user(locn1)]];
    \\};
    \\fragment main0_out main0(main0_in in [[stage_in]],
    \\        constant pfx& u [[buffer(0)]],
    \\        texture2d<float> tex [[texture(0)]],
    \\        sampler smp [[sampler(0)]]) {
    \\    main0_out out = {};
    \\    float2 cc = in.uv - float2(0.5, 0.5);
    \\    float r2 = dot(cc, cc);
    \\    float2 warp = in.uv + cc * r2 * u.params.x;
    \\    float ab = u.params.w;
    \\    float3 col;
    \\    col.r = tex.sample(smp, warp + float2(ab, 0.0)).r;
    \\    col.g = tex.sample(smp, warp).g;
    \\    col.b = tex.sample(smp, warp - float2(ab, 0.0)).b;
    \\    float inside = step(0.0, warp.x) * step(warp.x, 1.0) * step(0.0, warp.y) * step(warp.y, 1.0);
    \\    col *= inside;
    \\    float lines = 0.5 + 0.5 * abs(sin(warp.y * u.texel.w * 3.14159265));
    \\    float scan = mix(1.0, lines, clamp(u.params.y, 0.0, 1.0));
    \\    float stripe = 0.6 + 0.4 * step(0.5, fract(warp.x * u.texel.z / 3.0));
    \\    float m = mix(1.0, stripe, clamp(u.params.z, 0.0, 1.0));
    \\    out.frag_color = float4(col * scan * m, 1.0);
    \\    return out;
    \\}
;
