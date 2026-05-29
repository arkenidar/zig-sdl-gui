//! Entry point. Phase 1: a local window driven by a temporary *native* frame()
//! that exercises the command-buffer + widget-building API end-to-end, before the
//! Lua layer is bound on top (Phase 2).
//!
//! Config via environment variables (the std args API is mid-rework in this Zig
//! dev build, so we read settings through SDL_getenv):
//!   ZIGUI_FONT=PATH    TTF to use (default: DejaVuSans)
//!   ZIGUI_FRAMES=N     render N frames then quit (0/unset = run until closed)
//!   ZIGUI_SHOT=PATH    save a BMP screenshot of the last frame (headless verify)
//!   ZIGUI_LUA_DEBUG    if set, attach to a local LuaPanda session (127.0.0.1:8818)
const std = @import("std");
const c = @import("sdl.zig").c;
const core = @import("ui/core.zig");
const widgets = @import("ui/widgets.zig");
const Backend = @import("render/sdl_backend.zig").Backend;
const Script = @import("script/lua.zig").Script;
const InputEvent = @import("ui/command.zig").InputEvent;

const default_font = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
const default_script = "scripts/app.lua";

const AppState = struct {
    count: i64 = 0,
    vol: f32 = 0.5,
    dark: bool = true,
};

/// Temporary native UI logic. In Phase 2 this moves into scripts/app.lua.
fn demoFrame(ui: *core.Context, s: *AppState) void {
    widgets.label(ui, "zig-sdl - immediate-mode GUI (Phase 1)");

    // counter row: [ - ] [ count ] [ + ]
    ui.row(&.{ 48, -1, 48 }, 0);
    if (widgets.button(ui, "-")) s.count -= 1;
    var buf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "count: {d}", .{s.count}) catch "count";
    widgets.label(ui, t);
    if (widgets.button(ui, "+")) s.count += 1;

    s.vol = widgets.slider(ui, "volume", s.vol, 0, 1);
    s.dark = widgets.checkbox(ui, "dark mode", s.dark);

    if (widgets.button(ui, "Reset count")) s.count = 0;
}

fn envZ(name: [*:0]const u8) ?[*:0]const u8 {
    const v = c.SDL_getenv(name);
    if (v == null) return null;
    return @ptrCast(v);
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    // ---- config from env ----
    const font_z: [*:0]const u8 = envZ("ZIGUI_FONT") orelse default_font;
    const script_z: [*:0]const u8 = envZ("ZIGUI_SCRIPT") orelse default_script;
    const use_native = envZ("ZIGUI_NATIVE") != null;
    const lua_debug = envZ("ZIGUI_LUA_DEBUG") != null;
    var max_frames: u64 = 0;
    if (envZ("ZIGUI_FRAMES")) |f| max_frames = std.fmt.parseInt(u64, std.mem.span(f), 10) catch 0;
    const shot_z: ?[*:0]const u8 = envZ("ZIGUI_SHOT");

    // ---- backend + context ----
    var backend = Backend.init(gpa, "zig-sdl GUI", 480, 360, font_z, 17) catch |e| {
        _ = c.SDL_Log("backend init failed: %s", @errorName(e).ptr);
        return e;
    };
    defer backend.deinit();

    var ui = core.Context.init(gpa, Backend.measureText, &backend);
    defer ui.deinit();

    // Phase 2: app logic lives in Lua (hot-reloaded). ZIGUI_NATIVE=1 keeps the
    // temporary native demo from Phase 1 for comparison.
    var state: AppState = .{};
    var script: ?Script = if (use_native) null else (Script.init(script_z) catch |e| blk: {
        _ = c.SDL_Log("lua init failed: %s", @errorName(e).ptr);
        break :blk null;
    });
    defer if (script) |*s| s.deinit();

    // ZIGUI_LUA_DEBUG: attach to a local LuaPanda session (start it in VS Code first).
    if (lua_debug) if (script) |*s| s.enableDebugger();

    var events: std.ArrayList(InputEvent) = .empty;
    defer events.deinit(gpa);

    var frame: u64 = 0;
    while (true) {
        events.clearRetainingCapacity();
        const quit = backend.pollEvents(&events);

        if (script) |*s| s.maybeReload();

        const vp = backend.currentViewport();
        ui.beginFrame(vp, events.items);
        if (script) |*s| s.frame(&ui) else demoFrame(&ui, &state);
        ui.endFrame();

        backend.render(ui.theme.bg, ui.cmds.items);

        frame += 1;
        const last = max_frames > 0 and frame >= max_frames;
        if (last) if (shot_z) |p| backend.screenshot(p);
        backend.present();

        if (quit or last) break;
    }
}
