//! Immediate-mode Context: the layout engine (containers + row sizing specs),
//! interaction IDs, the unified pointer model, and the PUBLIC widget-building API
//! (draw primitives + interaction queries + a headless-safe text measure).
//!
//! Nothing here calls SDL — widgets only append `Command`s and read the pointer,
//! which is what lets this exact code run headless on a server.
const std = @import("std");
const cmd = @import("command.zig");

pub const Rect = cmd.Rect;
pub const Color = cmd.Color;
pub const Command = cmd.Command;
pub const InputEvent = cmd.InputEvent;
pub const Viewport = cmd.Viewport;
pub const Theme = @import("theme.zig").Theme;

pub const MAX_COLS = 16;
pub const Id = u64;

/// Backend-supplied text metrics. Takes opaque ctx so the same Context works with
/// an SDL backend (local/client) or a TTF-only measurer (headless server).
pub const MeasureFn = *const fn (ctx: ?*anyopaque, text: []const u8, size: f32) [2]f32;

const Pointer = struct {
    x: f32 = 0,
    y: f32 = 0,
    down: bool = false,
    pressed: bool = false, // down edge this frame
    released: bool = false, // up edge this frame
};

const Layout = struct {
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    x: f32 = 0,
    y: f32 = 0,
    row_h: f32 = 0,
    cols: usize = 0,
    col: usize = 0,
    widths: [MAX_COLS]f32 = undefined,
    started: bool = false,
};

pub const Context = struct {
    arena_impl: std.heap.ArenaAllocator,
    cmds: std.ArrayList(Command) = .empty,

    viewport: Viewport = .{ .w = 0, .h = 0, .scale = 1 },
    theme: Theme = .{},
    pointer: Pointer = .{},

    hot_id: Id = 0,
    active_id: Id = 0,

    id_seed: Id = 0,
    id_stack: [16]Id = undefined,
    id_depth: usize = 0,

    layout: Layout = .{},

    measure_fn: MeasureFn,
    measure_ctx: ?*anyopaque,

    pub fn init(gpa: std.mem.Allocator, measure_fn: MeasureFn, measure_ctx: ?*anyopaque) Context {
        return .{
            .arena_impl = std.heap.ArenaAllocator.init(gpa),
            .measure_fn = measure_fn,
            .measure_ctx = measure_ctx,
        };
    }

    pub fn deinit(self: *Context) void {
        const gpa = self.arena_impl.child_allocator;
        self.cmds.deinit(gpa);
        self.arena_impl.deinit();
    }

    fn aalloc(self: *Context) std.mem.Allocator {
        return self.arena_impl.allocator();
    }

    pub fn scaled(self: *Context, v: f32) f32 {
        return v * self.viewport.scale;
    }

    // ---- frame lifecycle ----

    pub fn beginFrame(self: *Context, vp: Viewport, events: []const InputEvent) void {
        _ = self.arena_impl.reset(.retain_capacity);
        const gpa = self.arena_impl.child_allocator;
        self.cmds.clearRetainingCapacity();
        _ = gpa;

        self.viewport = vp;
        self.pointer.pressed = false;
        self.pointer.released = false;
        for (events) |ev| switch (ev) {
            .pointer_down => |p| {
                self.pointer.x = p.x;
                self.pointer.y = p.y;
                self.pointer.down = true;
                self.pointer.pressed = true;
            },
            .pointer_up => |p| {
                self.pointer.x = p.x;
                self.pointer.y = p.y;
                self.pointer.down = false;
                self.pointer.released = true;
            },
            .pointer_move => |p| {
                self.pointer.x = p.x;
                self.pointer.y = p.y;
            },
        };

        self.hot_id = 0;
        self.id_seed = 0;
        self.id_depth = 0;

        const pad = self.scaled(self.theme.padding);
        self.layout = .{
            .body = .{ .x = pad, .y = pad, .w = vp.w - 2 * pad, .h = vp.h - 2 * pad },
            .row_h = self.scaled(self.theme.row_height),
        };
    }

    pub fn endFrame(self: *Context) void {
        if (!self.pointer.down) self.active_id = 0;
    }

    // ---- identity ----

    pub fn getId(self: *Context, label: []const u8) Id {
        var h = std.hash.Wyhash.init(self.id_seed);
        h.update(label);
        return h.final() | 1; // never 0 (0 == "none")
    }

    pub fn pushId(self: *Context, n: u64) void {
        self.id_stack[self.id_depth] = self.id_seed;
        self.id_depth += 1;
        var h = std.hash.Wyhash.init(self.id_seed);
        h.update(std.mem.asBytes(&n));
        self.id_seed = h.final();
    }

    pub fn popId(self: *Context) void {
        self.id_depth -= 1;
        self.id_seed = self.id_stack[self.id_depth];
    }

    // ---- interaction queries ----

    pub fn hovered(self: *Context, r: Rect) bool {
        return r.contains(self.pointer.x, self.pointer.y);
    }

    /// Standard button-style interaction. Updates hot/active and reports a click
    /// (pressed on it AND released on it).
    pub fn buttonBehavior(self: *Context, id: Id, r: Rect) bool {
        const over = self.hovered(r);
        if (over) self.hot_id = id;
        if (over and self.pointer.pressed) self.active_id = id;
        return over and self.active_id == id and self.pointer.released;
    }

    // ---- layout ----

    fn beginRow(self: *Context, specs: []const f32, height: f32) void {
        var n = if (specs.len == 0) 1 else specs.len;
        if (n > MAX_COLS) n = MAX_COLS;

        if (self.layout.started) {
            self.layout.y += self.layout.row_h + self.scaled(self.theme.spacing);
        } else {
            self.layout.started = true;
        }

        const sp = self.scaled(self.theme.spacing);
        const avail = self.layout.body.w - sp * @as(f32, @floatFromInt(n - 1));

        var used: f32 = 0;
        var fills: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const spec: f32 = if (specs.len == 0) -1 else specs[i];
            if (spec <= 0) {
                fills += 1;
                self.layout.widths[i] = 0;
            } else if (spec < 1) {
                self.layout.widths[i] = spec * avail; // fraction of available width
                used += self.layout.widths[i];
            } else {
                self.layout.widths[i] = spec * self.viewport.scale; // logical pixels
                used += self.layout.widths[i];
            }
        }
        if (fills > 0) {
            const each = @max(0, avail - used) / @as(f32, @floatFromInt(fills));
            i = 0;
            while (i < n) : (i += 1) {
                const spec: f32 = if (specs.len == 0) -1 else specs[i];
                if (spec <= 0) self.layout.widths[i] = each;
            }
        }

        self.layout.cols = n;
        self.layout.col = 0;
        self.layout.row_h = height;
        self.layout.x = self.layout.body.x;
    }

    /// Declare the next row's columns. Width spec per column:
    ///   > 1  -> fixed logical pixels (scaled by DPI)
    ///   0..1 -> fraction of available width
    ///   <= 0 -> "fill" (share leftover space equally)
    /// `height` <= 0 uses the theme row height.
    pub fn row(self: *Context, specs: []const f32, height: f32) void {
        const h = if (height <= 0) self.scaled(self.theme.row_height) else self.scaled(height);
        self.beginRow(specs, h);
    }

    /// The rectangle for the next widget (auto-starts a full-width row if needed).
    pub fn next(self: *Context) Rect {
        if (!self.layout.started or self.layout.col >= self.layout.cols) {
            self.beginRow(&.{}, self.scaled(self.theme.row_height));
        }
        const w = self.layout.widths[self.layout.col];
        const r: Rect = .{ .x = self.layout.x, .y = self.layout.y, .w = w, .h = self.layout.row_h };
        self.layout.x += w + self.scaled(self.theme.spacing);
        self.layout.col += 1;
        return r;
    }

    // ---- draw primitives (append to the command buffer) ----

    pub fn drawRect(self: *Context, r: Rect, color: Color) void {
        self.cmds.append(self.arena_impl.child_allocator, .{ .rect = .{ .rect = r, .color = color } }) catch {};
    }

    pub fn drawBorder(self: *Context, r: Rect, color: Color) void {
        self.cmds.append(self.arena_impl.child_allocator, .{ .border = .{ .rect = r, .color = color } }) catch {};
    }

    pub fn drawText(self: *Context, str: []const u8, x: f32, y: f32, color: Color, size: f32) void {
        const owned = self.aalloc().dupe(u8, str) catch return;
        self.cmds.append(self.arena_impl.child_allocator, .{ .text = .{ .str = owned, .x = x, .y = y, .color = color, .size = size } }) catch {};
    }

    pub fn drawImage(self: *Context, src: []const u8, dst: Rect, tint: Color) void {
        const owned = self.aalloc().dupe(u8, src) catch return;
        self.cmds.append(self.arena_impl.child_allocator, .{ .image = .{ .src = owned, .dst = dst, .tint = tint } }) catch {};
    }

    pub fn measure(self: *Context, text: []const u8, size: f32) [2]f32 {
        return self.measure_fn(self.measure_ctx, text, size);
    }

    /// Draw text centered (vertically always; horizontally if `center_x`) in a rect.
    pub fn drawTextIn(self: *Context, str: []const u8, r: Rect, color: Color, center_x: bool) void {
        const fs = self.scaled(self.theme.font_size);
        const m = self.measure(str, fs);
        const tx = if (center_x) r.x + (r.w - m[0]) / 2 else r.x + self.scaled(6);
        const ty = r.centerY() - m[1] / 2;
        self.drawText(str, tx, ty, color, fs);
    }
};
