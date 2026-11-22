// Port of selected cases from
// `src/vs/editor/test/common/model/bracketPairColorizer/beforeEditPositionMapper.test.ts`.
//
// Upstream columns are UTF-16 code units; the port uses UTF-8 byte columns.
// The multi-line inputs therefore use ASCII stand-ins of the same width as
// the upstream subscript/superscript characters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const mapper_mod = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig");
const BeforeEditPositionMapper = mapper_mod.BeforeEditPositionMapper;
const TextEditInfo = mapper_mod.TextEditInfo;

const Edit = struct {
    start: tree.Length,
    end: tree.Length,
    text: []const u8,
};

fn splitLines(allocator: Allocator, text: []const u8) !ArrayList([]const u8) {
    var result = ArrayList([]const u8).init(allocator);
    errdefer result.deinit();
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try result.append(text[start..i]);
            start = i + 1;
        }
    }
    try result.append(text[start..]);
    return result;
}

fn lineStartOffsets(allocator: Allocator, text: []const u8) !ArrayList(usize) {
    var starts = ArrayList(usize).init(allocator);
    errdefer starts.deinit();
    try starts.append(0);
    for (text, 0..) |ch, i| {
        if (ch == '\n') try starts.append(i + 1);
    }
    return starts;
}

fn lengthToOffset(starts: []const usize, length: tree.Length) usize {
    return starts[tree.lengthLineCount(length)] + tree.lengthColumnCount(length);
}

fn applyEdits(allocator: Allocator, text: []const u8, edits: []const Edit) ![]u8 {
    var starts = try lineStartOffsets(allocator, text);
    defer starts.deinit();

    var offsets = ArrayList(struct { start: usize, end: usize, edit: *const Edit }).init(allocator);
    defer offsets.deinit();
    for (edits) |*edit| {
        try offsets.append(.{
            .start = lengthToOffset(starts.items, edit.start),
            .end = lengthToOffset(starts.items, edit.end),
            .edit = edit,
        });
    }
    std.mem.sort(@TypeOf(offsets.items[0]), offsets.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(offsets.items[0]), b: @TypeOf(offsets.items[0])) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var cursor: usize = 0;
    for (offsets.items) |entry| {
        try result.appendSlice(text[cursor..entry.start]);
        try result.appendSlice(entry.edit.text);
        cursor = entry.end;
    }
    try result.appendSlice(text[cursor..]);
    return result.toOwnedSlice();
}

fn rightPad(list: *ArrayList(u8), value: []const u8) !void {
    try list.appendSlice(value);
    var len = value.len;
    while (len < 3) : (len += 1) try list.append(' ');
}

fn compute(allocator: Allocator, input_lines: []const []const u8, edits: []const Edit) ![][]u8 {
    var input = ArrayList(u8).init(allocator);
    defer input.deinit();
    for (input_lines, 0..) |line, i| {
        if (i > 0) try input.append('\n');
        try input.appendSlice(line);
    }

    const new_text = try applyEdits(allocator, input.items, edits);
    defer allocator.free(new_text);
    var lines = try splitLines(allocator, new_text);
    defer lines.deinit();

    var infos = ArrayList(TextEditInfo).init(allocator);
    defer infos.deinit();
    for (edits) |edit| {
        try infos.append(TextEditInfo.init(edit.start, edit.end, tree.lengthOfString(edit.text)));
    }
    var mapper = try BeforeEditPositionMapper.init(allocator, infos.items);
    defer mapper.deinit();

    var result = ArrayList([]u8).init(allocator);
    errdefer {
        for (result.items) |line| allocator.free(line);
        result.deinit();
    }

    for (lines.items, 0..) |line, line_idx| {
        var line_str = ArrayList(u8).init(allocator);
        errdefer line_str.deinit();
        var line_line = ArrayList(u8).init(allocator);
        errdefer line_line.deinit();
        var col_line = ArrayList(u8).init(allocator);
        errdefer col_line.deinit();
        var line_dist = ArrayList(u8).init(allocator);
        errdefer line_dist.deinit();
        var col_dist = ArrayList(u8).init(allocator);
        errdefer col_dist.deinit();

        var col_idx: usize = 0;
        while (col_idx <= line.len) : (col_idx += 1) {
            const position = tree.toLength(line_idx, col_idx);
            const before = mapper.getOffsetBeforeChange(position);
            const before_obj = tree.lengthToObj(before);
            if (col_idx < line.len) {
                const ch = line[col_idx .. col_idx + 1];
                try rightPad(&line_str, ch);
            }
            var buffer: [32]u8 = undefined;
            try rightPad(&line_line, try std.fmt.bufPrint(&buffer, "{d}", .{before_obj.lineCount}));
            try rightPad(&col_line, try std.fmt.bufPrint(&buffer, "{d}", .{before_obj.columnCount}));

            if (mapper.getDistanceToNextChange(position)) |distance| {
                const dist = tree.lengthToObj(distance);
                try rightPad(&line_dist, try std.fmt.bufPrint(&buffer, "{d}", .{dist.lineCount}));
                try rightPad(&col_dist, try std.fmt.bufPrint(&buffer, "{d}", .{dist.columnCount}));
            } else {
                try line_dist.appendSlice("∞  ");
                try col_dist.appendSlice("∞  ");
            }
        }

        try result.append(try line_str.toOwnedSlice());
        try result.append(try line_line.toOwnedSlice());
        try result.append(try col_line.toOwnedSlice());
        try result.append(try line_dist.toOwnedSlice());
        try result.append(try col_dist.toOwnedSlice());
    }

    return result.toOwnedSlice();
}

fn expectComputed(allocator: Allocator, input: []const []const u8, edits: []const Edit, expected: []const []const u8) !void {
    const actual = try compute(allocator, input, edits);
    defer {
        for (actual) |line| allocator.free(line);
        allocator.free(actual);
    }
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "beforeEditPositionMapper: Single-Line 1" {
    try expectComputed(std.testing.allocator, &.{"0123456789"}, &.{
        .{ .start = tree.toLength(0, 4), .end = tree.toLength(0, 7), .text = "xy" },
    }, &.{
        "0  1  2  3  x  y  7  8  9  ",
        "0  0  0  0  0  0  0  0  0  0  ",
        "0  1  2  3  4  5  7  8  9  10 ",
        "0  0  0  0  0  0  ∞  ∞  ∞  ∞  ",
        "4  3  2  1  0  0  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Single-Line 2" {
    try expectComputed(std.testing.allocator, &.{"0123456789"}, &.{
        .{ .start = tree.toLength(0, 2), .end = tree.toLength(0, 4), .text = "xxxx" },
        .{ .start = tree.toLength(0, 6), .end = tree.toLength(0, 6), .text = "yy" },
    }, &.{
        "0  1  x  x  x  x  4  5  y  y  6  7  8  9  ",
        "0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  ",
        "0  1  2  3  4  5  4  5  6  7  6  7  8  9  10 ",
        "0  0  0  0  0  0  0  0  0  0  ∞  ∞  ∞  ∞  ∞  ",
        "2  1  0  0  0  0  2  1  0  0  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Replace 1" {
    try expectComputed(std.testing.allocator, &.{ "abcdefghij", "0123456789", "ABCDEFGHIJ" }, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(1, 3), .text = "xy" },
    }, &.{
        "a  b  c  x  y  3  4  5  6  7  8  9  ",
        "0  0  0  0  0  1  1  1  1  1  1  1  1  ",
        "0  1  2  3  4  3  4  5  6  7  8  9  10 ",
        "0  0  0  0  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "3  2  1  0  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "A  B  C  D  E  F  G  H  I  J  ",
        "2  2  2  2  2  2  2  2  2  2  2  ",
        "0  1  2  3  4  5  6  7  8  9  10 ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Replace 2" {
    try expectComputed(std.testing.allocator, &.{ "abcdefghij", "012345678", "ABCDEFGHIJ" }, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(1, 0), .text = "ab" },
        .{ .start = tree.toLength(1, 5), .end = tree.toLength(1, 7), .text = "c" },
    }, &.{
        "a  b  c  a  b  0  1  2  3  4  c  7  8  ",
        "0  0  0  0  0  1  1  1  1  1  1  1  1  1  ",
        "0  1  2  3  4  0  1  2  3  4  5  7  8  9  ",
        "0  0  0  0  0  0  0  0  0  0  0  ∞  ∞  ∞  ",
        "3  2  1  0  0  5  4  3  2  1  0  ∞  ∞  ∞  ",
        "A  B  C  D  E  F  G  H  I  J  ",
        "2  2  2  2  2  2  2  2  2  2  2  ",
        "0  1  2  3  4  5  6  7  8  9  10 ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Replace 3" {
    try expectComputed(std.testing.allocator, &.{ "abcdefghij", "012345678", "ABCDEFGHIJ" }, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(1, 0), .text = "ab" },
        .{ .start = tree.toLength(1, 5), .end = tree.toLength(1, 7), .text = "c" },
        .{ .start = tree.toLength(1, 8), .end = tree.toLength(2, 4), .text = "d" },
    }, &.{
        "a  b  c  a  b  0  1  2  3  4  c  7  d  E  F  G  H  I  J  ",
        "0  0  0  0  0  1  1  1  1  1  1  1  1  2  2  2  2  2  2  2  ",
        "0  1  2  3  4  0  1  2  3  4  5  7  8  4  5  6  7  8  9  10 ",
        "0  0  0  0  0  0  0  0  0  0  0  0  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "3  2  1  0  0  5  4  3  2  1  0  1  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Insert 1" {
    try expectComputed(std.testing.allocator, &.{"012345678"}, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(0, 5), .text = "a\nb" },
    }, &.{
        "0  1  2  a  ",
        "0  0  0  0  0  ",
        "0  1  2  3  4  ",
        "0  0  0  0  0  ",
        "3  2  1  0  0  ",
        "b  5  6  7  8  ",
        "1  0  0  0  0  0  ",
        "0  5  6  7  8  9  ",
        "0  ∞  ∞  ∞  ∞  ∞  ",
        "0  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Insert 2" {
    try expectComputed(std.testing.allocator, &.{"012345678"}, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(0, 5), .text = "a\nb" },
        .{ .start = tree.toLength(0, 7), .end = tree.toLength(0, 8), .text = "x\ny" },
    }, &.{
        "0  1  2  a  ",
        "0  0  0  0  0  ",
        "0  1  2  3  4  ",
        "0  0  0  0  0  ",
        "3  2  1  0  0  ",
        "b  5  6  x  ",
        "1  0  0  0  0  ",
        "0  5  6  7  8  ",
        "0  0  0  0  0  ",
        "0  2  1  0  0  ",
        "y  8  ",
        "1  0  0  ",
        "0  8  9  ",
        "0  ∞  ∞  ",
        "0  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Replace/Insert 1" {
    try expectComputed(std.testing.allocator, &.{ "abcdefghij", "012345678", "ABCDEFGHIJ" }, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(1, 1), .text = "aaa\nbbb" },
    }, &.{
        "a  b  c  a  a  a  ",
        "0  0  0  0  0  0  0  ",
        "0  1  2  3  4  5  6  ",
        "0  0  0  0  0  0  0  ",
        "3  2  1  0  0  0  0  ",
        "b  b  b  1  2  3  4  5  6  7  8  ",
        "1  1  1  1  1  1  1  1  1  1  1  1  ",
        "0  1  2  1  2  3  4  5  6  7  8  9  ",
        "0  0  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "0  0  0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "A  B  C  D  E  F  G  H  I  J  ",
        "2  2  2  2  2  2  2  2  2  2  2  ",
        "0  1  2  3  4  5  6  7  8  9  10 ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
    });
}

test "beforeEditPositionMapper: Multi-Line Replace/Insert 2" {
    try expectComputed(std.testing.allocator, &.{ "abcdefghij", "012345678", "ABCDEFGHIJ" }, &.{
        .{ .start = tree.toLength(0, 3), .end = tree.toLength(1, 1), .text = "aaa\nbbb" },
        .{ .start = tree.toLength(1, 5), .end = tree.toLength(1, 5), .text = "x\ny" },
        .{ .start = tree.toLength(1, 7), .end = tree.toLength(2, 4), .text = "k\nl" },
    }, &.{
        "a  b  c  a  a  a  ",
        "0  0  0  0  0  0  0  ",
        "0  1  2  3  4  5  6  ",
        "0  0  0  0  0  0  0  ",
        "3  2  1  0  0  0  0  ",
        "b  b  b  1  2  3  4  x  ",
        "1  1  1  1  1  1  1  1  1  ",
        "0  1  2  1  2  3  4  5  6  ",
        "0  0  0  0  0  0  0  0  0  ",
        "0  0  0  4  3  2  1  0  0  ",
        "y  5  6  k  ",
        "2  1  1  1  1  ",
        "0  5  6  7  8  ",
        "0  0  0  0  0  ",
        "0  2  1  0  0  ",
        "l  E  F  G  H  I  J  ",
        "2  2  2  2  2  2  2  2  ",
        "0  4  5  6  7  8  9  10 ",
        "0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
        "0  ∞  ∞  ∞  ∞  ∞  ∞  ∞  ",
    });
}
