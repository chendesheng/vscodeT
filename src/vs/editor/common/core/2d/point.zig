// Port of `src/vs/editor/common/core/2d/point.ts`.
const std = @import("std");
const Io = std.Io;
pub const Point = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }
    pub fn equals(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
    pub fn subtract(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
    pub fn scale(self: Point, factor: f64) Point {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }
    pub fn deltaX(self: Point, delta: f64) Point {
        return .{ .x = self.x + delta, .y = self.y };
    }
    pub fn deltaY(self: Point, delta: f64) Point {
        return .{ .x = self.x, .y = self.y + delta };
    }
    pub fn isZero(self: Point) bool {
        return self.x == 0 and self.y == 0;
    }
    pub fn mapComponents(self: Point, context: anytype, map: fn (value: f64, ctx: @TypeOf(context)) f64) Point {
        return .{ .x = map(self.x, context), .y = map(self.y, context) };
    }

    pub fn toString(self: Point, writer: *Io.Writer) !void {
        try writer.print("({d},{d})", .{ self.x, self.y });
    }

    pub fn withThreshold(self: Point, threshold: f64) Point {
        return .{
            .x = applyThreshold(self.x, threshold),
            .y = applyThreshold(self.y, threshold),
        };
    }
};

fn applyThreshold(value: f64, threshold: f64) f64 {
    if (value > threshold) return value - threshold;
    if (value < -threshold) return value + threshold;
    return 0;
}

test "point: arithmetic" {
    const p = Point.init(2, 3);
    try std.testing.expect(Point.equals(Point.init(3, 5), p.add(.{ .x = 1, .y = 2 })));
    try std.testing.expect(Point.equals(Point.init(1, 1), p.subtract(.{ .x = 1, .y = 2 })));
    try std.testing.expect(Point.equals(Point.init(4, 6), p.scale(2)));
    try std.testing.expect(Point.equals(Point.init(0, 0), Point.init(1, -1).withThreshold(2)));
}

test "point: mapComponents and toString" {
    const Context = struct {
        fn double(value: f64, _: void) f64 {
            return value * 2;
        }
    };
    const p = Point.init(1.5, -2).mapComponents({}, Context.double);
    try std.testing.expectEqual(Point.init(3, -4), p);

    var buffer: [32]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try Point.init(1, 2).toString(&writer);
    try std.testing.expectEqualStrings("(1,2)", writer.buffered());
}
