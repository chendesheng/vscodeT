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
    return .{ .size = n.size_left + n.piece.?.length + actualRight.size, .lf_cnt = n.lf_left + n.piece.?.lineFeedCnt + actualRight.lf_cnt };
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

fn assertRawContent(expected: []const u8, pt: *PieceTreeBase) !void {
    var actual = try pt.getLinesRawContent();
    defer actual.deinit();
    try std.testing.expectEqualStrings(expected, actual.items);
}

test "more inserts" {
    const allocator = std.testing.allocator;
    var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pt = pieceTree.getPieceTree();
    try pt.insert(0, "AAA", false);
    try assertRawContent("AAA", pt);

    try pt.insert(0, "BBB", false);
    try assertRawContent("BBBAAA", pt);
    try pt.insert(6, "CCC", false);
    try assertRawContent("BBBAAACCC", pt);
    try pt.insert(5, "DDD", false);
    try assertRawContent("BBBAADDDACCC", pt);
    try assertTreeInvariants(pt);
}

test "more deletes" {
    const allocator = std.testing.allocator;
    var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"012345678"}, false);
    defer pieceTree.deinit();
    var pt = pieceTree.getPieceTree();

    try pt.delete(8, 1);
    try assertRawContent("01234567", pt);
    try pt.delete(0, 1);
    try assertRawContent("1234567", pt);
    try pt.delete(5, 1);
    try assertRawContent("123457", pt);
    try pt.delete(5, 1);
    try assertRawContent("12345", pt);
    try pt.delete(0, 5);
    try assertRawContent("", pt);
    try assertTreeInvariants(pt);
}

test "random test 1" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();

    try pieceTable.insert(0, "ceLPHmFzvCtFeHkCBej ", false);
    const str1 = str[0..0] ++ "ceLPHmFzvCtFeHkCBej " ++ str[0..];
    try assertRawContent(str1, pieceTable);
    try pieceTable.insert(8, "gDCEfNYiBUNkSwtvB K ", false);
    const str2 = str1[0..8] ++ "gDCEfNYiBUNkSwtvB K " ++ str1[8..];
    try assertRawContent(str2, pieceTable);
    try pieceTable.insert(38, "cyNcHxjNPPoehBJldLS ", false);
    const str3 = str2[0..38] ++ "cyNcHxjNPPoehBJldLS " ++ str2[38..];
    try assertRawContent(str3, pieceTable);
    try pieceTable.insert(59, "ejMx\nOTgWlbpeDExjOk ", false);
    const str4 = str3[0..59] ++ "ejMx\nOTgWlbpeDExjOk " ++ str3[59..];
    try assertRawContent(str4, pieceTable);

    try assertRawContent(str4, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random test 2" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(0, "VgPG ", false);
    const str1 = str[0..0] ++ "VgPG " ++ str[0..];
    try pieceTable.insert(2, "DdWF ", false);
    const str2 = str1[0..2] ++ "DdWF " ++ str1[2..];
    try pieceTable.insert(0, "hUJc ", false);
    const str3 = str2[0..0] ++ "hUJc " ++ str2[0..];
    try pieceTable.insert(8, "lQEq ", false);
    const str4 = str3[0..8] ++ "lQEq " ++ str3[8..];
    try pieceTable.insert(10, "Gbtp ", false);
    const str5 = str4[0..10] ++ "Gbtp " ++ str4[10..];
    try assertRawContent(str5, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random test 3" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(0, "gYSz", false);
    const str1 = str[0..0] ++ "gYSz" ++ str[0..];
    try pieceTable.insert(1, "mDQe", false);
    const str2 = str1[0..1] ++ "mDQe" ++ str1[1..];
    try pieceTable.insert(1, "DTMQ", false);
    const str3 = str2[0..1] ++ "DTMQ" ++ str2[1..];
    try pieceTable.insert(2, "GGZB", false);
    const str4 = str3[0..2] ++ "GGZB" ++ str3[2..];
    try pieceTable.insert(12, "wXpq", false);
    const str5 = str4[0..12] ++ "wXpq" ++ str4[12..];
    try assertRawContent(str5, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random delete 1" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();

    try pieceTable.insert(0, "vfb", false);
    const str1 = str[0..0] ++ "vfb" ++ str[0..];
    try assertRawContent(str1, pieceTable);
    try pieceTable.insert(0, "zRq", false);
    const str2 = str1[0..0] ++ "zRq" ++ str1[0..];
    try assertRawContent(str2, pieceTable);

    try pieceTable.delete(5, 1);
    const str3 = str2[0..5] ++ str2[6..];
    try assertRawContent(str3, pieceTable);

    try pieceTable.insert(1, "UNw", false);
    const str4 = str3[0..1] ++ "UNw" ++ str3[1..];
    try assertRawContent(str4, pieceTable);
    try pieceTable.delete(4, 3);
    const str5 = str4[0..4] ++ str4[7..];
    try assertRawContent(str5, pieceTable);
    try pieceTable.delete(1, 4);
    const str6 = str5[0..1] ++ str5[5..];
    try assertRawContent(str6, pieceTable);
    try pieceTable.delete(0, 1);
    const str7 = str6[0..0] ++ str6[1..];
    try assertRawContent(str7, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random delete 2" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();

    try pieceTable.insert(0, "IDT", false);
    const str1 = str[0..0] ++ "IDT" ++ str[0..];
    try pieceTable.insert(3, "wwA", false);
    const str2 = str1[0..3] ++ "wwA" ++ str1[3..];
    try pieceTable.insert(3, "Gnr", false);
    const str3 = str2[0..3] ++ "Gnr" ++ str2[3..];
    try pieceTable.insert(3, "Gnr", false);
    const str4 = str3[0..3] ++ "Gnr" ++ str3[3..];
    try pieceTable.delete(6, 3);
    const str5 = str4[0..6] ++ str4[6 + 3 ..];
    try pieceTable.insert(4, "eHp", false);
    const str6 = str5[0..4] ++ "eHp" ++ str5[4..];
    try pieceTable.insert(1, "UAi", false);
    const str7 = str6[0..1] ++ "UAi" ++ str6[1..];
    try pieceTable.insert(2, "FrR", false);
    const str8 = str7[0..2] ++ "FrR" ++ str7[2..];
    try pieceTable.delete(6, 7);
    const str9 = str8[0..6] ++ str8[6 + 7 ..];
    try pieceTable.delete(3, 5);
    const str10 = str9[0..3] ++ str9[3 + 5 ..];
    try assertRawContent(str10, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random delete 3" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(0, "PqM", false);
    const str1 = str[0..0] ++ "PqM" ++ str[0..];
    try pieceTable.delete(1, 2);
    const str2 = str1[0..1] ++ str1[1 + 2 ..];
    try pieceTable.insert(1, "zLc", false);
    const str3 = str2[0..1] ++ "zLc" ++ str2[1..];
    try pieceTable.insert(0, "MEX", false);
    const str4 = str3[0..0] ++ "MEX" ++ str3[0..];
    try pieceTable.insert(0, "jZh", false);
    const str5 = str4[0..0] ++ "jZh" ++ str4[0..];
    try pieceTable.insert(8, "GwQ", false);
    const str6 = str5[0..8] ++ "GwQ" ++ str5[8..];
    try pieceTable.delete(5, 6);
    const str7 = str6[0..5] ++ str6[5 + 6 ..];
    try pieceTable.insert(4, "ktw", false);
    const str8 = str7[0..4] ++ "ktw" ++ str7[4..];
    try pieceTable.insert(5, "GVu", false);
    const str9 = str8[0..5] ++ "GVu" ++ str8[5..];
    try pieceTable.insert(0, "jdm", false);
    const str10 = str9[0..0] ++ "jdm" ++ str9[0..];
    try pieceTable.insert(15, "na\n", false);
    const str11 = str10[0..15] ++ "na\n" ++ str10[15..];
    try pieceTable.delete(5, 8);
    const str12 = str11[0..5] ++ str11[5 + 8 ..];
    try pieceTable.delete(3, 4);
    const str13 = str12[0..3] ++ str12[3 + 4 ..];
    try assertRawContent(str13, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random insert/delete \\r bug 1" {
    const str = "a";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, false);
    defer pieceTree.deinit();

    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.delete(0, 1);
    const str1 = str[0..0] ++ str[0 + 1 ..];
    try pieceTable.insert(0, "\r\r\n\n", false);
    const str2 = str1[0..0] ++ "\r\r\n\n" ++ str1[0..];
    try pieceTable.delete(3, 1);
    const str3 = str2[0..3] ++ str2[3 + 1 ..];
    try pieceTable.insert(2, "\n\n\ra", false);
    const str4 = str3[0..2] ++ "\n\n\ra" ++ str3[2..];
    try pieceTable.delete(4, 3);
    const str5 = str4[0..4] ++ str4[4 + 3 ..];
    try pieceTable.insert(2, "\na\r\r", false);
    const str6 = str5[0..2] ++ "\na\r\r" ++ str5[2..];
    try pieceTable.insert(6, "\ra\n\n", false);
    const str7 = str6[0..6] ++ "\ra\n\n" ++ str6[6..];
    try pieceTable.insert(0, "aa\n\n", false);
    const str8 = str7[0..0] ++ "aa\n\n" ++ str7[0..];
    try pieceTable.insert(5, "\n\na\r", false);
    const str9 = str8[0..5] ++ "\n\na\r" ++ str8[5..];
    try assertRawContent(str9, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random insert/delete \\r bug 2" {
    const str = "a";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(1, "\naa\r", false);
    const str1 = str[0..1] ++ "\naa\r" ++ str[1..];
    try pieceTable.delete(0, 4);
    const str2 = str1[0..0] ++ str1[0 + 4 ..];
    try pieceTable.insert(1, "\r\r\na", false);
    const str3 = str2[0..1] ++ "\r\r\na" ++ str2[1..];
    try pieceTable.insert(2, "\n\r\ra", false);
    const str4 = str3[0..2] ++ "\n\r\ra" ++ str3[2..];
    try pieceTable.delete(4, 1);
    const str5 = str4[0..4] ++ str4[4 + 1 ..];
    try pieceTable.insert(8, "\r\n\r\r", false);
    const str6 = str5[0..8] ++ "\r\n\r\r" ++ str5[8..];
    try pieceTable.insert(7, "\n\n\na", false);
    const str7 = str6[0..7] ++ "\n\n\na" ++ str6[7..];
    try pieceTable.insert(13, "a\n\na", false);
    const str8 = str7[0..13] ++ "a\n\na" ++ str7[13..];
    try pieceTable.delete(17, 3);
    const str9 = str8[0..17] ++ str8[17 + 3 ..];
    try pieceTable.insert(2, "a\ra\n", false);
    const str10 = str9[0..2] ++ "a\ra\n" ++ str9[2..];
    try assertRawContent(str10, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random insert/delete \\r bug 3" {
    const str = "a";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(0, "\r\na\r", false);
    const str1 = str[0..0] ++ "\r\na\r" ++ str[0..];
    try pieceTable.delete(2, 3);
    const str2 = str1[0..2] ++ str1[2 + 3 ..];
    try pieceTable.insert(2, "a\r\n\r", false);
    const str3 = str2[0..2] ++ "a\r\n\r" ++ str2[2..];
    try pieceTable.delete(4, 2);
    const str4 = str3[0..4] ++ str3[4 + 2 ..];
    try pieceTable.insert(4, "a\n\r\n", false);
    const str5 = str4[0..4] ++ "a\n\r\n" ++ str4[4..];
    try pieceTable.insert(4, "a\n\r\n", false);
    const str6 = str5[0..4] ++ "a\n\r\n" ++ str5[4..];
    try pieceTable.insert(1, "aa\n\r", false);
    const str7 = str6[0..1] ++ "aa\n\r" ++ str6[1..];
    try pieceTable.insert(7, "\na\r\n", false);
    const str8 = str7[0..7] ++ "\na\r\n" ++ str7[7..];
    try pieceTable.insert(5, "\n\na\r", false);
    const str9 = str8[0..5] ++ "\n\na\r" ++ str8[5..];
    try pieceTable.insert(10, "\r\r\n\r", false);
    const str10 = str9[0..10] ++ "\r\r\n\r" ++ str9[10..];
    try assertRawContent(str10, pieceTable);
    try pieceTable.delete(21, 3);
    const str11 = str10[0..21] ++ str10[21 + 3 ..];
    try assertRawContent(str11, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random insert/delete \\r bug 4" {
    const str = "a";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.delete(0, 1);
    const str1 = str[0..0] ++ str[0 + 1 ..];
    try pieceTable.insert(0, "\naaa", false);
    const str2 = str1[0..0] ++ "\naaa" ++ str1[0..];
    try pieceTable.insert(2, "\n\naa", false);
    const str3 = str2[0..2] ++ "\n\naa" ++ str2[2..];
    try pieceTable.delete(1, 4);
    const str4 = str3[0..1] ++ str3[1 + 4 ..];
    try pieceTable.delete(3, 1);
    const str5 = str4[0..3] ++ str4[3 + 1 ..];
    try pieceTable.delete(1, 2);
    const str6 = str5[0..1] ++ str5[1 + 2 ..];
    try pieceTable.delete(0, 1);
    const str7 = str6[0..0] ++ str6[0 + 1 ..];
    try pieceTable.insert(0, "a\n\n\r", false);
    const str8 = str7[0..0] ++ "a\n\n\r" ++ str7[0..];
    try pieceTable.insert(2, "aa\r\n", false);
    const str9 = str8[0..2] ++ "aa\r\n" ++ str8[2..];
    try pieceTable.insert(3, "a\naa", false);
    const str10 = str9[0..3] ++ "a\naa" ++ str9[3..];
    try assertRawContent(str10, pieceTable);
    try assertTreeInvariants(pieceTable);
}

test "random insert/delete \\r bug 5" {
    const str = "";
    var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, false);
    defer pieceTree.deinit();
    var pieceTable = pieceTree.getPieceTree();
    try pieceTable.insert(0, "\n\n\n\r", false);
    const str1 = str[0..0] ++ "\n\n\n\r" ++ str[0..];
    try pieceTable.insert(1, "\n\n\n\r", false);
    const str2 = str1[0..1] ++ "\n\n\n\r" ++ str1[1..];
    try pieceTable.insert(2, "\n\r\r\r", false);
    const str3 = str2[0..2] ++ "\n\r\r\r" ++ str2[2..];
    try pieceTable.insert(8, "\n\r\n\r", false);
    const str4 = str3[0..8] ++ "\n\r\n\r" ++ str3[8..];
    try pieceTable.delete(5, 2);
    const str5 = str4[0..5] ++ str4[5 + 2 ..];
    try pieceTable.insert(4, "\n\r\r\r", false);
    const str6 = str5[0..4] ++ "\n\r\r\r" ++ str5[4..];
    try pieceTable.insert(8, "\n\n\n\r", false);
    const str7 = str6[0..8] ++ "\n\n\n\r" ++ str6[8..];
    try pieceTable.delete(0, 7);
    const str8 = str7[0..0] ++ str7[0 + 7 ..];
    try pieceTable.insert(1, "\r\n\r\r", false);
    const str9 = str8[0..1] ++ "\r\n\r\r" ++ str8[1..];
    try pieceTable.insert(15, "\n\r\r\r", false);
    const str10 = str9[0..15] ++ "\n\r\r\r" ++ str9[15..];
    try assertRawContent(str10, pieceTable);
    try assertTreeInvariants(pieceTable);
}
