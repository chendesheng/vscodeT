const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../core/range.zig").Range;

pub const IInplaceReplaceSupportResult = struct {
    range: Range,
    /// Owned by the caller.
    value: []const u8,
};

pub const BasicInplaceReplace = struct {
    const Self = @This();

    pub const INSTANCE = Self{};

    pub fn navigateValueSet(
        self: *const Self,
        allocator: Allocator,
        range1: Range,
        text1: []const u8,
        range2: ?Range,
        text2: ?[]const u8,
        up: bool,
    ) !?IInplaceReplaceSupportResult {
        _ = self;
        if (try doNavigateValueSet(allocator, text1, up)) |value| {
            return IInplaceReplaceSupportResult{ .range = range1, .value = value };
        }

        if (range2) |range| {
            if (text2) |text| {
                if (try doNavigateValueSet(allocator, text, up)) |value| {
                    return IInplaceReplaceSupportResult{ .range = range, .value = value };
                }
            }
        }

        return null;
    }

    fn doNavigateValueSet(allocator: Allocator, text: []const u8, up: bool) !?[]const u8 {
        if (try numberReplace(allocator, text, up)) |result| {
            return result;
        }
        return textReplace(allocator, text, up);
    }

    fn numberReplace(allocator: Allocator, value: []const u8, up: bool) !?[]const u8 {
        const digits_after_dot: usize = if (std.mem.lastIndexOfScalar(u8, value, '.')) |index| value.len - index - 1 else value.len;
        const precision = std.math.pow(f64, 10.0, @floatFromInt(digits_after_dot));

        const n1 = std.fmt.parseFloat(f64, value) catch return null;
        if (!std.math.isFinite(n1)) {
            return null;
        }
        if (n1 == 0 and !up) {
            return null; // don't do negative
        }

        var adjusted = @floor(n1 * precision);
        adjusted += if (up) precision else -precision;
        return try std.fmt.allocPrint(allocator, "{d}", .{adjusted / precision});
    }

    const default_value_set = [_][]const []const u8{
        &[_][]const u8{ "true", "false" },
        &[_][]const u8{ "True", "False" },
        &[_][]const u8{ "Private", "Public", "Friend", "ReadOnly", "Partial", "Protected", "WriteOnly" },
        &[_][]const u8{ "public", "protected", "private" },
    };

    fn textReplace(allocator: Allocator, value: []const u8, up: bool) !?[]const u8 {
        return valueSetsReplace(allocator, &default_value_set, value, up);
    }

    fn valueSetsReplace(
        allocator: Allocator,
        value_sets: []const []const []const u8,
        value: []const u8,
        up: bool,
    ) !?[]const u8 {
        for (value_sets) |value_set| {
            if (try valueSetReplace(allocator, value_set, value, up)) |result| {
                return result;
            }
        }
        return null;
    }

    fn valueSetReplace(
        allocator: Allocator,
        value_set: []const []const u8,
        value: []const u8,
        up: bool,
    ) !?[]const u8 {
        for (value_set, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, value)) {
                const len = value_set.len;
                var next_index: isize = @intCast(index);
                next_index += if (up) 1 else -1;
                if (next_index < 0) {
                    next_index = @intCast(len - 1);
                } else {
                    next_index = @mod(next_index, @as(isize, @intCast(len)));
                }
                return try allocator.dupe(u8, value_set[@intCast(next_index)]);
            }
        }
        return null;
    }
};

test "BasicInplaceReplace: numbers" {
    const allocator = std.testing.allocator;
    const replace = BasicInplaceReplace.INSTANCE;
    const range = Range.init(1, 1, 1, 2);

    {
        const result = (try replace.navigateValueSet(allocator, range, "1", null, null, true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("2", result.value);
    }
    {
        const result = (try replace.navigateValueSet(allocator, range, "1", null, null, false)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("0", result.value);
    }
    {
        const result = (try replace.navigateValueSet(allocator, range, "1.5", null, null, true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("2.5", result.value);
    }
    {
        const result = (try replace.navigateValueSet(allocator, range, "9", null, null, true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("10", result.value);
    }
    try std.testing.expect((try replace.navigateValueSet(allocator, range, "0", null, null, false)) == null);
}

test "BasicInplaceReplace: value sets" {
    const allocator = std.testing.allocator;
    const replace = BasicInplaceReplace.INSTANCE;
    const range1 = Range.init(1, 1, 1, 5);
    const range2 = Range.init(2, 1, 2, 5);

    {
        const result = (try replace.navigateValueSet(allocator, range1, "true", null, null, true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("false", result.value);
        try std.testing.expectEqualDeep(range1, result.range);
    }
    {
        const result = (try replace.navigateValueSet(allocator, range1, "private", null, null, true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("public", result.value);
    }
    {
        const result = (try replace.navigateValueSet(allocator, range1, "unknown", range2, "false", true)).?;
        defer allocator.free(result.value);
        try std.testing.expectEqualStrings("true", result.value);
        try std.testing.expectEqualDeep(range2, result.range);
    }
    try std.testing.expect((try replace.navigateValueSet(allocator, range1, "unknown", range2, "alsoUnknown", true)) == null);
}
