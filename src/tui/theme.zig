const TokenizationRegistry = @import("../vs/editor/common/tokenizationRegistry.zig").TokenizationRegistry;

/// Resolves a token color id through the active VS Code theme's color map.
/// The fallback palette keeps the read-only tools usable before a theme is
/// initialized.
pub fn colorForToken(foreground: u9) ?[3]u8 {
    if (TokenizationRegistry.instance.getColorMap()) |color_map| {
        if (foreground >= color_map.len) return null;
        const color = color_map[foreground];
        return .{ color.r, color.g, color.b };
    }
    return switch (foreground) {
        5 => .{ 106, 153, 85 },
        6 => .{ 206, 145, 120 },
        7 => .{ 209, 105, 105 },
        8 => .{ 197, 134, 192 },
        9 => .{ 181, 206, 168 },
        10 => .{ 220, 220, 170 },
        11 => .{ 78, 201, 176 },
        12 => .{ 156, 220, 254 },
        else => null,
    };
}
