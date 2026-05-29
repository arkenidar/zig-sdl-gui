//! The serializable frame boundary: draw Commands, InputEvents, and the Viewport.
//! These are plain data (no pointers into the renderer), which is exactly what lets
//! the same UI run in-process or across the umbilical socket.

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn inset(self: Rect, d: f32) Rect {
        return .{ .x = self.x + d, .y = self.y + d, .w = self.w - 2 * d, .h = self.h - 2 * d };
    }

    pub fn centerY(self: Rect) f32 {
        return self.y + self.h / 2;
    }
};

/// A single draw instruction. Text/image carry the string/source, not pixels —
/// the client rasterizes/loads with its own font and assets.
pub const Command = union(enum) {
    clip: ?Rect, // null = reset clip
    rect: struct { rect: Rect, color: Color },
    border: struct { rect: Rect, color: Color },
    text: struct { str: []const u8, x: f32, y: f32, color: Color, size: f32 },
    image: struct { src: []const u8, dst: Rect, tint: Color = Color.rgb(255, 255, 255) },
};

pub const InputEvent = union(enum) {
    pointer_down: struct { x: f32, y: f32 },
    pointer_up: struct { x: f32, y: f32 },
    pointer_move: struct { x: f32, y: f32 },
};

/// Client's logical size + DPI scale. The layout engine sizes everything against this.
pub const Viewport = struct {
    w: f32,
    h: f32,
    scale: f32 = 1.0,
};
