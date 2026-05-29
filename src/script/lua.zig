//! Zig <-> LuaJIT binding: the dynamic boundary. Exposes the native widget-building
//! API to Lua as a `ui` table, runs `scripts/app.lua`'s `frame(ui, s)` each frame,
//! and hot-reloads the file when it changes on disk (a pcall guard turns a bad edit
//! into an on-screen error instead of a crash).
//!
//! Many Lua C-API entries are function-like macros in lua.h, so we call the real
//! underlying functions (lua_createtable, lua_pushcclosure, lua_settop, ...).
const std = @import("std");
const c = @import("../sdl.zig").c; // SDL + LuaJIT both live in the cdefs module
const core = @import("../ui/core.zig");
const widgets = @import("../ui/widgets.zig");

/// Current context for the duration of a frame() call, so the bound C functions
/// can reach the engine. Single-threaded, so a file-scope pointer is fine.
var g_ui: ?*core.Context = null;

fn checkStr(L: ?*c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const p = c.luaL_checklstring(L, idx, &len);
    const m: [*]const u8 = @ptrCast(p);
    return m[0..len];
}

// ---- bound widget functions (the `ui` table) ----

fn l_label(L: ?*c.lua_State) callconv(.c) c_int {
    const ui = g_ui orelse return 0;
    widgets.label(ui, checkStr(L, 1));
    return 0;
}

fn l_button(L: ?*c.lua_State) callconv(.c) c_int {
    const ui = g_ui orelse return 0;
    const clicked = widgets.button(ui, checkStr(L, 1));
    c.lua_pushboolean(L, if (clicked) 1 else 0);
    return 1;
}

fn l_checkbox(L: ?*c.lua_State) callconv(.c) c_int {
    const ui = g_ui orelse return 0;
    const text = checkStr(L, 1);
    const val = c.lua_toboolean(L, 2) != 0;
    c.lua_pushboolean(L, if (widgets.checkbox(ui, text, val)) 1 else 0);
    return 1;
}

fn l_slider(L: ?*c.lua_State) callconv(.c) c_int {
    const ui = g_ui orelse return 0;
    const text = checkStr(L, 1);
    const val: f32 = @floatCast(c.luaL_checknumber(L, 2));
    const mn: f32 = @floatCast(c.luaL_checknumber(L, 3));
    const mx: f32 = @floatCast(c.luaL_checknumber(L, 4));
    c.lua_pushnumber(L, @as(f64, widgets.slider(ui, text, val, mn, mx)));
    return 1;
}

/// ui.row{ w1, w2, ... [ ] , optional_height }  -- declare next row's columns.
fn l_row(L: ?*c.lua_State) callconv(.c) c_int {
    const ui = g_ui orelse return 0;
    var specs: [core.MAX_COLS]f32 = undefined;
    const n = @min(c.lua_objlen(L, 1), core.MAX_COLS);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.lua_rawgeti(L, 1, @intCast(i + 1));
        specs[i] = @floatCast(c.lua_tonumber(L, -1));
        c.lua_settop(L, -2); // pop
    }
    const height: f32 = if (c.lua_gettop(L) >= 2) @floatCast(c.lua_tonumber(L, 2)) else 0;
    ui.row(specs[0..n], height);
    return 0;
}

fn registerFn(L: ?*c.lua_State, name: [*:0]const u8, func: c.lua_CFunction) void {
    c.lua_pushcclosure(L, func, 0);
    c.lua_setfield(L, -2, name); // table is at -2
}

pub const Script = struct {
    L: *c.lua_State,
    path: [*:0]const u8,
    ui_ref: c_int,
    state_ref: c_int,
    mtime: c.SDL_Time = 0,
    ok: bool = false,
    err_buf: [512]u8 = undefined,
    err: []const u8 = "",

    pub fn init(path: [*:0]const u8) !Script {
        const L = c.luaL_newstate() orelse return error.LuaState;
        c.luaL_openlibs(L);

        // build the `ui` table of bound functions, store a registry ref to it
        c.lua_createtable(L, 0, 8);
        registerFn(L, "label", l_label);
        registerFn(L, "button", l_button);
        registerFn(L, "checkbox", l_checkbox);
        registerFn(L, "slider", l_slider);
        registerFn(L, "row", l_row);
        const ui_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

        // persistent app state table (survives hot-reloads, so values are kept)
        c.lua_createtable(L, 0, 8);
        const state_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

        var self: Script = .{
            .L = L,
            .path = path,
            .ui_ref = ui_ref,
            .state_ref = state_ref,
        };
        self.refreshMtime();
        _ = self.loadFile();
        return self;
    }

    pub fn deinit(self: *Script) void {
        c.lua_close(self.L);
    }

    fn setErrFromStack(self: *Script) void {
        var len: usize = 0;
        const p = c.lua_tolstring(self.L, -1, &len);
        if (p != null) {
            const m: [*]const u8 = @ptrCast(p);
            const n = @min(len, self.err_buf.len);
            @memcpy(self.err_buf[0..n], m[0..n]);
            self.err = self.err_buf[0..n];
        } else {
            self.err = "lua error";
        }
        c.lua_settop(self.L, -2); // pop error message
    }

    fn refreshMtime(self: *Script) void {
        var info: c.SDL_PathInfo = undefined;
        if (c.SDL_GetPathInfo(self.path, &info)) self.mtime = info.modify_time;
    }

    /// (Re)load and run the chunk, which (re)defines the global `frame`.
    pub fn loadFile(self: *Script) bool {
        var size: usize = 0;
        const data = c.SDL_LoadFile(self.path, &size);
        if (data == null) {
            self.err = "cannot read script file";
            self.ok = false;
            return false;
        }
        defer c.SDL_free(data);

        if (c.luaL_loadbuffer(self.L, @ptrCast(data), size, self.path) != 0) {
            self.setErrFromStack();
            self.ok = false;
            return false;
        }
        if (c.lua_pcall(self.L, 0, 0, 0) != 0) {
            self.setErrFromStack();
            self.ok = false;
            return false;
        }
        self.ok = true;
        self.err = "";
        return true;
    }

    /// Reload if the file changed on disk since last check.
    pub fn maybeReload(self: *Script) void {
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(self.path, &info)) return;
        if (info.modify_time != self.mtime) {
            self.mtime = info.modify_time;
            _ = self.loadFile();
        }
    }

    /// Run frame(ui, state). On error, flips to the on-screen error view.
    pub fn frame(self: *Script, ui: *core.Context) void {
        if (!self.ok) {
            drawError(ui, self.err);
            return;
        }
        g_ui = ui;
        defer g_ui = null;

        c.lua_getfield(self.L, c.LUA_GLOBALSINDEX, "frame");
        if (c.lua_type(self.L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(self.L, -2); // pop non-function
            self.err = "scripts/app.lua must define: function frame(ui, s)";
            self.ok = false;
            drawError(ui, self.err);
            return;
        }
        c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.ui_ref);
        c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.state_ref);
        if (c.lua_pcall(self.L, 2, 0, 0) != 0) {
            self.setErrFromStack();
            self.ok = false;
            drawError(ui, self.err);
        }
    }
};

fn drawError(ui: *core.Context, msg: []const u8) void {
    widgets.label(ui, "Lua error - fix scripts/app.lua:");
    widgets.label(ui, msg);
}

// ---- tests ----
const testing = std.testing;

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fputs(s: [*:0]const u8, stream: ?*anyopaque) c_int;
extern fn fclose(stream: ?*anyopaque) c_int;

fn writeFileZ(path: [*:0]const u8, contents: [*:0]const u8) void {
    const f = fopen(path, "w") orelse return;
    _ = fputs(contents, f);
    _ = fclose(f);
}

fn tstMeasure(_: ?*anyopaque, text: []const u8, size: f32) [2]f32 {
    _ = size;
    return .{ @as(f32, @floatFromInt(text.len)) * 7, 14 };
}

fn hasText(ui: *core.Context, needle: []const u8) bool {
    for (ui.cmds.items) |command| switch (command) {
        .text => |t| if (std.mem.indexOf(u8, t.str, needle) != null) return true,
        else => {},
    };
    return false;
}

test "lua frame output, hot-reload, and error guard" {
    const path = "/tmp/zigui_reload_test.lua";
    writeFileZ(path, "function frame(ui,s) ui.label('AAA') end");

    var sc = try Script.init(path);
    defer sc.deinit();
    var ui = core.Context.init(testing.allocator, tstMeasure, null);
    defer ui.deinit();
    const vp: core.Viewport = .{ .w = 200, .h = 100, .scale = 1 };
    const no_events = [_]core.InputEvent{};

    ui.beginFrame(vp, &no_events);
    sc.frame(&ui);
    ui.endFrame();
    try testing.expect(sc.ok);
    try testing.expect(hasText(&ui, "AAA"));

    // edit -> reload -> new output (mtime forced stale to guarantee detection)
    writeFileZ(path, "function frame(ui,s) ui.label('BBB') end");
    sc.mtime = 0;
    sc.maybeReload();
    ui.beginFrame(vp, &no_events);
    sc.frame(&ui);
    ui.endFrame();
    try testing.expect(hasText(&ui, "BBB"));

    // bad edit -> on-screen error, no crash
    writeFileZ(path, "function frame(ui,s) this is not lua end");
    sc.mtime = 0;
    sc.maybeReload();
    try testing.expect(!sc.ok);
    ui.beginFrame(vp, &no_events);
    sc.frame(&ui);
    ui.endFrame();
    try testing.expect(hasText(&ui, "Lua error"));
}
