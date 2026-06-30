//! Play-in-Editor preview producer — Path-A IOSurface ring (macOS/iOS).
//!
//! Extracted verbatim from `window.zig` (labelle-assembler#140 preview
//! decoupling) so the host window module stays under the per-file line
//! budget. The host re-exports every public symbol here as
//! `window.<name>` so the generated `main.zig` / codegen template — which
//! aliases `window.PreviewMtlBridge`, `window.preview_mtl`,
//! `window.PreviewIOSurfaceVtable`, `window.preview_metal_enabled` —
//! keeps working unchanged.
//!
//! These are pure backend-specific Metal/objc runtime bindings + the
//! per-frame ring management. The comptime gate
//! (`preview_metal_enabled`) keeps the libobjc/Metal `@extern`s out of
//! the link line on non-Darwin targets via the
//! `if (comptime ...) struct {...} else struct {}` shape — behaviour
//! identical to when this lived inline in `window.zig`.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sg = sokol.gfx;

/// Host window module — used for the runtime accessors the ring needs
/// (`width`/`height`/`metalDevice`) and the editor render-target shim
/// (`setEditorRenderTarget`/`clearEditorRenderTarget`). Imported lazily
/// (only inside function bodies) so there's no comptime import cycle
/// with `window.zig`, which re-exports the symbols from this file.
const window = @import("../window.zig");

/// Comptime gate equivalent to the codegen's old `_sokol_preview_metal_enabled`.
/// The codegen `PREVIEW_READBACK_HELPERS_METAL_SOKOL` template now reads:
///   const _sokol_preview_metal_enabled = window.preview_metal_enabled;
/// so the truth-value lives in the backend module.
pub const preview_metal_enabled: bool = switch (builtin.target.os.tag) {
    .macos, .ios => true,
    else => false,
};

/// libobjc + Metal runtime bindings used by the macOS Path-A preview
/// producer (#131). Wraps an IOSurface as an `MTLTexture` so sokol-gfx
/// can render directly into shared editor-visible memory.
///
/// MTLPixelFormatBGRA8Unorm = 80 — matches the IOSurface's BGRA8 pixel
/// format the engine producer negotiates (preview_iosurface.kPixelFormat_BGRA8).
///
/// On non-Darwin this resolves to an empty struct so no libobjc / Metal
/// symbols leak into the link line.
pub const PreviewMtlBridge = if (preview_metal_enabled) struct {
    pub const MTLPixelFormatBGRA8Unorm: u64 = 80;
    pub const MTLStorageModeShared: u64 = 0;
    pub const MTLStorageModeManaged: u64 = 1;
    pub const MTLTextureUsageShaderRead: u64 = 0x01;
    pub const MTLTextureUsageRenderTarget: u64 = 0x04;
    pub const MTLTextureType2D: u64 = 2;

    // libobjc primitives. Each typed `objc_msgSend` variant is a separate
    // @extern with a concrete signature — the libobjc symbol is variadic
    // but every call site has a fixed shape.
    pub const sel_registerName = @extern(
        *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "sel_registerName" },
    );
    pub const objc_getClass = @extern(
        *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "objc_getClass" },
    );

    // msgSend(obj, sel) -> void  (for `release`)
    pub const msgSend_void = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );
    // msgSend(cls, sel) -> id  (for `[MTLTextureDescriptor alloc]` style)
    pub const msgSend_id = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );
    // [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:width:height:mipmapped:]
    pub const msgSend_texdesc = @extern(
        *const fn (cls: ?*anyopaque, sel: ?*anyopaque, fmt: u64, w: usize, h: usize, mip: u8) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );
    // single-arg u64 setters
    pub const msgSend_set_u64 = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque, v: u64) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );
    // [device newTextureWithDescriptor:iosurface:plane:]
    pub const msgSend_newtex_iosurf = @extern(
        *const fn (
            obj: ?*anyopaque,
            sel: ?*anyopaque,
            desc: ?*anyopaque,
            iosurface: ?*anyopaque,
            plane: usize,
        ) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );

    // Selector cache — looked up lazily on first frame.
    pub var sel_release: ?*anyopaque = null;
    pub var sel_setStorageMode: ?*anyopaque = null;
    pub var sel_setUsage: ?*anyopaque = null;
    pub var sel_texDesc: ?*anyopaque = null;
    pub var sel_newTextureWithDescriptorIOSurfacePlane: ?*anyopaque = null;
    pub var cls_MTLTextureDescriptor: ?*anyopaque = null;

    pub fn loadSelectors() void {
        if (sel_release != null) return;
        sel_release = sel_registerName("release");
        sel_setStorageMode = sel_registerName("setStorageMode:");
        sel_setUsage = sel_registerName("setUsage:");
        sel_texDesc = sel_registerName(
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        );
        sel_newTextureWithDescriptorIOSurfacePlane = sel_registerName(
            "newTextureWithDescriptor:iosurface:plane:",
        );
        cls_MTLTextureDescriptor = objc_getClass("MTLTextureDescriptor");
    }

    /// Wrap `iosurface` as an `MTLTexture` whose backing store is the
    /// surface bytes. Width/height/format must match the IOSurface.
    /// Usage: ShaderRead | RenderTarget. Returns null on alloc failure.
    pub fn createIOSurfaceTexture(
        device: ?*anyopaque,
        iosurface: ?*anyopaque,
        w: u32,
        h: u32,
    ) ?*anyopaque {
        const cls = cls_MTLTextureDescriptor orelse return null;
        const desc = msgSend_texdesc(
            cls,
            sel_texDesc,
            MTLPixelFormatBGRA8Unorm,
            @intCast(w),
            @intCast(h),
            0,
        ) orelse return null;
        msgSend_set_u64(desc, sel_setStorageMode, MTLStorageModeShared);
        msgSend_set_u64(desc, sel_setUsage, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
        return msgSend_newtex_iosurf(
            device,
            sel_newTextureWithDescriptorIOSurfacePlane,
            desc,
            iosurface,
            0,
        );
    }

    pub fn release(obj: ?*anyopaque) void {
        if (obj) |o| msgSend_void(o, sel_release);
    }
} else struct {};

// ──────────────────────────────────────────────────────────────────
// Preview-mode Path-A state + lifecycle (labelle-assembler#140 Phase B)
// ──────────────────────────────────────────────────────────────────
// Phase A moved the libobjc/Metal bindings (PreviewMtlBridge) into
// this module. Phase B moves the per-frame ring management, the
// associated module-scope state, and the cleanup teardown.
//
// To avoid an engine dependency on this backend module (and the
// resulting type-instance ambiguity in the build graph), the
// codegen passes engine.Preview's relevant methods through this
// vtable. The backend module never sees an `engine.Preview` type.

pub const PreviewIOSurfaceVtable = struct {
    /// Opaque pointer to the host's `engine.Preview` instance. The
    /// backend never dereferences it; passes it back verbatim.
    ctx: *anyopaque,
    beginStream: *const fn (ctx: *anyopaque, w: u32, h: u32) anyerror!void,
    getSurfaceAt: *const fn (ctx: *anyopaque, slot: u32) ?*anyopaque,
    signalSlotReady: *const fn (ctx: *anyopaque, slot: u32) anyerror!void,
    endStream: *const fn (ctx: *anyopaque) void,
    isFrameAccepted: *const fn (ctx: *anyopaque) bool,
};

/// Path-A state + frame/cleanup hooks. The codegen calls these from
/// init/frame/cleanup callbacks. All state lives here; the generated
/// main.zig no longer carries `_preview_mtl_*` vars or the
/// ring-management block.
pub const preview_mtl = if (preview_metal_enabled) struct {
    pub const RING_MAX: u32 = 8;
    var initialized: bool = false;
    var ring_size: u32 = 0;
    var textures: [RING_MAX]?*anyopaque = [_]?*anyopaque{null} ** RING_MAX;
    var sg_images: [RING_MAX]sg.Image = [_]sg.Image{.{}} ** RING_MAX;
    var views: [RING_MAX]sg.View = [_]sg.View{.{}} ** RING_MAX;
    var attachments: [RING_MAX]sg.Attachments = [_]sg.Attachments{.{}} ** RING_MAX;
    var depth_img: sg.Image = .{};
    var depth_view: sg.View = .{};
    var target_active: bool = false;
    var write_slot: u32 = 0;
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var vt: ?PreviewIOSurfaceVtable = null;

    /// Wire the engine.Preview vtable. Called once after the gui's
    /// preview handshake succeeds, before the first frame.
    pub fn attach(vtable: PreviewIOSurfaceVtable) void {
        vt = vtable;
    }

    /// Pre-render hook. Negotiates the ring with the editor on resize,
    /// picks the next write slot, redirects the next `beginPass` into
    /// the offscreen IOSurface render target via `setEditorRenderTarget`.
    /// No-op if the editor hasn't accepted the frame stream yet.
    pub fn beginFrame() void {
        const vtable = vt orelse return;

        // Use width()/height() wrappers so headless mode returns the
        // configured dims (sapp isn't running in headless).
        const sw_i = window.width();
        const sh_i = window.height();
        if (sw_i <= 0 or sh_i <= 0) return;
        const sw: u32 = @intCast(sw_i);
        const sh: u32 = @intCast(sh_i);

        const device = @as(?*anyopaque, @constCast(window.metalDevice())) orelse return;
        PreviewMtlBridge.loadSelectors();

        if (!initialized or sw != last_w or sh != last_h) {
            // Tear down any prior ring before reallocating.
            if (initialized) {
                var i: u32 = 0;
                while (i < ring_size) : (i += 1) {
                    if (views[i].id != 0) {
                        sg.destroyView(views[i]);
                        views[i] = .{};
                    }
                    attachments[i] = .{};
                    // Order matters: destroy the sokol image first (it
                    // holds an internal reference to the MTLTexture but
                    // does NOT retain it), then release the MTLTexture.
                    if (sg_images[i].id != 0) {
                        sg.destroyImage(sg_images[i]);
                        sg_images[i] = .{};
                    }
                    if (textures[i]) |t| {
                        PreviewMtlBridge.release(t);
                        textures[i] = null;
                    }
                }
                initialized = false;
            }

            vtable.beginStream(vtable.ctx, sw, sh) catch return;

            // (Re)alloc shared depth-stencil image.
            if (depth_view.id != 0) {
                sg.destroyView(depth_view);
                depth_view = .{};
            }
            if (depth_img.id != 0) {
                sg.destroyImage(depth_img);
                depth_img = .{};
            }
            depth_img = sg.makeImage(.{
                .width = @intCast(sw),
                .height = @intCast(sh),
                .pixel_format = .DEPTH_STENCIL,
                .usage = .{ .depth_stencil_attachment = true, .immutable = true },
            });
            if (depth_img.id == 0) return;
            depth_view = sg.makeView(.{
                .depth_stencil_attachment = .{ .image = depth_img },
            });
            if (depth_view.id == 0) return;

            // Allocate ring slots (up to RING_MAX) until we hit the first
            // null IOSurface — the engine's producer maintains its own
            // ring size (default 3) and exposes slots via `getSurfaceAt`.
            var alloc_ok = true;
            var slot: u32 = 0;
            while (slot < RING_MAX) : (slot += 1) {
                const iosurf = vtable.getSurfaceAt(vtable.ctx, slot) orelse break;
                const mtl_tex = PreviewMtlBridge.createIOSurfaceTexture(device, iosurf, sw, sh) orelse {
                    alloc_ok = false;
                    break;
                };
                textures[slot] = mtl_tex;
                var desc: sg.ImageDesc = .{
                    .width = @intCast(sw),
                    .height = @intCast(sh),
                    .pixel_format = .BGRA8,
                    .usage = .{ .color_attachment = true, .immutable = true },
                };
                desc.mtl_textures[0] = @ptrCast(mtl_tex);
                desc.mtl_textures[1] = @ptrCast(mtl_tex);
                const img = sg.makeImage(desc);
                if (img.id == 0) {
                    alloc_ok = false;
                    break;
                }
                sg_images[slot] = img;
                const view = sg.makeView(.{
                    .color_attachment = .{ .image = img },
                });
                if (view.id == 0) {
                    alloc_ok = false;
                    break;
                }
                views[slot] = view;
                var att: sg.Attachments = .{};
                att.colors[0] = view;
                att.depth_stencil = depth_view;
                attachments[slot] = att;
            }

            if (!alloc_ok) {
                // Roll back partial ring; reset state so next attempt is clean.
                // Order matters: destroy the sokol image first (it holds an
                // internal reference to the MTLTexture but does NOT retain
                // it), then release the MTLTexture.
                var i: u32 = 0;
                while (i <= slot and i < RING_MAX) : (i += 1) {
                    if (views[i].id != 0) {
                        sg.destroyView(views[i]);
                        views[i] = .{};
                    }
                    attachments[i] = .{};
                    if (sg_images[i].id != 0) {
                        sg.destroyImage(sg_images[i]);
                        sg_images[i] = .{};
                    }
                    if (textures[i]) |t| {
                        PreviewMtlBridge.release(t);
                        textures[i] = null;
                    }
                }
                return;
            }

            ring_size = slot;
            initialized = true;
            last_w = sw;
            last_h = sh;
            write_slot = 0;
        }

        if (!vtable.isFrameAccepted(vtable.ctx)) return;
        if (ring_size == 0) return;

        window.setEditorRenderTarget(attachments[write_slot]);
        target_active = true;
    }

    /// Post-render hook. Signals the just-written slot to the editor
    /// and clears the render-target redirect. No-op if `beginFrame`
    /// didn't activate a target this frame.
    pub fn endFrame() void {
        const vtable = vt orelse return;
        if (!target_active) return;
        vtable.signalSlotReady(vtable.ctx, write_slot) catch {};
        window.clearEditorRenderTarget();
        target_active = false;
        write_slot = (write_slot + 1) % ring_size;
    }

    /// Cleanup hook. Destroys all sokol resources + MTLTextures + the
    /// shared depth attachments, then asks the engine to tear down
    /// the IOSurface ring.
    pub fn deinit() void {
        const vtable_opt = vt;
        window.clearEditorRenderTarget();
        var i: u32 = 0;
        while (i < ring_size) : (i += 1) {
            if (views[i].id != 0) {
                sg.destroyView(views[i]);
                views[i] = .{};
            }
            attachments[i] = .{};
            // Order matters: destroy the sokol image first (it holds an
            // internal reference to the MTLTexture but does NOT retain it),
            // then release the MTLTexture. Reversing the order leaves
            // sg_image pointing at freed Metal memory.
            if (sg_images[i].id != 0) {
                sg.destroyImage(sg_images[i]);
                sg_images[i] = .{};
            }
            if (textures[i]) |t| {
                PreviewMtlBridge.release(t);
                textures[i] = null;
            }
        }
        if (depth_view.id != 0) {
            sg.destroyView(depth_view);
            depth_view = .{};
        }
        if (depth_img.id != 0) {
            sg.destroyImage(depth_img);
            depth_img = .{};
        }
        ring_size = 0;
        initialized = false;
        target_active = false;
        if (vtable_opt) |vtable| vtable.endStream(vtable.ctx);
    }
} else struct {
    pub fn attach(_: PreviewIOSurfaceVtable) void {}
    pub fn beginFrame() void {}
    pub fn endFrame() void {}
    pub fn deinit() void {}
};
