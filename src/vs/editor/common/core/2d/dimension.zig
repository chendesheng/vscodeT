// Port of `src/vs/editor/common/core/2d/dimension.ts`.
const std = @import("std");
const Io = std.Io;

/// A width and height in pixels.
pub const IDimension = struct {
    width: f64,
    height: f64,

    pub fn init(width: f64, height: f64) IDimension {
        return .{ .width = width, .height = height };
    }

    pub fn equals(self: IDimension, other: IDimension) bool {
        return self.width == other.width and self.height == other.height;
    }

    pub fn toString(self: IDimension, writer: *Io.Writer) !void {
        try writer.print("{d}x{d}", .{ self.width, self.height });
    }
};

test "IDimension" {
    const dimension = IDimension.init(100, 50);
    try std.testing.expect(dimension.equals(IDimension.init(100, 50)));
    try std.testing.expect(!dimension.equals(IDimension.init(100, 51)));
}
