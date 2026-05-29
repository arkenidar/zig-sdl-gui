//! Client-side renderer: owns the SDL3 window/renderer/font, consumes a command
//! buffer, caches rasterized text, loads images, and maps SDL mouse + touch events
//! to the engine's unified InputEvent. Also provides the text-measure callback.
//!
//! v1 coordinate choice: no HIGH_PIXEL_DENSITY, so render-output size == window
//! size == mouse-coordinate space (no point/pixel mismatch). DPI is applied as a
//! UI scale via SDL_GetWindowDisplayScale (text opened at the scaled pixel size).
const std = @import("std");
const c = @import("../sdl.zig").c;
const cmd = @import("../ui/command.zig");

const Command = cmd.Command;
const InputEvent = cmd.InputEvent;
const Viewport = cmd.Viewport;
const Color = cmd.Color;

const CachedText = struct { tex: *c.SDL_Texture, w: f32, h: f32 };

pub const Backend = struct {
    gpa: std.mem.Allocator,
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    font_logical: f32, // logical pt size; physical = font_logical * scale
    font_px: c_int,
    scale: f32,
    tex_cache: std.StringHashMap(CachedText),
    img_cache: std.StringHashMap(*c.SDL_Texture),

    pub fn init(gpa: std.mem.Allocator, title: [*:0]const u8, w: c_int, h: c_int, font_path: [*:0]const u8, font_logical: f32) !Backend {
        c.SDL_SetMainReady();
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        if (!c.TTF_Init()) return error.TtfInit;

        const window = c.SDL_CreateWindow(title, w, h, c.SDL_WINDOW_RESIZABLE) orelse return error.Window;
        const renderer = c.SDL_CreateRenderer(window, null) orelse return error.Renderer;
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderVSync(renderer, 1);

        var scale = c.SDL_GetWindowDisplayScale(window);
        if (scale < 1.0 or !std.math.isFinite(scale)) scale = 1.0;

        const font_px: c_int = @intFromFloat(@round(font_logical * scale));
        const font = c.TTF_OpenFont(font_path, @floatFromInt(font_px)) orelse return error.Font;

        return .{
            .gpa = gpa,
            .window = window,
            .renderer = renderer,
            .font = font,
            .font_logical = font_logical,
            .font_px = font_px,
            .scale = scale,
            .tex_cache = std.StringHashMap(CachedText).init(gpa),
            .img_cache = std.StringHashMap(*c.SDL_Texture).init(gpa),
        };
    }

    pub fn deinit(self: *Backend) void {
        self.clearTextCache();
        self.tex_cache.deinit();
        var it = self.img_cache.iterator();
        while (it.next()) |e| {
            c.SDL_DestroyTexture(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.img_cache.deinit();
        c.TTF_CloseFont(self.font);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.TTF_Quit();
        c.SDL_Quit();
    }

    fn clearTextCache(self: *Backend) void {
        var it = self.tex_cache.iterator();
        while (it.next()) |e| {
            c.SDL_DestroyTexture(e.value_ptr.tex);
            self.gpa.free(e.key_ptr.*);
        }
        self.tex_cache.clearRetainingCapacity();
    }

    pub fn currentViewport(self: *Backend) Viewport {
        var ow: c_int = 0;
        var oh: c_int = 0;
        _ = c.SDL_GetRenderOutputSize(self.renderer, &ow, &oh);

        var scale = c.SDL_GetWindowDisplayScale(self.window);
        if (scale < 1.0 or !std.math.isFinite(scale)) scale = 1.0;
        if (scale != self.scale) {
            self.scale = scale;
            const px: c_int = @intFromFloat(@round(self.font_logical * scale));
            if (px != self.font_px) {
                _ = c.TTF_SetFontSize(self.font, @floatFromInt(px));
                self.font_px = px;
                self.clearTextCache();
            }
        }
        return .{ .w = @floatFromInt(ow), .h = @floatFromInt(oh), .scale = scale };
    }

    // ---- text measure (MeasureFn) ----

    pub fn measureText(ctx: ?*anyopaque, text: []const u8, size: f32) [2]f32 {
        _ = size; // single open font size in v1
        const self: *Backend = @ptrCast(@alignCast(ctx.?));
        if (text.len == 0) return .{ 0, @floatFromInt(self.font_px) };
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetStringSize(self.font, text.ptr, text.len, &w, &h);
        return .{ @floatFromInt(w), @floatFromInt(h) };
    }

    fn getText(self: *Backend, text: []const u8) ?CachedText {
        if (text.len == 0) return null;
        if (self.tex_cache.get(text)) |ct| return ct;
        if (self.tex_cache.count() > 512) self.clearTextCache();

        const white = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const surf = c.TTF_RenderText_Blended(self.font, text.ptr, text.len, white) orelse return null;
        defer c.SDL_DestroySurface(surf);
        const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse return null;
        const ct: CachedText = .{ .tex = tex, .w = @floatFromInt(surf.*.w), .h = @floatFromInt(surf.*.h) };
        const key = self.gpa.dupe(u8, text) catch return ct;
        self.tex_cache.put(key, ct) catch self.gpa.free(key);
        return ct;
    }

    fn loadImage(self: *Backend, src: []const u8) ?*c.SDL_Texture {
        if (self.img_cache.get(src)) |t| return t;
        const z = self.gpa.allocSentinel(u8, src.len, 0) catch return null;
        @memcpy(z, src);
        defer self.gpa.free(z);
        const tex = c.IMG_LoadTexture(self.renderer, z.ptr) orelse return null;
        const key = self.gpa.dupe(u8, src) catch return tex;
        self.img_cache.put(key, tex) catch self.gpa.free(key);
        return tex;
    }

    fn setColor(self: *Backend, col: Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, col.r, col.g, col.b, col.a);
    }

    pub fn render(self: *Backend, theme_bg: Color, cmds: []const Command) void {
        self.setColor(theme_bg);
        _ = c.SDL_RenderClear(self.renderer);

        for (cmds) |command| switch (command) {
            .clip => |maybe| {
                if (maybe) |r| {
                    const ir = c.SDL_Rect{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.w), .h = @intFromFloat(r.h) };
                    _ = c.SDL_SetRenderClipRect(self.renderer, &ir);
                } else {
                    _ = c.SDL_SetRenderClipRect(self.renderer, null);
                }
            },
            .rect => |d| {
                self.setColor(d.color);
                var fr = c.SDL_FRect{ .x = d.rect.x, .y = d.rect.y, .w = d.rect.w, .h = d.rect.h };
                _ = c.SDL_RenderFillRect(self.renderer, &fr);
            },
            .border => |d| {
                self.setColor(d.color);
                var fr = c.SDL_FRect{ .x = d.rect.x, .y = d.rect.y, .w = d.rect.w, .h = d.rect.h };
                _ = c.SDL_RenderRect(self.renderer, &fr);
            },
            .text => |d| {
                const ct = self.getText(d.str) orelse continue;
                _ = c.SDL_SetTextureColorMod(ct.tex, d.color.r, d.color.g, d.color.b);
                _ = c.SDL_SetTextureAlphaMod(ct.tex, d.color.a);
                var dst = c.SDL_FRect{ .x = d.x, .y = d.y, .w = ct.w, .h = ct.h };
                _ = c.SDL_RenderTexture(self.renderer, ct.tex, null, &dst);
            },
            .image => |d| {
                const tex = self.loadImage(d.src) orelse continue;
                _ = c.SDL_SetTextureColorMod(tex, d.tint.r, d.tint.g, d.tint.b);
                _ = c.SDL_SetTextureAlphaMod(tex, d.tint.a);
                var dst = c.SDL_FRect{ .x = d.dst.x, .y = d.dst.y, .w = d.dst.w, .h = d.dst.h };
                _ = c.SDL_RenderTexture(self.renderer, tex, null, &dst);
            },
        };
    }

    pub fn present(self: *Backend) void {
        _ = c.SDL_RenderPresent(self.renderer);
    }

    /// Drain SDL events into `out`. Returns true if a quit was requested.
    pub fn pollEvents(self: *Backend, out: *std.ArrayList(InputEvent)) bool {
        var ow: c_int = 0;
        var oh: c_int = 0;
        _ = c.SDL_GetRenderOutputSize(self.renderer, &ow, &oh);
        const fw: f32 = @floatFromInt(ow);
        const fh: f32 = @floatFromInt(oh);

        var quit = false;
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => quit = true,
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => out.append(self.gpa, .{ .pointer_down = .{ .x = ev.button.x, .y = ev.button.y } }) catch {},
                c.SDL_EVENT_MOUSE_BUTTON_UP => out.append(self.gpa, .{ .pointer_up = .{ .x = ev.button.x, .y = ev.button.y } }) catch {},
                c.SDL_EVENT_MOUSE_MOTION => out.append(self.gpa, .{ .pointer_move = .{ .x = ev.motion.x, .y = ev.motion.y } }) catch {},
                c.SDL_EVENT_FINGER_DOWN => out.append(self.gpa, .{ .pointer_down = .{ .x = ev.tfinger.x * fw, .y = ev.tfinger.y * fh } }) catch {},
                c.SDL_EVENT_FINGER_UP => out.append(self.gpa, .{ .pointer_up = .{ .x = ev.tfinger.x * fw, .y = ev.tfinger.y * fh } }) catch {},
                c.SDL_EVENT_FINGER_MOTION => out.append(self.gpa, .{ .pointer_move = .{ .x = ev.tfinger.x * fw, .y = ev.tfinger.y * fh } }) catch {},
                else => {},
            }
        }
        return quit;
    }

    pub fn screenshot(self: *Backend, path: [*:0]const u8) void {
        const surf = c.SDL_RenderReadPixels(self.renderer, null) orelse return;
        defer c.SDL_DestroySurface(surf);
        _ = c.SDL_SaveBMP(surf, path);
    }
};
