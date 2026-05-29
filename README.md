# zig-sdl GUI

A small **immediate-mode GUI** for **Zig + SDL3** with **Lua-scripted app logic** and
**hot-reload**. The same UI code is designed to run locally, or split across an optional
"umbilical" socket (UI server ↔ UI client) for desktop, mobile, or a VPS — see
[Roadmap](#roadmap).

> Status: **Phase 1 + Phase 2 complete and verified** (local window, widgets, layout, Lua
> logic, live hot-reload). Networking (Phase 3) and Android (Phase 4) are designed-for but
> not yet built.

![demo](docs/demo.png)

## The one idea

The GUI is a function whose edges are plain data:

```
frame(state, input_events, ui) -> (state', command_buffer)
```

- The app logic (`frame`) is authored in **Lua** (`scripts/app.lua`) and runs against a
  **native Zig core**.
- Widgets don't paint pixels — they append to a **command buffer**; a layout engine resolves
  their rectangles.
- Because both the input and the command buffer are serializable, the same logic can later run
  in-process or across a socket without changing the UI code (the umbilical).

## Requirements

- **Zig 0.17.0-dev** (this targets the dev build's APIs: translate-c instead of `@cImport`,
  unmanaged `ArrayList`, `createModule`/`root_module`).
- System libraries (Debian/Ubuntu package names):
  `libsdl3-dev libsdl3-ttf-dev libsdl3-image-dev libluajit-5.1-dev`
  (pkg-config names: `sdl3`, `sdl3-ttf`, `sdl3-image`, `luajit`).
- A TTF font (defaults to DejaVuSans at `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf`).

The build commands below invoke `zig` from your `PATH`. If you unpacked the dev
build to a custom directory (e.g. `~/apps/zig`, as on this Debian 13 setup), add it
to `PATH` — and to `~/.bashrc` to make it permanent:

```sh
# add to ~/.bashrc, then `source ~/.bashrc` (or open a new terminal)
export PATH="$HOME/apps/zig:$PATH"

zig version   # -> 0.17.0-dev.389+...
```

## Build & run

```sh
zig build            # compile
zig build run        # compile + run (Lua-driven UI from scripts/app.lua)
zig build test       # run unit tests (interaction logic + hot-reload)
```

The binary is `zig-out/bin/zigui`.

### Configuration (environment variables)

Config is read via `SDL_getenv` (the std args API is mid-rework in this Zig dev build):

| Var            | Meaning                                                        |
|----------------|---------------------------------------------------------------|
| `ZIGUI_FONT`   | Path to a `.ttf` (default: DejaVuSans)                         |
| `ZIGUI_SCRIPT` | Path to the Lua app (default: `scripts/app.lua`)              |
| `ZIGUI_NATIVE` | If set, use the built-in native demo instead of Lua          |
| `ZIGUI_FRAMES` | Render N frames then quit (for headless/CI; 0 = run forever)  |
| `ZIGUI_SHOT`   | Save a BMP screenshot of the last frame                       |
| `ZIGUI_LUA_DEBUG` | If set, attach to a local LuaPanda session (`127.0.0.1:8818`) — see [Debugging](#debugging) |

Example headless smoke test:

```sh
ZIGUI_FRAMES=8 ZIGUI_SHOT=/tmp/shot.bmp ./zig-out/bin/zigui
```

## Debugging

Two independent debuggers — use either alone or both in the same run.

### Native (Zig) — gdb

`zig build` is a Debug build with symbols. In VS Code (with the C/C++ extension,
`ms-vscode.cpptools`) pick **Debug zigui (gdb)**: it builds, launches `zig-out/bin/zigui`
under gdb, and stops at breakpoints in `src/*.zig`. Equivalent from a terminal:

```sh
gdb --args zig-out/bin/zigui
```

### Lua (`scripts/app.lua`) — LuaPanda over a local socket

Real breakpoints/stepping in your live-edited Lua via the **LuaPanda** extension
(`stuartwang.luapanda`). The debugger core is vendored at `scripts/LuaPanda.lua`, and the
connection rides LuaSocket (a system package here) over `127.0.0.1` loopback — no networking
code in the app.

1. Install the LuaPanda VS Code extension.
2. Start the **Lua: LuaPanda (listen 8818)** debug session **first** — VS Code listens on 8818.
3. Run the app with the opt-in flag so it connects out:

   ```sh
   ZIGUI_LUA_DEBUG=1 zig build run
   ```

4. Set breakpoints in `scripts/app.lua`; interacting with the window hits them. Since `frame()`
   runs synchronously, the window pauses while you're stopped and resumes on continue.
   Hot-reload still works while debugging.

If no listener is up, `ZIGUI_LUA_DEBUG=1` is a quiet no-op and the app runs normally. Loopback
only by design (remote/umbilical debugging is a later phase); stepping through Lua *tail calls*
under LuaJIT can be imperfect — a known LuaPanda limitation.

#### Worked example — break on the `+` button's increment

With the **Lua: LuaPanda (listen 8818)** session running, launch the app so it connects out:

```sh
ZIGUI_LUA_DEBUG=1 zig build run
```

In `scripts/app.lua` the counter is bumped inside a guard:

```lua
if ui.button("+") then
  s.count = s.count + 1   -- ← set the breakpoint on THIS line
end
```

Set the breakpoint on the `s.count = s.count + 1` line and click **+** in the window — execution
stops there; inspect `s` and `ui`, step, continue (the window resumes). Edit the script and it
still hot-reloads mid-session.

Break on the **statement**, not a one-line `if … then … end`: that `if` line runs *every frame*
(the condition is polled each frame), so a breakpoint on it fires constantly. This is why the
project keeps each statement on its own line — `.stylua.toml` sets
`collapse_simple_statement = "Never"` (see [Pre-commit gate](#pre-commit-gate)), so the formatter
and editor never collapse a guarded statement back onto the `if` line.

#### Both debuggers at once

The compound **Dual debug (Zig gdb + Lua LuaPanda)** starts the listener and the gdb session
together (it sets `ZIGUI_LUA_DEBUG=1` for you): two concurrent sessions — native breakpoints in
`src/*.zig` **and** Lua breakpoints in `scripts/app.lua`. Switch between them in the Call Stack
panel. A gdb breakpoint halts the whole process; a LuaPanda breakpoint parks inside `frame()`, so
gdb still shows the process as running while you're stopped in Lua.

## Writing UI (Lua)

Edit `scripts/app.lua` **while the app is running** — it hot-reloads within a frame and your
state is preserved. Interactions are return values, not callbacks:

```lua
function frame(ui, s)
  s.count = s.count or 0

  ui.label("Hello")

  -- a row: 48px button | filling label | 48px button
  ui.row{ 48, -1, 48 }
  if ui.button("-") then s.count = s.count - 1 end
  ui.label("count: " .. s.count)
  if ui.button("+") then s.count = s.count + 1 end

  s.vol  = ui.slider("volume", s.vol or 0.5, 0, 1)
  s.dark = ui.checkbox("dark", s.dark or false)
end
```

A custom widget is just a Lua function built from the same primitives:

```lua
local function counter(ui, label, v)
  ui.row{ 40, -1, 40 }
  if ui.button("-") then v = v - 1 end
  ui.label(label .. ": " .. v)
  if ui.button("+") then v = v + 1 end
  return v
end
```

### The `ui` API (currently bound to Lua)

| Call | Returns | Notes |
|------|---------|-------|
| `ui.label(text)` | – | left-aligned text |
| `ui.button(text)` | `bool` | true on click |
| `ui.checkbox(text, value)` | `bool` | the (possibly toggled) value |
| `ui.slider(text, value, min, max)` | `number` | the (possibly dragged) value |
| `ui.row{ w1, w2, ... [, height] }` | – | column widths: `>1` px, `0..1` fraction, `<=0` fill |

If a row isn't declared, each widget gets its own full-width row.

## Architecture / source layout

> **Deep dive:** a living design record — decisions (considered → chosen → why → status),
> dynamics, schematics, inspirations, and a dated decision log. Read it rendered at
> **<https://arkenidar.github.io/zig-sdl-gui/design/architecture.html>**
> (source: [docs/design/architecture.html](docs/design/architecture.html)).

```
src/
  cdefs.h              C headers for the build's translate-c step (SDL3 + ttf + image + LuaJIT)
  sdl.zig              re-exports the translated C module as `c`
  ui/
    command.zig        Command / InputEvent / Viewport / Rect / Color  (the serializable boundary)
    core.zig           Context: layout engine, IDs, pointer model, public widget-building API
    widgets.zig        example widgets on the public API (replaceable userland) + tests
    theme.zig          colors + DPI-scaled metrics
  render/
    sdl_backend.zig    window/renderer/font; renders the command buffer; text cache; input -> InputEvent
  script/
    lua.zig            Zig<->LuaJIT binding; runs frame(); file-watch hot-reload + error guard + tests
  main.zig             entry point; wires backend + context + (Lua | native) loop
scripts/
  app.lua              THE app logic you edit live
build.zig{,.zon}       targets Zig 0.17-dev; links the system libs via translate-c
```

Key design choices:

- **Widgets are userland.** The toolkit's value is the public API on `Context`
  (`layout`/`interaction`/`draw` primitives). `widgets.zig` is example widgets nothing depends
  on; you replace or compose freely (in Zig or Lua).
- **`core` calls no SDL.** Widgets only append `Command`s and read the unified pointer, so the
  exact same code can run headless on a server (Phase 3).
- **Touch-ready.** Mouse and `SDL_EVENT_FINGER_*` map to the same `InputEvent`s.
- **Text is measured, not embedded.** The core measures via a backend callback so layout is
  exact; the backend rasterizes + caches glyph textures (tinted per draw via color-mod).

## Tests

`zig build test` runs:
- widget interaction logic (button click across press+release, checkbox toggle, slider drag),
- Lua frame output + **hot-reload** (edit → reload → new output) + the bad-edit error guard.

## Pre-commit gate

A git hook autoformats and checks every commit. Enable it once per clone:

```sh
git config core.hooksPath .githooks
```

On commit, `.githooks/pre-commit` runs:

- **format** — `zig fmt` on staged `.zig`, `stylua` on staged `.lua` (the vendored
  `scripts/LuaPanda.lua` is excluded); reformatted files are re-staged. Lua style lives in
  `.stylua.toml` (2-space; statements kept on their own line so breakpoints can target them).
- **check** — `zig build` then `zig build test`; a failure aborts the commit.

It finds `zig` on PATH or at `~/apps/zig`, and `stylua` on PATH or at `~/.local/bin`
(install stylua from its [releases](https://github.com/JohnnyMorganz/StyLua/releases) or
`cargo install stylua`; if it's missing, the hook warns and skips Lua formatting rather than
blocking).

VS Code is set to match: `.vscode/settings.json` makes stylua the Lua formatter with
format-on-save (install the
[stylua extension](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.stylua)),
reading the same `.stylua.toml` — so on-save formatting equals the gate, no tug-of-war.

## Roadmap

- **Phase 3 — Umbilical:** `net/` with a length-prefixed codec + `Transport { Local, Tcp }`;
  modes `--server` / `--client`; two channels (remote-render and Lua `ScriptPush`). Works
  desktop↔desktop, over a VPS, or to a phone via `adb reverse`.
- **Phase 4 — Android:** package the native host with SDL3; connect over the USB umbilical.
- **Later:** multi-session server, TLS/auth, scrolling/text-input widgets, image-heavy demos.

The architecture is built so these are additive — the `frame`/command-buffer boundary and the
public widget API don't change.
