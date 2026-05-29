//! Colors + metrics. Metrics are in *logical* units; the core multiplies them by
//! the viewport DPI scale, so a value like `row_height = 28` stays a comfortable
//! touch target on a high-density phone screen.
const cmd = @import("command.zig");
const Color = cmd.Color;

pub const Theme = struct {
    bg: Color = Color.rgb(28, 30, 34),
    panel: Color = Color.rgb(42, 46, 52),
    button: Color = Color.rgb(64, 70, 80),
    button_hot: Color = Color.rgb(82, 90, 102),
    button_active: Color = Color.rgb(110, 120, 135),
    accent: Color = Color.rgb(90, 160, 240),
    text: Color = Color.rgb(232, 234, 238),
    border: Color = Color.rgb(20, 22, 25),

    // logical metrics (scaled by DPI at use)
    font_size: f32 = 17,
    row_height: f32 = 30,
    spacing: f32 = 6,
    padding: f32 = 10,
};
