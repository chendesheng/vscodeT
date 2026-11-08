const std = @import("std");
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const TextLength = @import("../text/textLength.zig").TextLength;

pub const PositionOrRange = union(enum) {
    position: Position,
    range: Range,
};

pub const SingleRangeMapping = struct {
    original: Range,
    modified: Range,

    pub fn reverse(self: SingleRangeMapping) SingleRangeMapping {
        return .{ .original = self.modified, .modified = self.original };
    }
};

pub const RangeMapping = struct {
    mappings: []const SingleRangeMapping,

    pub fn init(mappings: []const SingleRangeMapping) RangeMapping {
        return .{ .mappings = mappings };
    }

    pub fn mapPosition(self: RangeMapping, position: Position) PositionOrRange {
        var mapping: ?SingleRangeMapping = null;
        var i = self.mappings.len;
        while (i > 0) {
            i -= 1;
            if (self.mappings[i].original.getStartPosition().isBeforeOrEqual(position)) {
                mapping = self.mappings[i];
                break;
            }
        }
        const found = mapping orelse return .{ .position = position };
        if (found.original.containsPosition(&position)) {
            return .{ .range = found.modified };
        }
        const length = TextLength.betweenPositions(found.original.getEndPosition(), position);
        return .{ .position = length.addToPosition(found.modified.getEndPosition()) };
    }

    pub fn mapRange(self: RangeMapping, range: Range) Range {
        const start = self.mapPosition(range.getStartPosition());
        const end = self.mapPosition(range.getEndPosition());
        const start_position = switch (start) {
            .position => |p| p,
            .range => |r| r.getStartPosition(),
        };
        const end_position = switch (end) {
            .position => |p| p,
            .range => |r| r.getEndPosition(),
        };
        return Range.init(start_position.lineNumber, start_position.column, end_position.lineNumber, end_position.column);
    }

    pub fn reverse(self: RangeMapping, allocator: std.mem.Allocator) !RangeMapping {
        const result = try allocator.alloc(SingleRangeMapping, self.mappings.len);
        for (self.mappings, 0..) |mapping, i| result[i] = mapping.reverse();
        return .{ .mappings = result };
    }
};

test "rangeMapping: maps positions and ranges" {
    const mappings = [_]SingleRangeMapping{.{
        .original = Range.init(1, 2, 1, 4),
        .modified = Range.init(2, 5, 2, 7),
    }};
    const mapping = RangeMapping.init(&mappings);
    const inside = mapping.mapPosition(Position.init(1, 3));
    try std.testing.expectEqual(@as(usize, 2), inside.range.startLineNumber);
    const after = mapping.mapPosition(Position.init(1, 5));
    try std.testing.expectEqual(@as(usize, 2), after.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 8), after.position.column);
    const range = mapping.mapRange(Range.init(1, 3, 1, 5));
    try std.testing.expectEqual(@as(usize, 2), range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 8), range.endColumn);
}
