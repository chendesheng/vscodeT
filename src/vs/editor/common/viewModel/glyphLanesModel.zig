const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../core/range.zig").Range;
const GlyphMarginLane = @import("../model.zig").GlyphMarginLane;

const MAX_LANE: usize = @backingInt(GlyphMarginLane.Right);

pub const GlyphMarginLanesModel = struct {
    allocator: Allocator,
    lanes: []u8,
    persist: u8,
    _requiredLanes: usize,

    pub fn init(allocator: Allocator, maxLine: usize) !GlyphMarginLanesModel {
        const lanes = try allocator.alloc(u8, byteLen(maxLine));
        @memset(lanes, 0);
        return .{
            .allocator = allocator,
            .lanes = lanes,
            .persist = 0,
            ._requiredLanes = 1, // always render at least one lane
        };
    }

    pub fn deinit(self: *GlyphMarginLanesModel) void {
        self.allocator.free(self.lanes);
    }

    pub fn reset(self: *GlyphMarginLanesModel, maxLine: usize) !void {
        const bytes = byteLen(maxLine);
        if (self.lanes.len < bytes) {
            const new_lanes = try self.allocator.alloc(u8, bytes);
            @memset(new_lanes, 0);
            self.allocator.free(self.lanes);
            self.lanes = new_lanes;
        } else {
            @memset(self.lanes, 0);
        }
        self._requiredLanes = 1;
    }

    pub fn requiredLanes(self: *const GlyphMarginLanesModel) usize {
        return self._requiredLanes;
    }

    pub fn push(self: *GlyphMarginLanesModel, lane: GlyphMarginLane, range: Range, persist: bool) void {
        const lane_index = @backingInt(lane) - 1;
        if (persist) {
            self.persist |= @as(u8, 1) << @intCast(lane_index);
        }
        var line = range.startLineNumber;
        while (line <= range.endLineNumber) : (line += 1) {
            const bit = MAX_LANE * line + lane_index;
            self.lanes[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
            self._requiredLanes = @max(self._requiredLanes, self.countAtLine(line));
        }
    }

    pub fn getLanesAtLine(self: *const GlyphMarginLanesModel, allocator: Allocator, lineNumber: usize) ![]GlyphMarginLane {
        const count = self.countAtLine(lineNumber);
        if (count == 0) {
            const result = try allocator.alloc(GlyphMarginLane, 1);
            result[0] = .Center;
            return result;
        }

        const result = try allocator.alloc(GlyphMarginLane, count);
        var result_index: usize = 0;
        var bit = MAX_LANE * lineNumber;
        for (0..MAX_LANE) |i| {
            if ((self.persist & (@as(u8, 1) << @intCast(i))) != 0 or
                (bit / 8 < self.lanes.len and (self.lanes[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0))
            {
                result[result_index] = @fromBackingInt(@intCast(i + 1));
                result_index += 1;
            }
            bit += 1;
        }
        return result;
    }

    fn countAtLine(self: *const GlyphMarginLanesModel, lineNumber: usize) usize {
        var count: usize = 0;
        var bit = MAX_LANE * lineNumber;
        for (0..MAX_LANE) |i| {
            if ((self.persist & (@as(u8, 1) << @intCast(i))) != 0 or
                (bit / 8 < self.lanes.len and (self.lanes[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0))
            {
                count += 1;
            }
            bit += 1;
        }
        return count;
    }
};

fn byteLen(maxLine: usize) usize {
    const bits = (maxLine + 1) * MAX_LANE;
    return (bits + 7) / 8;
}

test "glyph lanes: handles empty" {
    var model = try GlyphMarginLanesModel.init(std.testing.allocator, 10);
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 1), model.requiredLanes());
    const lanes = try model.getLanesAtLine(std.testing.allocator, 1);
    defer std.testing.allocator.free(lanes);
    try std.testing.expectEqualSlices(GlyphMarginLane, &.{.Center}, lanes);
}

test "glyph lanes: works with a single line range" {
    var model = try GlyphMarginLanesModel.init(std.testing.allocator, 10);
    defer model.deinit();
    model.push(.Left, Range.init(2, 1, 3, 1), false);

    try std.testing.expectEqual(@as(usize, 1), model.requiredLanes());
    const expected = [_][]const GlyphMarginLane{
        &.{.Center},
        &.{.Left},
        &.{.Left},
        &.{.Center},
        &.{.Center},
    };
    for (expected, 0..) |expected_lanes, i| {
        const lanes = try model.getLanesAtLine(std.testing.allocator, i + 1);
        defer std.testing.allocator.free(lanes);
        try std.testing.expectEqualSlices(GlyphMarginLane, expected_lanes, lanes);
    }
}

test "glyph lanes: persists ranges" {
    var model = try GlyphMarginLanesModel.init(std.testing.allocator, 10);
    defer model.deinit();
    model.push(.Left, Range.init(2, 1, 3, 1), true);

    try std.testing.expectEqual(@as(usize, 1), model.requiredLanes());
    for (1..6) |line| {
        const lanes = try model.getLanesAtLine(std.testing.allocator, line);
        defer std.testing.allocator.free(lanes);
        try std.testing.expectEqualSlices(GlyphMarginLane, &.{.Left}, lanes);
    }
}

test "glyph lanes: handles overlaps" {
    var model = try GlyphMarginLanesModel.init(std.testing.allocator, 10);
    defer model.deinit();
    model.push(.Left, Range.init(6, 1, 9, 1), false);
    model.push(.Right, Range.init(5, 1, 7, 1), false);
    model.push(.Center, Range.init(7, 1, 8, 1), false);

    try std.testing.expectEqual(@as(usize, 3), model.requiredLanes());
    const expected = [_][]const GlyphMarginLane{
        &.{.Right},
        &.{ .Left, .Right },
        &.{ .Left, .Center, .Right },
        &.{ .Left, .Center },
        &.{.Left},
        &.{.Center},
    };
    for (expected, 0..) |expected_lanes, i| {
        const lanes = try model.getLanesAtLine(std.testing.allocator, i + 5);
        defer std.testing.allocator.free(lanes);
        try std.testing.expectEqualSlices(GlyphMarginLane, expected_lanes, lanes);
    }
}

test "glyph lanes: positions below the last decorated line inherit only persistent lanes" {
    const a = std.testing.allocator;
    var model = try GlyphMarginLanesModel.init(a, 1);
    defer model.deinit();
    const empty = try model.getLanesAtLine(a, 1000);
    defer a.free(empty);
    try std.testing.expectEqualSlices(GlyphMarginLane, &.{.Center}, empty);
    model.push(.Left, Range.init(1, 1, 1, 1), true);
    const persistent = try model.getLanesAtLine(a, 1000);
    defer a.free(persistent);
    try std.testing.expectEqualSlices(GlyphMarginLane, &.{.Left}, persistent);
}
