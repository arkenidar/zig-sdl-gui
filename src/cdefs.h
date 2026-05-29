/* Root header for Zig's translate-c step (replaces the old @cImport).
 * SDL_MAIN_HANDLED keeps SDL's header-only main shim from hijacking our Zig main. */
#define SDL_MAIN_HANDLED 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_image/SDL_image.h>

/* LuaJIT (app logic / hot-reload). Many Lua API entries are function-like macros
 * in lua.h; the Zig binding calls the underlying real functions instead. */
#include <luajit-2.1/lua.h>
#include <luajit-2.1/lualib.h>
#include <luajit-2.1/lauxlib.h>
