const std = @import("std");
const IDimension = @import("dimension.zig").IDimension;

pub const Size2D = struct {
    width: f64,
    height: f64,

    pub fn init(width: f64, height: f64) Size2D {
        return .{ .width = width, .height = height };
    }
    pub fn equals(a: Size2D, b: Size2D) bool {
        return a.width == b.width and a.height == b.height;
    }
    pub fn add(self: Size2D, other: Size2D) Size2D {
        return .{ .width = self.width + other.width, .height = self.height + other.height };
    }
    pub fn subtract(self: Size2D, other: Size2D) Size2D {
        return .{ .width = self.width - other.width, .height = self.height - other.height };
    }
    pub fn scale(self: Size2D, factor: f64) Size2D {
        return .{ .width = self.width * factor, .height = self.height * factor };
    }
    pub fn scaleWidth(self: Size2D, factor: f64) Size2D {
        return .{ .width = self.width * factor, .height = self.height };
    }
    pub fn isZero(self: Size2D) bool {
        return self.width == 0 and self.height == 0;
    }
    pub fn transpose(self: Size2D) Size2D {
        return .{ .width = self.height, .height = self.width };
    }
    pub fn toDimension(self: Size2D) IDimension {
        return .{ .width = self.width, .height = self.height };
    }
};

test "size: arithmetic and transpose" {
    const size = Size2D.init(2, 3);
    try std.testing.expect(Size2D.equals(Size2D.init(4, 6), size.scale(2)));
    try std.testing.expect(Size2D.equals(Size2D.init(3, 2), size.transpose()));
    try std.testing.expect(Size2D.equals(Size2D.init(1, 3), size.subtract(Size2D.init(1, 0))));
}
