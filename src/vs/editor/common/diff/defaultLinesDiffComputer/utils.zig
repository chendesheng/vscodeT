const std = @import("std");
const Allocator = std.mem.Allocator;
const CharCode = @import("../../../../base/common/charCode.zig").CharCode;
const LineRange = @import("../../core/ranges/lineRange.zig").LineRange;
const DetailedLineRangeMapping = @import("../rangeMapping.zig").DetailedLineRangeMapping;

/// A two-dimensional array with a row-major layout.
pub fn Array2D(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        width: usize,
        height: usize,
        array: []T,

        pub fn init(allocator: Allocator, width: usize, height: usize, fill: T) !Self {
            const array = try allocator.alloc(T, width * height);
            @memset(array, fill);
            return .{
                .allocator = allocator,
                .width = width,
                .height = height,
                .array = array,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.array);
        }

        pub fn get(self: *const Self, x: usize, y: usize) T {
            return self.array[x + y * self.width];
        }

        pub fn set(self: *Self, x: usize, y: usize, value: T) void {
            self.array[x + y * self.width] = value;
        }
    };
}

pub fn isSpace(char_code: u32) bool {
    return char_code == CharCode.Space or char_code == CharCode.Tab;
}

test "Array2D" {
    const allocator = std.testing.allocator;
    var array = try Array2D(u8).init(allocator, 3, 2, 0);
    defer array.deinit();

    array.set(1, 0, 5);
    array.set(2, 1, 7);
    try std.testing.expectEqual(@as(u8, 5), array.get(1, 0));
    try std.testing.expectEqual(@as(u8, 7), array.get(2, 1));
    try std.testing.expectEqual(@as(u8, 0), array.get(0, 1));
}

test "isSpace" {
    try std.testing.expect(isSpace(' '));
    try std.testing.expect(isSpace('\t'));
    try std.testing.expect(!isSpace('a'));
}

/// A fragment of lines used to compare the similarity of two line ranges.
pub const LineRangeFragment = struct {
    const Self = @This();

    range: LineRange,
    lines: []const []const u8,
    source: DetailedLineRangeMapping,
    total_count: usize,
    histogram: [256]usize,

    pub fn init(sequence_range: LineRange, lines: []const []const u8, source: DetailedLineRangeMapping) Self {
        var histogram: [256]usize = @splat(0);
        var counter: usize = 0;

        var i = sequence_range.startLineNumber - 1;
        while (i < sequence_range.endLineNumberExclusive - 1) : (i += 1) {
            const line = lines[i];
            for (line) |byte| {
                counter += 1;
                histogram[byte] += 1;
            }
            counter += 1;
            histogram['\n'] += 1;
        }

        return .{
            .range = sequence_range,
            .lines = lines,
            .source = source,
            .total_count = counter,
            .histogram = histogram,
        };
    }

    pub fn computeSimilarity(self: *const Self, other: *const Self) f64 {
        var sum_differences: usize = 0;
        for (self.histogram, other.histogram) |a, b| {
            sum_differences += if (a > b) a - b else b - a;
        }
        const denominator = self.total_count + other.total_count;
        if (denominator == 0) {
            return 1;
        }
        return 1 - (@as(f64, @floatFromInt(sum_differences)) / @as(f64, @floatFromInt(denominator)));
    }
};

test "LineRangeFragment: similarity" {
    const allocator = std.testing.allocator;

    var text = @import("../../core/text/abstractText.zig").AbstractText.initString(allocator, "abc\ndef");
    defer text.deinit();

    const source = DetailedLineRangeMapping.init(LineRange.init(1, 3), LineRange.init(1, 3), null);
    const lines = [_][]const u8{ "abc", "def" };
    const fragment1 = LineRangeFragment.init(LineRange.init(1, 3), &lines, source);
    const fragment2 = LineRangeFragment.init(LineRange.init(1, 3), &lines, source);
    const fragment3 = LineRangeFragment.init(LineRange.init(1, 2), &lines, source);

    try std.testing.expectEqual(@as(f64, 1), fragment1.computeSimilarity(&fragment2));
    try std.testing.expect(fragment1.computeSimilarity(&fragment3) < 1);
}
