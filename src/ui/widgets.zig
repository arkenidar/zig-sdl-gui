//! Native EXAMPLE widgets, written entirely on the public Context API.
//! Nothing in core/ or render/ depends on this file — it's replaceable userland.
//! These are also what gets exposed to Lua; users compose new widgets in Lua on
//! the very same primitives.
const std = @import("std");
const core = @import("core.zig");
const Context = core.Context;
const Rect = core.Rect;

pub fn label(ui: *Context, text: []const u8) void {
    const r = ui.next();
    ui.drawTextIn(text, r, ui.theme.text, false);
}

pub fn button(ui: *Context, text: []const u8) bool {
    const id = ui.getId(text);
    const r = ui.next();
    const clicked = ui.buttonBehavior(id, r);
    const col = if (ui.active_id == id and ui.hovered(r))
        ui.theme.button_active
    else if (ui.hot_id == id)
        ui.theme.button_hot
    else
        ui.theme.button;
    ui.drawRect(r, col);
    ui.drawBorder(r, ui.theme.border);
    ui.drawTextIn(text, r, ui.theme.text, true);
    return clicked;
}

/// Returns the (possibly toggled) value.
pub fn checkbox(ui: *Context, text: []const u8, value: bool) bool {
    const id = ui.getId(text);
    const r = ui.next();
    const clicked = ui.buttonBehavior(id, r);
    const v = if (clicked) !value else value;

    const s = r.h * 0.7;
    const box: Rect = .{ .x = r.x, .y = r.centerY() - s / 2, .w = s, .h = s };
    ui.drawRect(box, ui.theme.button);
    ui.drawBorder(box, ui.theme.border);
    if (v) ui.drawRect(box.inset(s * 0.22), ui.theme.accent);

    const fs = ui.scaled(ui.theme.font_size);
    ui.drawText(text, box.x + box.w + ui.scaled(8), r.centerY() - fs / 2, ui.theme.text, fs);
    return v;
}

/// Horizontal slider. Returns the (possibly dragged) value. Draws `text` centered.
pub fn slider(ui: *Context, text: []const u8, value: f32, min: f32, max: f32) f32 {
    const id = ui.getId(text);
    const r = ui.next();
    const over = ui.hovered(r);
    if (over) ui.hot_id = id;
    if (over and ui.pointer.pressed) ui.active_id = id;

    var v = value;
    if (ui.active_id == id and ui.pointer.down) {
        const t = std.math.clamp((ui.pointer.x - r.x) / r.w, 0, 1);
        v = min + t * (max - min);
    }
    v = std.math.clamp(v, min, max);

    ui.drawRect(r, ui.theme.button);
    ui.drawBorder(r, ui.theme.border);

    const t = if (max > min) (v - min) / (max - min) else 0;
    const knob_w = ui.scaled(12);
    const knob: Rect = .{ .x = r.x + t * (r.w - knob_w), .y = r.y, .w = knob_w, .h = r.h };
    ui.drawRect(knob, ui.theme.accent);

    if (text.len > 0) ui.drawTextIn(text, r, ui.theme.text, true);
    return v;
}

// ---- tests (pure: no SDL) ----
const testing = std.testing;

fn stubMeasure(_: ?*anyopaque, text: []const u8, size: f32) [2]f32 {
    _ = size;
    return .{ @as(f32, @floatFromInt(text.len)) * 7, 14 };
}

test "button reports a click only across press+release over its rect" {
    var ui = core.Context.init(testing.allocator, stubMeasure, null);
    defer ui.deinit();
    const vp: core.Viewport = .{ .w = 200, .h = 100, .scale = 1 };

    // frame 1: press inside the (full-width) button -> not yet a click
    var down = [_]core.InputEvent{.{ .pointer_down = .{ .x = 50, .y = 20 } }};
    ui.beginFrame(vp, &down);
    try testing.expect(!button(&ui, "Hit"));
    ui.endFrame();

    // frame 2: release inside -> click fires
    var up = [_]core.InputEvent{.{ .pointer_up = .{ .x = 50, .y = 20 } }};
    ui.beginFrame(vp, &up);
    try testing.expect(button(&ui, "Hit"));
    ui.endFrame();
}

test "checkbox toggles on click; slider maps drag position to value" {
    var ui = core.Context.init(testing.allocator, stubMeasure, null);
    defer ui.deinit();
    const vp: core.Viewport = .{ .w = 200, .h = 100, .scale = 1 };

    // press then release toggles the checkbox false -> true
    var down = [_]core.InputEvent{.{ .pointer_down = .{ .x = 20, .y = 20 } }};
    ui.beginFrame(vp, &down);
    _ = checkbox(&ui, "on", false);
    ui.endFrame();
    var up = [_]core.InputEvent{.{ .pointer_up = .{ .x = 20, .y = 20 } }};
    ui.beginFrame(vp, &up);
    try testing.expect(checkbox(&ui, "on", false) == true);
    ui.endFrame();

    // dragging the slider: hold down near the right edge -> value near max
    var drag = [_]core.InputEvent{.{ .pointer_down = .{ .x = 188, .y = 20 } }};
    ui.beginFrame(vp, &drag);
    const v = slider(&ui, "", 0, 0, 1);
    ui.endFrame();
    try testing.expect(v > 0.8);
}
