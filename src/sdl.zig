//! Sole C-interop surface for the rendering side: SDL3 + SDL3_ttf + SDL3_image.
//! The bindings are produced by the build's translate-c step (see build.zig and
//! src/cdefs.h), which replaces the language's old @cImport.
pub const c = @import("cdefs");
