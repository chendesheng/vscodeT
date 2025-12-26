const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const PieceTreeBase = @import("pieceTreeBase.zig").PieceTreeBase;
const PieceTreeBufferBuilder = @import("pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const re = @import("../basics/RegExp.zig");
const RegExp = re.RegExp;
const Position = @import("../basics/position.zig").Position;
const PieceTreeTextBuffer = @import("pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const SENTINEL = @import("rbTreeBase.zig").SENTINEL;
const TreeNode = @import("rbTreeBase.zig").TreeNode;

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n";
var rand = std.Random.Pcg.init(0).random();
fn randomChar() u8 {
    return alphabet[rand.int(usize) % alphabet.len];
}

fn randomInt(bound: u64) u64 {
    return rand.intRangeLessThan(u64, 0, bound);
}

fn randomStr(allocator: Allocator, len: usize) ArrayList(u8) {
    var res = ArrayList(u8).initCapacity(allocator, len);
    for (0..len) |_| {
        try res.append(randomChar());
    }
    return res;
}

fn trimLineFeed(text: []const u8) []const u8 {
    if (text.len == 0) {
        return text;
    }

    if (text.len == 1) {
        if (text[0] == 10 or text[0] == 13) {
            return text[0..0];
        }
        return text;
    }

    if (text[text.len - 1] == 10) {
        if (text[text.len - 2] == 13) {
            return text[0 .. text.len - 2];
        }
        return text[0 .. text.len - 1];
    }
    if (text[text.len - 1] == 13) {
        return text[0 .. text.len - 1];
    }
    return text;
}

fn testLinesContent(str: []const u8, pieceTable: *PieceTreeBase) !void {
    var lines = std.mem.splitAny(u8, str, "\r\n");
    var len = 0;
    while (lines.next()) |_| {
        len += 1;
    }

    std.testing.expectEqual(pieceTable.getLineCount(), len);
    std.testing.expectEqualStrings(pieceTable.getLinesRawContent(), str);

    var i = 1;
    while (lines.next()) |line| {
        std.testing.expectEqualStrings(pieceTable.getLineContent(i), line);

        var value = try pieceTable.getValueInRange(Range.init(i, 1, i, line.len + (if (i == len) 1 else 2)), null);
        defer value.deinit();

        std.testing.expectEqualStrings(trimLineFeed(value.items), line);

        i += 1;
    }
}

fn testLineStarts(allocator: Allocator, str: []u8, pieceTable: *PieceTreeBase) !void {
    try re.initialize(null);
    defer re.uninitialize();

    var lineStarts = ArrayList(usize).init(allocator);
    defer lineStarts.deinit();
    try lineStarts.append(0);

    const _regex = try RegExp.init("\r\n|\r|\n");

    var iter = _regex.searchIterator(str, 0);
    while (iter.next()) |m| {
        defer m.deinit();

        try lineStarts.append(m.index() + m.groupN(0).len);
    }

    for (lineStarts.items, 0..) |lineStart, i| {
        std.testing.expectEqualDeep(pieceTable.getPositionAt(lineStart), Position.init(i + 1, 1));
        std.testing.expectEqual(pieceTable.getOffsetAt(i + 1, 1), lineStart);
    }

    for (1..lineStarts.len) |i| {
        const pos = pieceTable.getPositionAt(lineStarts[i] - 1);
        std.testing.expectEqual(pieceTable.getOffsetAt(pos.lineNumber, pos.column), lineStarts[i] - 1);
    }
}

fn createTextBuffer(allocator: Allocator, val: []const []const u8, normalizeEOL: bool) !PieceTreeTextBuffer {
    var bufferBuilder = PieceTreeBufferBuilder.init(allocator);
    for (val) |chunk| {
        try bufferBuilder.acceptChunk(chunk);
    }
    const factory = try bufferBuilder.finish(normalizeEOL);
    defer factory.deinit();

    return try factory.create(.LF);
}

fn assertTreeInvariants(t: *PieceTreeBase) !void {
    try std.testing.expectEqual(.black, SENTINEL.color);
    try std.testing.expectEqual(SENTINEL, SENTINEL.parent);
    try std.testing.expectEqual(SENTINEL, SENTINEL.left);
    try std.testing.expectEqual(SENTINEL, SENTINEL.right);
    try std.testing.expectEqual(0, SENTINEL.size_left);
    try std.testing.expectEqual(0, SENTINEL.lf_left);
    try assertValidTree(t);
}

fn depth(n: *TreeNode) !usize {
    if (n == SENTINEL) {
        // The leafs are black
        return 1;
    }
    try std.testing.expectEqual(try depth(n.right), try depth(n.left));
    return (if (n.color == .black) @as(usize, 1) else @as(usize, 0)) + (try depth(n.left));
}

fn assertValidNode(n: *TreeNode) !struct { size: usize, lf_cnt: usize } {
    if (n == SENTINEL) {
        return .{ .size = 0, .lf_cnt = 0 };
    }

    const l = n.left;
    const r = n.right;

    if (n.color == .red) {
        try std.testing.expectEqual(.black, l.color);
        try std.testing.expectEqual(.black, r.color);
    }

    const actualLeft = try assertValidNode(l);
    try std.testing.expectEqual(n.lf_left, actualLeft.lf_cnt);
    try std.testing.expectEqual(n.size_left, actualLeft.size);

    const actualRight = try assertValidNode(r);
    return .{ .size = n.size_left + n.piece.?.length, .lf_cnt = n.lf_left + n.piece.?.lineFeedCnt + actualRight.lf_cnt };
}

fn assertValidTree(t: *PieceTreeBase) !void {
    if (t.root == SENTINEL) {
        return;
    }

    try std.testing.expectEqual(.black, t.root.color);
    try std.testing.expectEqual(try depth(t.root.right), try depth(t.root.left));
    _ = try assertValidNode(t.root);
}

test "basic insert/delete" {
    const allocator = std.testing.allocator;
    var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"This is a document with some text."}, false);
    defer pieceTree.deinit();

    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(34, "This is some more text to insert at offset 34.", false);
    var rawContent = try pieceTable.getLinesRawContent();
    defer rawContent.deinit();
    try std.testing.expectEqualStrings("This is a document with some text.This is some more text to insert at offset 34.", rawContent.items);
    try pieceTable.delete(42, 5);

    var rawContent2 = try pieceTable.getLinesRawContent();
    defer rawContent2.deinit();
    try std.testing.expectEqualStrings("This is a document with some text.This is more text to insert at offset 34.", rawContent2.items);
    _ = try assertTreeInvariants(pieceTable);
}

test "more inserts" {
    const allocator = std.testing.allocator;
    var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pt = pieceTree.getPieceTree();
    try pt.insert(0, "AAA", false);
    {
        var rawContent = try pt.getLinesRawContent();
        defer rawContent.deinit();
        try std.testing.expectEqualStrings("AAA", rawContent.items);
    }

    try pt.insert(0, "BBB", false);
    {
        var rawContent = try pt.getLinesRawContent();
        defer rawContent.deinit();
        try std.testing.expectEqualStrings("BBBAAA", rawContent.items);
    }
    try pt.insert(6, "CCC", false);
    {
        var rawContent = try pt.getLinesRawContent();
        defer rawContent.deinit();
        try std.testing.expectEqualStrings("BBBAAACCC", rawContent.items);
    }
    try pt.insert(5, "DDD", false);
    {
        var rawContent = try pt.getLinesRawContent();
        defer rawContent.deinit();
        try std.testing.expectEqualStrings("BBBAADDDACCC", rawContent.items);
    }
    try assertTreeInvariants(pt);
}
