//! Port of
//! `vscode/extensions/markdown-language-features/src/test/sourceLineMap.test.ts`.

const std = @import("std");
const sourceLineMap = @import("../../browser/sourceLineMap.zig");
const SourceLineMap = sourceLineMap.SourceLineMap;

const LineElement = struct {
    line_value: ?[]const u8,
    descendants: []const LineElement = &.{},
    updates: usize = 0,

    pub fn getAttribute(self: *const LineElement, name: []const u8) ?[]const u8 {
        std.debug.assert(std.mem.eql(u8, name, "data-line"));
        return self.line_value;
    }

    pub fn setAttribute(self: *LineElement, name: []const u8, value: []const u8) void {
        std.debug.assert(std.mem.eql(u8, name, "data-line"));
        self.line_value = value;
        self.updates += 1;
    }

    pub fn querySelectorAll(self: *LineElement, selector: []const u8) []LineElement {
        std.debug.assert(std.mem.eql(u8, selector, "[data-line]"));
        return @constCast(self.descendants);
    }
};

fn elementIndex(elements: []const TestElement, wanted: *const TestElement) usize {
    for (elements, 0..) |*entry, index| {
        if (entry == wanted) return index;
    }
    unreachable;
}

const TestElement = struct {
    line: f64,
    name: []const u8 = "",
};

fn mapLines(allocator: std.mem.Allocator, lines: []const f64, targets: []const f64) ![]const [2]?usize {
    const elements = try allocator.alloc(TestElement, lines.len + 1);
    defer allocator.free(elements);
    elements[0] = .{ .line = -1, .name = "body" };
    for (lines, 0..) |line, index| elements[index + 1] = .{ .line = line };

    var map = SourceLineMap(TestElement).init(elements);
    const result = try allocator.alloc([2]?usize, targets.len);
    for (targets, 0..) |target, index| {
        const found = map.getElementsForSourceLine(target);
        result[index] = .{
            elementIndex(elements, found.previous),
            if (found.next) |next| elementIndex(elements, next) else null,
        };
    }
    return result;
}

test "sourceLineMap: preserves boundaries, fractional lines and the first exact duplicate" {
    const allocator = std.testing.allocator;
    const actual = try mapLines(allocator, &.{ 2, 2, 4, 6 }, &.{ -4, -1, 0, 1, 2, 2.8, 3, 4, 5, 6, 7 });
    defer allocator.free(actual);
    const expected = [_][2]?usize{
        .{ 0, 0 },    .{ 0, null }, .{ 0, 1 },    .{ 0, 1 }, .{ 1, null },
        .{ 1, null }, .{ 2, 3 },    .{ 3, null }, .{ 3, 4 }, .{ 4, null },
        .{ 4, null },
    };
    try std.testing.expectEqualSlices([2]?usize, &expected, actual);
}

test "sourceLineMap: preserves document order for nested and out-of-order mappings" {
    const allocator = std.testing.allocator;
    const actual = try mapLines(allocator, &.{ 0, 0, 4, 2, 8, 8, 3, 12 }, &.{ 0, 2, 4, 5, 8, 9, 12, 20 });
    defer allocator.free(actual);
    const expected = [_][2]?usize{
        .{ 1, null }, .{ 2, 3 }, .{ 3, null }, .{ 4, 5 },
        .{ 5, null }, .{ 7, 8 }, .{ 8, null }, .{ 8, null },
    };
    try std.testing.expectEqualSlices([2]?usize, &expected, actual);
}

test "sourceLineMap: restarts for backward and unordered queries" {
    const allocator = std.testing.allocator;
    const actual = try mapLines(allocator, &.{ 0, 2, 2, 8 }, &.{ 20, 2, 8, 0, 3, 2, 2, 1 });
    defer allocator.free(actual);
    const expected = [_][2]?usize{
        .{ 4, null }, .{ 2, null }, .{ 4, null }, .{ 1, null },
        .{ 3, 4 },    .{ 2, null }, .{ 2, null }, .{ 1, 2 },
    };
    try std.testing.expectEqualSlices([2]?usize, &expected, actual);
}

test "sourceLineMap: maps an empty document to its body sentinel" {
    const allocator = std.testing.allocator;
    const actual = try mapLines(allocator, &.{}, &.{ 0, 100, -1, -2, 0 });
    defer allocator.free(actual);
    const expected = [_][2]?usize{
        .{ 0, null }, .{ 0, null }, .{ 0, null }, .{ 0, 0 }, .{ 0, null },
    };
    try std.testing.expectEqualSlices([2]?usize, &expected, actual);
}

test "sourceLineMap: NaN and infinities do not poison later lookups" {
    const allocator = std.testing.allocator;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const actual = try mapLines(allocator, &.{ 0, 2, 4 }, &.{ nan, 0, inf, 2, -inf, 4 });
    defer allocator.free(actual);
    const expected = [_][2]?usize{
        .{ 3, null }, .{ 1, null }, .{ 3, null }, .{ 2, null }, .{ 0, 0 }, .{ 3, null },
    };
    try std.testing.expectEqualSlices([2]?usize, &expected, actual);
}

test "sourceLineMap: agrees with the legacy scan for arbitrary mappings" {
    const allocator = std.testing.allocator;
    var seed: usize = 0;
    while (seed < 32) : (seed += 1) {
        const elements = try allocator.alloc(TestElement, 9);
        defer allocator.free(elements);
        elements[0] = .{ .line = -1 };
        for (0..8) |index| {
            const digit = (seed >> @intCast(index)) % 5;
            elements[index + 1] = .{ .line = @floatFromInt(digit) };
        }
        var map = SourceLineMap(TestElement).init(elements);
        const targets = [_]f64{ -2, -1, 0, 0, 0.8, 1, 2, 3, 4, 5, 3, 0, 5, 1, 4, 2 };
        for (targets) |target| {
            const found = map.getElementsForSourceLine(target);
            const line = @floor(target);
            var previous: *const TestElement = &elements[0];
            var expected_next: ?*const TestElement = null;
            for (elements) |*entry| {
                if (entry.line == line) {
                    previous = entry;
                    expected_next = null;
                    break;
                } else if (entry.line > line) {
                    expected_next = entry;
                    break;
                }
                previous = entry;
            }
            try std.testing.expectEqual(previous, found.previous);
            try std.testing.expectEqual(expected_next, found.next);
        }
    }
}

test "sourceLineMap: synchronizes moved blocks and their descendants" {
    const child = LineElement{ .line_value = "1" };
    var alpha = LineElement{ .line_value = "0", .descendants = &.{child} };
    const incoming_child = LineElement{ .line_value = "3" };
    var incoming = LineElement{ .line_value = "2", .descendants = &.{incoming_child} };
    sourceLineMap.updateSourceLineAttributes(&alpha, &incoming);
    var beta = LineElement{ .line_value = "2" };
    var incoming_beta = LineElement{ .line_value = "4" };
    sourceLineMap.updateSourceLineAttributes(&beta, &incoming_beta);

    const elements = [_]TestElement{
        .{ .line = -1, .name = "body" },
        .{ .line = 2, .name = "Alpha" },
        .{ .line = 4, .name = "Beta" },
    };
    var map = SourceLineMap(TestElement).init(&elements);
    try std.testing.expectEqualStrings("Alpha", map.getElementsForSourceLine(2).previous.name);
    try std.testing.expectEqualStrings("3", alpha.descendants[0].line_value.?);
    try std.testing.expectEqualStrings("4", beta.line_value.?);
}

test "sourceLineMap: does not rewrite unchanged attributes" {
    const child = LineElement{ .line_value = "2" };
    var root = LineElement{ .line_value = null, .descendants = &.{child} };
    const incoming_child = LineElement{ .line_value = "2" };
    var incoming = LineElement{ .line_value = null, .descendants = &.{incoming_child} };
    sourceLineMap.updateSourceLineAttributes(&root, &incoming);
    try std.testing.expect(root.line_value == null);
    try std.testing.expectEqualStrings("2", root.descendants[0].line_value.?);
    try std.testing.expectEqual(@as(usize, 0), root.updates);
    try std.testing.expectEqual(@as(usize, 0), root.descendants[0].updates);
}

test "sourceLineMap: updateSourceLineAttributes rewrites only changed nodes" {
    const child = LineElement{ .line_value = "1" };
    var alpha = LineElement{ .line_value = "0", .descendants = &.{child} };
    const incoming_child = LineElement{ .line_value = "3" };
    var incoming = LineElement{ .line_value = "2", .descendants = &.{incoming_child} };
    sourceLineMap.updateSourceLineAttributes(&alpha, &incoming);
    try std.testing.expectEqualStrings("2", alpha.line_value.?);
    try std.testing.expectEqualStrings("3", alpha.descendants[0].line_value.?);
    try std.testing.expectEqual(@as(usize, 1), alpha.updates);
    try std.testing.expectEqual(@as(usize, 1), alpha.descendants[0].updates);
}
