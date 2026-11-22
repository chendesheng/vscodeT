// Port of `src/vs/editor/common/core/2d/size.ts`.
const std = @import("std");
const Io = std.Io;
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
    pub fn deltaX(self: Size2D, delta: f64) Size2D {
        return .{ .width = self.width + delta, .height = self.height };
    }

    pub fn deltaY(self: Size2D, delta: f64) Size2D {
        return .{ .width = self.width, .height = self.height + delta };
    }

    pub fn mapComponents(self: Size2D, context: anytype, map: fn (value: f64, ctx: @TypeOf(context)) f64) Size2D {
        return .{ .width = map(self.width, context), .height = map(self.height, context) };
    }

    pub fn toString(self: Size2D, writer: *Io.Writer) !void {
        try writer.print("({d},{d})", .{ self.width, self.height });
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

test "size: deltas, mapComponents and toString" {
    const size = Size2D.init(2, 3);
    try std.testing.expectEqual(Size2D.init(5, 3), size.deltaX(3));
    try std.testing.expectEqual(Size2D.init(2, 8), size.deltaY(5));

    const Context = struct {
        fn negate(value: f64, _: void) f64 {
            return -value;
        }
    };
    try std.testing.expectEqual(Size2D.init(-2, -3), size.mapComponents({}, Context.negate));

    var buffer: [32]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try size.toString(&writer);
    try std.testing.expectEqualStrings("(2,3)", writer.buffered());
}
