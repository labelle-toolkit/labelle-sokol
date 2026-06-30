//! D3D11 pixel readback for screenshot capture (labelle-assembler#213).
//!
//! Strategy: get the back buffer from sokol_app's swapchain, create a
//! staging texture with `D3D11_USAGE_STAGING + D3D11_CPU_ACCESS_READ`,
//! `CopyResource` back-buffer → staging, `Map` the staging texture for
//! CPU read, copy bytes out, `Unmap`. Runs after `sg.commit()` so the
//! back buffer holds the just-drawn frame.
//!
//! Native back-buffer format is DXGI_FORMAT_B8G8R8A8_UNORM (sokol's
//! desktop default). Bytes hit `out` as BGRA — the BMP writer's
//! `writeBmpFromBgra` skips the channel swizzle.
//!
//! D3D11 is COM. Zig doesn't have COM language support, so each call
//! reaches through the vtable manually: load the function-pointer
//! at index N, call with `this` as the first argument. Indices come
//! from `d3d11.h` (stable across SDK versions for the methods we use).

const std = @import("std");

// ── Sokol app handles ───────────────────────────────────────────────
extern fn sapp_d3d11_get_device() ?*anyopaque;
extern fn sapp_d3d11_get_device_context() ?*anyopaque;
extern fn sapp_d3d11_get_render_view() ?*anyopaque; // ID3D11RenderTargetView*

// ── DXGI / D3D11 constants ──────────────────────────────────────────
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const D3D11_USAGE_STAGING: u32 = 3;
const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
const D3D11_MAP_READ: u32 = 1;

// ── Subset of D3D11 / DXGI structs we touch ──────────────────────────
const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc: extern struct { Count: u32, Quality: u32 },
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?[*]u8,
    RowPitch: u32,
    DepthPitch: u32,
};

// ── IUnknown vtable (generic Release for any COM object) ──────────────
// All ID3D11* / IDXGI* interfaces inherit IUnknown — Release sits at
// slot 2 in every one of them. Using a dedicated IUnknownVTable for the
// `.Release()` calls below makes intent obvious: we are not invoking a
// view-specific method, just the universal IUnknown::Release.
const IUnknownVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
};

// ── ID3D11RenderTargetView vtable (we only need GetResource at slot 7) ──
// IUnknown:         0=QueryInterface 1=AddRef 2=Release
// ID3D11DeviceChild: 3=GetDevice 4=GetPrivateData 5=SetPrivateData 6=SetPrivateDataInterface
// ID3D11View:       7=GetResource
// ID3D11RenderTargetView: 8=GetDesc
// (Verified against MinGW-w64 `d3d11.h` `ID3D11RenderTargetViewVtbl`.)
const RtvVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetDevice: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    GetResource: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
};

// ── ID3D11Texture2D vtable: 10=GetDesc ─────────────────────────────
// IUnknown 0..2 + DeviceChild 3..6 + Resource 7..9 (GetType,
// SetEvictionPriority, GetEvictionPriority) + Texture2D 10 (GetDesc).
// (Verified against MinGW-w64 `d3d11.h` `ID3D11Texture2DVtbl`.)
const Tex2dVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetDevice: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    GetType: *const anyopaque,
    SetEvictionPriority: *const anyopaque,
    GetEvictionPriority: *const anyopaque,
    GetDesc: *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(.c) void,
};

// ── ID3D11Device vtable ─────────────────────────────────────────────
// ID3D11Device inherits IUnknown ONLY (NOT ID3D11DeviceChild — Device
// is the top of the chain, every other interface has a GetDevice() that
// points back at it). So the layout is:
//   IUnknown: 0=QueryInterface 1=AddRef 2=Release
//   ID3D11Device: 3=CreateBuffer 4=CreateTexture1D 5=CreateTexture2D ...
// (Verified against MinGW-w64 `d3d11.h` `ID3D11DeviceVtbl`.)
const DeviceVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const anyopaque,
    CreateBuffer: *const anyopaque,
    CreateTexture1D: *const anyopaque,
    CreateTexture2D: *const fn (
        *anyopaque,
        *const D3D11_TEXTURE2D_DESC,
        ?*const anyopaque, // initial data (null)
        *?*anyopaque,
    ) callconv(.c) i32,
};

// ── ID3D11DeviceContext: CopyResource=47, Map=14, Unmap=15 ─────────
// We only need three methods — declare the full prefix up through the
// highest one (47) so vtable layout matches.
const CtxVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const anyopaque,
    GetDevice: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    VSSetConstantBuffers: *const anyopaque,
    PSSetShaderResources: *const anyopaque,
    PSSetShader: *const anyopaque,
    PSSetSamplers: *const anyopaque,
    VSSetShader: *const anyopaque,
    DrawIndexed: *const anyopaque,
    Draw: *const anyopaque,
    Map: *const fn (
        *anyopaque,
        *anyopaque, // resource
        u32, // subresource
        u32, // map type
        u32, // map flags
        *D3D11_MAPPED_SUBRESOURCE,
    ) callconv(.c) i32,
    Unmap: *const fn (
        *anyopaque,
        *anyopaque, // resource
        u32, // subresource
    ) callconv(.c) void,
    // 16..46 — placeholder pointers we never invoke.
    _gap_16: *const anyopaque,
    _gap_17: *const anyopaque,
    _gap_18: *const anyopaque,
    _gap_19: *const anyopaque,
    _gap_20: *const anyopaque,
    _gap_21: *const anyopaque,
    _gap_22: *const anyopaque,
    _gap_23: *const anyopaque,
    _gap_24: *const anyopaque,
    _gap_25: *const anyopaque,
    _gap_26: *const anyopaque,
    _gap_27: *const anyopaque,
    _gap_28: *const anyopaque,
    _gap_29: *const anyopaque,
    _gap_30: *const anyopaque,
    _gap_31: *const anyopaque,
    _gap_32: *const anyopaque,
    _gap_33: *const anyopaque,
    _gap_34: *const anyopaque,
    _gap_35: *const anyopaque,
    _gap_36: *const anyopaque,
    _gap_37: *const anyopaque,
    _gap_38: *const anyopaque,
    _gap_39: *const anyopaque,
    _gap_40: *const anyopaque,
    _gap_41: *const anyopaque,
    _gap_42: *const anyopaque,
    _gap_43: *const anyopaque,
    _gap_44: *const anyopaque,
    _gap_45: *const anyopaque,
    _gap_46: *const anyopaque,
    CopyResource: *const fn (
        *anyopaque,
        *anyopaque, // dst
        *anyopaque, // src
    ) callconv(.c) void,
};

// COM vtable layout: `this` is a pointer whose first field is a pointer
// to its vtable struct. So `*?**const VTable` (interface) → vtable*.
fn vt(comptime V: type, obj: *anyopaque) *const V {
    const pp: *const *const V = @ptrCast(@alignCast(obj));
    return pp.*;
}

/// Read the back buffer into `out` (BGRA8, `w*h*4` bytes). Returns true
/// on success. `w`/`h` are queried internally from the back buffer's
/// descriptor; the caller's `w`/`h` arguments are sanity-checked
/// against them — any mismatch (e.g. HiDPI scaling drift) logs and
/// fails closed rather than producing a malformed file.
pub fn readback(out: []u8, w: u32, h: u32) bool {
    const device = sapp_d3d11_get_device() orelse {
        std.log.warn("screenshot: D3D11 device unavailable", .{});
        return false;
    };
    const ctx = sapp_d3d11_get_device_context() orelse {
        std.log.warn("screenshot: D3D11 context unavailable", .{});
        return false;
    };
    const rtv = sapp_d3d11_get_render_view() orelse {
        std.log.warn("screenshot: D3D11 render view unavailable", .{});
        return false;
    };

    // RTV → back buffer texture.
    var back_buffer_opaque: ?*anyopaque = null;
    vt(RtvVTable, rtv).GetResource(rtv, &back_buffer_opaque);
    const back_buffer = back_buffer_opaque orelse {
        std.log.warn("screenshot: RTV.GetResource returned null", .{});
        return false;
    };
    defer _ = vt(IUnknownVTable, back_buffer).Release(back_buffer);

    // Inspect the back buffer's descriptor — we need the actual width/
    // height to allocate the staging copy at the right size (sokol's
    // `width()`/`height()` are NSWindow / HWND client size; on HiDPI
    // displays these may differ from the swapchain's pixel dims).
    var desc: D3D11_TEXTURE2D_DESC = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
    vt(Tex2dVTable, back_buffer).GetDesc(back_buffer, &desc);

    if (desc.Width != w or desc.Height != h) {
        std.log.warn(
            "screenshot: back buffer ({d}x{d}) doesn't match expected ({d}x{d}); skipping",
            .{ desc.Width, desc.Height, w, h },
        );
        return false;
    }

    // Create the staging copy: same dims/format but CPU-readable.
    var staging_desc = desc;
    staging_desc.MipLevels = 1;
    staging_desc.ArraySize = 1;
    staging_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;

    var staging_opaque: ?*anyopaque = null;
    const hr = vt(DeviceVTable, device).CreateTexture2D(device, &staging_desc, null, &staging_opaque);
    if (hr < 0) {
        std.log.warn("screenshot: CreateTexture2D failed (hr=0x{x})", .{@as(u32, @bitCast(hr))});
        return false;
    }
    const staging = staging_opaque orelse {
        std.log.warn("screenshot: CreateTexture2D returned null", .{});
        return false;
    };
    defer _ = vt(IUnknownVTable, staging).Release(staging);

    // GPU-side copy back-buffer → staging.
    vt(CtxVTable, ctx).CopyResource(ctx, staging, back_buffer);

    // Map for read.
    var mapped: D3D11_MAPPED_SUBRESOURCE = .{ .pData = null, .RowPitch = 0, .DepthPitch = 0 };
    const map_hr = vt(CtxVTable, ctx).Map(ctx, staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (map_hr < 0 or mapped.pData == null) {
        std.log.warn("screenshot: Map failed (hr=0x{x})", .{@as(u32, @bitCast(map_hr))});
        return false;
    }
    defer vt(CtxVTable, ctx).Unmap(ctx, staging, 0);

    const src = mapped.pData.?;
    const dst_row_bytes: usize = @as(usize, w) * 4;
    const total: usize = dst_row_bytes * @as(usize, h);
    if (out.len < total) {
        std.log.warn("screenshot: output buffer too small ({d} < {d})", .{ out.len, total });
        return false;
    }
    // RowPitch may exceed `w*4` (driver alignment). Copy row by row.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_row = src + @as(usize, y) * mapped.RowPitch;
        const dst_off = @as(usize, y) * dst_row_bytes;
        @memcpy(out[dst_off .. dst_off + dst_row_bytes], src_row[0..dst_row_bytes]);
    }
    return true;
}
