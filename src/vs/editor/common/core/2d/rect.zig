// Port of `src/vs/editor/common/core/2d/rect.ts`.
//
// `toStyles` is not ported because the terminal has no CSS; the upstream
// `union` method is named `unionRect` because `union` is a Zig keyword.
const std = @import("std");
const Io = std.Io;
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
    pub fn hull(rects: []const Rect) !Rect {
        if (rects.len == 0) return error.InvalidRect;
        const max = @as(f64, 9007199254740991);
        var left = max;
        var top = max;
        var right = -max;
        var bottom = -max;
        for (rects) |rect| {
            left = @min(left, rect.left);
            top = @min(top, rect.top);
            right = @max(right, rect.right);
            bottom = @max(bottom, rect.bottom);
        }
        return init(left, top, right, bottom);
    }

    pub fn fromRanges(leftRight: OffsetRange, topBottom: OffsetRange) !Rect {
        return init(@floatFromInt(leftRight.start), @floatFromInt(topBottom.start), @floatFromInt(leftRight.endExclusive), @floatFromInt(topBottom.endExclusive));
    }

    pub fn withMargin(self: Rect, margin: f64) !Rect {
        return init(self.left - margin, self.top - margin, self.right + margin, self.bottom + margin);
    }

    pub fn withMargins(self: Rect, marginVertical: f64, marginHorizontal: f64) !Rect {
        return init(
            self.left - marginHorizontal,
            self.top - marginVertical,
            self.right + marginHorizontal,
            self.bottom + marginVertical,
        );
    }

    pub fn withMargins4(self: Rect, marginTop: f64, marginRight: f64, marginBottom: f64, marginLeft: f64) !Rect {
        return init(
            self.left - marginLeft,
            self.top - marginTop,
            self.right + marginRight,
            self.bottom + marginBottom,
        );
    }

    pub fn intersectVertical(self: Rect, range: OffsetRange) !Rect {
        const new_top = @max(self.top, @as(f64, @floatFromInt(range.start)));
        const new_bottom = @min(self.bottom, @as(f64, @floatFromInt(range.endExclusive)));
        return init(self.left, new_top, self.right, @max(new_top, new_bottom));
    }

    pub fn intersectHorizontal(self: Rect, range: OffsetRange) !Rect {
        const new_left = @max(self.left, @as(f64, @floatFromInt(range.start)));
        const new_right = @min(self.right, @as(f64, @floatFromInt(range.endExclusive)));
        return init(new_left, self.top, @max(new_left, new_right), self.bottom);
    }

    pub fn toString(self: Rect, writer: *Io.Writer) !void {
        try writer.print("Rect{{({d},{d}), ({d},{d})}}", .{ self.left, self.top, self.right, self.bottom });
    }

    pub fn moveToBeContainedIn(self: Rect, parent: Rect) !Rect {
        const rect_width = self.width();
        const rect_height = self.height();

        var left = self.left;
        var top = self.top;

        if (left < parent.left) {
            left = parent.left;
        } else if (left + rect_width > parent.right) {
            left = parent.right - rect_width;
        }

        if (top < parent.top) {
            top = parent.top;
        } else if (top + rect_height > parent.bottom) {
            top = parent.bottom - rect_height;
        }

        return init(left, top, left + rect_width, top + rect_height);
    }

    pub fn withWidth(self: Rect, new_width: f64) !Rect {
        return init(self.left, self.top, self.left + new_width, self.bottom);
    }

    pub fn withHeight(self: Rect, new_height: f64) !Rect {
        return init(self.left, self.top, self.right, self.top + new_height);
    }

    pub fn withTop(self: Rect, top: f64) !Rect {
        return init(self.left, top, self.right, self.bottom);
    }

    pub fn withLeft(self: Rect, left: f64) !Rect {
        return init(left, self.top, self.right, self.bottom);
    }

    pub fn translateX(self: Rect, delta: f64) !Rect {
        return init(self.left + delta, self.top, self.right + delta, self.bottom);
    }

    pub fn translateY(self: Rect, delta: f64) !Rect {
        return init(self.left, self.top + delta, self.right, self.bottom + delta);
    }

    pub fn deltaRight(self: Rect, delta: f64) !Rect {
        return init(self.left, self.top, self.right + delta, self.bottom);
    }

    pub fn deltaTop(self: Rect, delta: f64) !Rect {
        return init(self.left, self.top + delta, self.right, self.bottom);
    }

    pub fn deltaLeft(self: Rect, delta: f64) !Rect {
        return init(self.left + delta, self.top, self.right, self.bottom);
    }

    pub fn deltaBottom(self: Rect, delta: f64) !Rect {
        return init(self.left, self.top, self.right, self.bottom + delta);
    }

    pub fn getLeftBottom(self: Rect) Point {
        return Point.init(self.left, self.bottom);
    }

    pub fn getRightBottom(self: Rect) Point {
        return Point.init(self.right, self.bottom);
    }

    pub fn getLeftTop(self: Rect) Point {
        return Point.init(self.left, self.top);
    }

    pub fn getRightTop(self: Rect) Point {
        return Point.init(self.right, self.top);
    }

    pub fn withHorizontalRange(self: Rect, range: OffsetRange) !Rect {
        return init(@floatFromInt(range.start), self.top, @floatFromInt(range.endExclusive), self.bottom);
    }

    pub fn withVerticalRange(self: Rect, range: OffsetRange) !Rect {
        return init(self.left, @floatFromInt(range.start), self.right, @floatFromInt(range.endExclusive));
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

test "rect: hull, margins, translation and corners" {
    const a = try Rect.init(0, 0, 10, 10);
    const b = try Rect.init(5, -5, 15, 5);
    const hull = try Rect.hull(&.{ a, b });
    try std.testing.expectEqual(Rect{ .left = 0, .top = -5, .right = 15, .bottom = 10 }, hull);
    try std.testing.expectError(error.InvalidRect, Rect.hull(&.{}));

    try std.testing.expectEqual(Rect{ .left = -2, .top = -2, .right = 12, .bottom = 12 }, try a.withMargin(2));
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 16, .bottom = 10 }, try a.deltaRight(6));
    try std.testing.expectEqual(Rect{ .left = 2, .top = 0, .right = 10, .bottom = 10 }, try a.withLeft(2));
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 10, .bottom = 4 }, try a.withHeight(4));

    try std.testing.expectEqual(Point.init(0, 10), a.getLeftBottom());
    try std.testing.expectEqual(Point.init(10, 0), a.getRightTop());

    // The rect is moved back into the parent, preserving its size.
    const moved = try (try Rect.init(20, 20, 30, 30)).moveToBeContainedIn(a);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 10, .bottom = 10 }, moved);

    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try a.toString(&writer);
    try std.testing.expectEqualStrings("Rect{(0,0), (10,10)}", writer.buffered());
}
