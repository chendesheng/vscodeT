const std = @import("std");
/// A VM-friendly RGBA8 color: each channel is clamped to [0, 255].
pub const RGBA8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const empty: RGBA8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn init(r: i32, g: i32, b: i32, a: i32) RGBA8 {
        return .{ .r = clamp(r), .g = clamp(g), .b = clamp(b), .a = clamp(a) };
    }

    pub fn equals(self: RGBA8, other: RGBA8) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }

    fn clamp(value: i32) u8 {
        if (value < 0) return 0;
        if (value > 255) return 255;
        return @intCast(value);
    }
};

test "rgba8: clamps channels" {
    const color = RGBA8.init(-1, 128, 300, 255);
    try std.testing.expectEqual(@as(u8, 0), color.r);
    try std.testing.expectEqual(@as(u8, 128), color.g);
    try std.testing.expectEqual(@as(u8, 255), color.b);
    try std.testing.expect(color.equals(.{ .r = 0, .g = 128, .b = 255, .a = 255 }));
}
