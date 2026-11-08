const std = @import("std");
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const Point = @import("point.zig").Point;
const Size2D = @import("size.zig").Size2D;

pub const Rect = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,

    pub fn init(left: f64, top: f64, right: f64, bottom: f64) !Rect {
        if (left > right or top > bottom) return error.InvalidRect;
        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }

    pub fn width(self: Rect) f64 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) f64 {
        return self.bottom - self.top;
    }
    pub fn fromPoint(point: Point) !Rect {
        return init(point.x, point.y, point.x, point.y);
    }
    pub fn fromPoints(topLeft: Point, bottomRight: Point) !Rect {
        return init(topLeft.x, topLeft.y, bottomRight.x, bottomRight.y);
    }
    pub fn fromPointSize(point: Point, size: Point) !Rect {
        return init(point.x, point.y, point.x + size.x, point.y + size.y);
    }
    pub fn fromLeftTopRightBottom(left: f64, top: f64, right: f64, bottom: f64) !Rect {
        return init(left, top, right, bottom);
    }
    pub fn fromLeftTopWidthHeight(left: f64, top: f64, width_: f64, height_: f64) !Rect {
        return init(left, top, left + width_, top + height_);
    }
    pub fn fromRanges(leftRight: OffsetRange, topBottom: OffsetRange) !Rect {
        return init(@floatFromInt(leftRight.start), @floatFromInt(topBottom.start), @floatFromInt(leftRight.endExclusive), @floatFromInt(topBottom.endExclusive));
    }

    pub fn intersect(self: Rect, parent: Rect) ?Rect {
        const left = @max(self.left, parent.left);
        const right = @min(self.right, parent.right);
        const top = @max(self.top, parent.top);
        const bottom = @min(self.bottom, parent.bottom);
        if (left > right or top > bottom) return null;
        return init(left, top, right, bottom) catch null;
    }

    pub fn unionRect(self: Rect, other: Rect) !Rect {
        return init(@min(self.left, other.left), @min(self.top, other.top), @max(self.right, other.right), @max(self.bottom, other.bottom));
    }

    pub fn containsRect(self: Rect, other: Rect) bool {
        return self.left <= other.left and self.top <= other.top and self.right >= other.right and self.bottom >= other.bottom;
    }

    pub fn containsPoint(self: Rect, point: Point) bool {
        return self.left <= point.x and self.top <= point.y and self.right >= point.x and self.bottom >= point.y;
    }

    pub fn translate(self: Rect, point: Point) !Rect {
        return init(self.left + point.x, self.top + point.y, self.right + point.x, self.bottom + point.y);
    }

    pub fn getSize(self: Rect) Size2D {
        return Size2D.init(self.width(), self.height());
    }
    pub fn getHorizontalRange(self: Rect) OffsetRange {
        return OffsetRange.init(@intFromFloat(self.left), @intFromFloat(self.right));
    }
    pub fn getVerticalRange(self: Rect) OffsetRange {
        return OffsetRange.init(@intFromFloat(self.top), @intFromFloat(self.bottom));
    }
};

test "rect: intersections and containment" {
    const rect = try Rect.init(0, 0, 10, 10);
    const other = try Rect.init(5, 5, 15, 15);
    const intersection = rect.intersect(other).?;
    try std.testing.expectEqual(@as(f64, 5), intersection.left);
    try std.testing.expectEqual(@as(f64, 10), intersection.right);
    try std.testing.expect(rect.containsPoint(Point.init(3, 4)));
    try std.testing.expect(rect.containsRect(other) == false);
    try std.testing.expectError(error.InvalidRect, Rect.init(2, 0, 1, 1));
}
