const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const PieceTreeBase = @import("../pieceTreeTextBuffer/pieceTreeBase.zig").PieceTreeBase;
const PieceTreeBufferBuilder = @import("../pieceTreeTextBuffer/pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const re = @import("../basics/RegExp.zig");
const RegExp = re.RegExp;
const Position = @import("../basics/position.zig").Position;
const PieceTreeTextBuffer = @import("../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const SENTINEL = @import("../pieceTreeTextBuffer/rbTreeBase.zig").SENTINEL;
const TreeNode = @import("../pieceTreeTextBuffer/rbTreeBase.zig").TreeNode;
const countLines = @import("../basics/strings.zig").countLines;
const splitLines = @import("../basics/strings.zig").splitLines;
const SearchData = @import("../textModel/model.zig").SearchData;
const WordCharacterClassifier = @import("../basics/wordCharacterClassifier.zig").WordCharacterClassifier;

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n";
var pcg = std.Random.Pcg.init(0);
var rand = pcg.random();
fn randomChar() u8 {
    return alphabet[rand.int(usize) % alphabet.len];
}

fn randomInt(bound: usize) usize {
    return @intFromFloat(@floor(rand.float(f64) * @as(f64, @floatFromInt(bound))));
}

fn randomStr(allocator: Allocator, len: usize) ![]u8 {
    var res = try allocator.alloc(u8, len);
    for (0..len) |i| {
        res[i] = randomChar();
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

fn testLinesContent(allocator: Allocator, str: []const u8, pieceTable: *PieceTreeBase) !void {
    const lines = try splitLines(allocator, str);
    defer lines.deinit();

    try std.testing.expectEqual(lines.items.len, pieceTable.getLineCount());
    try assertRawContent(str, pieceTable);

    for (lines.items, 1..) |line, i| {
        try assertLineContent(line, pieceTable, i);
        var value = try pieceTable.getValueInRange(.init(i, 1, i, (line.len + (if (i == lines.items.len) @as(usize, 1) else @as(usize, 2)))), null);
        defer value.deinit();

        try std.testing.expectEqualStrings(line, trimLineFeed(value.items));
    }
}

fn getLineStarts(allocator: Allocator, str: []const u8) !ArrayList(usize) {
    var lineStarts = ArrayList(usize).init(allocator);
    var i: usize = 0;
    try lineStarts.append(0);
    while (i < str.len) {
        if (str[i] == '\r') {
            i += 1;
            if (i < str.len and str[i] == '\n') {
                i += 1;
            }
            try lineStarts.append(i);
        } else if (str[i] == '\n') {
            i += 1;
            try lineStarts.append(i);
        } else {
            i += 1;
        }
    }
    return lineStarts;
}

fn testLineStarts(allocator: Allocator, str: []const u8, pieceTable: *PieceTreeBase) !void {
    var lineStarts = try getLineStarts(allocator, str);
    defer lineStarts.deinit();

    for (lineStarts.items, 0..) |lineStart, i| {
        try std.testing.expectEqualDeep(pieceTable.getPositionAt(lineStart), Position.init(i + 1, 1));
        try std.testing.expectEqual(lineStart, pieceTable.getOffsetAt(i + 1, 1));
    }

    for (1..lineStarts.items.len) |i| {
        const pos = pieceTable.getPositionAt(lineStarts.items[i] - 1);
        try std.testing.expectEqual(lineStarts.items[i] - 1, pieceTable.getOffsetAt(pos.lineNumber, pos.column));
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

fn assertRawContent(expected: []const u8, pt: *PieceTreeBase) !void {
    var actual = try pt.getLinesRawContent();
    defer actual.deinit();
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn assertValueInRange(expected: []const u8, pt: *PieceTreeBase, range: Range) !void {
    var value = try pt.getValueInRange(range, null);
    defer value.deinit();
    try std.testing.expectEqualStrings(expected, value.items);
}

fn assertLineContent(expected: []const u8, pt: *PieceTreeBase, lineNumber: usize) !void {
    var content = try pt.getLineContent(lineNumber);
    defer content.deinit();
    try std.testing.expectEqualStrings(expected, content.items);
}

fn assertLineRowContent(expected: []const u8, pt: *PieceTreeBase, lineNumber: usize) !void {
    var content = try pt.getLineRawContent(lineNumber, 0);
    defer content.deinit();
    try std.testing.expectEqualStrings(expected, content.items);
}

const InsertAndDeleteTests = struct {
    test "basic insert/delete" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"This is a document with some text."}, true);
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
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"012345678"}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a"}, true);
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
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{""}, true);
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
};

const PrefixSumForLineFeedTests = struct {
    test "basic" {
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"1\n2\n3\n4"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try std.testing.expectEqual(4, pieceTable.getLineCount());
        try std.testing.expectEqualDeep(Position.init(1, 1), pieceTable.getPositionAt(0));
        try std.testing.expectEqualDeep(Position.init(1, 2), pieceTable.getPositionAt(1));
        try std.testing.expectEqualDeep(Position.init(2, 1), pieceTable.getPositionAt(2));
        try std.testing.expectEqualDeep(Position.init(2, 2), pieceTable.getPositionAt(3));
        try std.testing.expectEqualDeep(Position.init(3, 1), pieceTable.getPositionAt(4));
        try std.testing.expectEqualDeep(Position.init(3, 2), pieceTable.getPositionAt(5));
        try std.testing.expectEqualDeep(Position.init(4, 1), pieceTable.getPositionAt(6));

        try std.testing.expectEqual(0, pieceTable.getOffsetAt(1, 1));
        try std.testing.expectEqual(1, pieceTable.getOffsetAt(1, 2));
        try std.testing.expectEqual(2, pieceTable.getOffsetAt(2, 1));
        try std.testing.expectEqual(3, pieceTable.getOffsetAt(2, 2));
        try std.testing.expectEqual(4, pieceTable.getOffsetAt(3, 1));
        try std.testing.expectEqual(5, pieceTable.getOffsetAt(3, 2));
        try std.testing.expectEqual(6, pieceTable.getOffsetAt(4, 1));
        try assertTreeInvariants(pieceTable);
    }
    test "append" {
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a\nb\nc\nde"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(8, "fh\ni\njk", false);

        try std.testing.expectEqual(6, pieceTable.getLineCount());
        try std.testing.expectEqualDeep(Position.init(4, 4), pieceTable.getPositionAt(9));
        try std.testing.expectEqual(0, pieceTable.getOffsetAt(1, 1));
        try assertTreeInvariants(pieceTable);
    }

    test "insert" {
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a\nb\nc\nde"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(7, "fh\ni\njk", false);

        try std.testing.expectEqual(6, pieceTable.getLineCount());
        try std.testing.expectEqualDeep(Position.init(4, 1), pieceTable.getPositionAt(6));
        try std.testing.expectEqualDeep(Position.init(4, 2), pieceTable.getPositionAt(7));
        try std.testing.expectEqualDeep(Position.init(4, 3), pieceTable.getPositionAt(8));
        try std.testing.expectEqualDeep(Position.init(4, 4), pieceTable.getPositionAt(9));
        try std.testing.expectEqualDeep(Position.init(6, 1), pieceTable.getPositionAt(12));
        try std.testing.expectEqualDeep(Position.init(6, 2), pieceTable.getPositionAt(13));
        try std.testing.expectEqualDeep(Position.init(6, 3), pieceTable.getPositionAt(14));

        try std.testing.expectEqual(6, pieceTable.getOffsetAt(4, 1));
        try std.testing.expectEqual(7, pieceTable.getOffsetAt(4, 2));
        try std.testing.expectEqual(8, pieceTable.getOffsetAt(4, 3));
        try std.testing.expectEqual(9, pieceTable.getOffsetAt(4, 4));
        try std.testing.expectEqual(12, pieceTable.getOffsetAt(6, 1));
        try std.testing.expectEqual(13, pieceTable.getOffsetAt(6, 2));
        try std.testing.expectEqual(14, pieceTable.getOffsetAt(6, 3));
        try assertTreeInvariants(pieceTable);
    }

    test "delete" {
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a\nb\nc\ndefh\ni\njk"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(7, 2);

        try assertRawContent("a\nb\nc\ndh\ni\njk", pieceTable);
        try std.testing.expectEqual(6, pieceTable.getLineCount());
        try std.testing.expectEqualDeep(Position.init(4, 1), pieceTable.getPositionAt(6));
        try std.testing.expectEqualDeep(Position.init(4, 2), pieceTable.getPositionAt(7));
        try std.testing.expectEqualDeep(Position.init(4, 3), pieceTable.getPositionAt(8));
        try std.testing.expectEqualDeep(Position.init(5, 1), pieceTable.getPositionAt(9));
        try std.testing.expectEqualDeep(Position.init(6, 1), pieceTable.getPositionAt(11));
        try std.testing.expectEqualDeep(Position.init(6, 2), pieceTable.getPositionAt(12));
        try std.testing.expectEqualDeep(Position.init(6, 3), pieceTable.getPositionAt(13));

        try std.testing.expectEqual(6, pieceTable.getOffsetAt(4, 1));
        try std.testing.expectEqual(7, pieceTable.getOffsetAt(4, 2));
        try std.testing.expectEqual(8, pieceTable.getOffsetAt(4, 3));
        try std.testing.expectEqual(9, pieceTable.getOffsetAt(5, 1));
        try std.testing.expectEqual(11, pieceTable.getOffsetAt(6, 1));
        try std.testing.expectEqual(12, pieceTable.getOffsetAt(6, 2));
        try std.testing.expectEqual(13, pieceTable.getOffsetAt(6, 3));
        try assertTreeInvariants(pieceTable);
    }

    test "add+delete 1" {
        var pieceTree = try createTextBuffer(std.testing.allocator, &[_][]const u8{"a\nb\nc\nde"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(8, "fh\ni\njk", false);
        try pieceTable.delete(7, 2);

        try assertRawContent("a\nb\nc\ndh\ni\njk", pieceTable);
        try std.testing.expectEqual(6, pieceTable.getLineCount());
        try std.testing.expectEqualDeep(Position.init(4, 1), pieceTable.getPositionAt(6));
        try std.testing.expectEqualDeep(Position.init(4, 2), pieceTable.getPositionAt(7));
        try std.testing.expectEqualDeep(Position.init(4, 3), pieceTable.getPositionAt(8));
        try std.testing.expectEqualDeep(Position.init(5, 1), pieceTable.getPositionAt(9));
        try std.testing.expectEqualDeep(Position.init(6, 1), pieceTable.getPositionAt(11));
        try std.testing.expectEqualDeep(Position.init(6, 2), pieceTable.getPositionAt(12));
        try std.testing.expectEqualDeep(Position.init(6, 3), pieceTable.getPositionAt(13));

        try std.testing.expectEqual(6, pieceTable.getOffsetAt(4, 1));
        try std.testing.expectEqual(7, pieceTable.getOffsetAt(4, 2));
        try std.testing.expectEqual(8, pieceTable.getOffsetAt(4, 3));
        try std.testing.expectEqual(9, pieceTable.getOffsetAt(5, 1));
        try std.testing.expectEqual(11, pieceTable.getOffsetAt(6, 1));
        try std.testing.expectEqual(12, pieceTable.getOffsetAt(6, 2));
        try std.testing.expectEqual(13, pieceTable.getOffsetAt(6, 3));
        try assertTreeInvariants(pieceTable);
    }

    test "insert random bug 1: prefixSumComputer.removeValues(start, cnt) cnt is 1 based." {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, " ZX \n Z\nZ\n YZ\nY\nZXX ", false);
        const str1 = str[0..0] ++ " ZX \n Z\nZ\n YZ\nY\nZXX " ++ str[0..];
        try pieceTable.insert(14, "X ZZ\nYZZYZXXY Y XY\n ", false);
        const str2 = str1[0..14] ++ "X ZZ\nYZZYZXXY Y XY\n " ++ str1[14..];

        try assertRawContent(str2, pieceTable);
        try testLineStarts(allocator, str2, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "insert random bug 2: prefixSumComputer initialize does not do deep copy of UInt32Array." {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "ZYZ\nYY XY\nX \nZ Y \nZ ", false);
        const str1 = str[0..0] ++ "ZYZ\nYY XY\nX \nZ Y \nZ " ++ str[0..];
        try pieceTable.insert(3, "XXY \n\nY Y YYY  ZYXY ", false);
        const str2 = str1[0..3] ++ "XXY \n\nY Y YYY  ZYXY " ++ str1[3..];

        try assertRawContent(str2, pieceTable);
        try testLineStarts(allocator, str2, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "delete random bug 1: I forgot to update the lineFeedCnt when deletion is on one single piece." {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "ba\na\nca\nba\ncbab\ncaa ", false);
        try pieceTable.insert(13, "cca\naabb\ncac\nccc\nab ", false);
        try pieceTable.delete(5, 8);
        try pieceTable.delete(30, 2);
        try pieceTable.insert(24, "cbbacccbac\nbaaab\n\nc ", false);
        try pieceTable.delete(29, 3);
        try pieceTable.delete(23, 9);
        try pieceTable.delete(21, 5);
        try pieceTable.delete(30, 3);
        try pieceTable.insert(3, "cb\nac\nc\n\nacc\nbb\nb\nc ", false);
        try pieceTable.delete(19, 5);
        try pieceTable.insert(18, "\nbb\n\nacbc\ncbb\nc\nbb\n ", false);
        try pieceTable.insert(65, "cbccbac\nbc\n\nccabba\n ", false);
        try pieceTable.insert(77, "a\ncacb\n\nac\n\n\n\n\nabab ", false);
        try pieceTable.delete(30, 9);
        try pieceTable.insert(45, "b\n\nc\nba\n\nbbbba\n\naa\n ", false);
        try pieceTable.insert(82, "ab\nbb\ncabacab\ncbc\na ", false);
        try pieceTable.delete(123, 9);
        try pieceTable.delete(71, 2);
        try pieceTable.insert(33, "acaa\nacb\n\naa\n\nc\n\n\n\n ", false);

        var str = try pieceTable.getLinesRawContent();
        defer str.deinit();
        try testLineStarts(allocator, str.items, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "delete random bug rb tree 1" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "YXXZ\n\nYY\n", false);
        const str1 = str[0..0] ++ "YXXZ\n\nYY\n" ++ str[0..];
        try pieceTable.delete(0, 5);
        const str2 = str1[0..0] ++ str1[0 + 5 ..];
        try pieceTable.insert(0, "ZXYY\nX\nZ\n", false);
        const str3 = str2[0..0] ++ "ZXYY\nX\nZ\n" ++ str2[0..];
        try pieceTable.insert(10, "\nXY\nYXYXY", false);
        const str4 = str3[0..10] ++ "\nXY\nYXYXY" ++ str3[10..];
        try testLineStarts(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "delete random bug rb tree 2" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "YXXZ\n\nYY\n", false);
        const str1 = str[0..0] ++ "YXXZ\n\nYY\n" ++ str[0..];
        try pieceTable.insert(0, "ZXYY\nX\nZ\n", false);
        const str2 = str1[0..0] ++ "ZXYY\nX\nZ\n" ++ str1[0..];
        try pieceTable.insert(10, "\nXY\nYXYXY", false);
        const str4 = str2[0..10] ++ "\nXY\nYXYXY" ++ str2[10..];
        try pieceTable.insert(8, "YZXY\nZ\nYX", false);
        const str5 = str4[0..8] ++ "YZXY\nZ\nYX" ++ str4[8..];
        try pieceTable.insert(12, "XX\nXXYXYZ", false);
        const str6 = str5[0..12] ++ "XX\nXXYXYZ" ++ str5[12..];
        try pieceTable.delete(0, 4);
        const str7 = str6[0..0] ++ str6[0 + 4 ..];
        try testLineStarts(allocator, str7, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "delete random bug rb tree 3" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "YXXZ\n\nYY\n", false);
        const str1 = str[0..0] ++ "YXXZ\n\nYY\n" ++ str[0..];
        try pieceTable.delete(7, 2);
        const str2 = str1[0..7] ++ str1[7 + 2 ..];
        try pieceTable.delete(6, 1);
        const str3 = str2[0..6] ++ str2[6 + 1 ..];
        try pieceTable.delete(0, 5);
        const str4 = str3[0..0] ++ str3[0 + 5 ..];
        try pieceTable.insert(0, "ZXYY\nX\nZ\n", false);
        const str5 = str4[0..0] ++ "ZXYY\nX\nZ\n" ++ str4[0..];
        try pieceTable.insert(10, "\nXY\nYXYXY", false);
        const str6 = str5[0..10] ++ "\nXY\nYXYXY" ++ str5[10..];
        try pieceTable.insert(8, "YZXY\nZ\nYX", false);
        const str7 = str6[0..8] ++ "YZXY\nZ\nYX" ++ str6[8..];
        try pieceTable.insert(12, "XX\nXXYXYZ", false);
        const str8 = str7[0..12] ++ "XX\nXXYXYZ" ++ str7[12..];
        try pieceTable.delete(0, 4);
        const str9 = str8[0..0] ++ str8[0 + 4 ..];
        try pieceTable.delete(30, 3);
        const str10 = str9[0..30] ++ str9[30 + 3 ..];
        try testLineStarts(allocator, str10, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const Offset2PositionTests = struct {
    test "random tests bug 1" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "huuyYzUfKOENwGgZLqn ", false);
        const str1 = str[0..0] ++ "huuyYzUfKOENwGgZLqn " ++ str[0..];
        try pieceTable.delete(18, 2);
        const str2 = str1[0..18] ++ str1[18 + 2 ..];
        try pieceTable.delete(3, 1);
        const str3 = str2[0..3] ++ str2[3 + 1 ..];
        try pieceTable.delete(12, 4);
        const str4 = str3[0..12] ++ str3[12 + 4 ..];
        try pieceTable.insert(3, "hMbnVEdTSdhLlPevXKF ", false);
        const str5 = str4[0..3] ++ "hMbnVEdTSdhLlPevXKF " ++ str4[3..];
        try pieceTable.delete(22, 8);
        const str6 = str5[0..22] ++ str5[22 + 8 ..];
        try pieceTable.insert(4, "S umSnYrqOmOAV\nEbZJ ", false);
        const str7 = str6[0..4] ++ "S umSnYrqOmOAV\nEbZJ " ++ str6[4..];
        try testLineStarts(allocator, str7, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const GetTextInRangeTests = struct {
    test "getContentInRange" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"a\nb\nc\nde"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(8, "fh\ni\njk", false);
        try pieceTable.delete(7, 2);
        // 'a\nb\nc\ndh\ni\njk'

        try assertValueInRange("a\n", pieceTable, Range.init(1, 1, 1, 3));
        try assertValueInRange("b\n", pieceTable, Range.init(2, 1, 2, 3));
        try assertValueInRange("c\n", pieceTable, Range.init(3, 1, 3, 3));
        try assertValueInRange("dh\n", pieceTable, Range.init(4, 1, 4, 4));
        try assertValueInRange("i\n", pieceTable, Range.init(5, 1, 5, 3));
        try assertValueInRange("jk", pieceTable, Range.init(6, 1, 6, 3));
        try assertTreeInvariants(pieceTable);
    }

    test "random test value in range" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "ZXXY", false);
        const str1 = str[0..0] ++ "ZXXY" ++ str[0..];
        try pieceTable.insert(1, "XZZY", false);
        const str2 = str1[0..1] ++ "XZZY" ++ str1[1..];
        try pieceTable.insert(5, "\nX\n\n", false);
        const str3 = str2[0..5] ++ "\nX\n\n" ++ str2[5..];
        try pieceTable.insert(3, "\nXX\n", false);
        const str4 = str3[0..3] ++ "\nXX\n" ++ str3[3..];
        try pieceTable.insert(12, "YYYX", false);
        const str5 = str4[0..12] ++ "YYYX" ++ str4[12..];

        try testLinesContent(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random test value in range exception" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "XZ\nZ", false);
        const str1 = str[0..0] ++ "XZ\nZ" ++ str[0..];
        try pieceTable.delete(0, 3);
        const str2 = str1[0..0] ++ str1[0 + 3 ..];
        try pieceTable.delete(0, 1);
        const str3 = str2[0..0] ++ str2[0 + 1 ..];
        try pieceTable.insert(0, "ZYX\n", false);
        const str4 = str3[0..0] ++ "ZYX\n" ++ str3[0..];
        try pieceTable.delete(0, 4);
        const str5 = str4[0..0] ++ str4[0 + 4 ..];
        _ = str5;

        _ = try pieceTable.getValueInRange(Range.init(1, 1, 1, 1), null);
        try assertTreeInvariants(pieceTable);
    }

    test "random tests bug 1" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "huuyYzUfKOENwGgZLqn ", false);
        const str1 = str[0..0] ++ "huuyYzUfKOENwGgZLqn " ++ str[0..];
        try pieceTable.delete(18, 2);
        const str2 = str1[0..18] ++ str1[18 + 2 ..];
        try pieceTable.delete(3, 1);
        const str3 = str2[0..3] ++ str2[3 + 1 ..];
        try pieceTable.delete(12, 4);
        const str4 = str3[0..12] ++ str3[12 + 4 ..];
        try pieceTable.insert(3, "hMbnVEdTSdhLlPevXKF ", false);
        const str5 = str4[0..3] ++ "hMbnVEdTSdhLlPevXKF " ++ str4[3..];
        try pieceTable.delete(22, 8);
        const str6 = str5[0..22] ++ str5[22 + 8 ..];
        try pieceTable.insert(4, "S umSnYrqOmOAV\nEbZJ ", false);
        const str7 = str6[0..4] ++ "S umSnYrqOmOAV\nEbZJ " ++ str6[4..];
        try testLinesContent(allocator, str7, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random tests bug 2" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "xfouRDZwdAHjVXJAMV\n ", false);
        const str1 = str[0..0] ++ "xfouRDZwdAHjVXJAMV\n " ++ str[0..];
        try pieceTable.insert(16, "dBGndxpFZBEAIKykYYx ", false);
        const str2 = str1[0..16] ++ "dBGndxpFZBEAIKykYYx " ++ str1[16..];
        try pieceTable.delete(7, 6);
        const str3 = str2[0..7] ++ str2[7 + 6 ..];
        try pieceTable.delete(9, 7);
        const str4 = str3[0..9] ++ str3[9 + 7 ..];
        try pieceTable.delete(17, 6);
        const str5 = str4[0..17] ++ str4[17 + 6 ..];
        try pieceTable.delete(0, 4);
        const str6 = str5[0..0] ++ str5[0 + 4 ..];
        try pieceTable.insert(9, "qvEFXCNvVkWgvykahYt ", false);
        const str7 = str6[0..9] ++ "qvEFXCNvVkWgvykahYt " ++ str6[9..];
        try pieceTable.delete(4, 6);
        const str8 = str7[0..4] ++ str7[4 + 6 ..];
        try pieceTable.insert(11, "OcSChUYT\nzPEBOpsGmR ", false);
        const str9 = str8[0..11] ++ "OcSChUYT\nzPEBOpsGmR " ++ str8[11..];
        try pieceTable.insert(15, "KJCozaXTvkE\nxnqAeTz ", false);
        const str10 = str9[0..15] ++ "KJCozaXTvkE\nxnqAeTz " ++ str9[15..];

        try testLinesContent(allocator, str10, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "get line content" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"1"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try assertLineRowContent("1", pieceTable, 1);
        try pieceTable.insert(1, "2", false);
        try assertLineRowContent("12", pieceTable, 1);
        try assertTreeInvariants(pieceTable);
    }

    test "get line content basic" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"1\n2\n3\n4"}, true);
        defer pieceTree.deinit();
        const pieceTable = pieceTree.getPieceTree();

        try assertLineRowContent("1\n", pieceTable, 1);
        try assertLineRowContent("2\n", pieceTable, 2);
        try assertLineRowContent("3\n", pieceTable, 3);
        try assertLineRowContent("4", pieceTable, 4);
        try assertTreeInvariants(pieceTable);
    }

    test "get line content after inserts/deletes" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"a\nb\nc\nde"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(8, "fh\ni\njk", false);
        try pieceTable.delete(7, 2);
        // 'a\nb\nc\ndh\ni\njk'

        try assertLineRowContent("a\n", pieceTable, 1);
        try assertLineRowContent("b\n", pieceTable, 2);
        try assertLineRowContent("c\n", pieceTable, 3);
        try assertLineRowContent("dh\n", pieceTable, 4);
        try assertLineRowContent("i\n", pieceTable, 5);
        try assertLineRowContent("jk", pieceTable, 6);
        try assertTreeInvariants(pieceTable);
    }

    test "random 1" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "J eNnDzQpnlWyjmUu\ny ", false);
        const str1 = str[0..0] ++ "J eNnDzQpnlWyjmUu\ny " ++ str[0..];
        try pieceTable.insert(0, "QPEeRAQmRwlJqtZSWhQ ", false);
        const str2 = str1[0..0] ++ "QPEeRAQmRwlJqtZSWhQ " ++ str1[0..];
        try pieceTable.delete(5, 1);
        const str3 = str2[0..5] ++ str2[5 + 1 ..];
        try testLinesContent(allocator, str3, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random 2" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "DZoQ tglPCRHMltejRI ", false);
        const str1 = str[0..0] ++ "DZoQ tglPCRHMltejRI " ++ str[0..];
        try pieceTable.insert(10, "JRXiyYqJ qqdcmbfkKX ", false);
        const str2 = str1[0..10] ++ "JRXiyYqJ qqdcmbfkKX " ++ str1[10..];
        try pieceTable.delete(16, 3);
        const str3 = str2[0..16] ++ str2[16 + 3 ..];
        try pieceTable.delete(25, 1);
        const str4 = str3[0..25] ++ str3[25 + 1 ..];
        try pieceTable.insert(18, "vH\nNlvfqQJPm\nSFkhMc ", false);
        const str5 = str4[0..18] ++ "vH\nNlvfqQJPm\nSFkhMc " ++ str4[18..];
        try testLinesContent(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const CRLFTests = struct {
    test "delete CR in CRLF 1" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "a\r\nb", false);
        try pieceTable.delete(0, 2);

        try std.testing.expectEqual(2, pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "delete CR in CRLF 2" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "a\r\nb", false);
        try pieceTable.delete(2, 2);

        try std.testing.expectEqual(2, pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 1" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.insert(0, "\n\n\r\r", false);
        const str1 = str[0..0] ++ "\n\n\r\r" ++ str[0..];
        try pieceTable.insert(1, "\r\n\r\n", false);
        const str2 = str1[0..1] ++ "\r\n\r\n" ++ str1[1..];
        try pieceTable.delete(5, 3);
        const str3 = str2[0..5] ++ str2[5 + 3 ..];
        try pieceTable.delete(2, 3);
        const str4 = str3[0..2] ++ str3[2 + 3 ..];
        try testLinesContent(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 2" {
        try re.initialize(null);
        defer re.uninitialize();

        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\r\n\r", false);
        const str1 = str[0..0] ++ "\n\r\n\r" ++ str[0..];
        try pieceTable.insert(2, "\n\r\r\r", false);
        const str2 = str1[0..2] ++ "\n\r\r\r" ++ str1[2..];
        try pieceTable.delete(4, 1);
        const str3 = str2[0..4] ++ str2[4 + 1 ..];

        try std.testing.expectEqual(countLines(str3), pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 3" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\n\n\r", false);
        const str1 = str[0..0] ++ "\n\n\n\r" ++ str[0..];
        try pieceTable.delete(2, 2);
        const str2 = str1[0..2] ++ str1[2 + 2 ..];
        try pieceTable.delete(0, 2);
        const str3 = str2[0..0] ++ str2[0 + 2 ..];
        try pieceTable.insert(0, "\r\r\r\r", false);
        const str4 = str3[0..0] ++ "\r\r\r\r" ++ str3[0..];
        try pieceTable.insert(2, "\r\n\r\r", false);
        const str5 = str4[0..2] ++ "\r\n\r\r" ++ str4[2..];
        try pieceTable.insert(3, "\r\r\r\n", false);
        const str6 = str5[0..3] ++ "\r\r\r\n" ++ str5[3..];
        try std.testing.expectEqual(countLines(str6), pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 4" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\n\n\n", false);
        const str1 = str[0..0] ++ "\n\n\n\n" ++ str[0..];
        try pieceTable.delete(3, 1);
        const str2 = str1[0..3] ++ str1[3 + 1 ..];
        try pieceTable.insert(1, "\r\r\r\r", false);
        const str3 = str2[0..1] ++ "\r\r\r\r" ++ str2[1..];
        try pieceTable.insert(6, "\r\n\n\r", false);
        const str4 = str3[0..6] ++ "\r\n\n\r" ++ str3[6..];
        try pieceTable.delete(5, 3);
        const str5 = str4[0..5] ++ str4[5 + 3 ..];

        try testLinesContent(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 5" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\n\n\n", false);
        const str1 = str[0..0] ++ "\n\n\n\n" ++ str[0..];
        try pieceTable.delete(3, 1);
        const str2 = str1[0..3] ++ str1[3 + 1 ..];
        try pieceTable.insert(0, "\n\r\r\n", false);
        const str3 = str2[0..0] ++ "\n\r\r\n" ++ str2[0..];
        try pieceTable.insert(4, "\n\r\r\n", false);
        const str4 = str3[0..4] ++ "\n\r\r\n" ++ str3[4..];
        try pieceTable.delete(4, 3);
        const str5 = str4[0..4] ++ str4[4 + 3 ..];
        try pieceTable.insert(5, "\r\r\n\r", false);
        const str6 = str5[0..5] ++ "\r\r\n\r" ++ str5[5..];
        try pieceTable.insert(12, "\n\n\n\r", false);
        const str7 = str6[0..12] ++ "\n\n\n\r" ++ str6[12..];
        try pieceTable.insert(5, "\r\r\r\n", false);
        const str8 = str7[0..5] ++ "\r\r\r\n" ++ str7[5..];
        try pieceTable.insert(20, "\n\n\r\n", false);
        const str9 = str8[0..20] ++ "\n\n\r\n" ++ str8[20..];
        try testLinesContent(allocator, str9, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 6" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\r\r\n", false);
        const str1 = str[0..0] ++ "\n\r\r\n" ++ str[0..];
        try pieceTable.insert(4, "\r\n\n\r", false);
        const str2 = str1[0..4] ++ "\r\n\n\r" ++ str1[4..];
        try pieceTable.insert(3, "\r\n\n\n", false);
        const str3 = str2[0..3] ++ "\r\n\n\n" ++ str2[3..];
        try pieceTable.delete(4, 8);
        const str4 = str3[0..4] ++ str3[4 + 8 ..];
        try pieceTable.insert(4, "\r\n\n\r", false);
        const str5 = str4[0..4] ++ "\r\n\n\r" ++ str4[4..];
        try pieceTable.insert(0, "\r\n\n\r", false);
        const str6 = str5[0..0] ++ "\r\n\n\r" ++ str5[0..];
        try pieceTable.delete(4, 0);
        const str7 = str6[0..4] ++ str6[4 + 0 ..];
        try pieceTable.delete(8, 4);
        const str8 = str7[0..8] ++ str7[8 + 4 ..];
        try testLinesContent(allocator, str8, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
    test "random bug 8" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\r\n\n\r", false);
        const str1 = str[0..0] ++ "\r\n\n\r" ++ str[0..];
        try pieceTable.delete(1, 0);
        const str2 = str1[0..1] ++ str1[1 + 0 ..];
        try pieceTable.insert(3, "\n\n\n\r", false);
        const str3 = str2[0..3] ++ "\n\n\n\r" ++ str2[3..];
        try pieceTable.insert(7, "\n\n\r\n", false);
        const str4 = str3[0..7] ++ "\n\n\r\n" ++ str3[7..];
        try testLinesContent(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 7" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\r\r\n\n", false);
        const str1 = str[0..0] ++ "\r\r\n\n" ++ str[0..];
        try pieceTable.insert(4, "\r\n\n\r", false);
        const str2 = str1[0..4] ++ "\r\n\n\r" ++ str1[4..];
        try pieceTable.insert(7, "\n\r\r\r", false);
        const str3 = str2[0..7] ++ "\n\r\r\r" ++ str2[7..];
        try pieceTable.insert(11, "\n\n\r\n", false);
        const str4 = str3[0..11] ++ "\n\n\r\n" ++ str3[11..];
        try testLinesContent(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 10" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "qneW", false);
        const str2 = str[0..0] ++ "qneW" ++ str[0..];
        try pieceTable.insert(0, "YhIl", false);
        const str3 = str2[0..0] ++ "YhIl" ++ str2[0..];
        try pieceTable.insert(0, "qdsm", false);
        const str4 = str3[0..0] ++ "qdsm" ++ str3[0..];
        try pieceTable.delete(7, 0);
        const str5 = str4[0..7] ++ str4[7 + 0 ..];
        try pieceTable.insert(12, "iiPv", false);
        const str6 = str5[0..12] ++ "iiPv" ++ str5[12..];
        try pieceTable.insert(9, "V\rSA", false);
        const str7 = str6[0..9] ++ "V\rSA" ++ str6[9..];
        try testLinesContent(allocator, str7, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 9" {
        const allocator = std.testing.allocator;
        const str = "";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "\n\n\n\n", false);
        const str1 = str[0..0] ++ "\n\n\n\n" ++ str[0..];
        try pieceTable.insert(3, "\n\r\n\r", false);
        const str2 = str1[0..3] ++ "\n\r\n\r" ++ str1[3..];
        try pieceTable.insert(2, "\n\r\n\n", false);
        const str3 = str2[0..2] ++ "\n\r\n\n" ++ str2[2..];
        try pieceTable.insert(0, "\n\n\r\r", false);
        const str4 = str3[0..0] ++ "\n\n\r\r" ++ str3[0..];
        try pieceTable.insert(3, "\r\r\r\r", false);
        const str5 = str4[0..3] ++ "\r\r\r\r" ++ str4[3..];
        try pieceTable.insert(3, "\n\n\r\r", false);
        const str6 = str5[0..3] ++ "\n\n\r\r" ++ str5[3..];
        try testLinesContent(allocator, str6, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const CentralizedLineStartsWithCRLFTests = struct {
    test "delete CR in CRLF 1" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"a\r\nb"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.delete(2, 2);
        try std.testing.expectEqual(2, pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }
    test "delete CR in CRLF 2" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"a\r\nb"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.delete(0, 2);
        try std.testing.expectEqual(2, pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 1" {
        const allocator = std.testing.allocator;
        const str = "\n\n\r\r";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"\n\n\r\r"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(1, "\r\n\r\n", false);
        const str1 = str[0..1] ++ "\r\n\r\n" ++ str[1..];
        try pieceTable.delete(5, 3);
        const str2 = str1[0..5] ++ str1[5 + 3 ..];
        try pieceTable.delete(2, 3);
        const str3 = str2[0..2] ++ str2[2 + 3 ..];
        try testLinesContent(allocator, str3, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 2" {
        const allocator = std.testing.allocator;
        const str = "\n\r\n\r";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(2, "\n\r\r\r", false);
        const str1 = str[0..2] ++ "\n\r\r\r" ++ str[2..];
        try pieceTable.delete(4, 1);
        const str2 = str1[0..4] ++ str1[4 + 1 ..];

        try std.testing.expectEqual(countLines(str2), pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 3" {
        const allocator = std.testing.allocator;
        const str = "\n\n\n\r";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(2, 2);
        const str1 = str[0..2] ++ str[2 + 2 ..];
        try pieceTable.delete(0, 2);
        const str2 = str1[0..0] ++ str1[0 + 2 ..];
        try pieceTable.insert(0, "\r\r\r\r", false);
        const str3 = str2[0..0] ++ "\r\r\r\r" ++ str2[0..];
        try pieceTable.insert(2, "\r\n\r\r", false);
        const str4 = str3[0..2] ++ "\r\n\r\r" ++ str3[2..];
        try pieceTable.insert(3, "\r\r\r\n", false);
        const str5 = str4[0..3] ++ "\r\r\r\n" ++ str4[3..];
        try std.testing.expectEqual(countLines(str5), pieceTable.getLineCount());
        try assertTreeInvariants(pieceTable);
    }
    test "random bug 4" {
        const allocator = std.testing.allocator;
        const str = "\n\n\n\n";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(3, 1);
        const str1 = str[0..3] ++ str[3 + 1 ..];
        try pieceTable.insert(1, "\r\r\r\r", false);
        const str2 = str1[0..1] ++ "\r\r\r\r" ++ str1[1..];
        try pieceTable.insert(6, "\r\n\n\r", false);
        const str3 = str2[0..6] ++ "\r\n\n\r" ++ str2[6..];
        try pieceTable.delete(5, 3);
        const str4 = str3[0..5] ++ str3[5 + 3 ..];

        try testLinesContent(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 5" {
        const allocator = std.testing.allocator;
        const str = "\n\n\n\n";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.delete(3, 1);
        const str1 = str[0..3] ++ str[3 + 1 ..];
        try pieceTable.insert(0, "\n\r\r\n", false);
        const str2 = str1[0..0] ++ "\n\r\r\n" ++ str1[0..];
        try pieceTable.insert(4, "\n\r\r\n", false);
        const str3 = str2[0..4] ++ "\n\r\r\n" ++ str2[4..];
        try pieceTable.delete(4, 3);
        const str4 = str3[0..4] ++ str3[4 + 3 ..];
        try pieceTable.insert(5, "\r\r\n\r", false);
        const str5 = str4[0..5] ++ "\r\r\n\r" ++ str4[5..];
        try pieceTable.insert(12, "\n\n\n\r", false);
        const str6 = str5[0..12] ++ "\n\n\n\r" ++ str5[12..];
        try pieceTable.insert(5, "\r\r\r\n", false);
        const str7 = str6[0..5] ++ "\r\r\r\n" ++ str6[5..];
        try pieceTable.insert(20, "\n\n\r\n", false);
        const str8 = str7[0..20] ++ "\n\n\r\n" ++ str7[20..];
        try testLinesContent(allocator, str8, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 6" {
        const allocator = std.testing.allocator;
        const str = "\n\r\r\n";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(4, "\r\n\n\r", false);
        const str1 = str[0..4] ++ "\r\n\n\r" ++ str[4..];
        try pieceTable.insert(3, "\r\n\n\n", false);
        const str2 = str1[0..3] ++ "\r\n\n\n" ++ str1[3..];
        try pieceTable.delete(4, 8);
        const str3 = str2[0..4] ++ str2[4 + 8 ..];
        try pieceTable.insert(4, "\r\n\n\r", false);
        const str4 = str3[0..4] ++ "\r\n\n\r" ++ str3[4..];
        try pieceTable.insert(0, "\r\n\n\r", false);
        const str5 = str4[0..0] ++ "\r\n\n\r" ++ str4[0..];
        try pieceTable.delete(4, 0);
        const str6 = str5[0..4] ++ str5[4 + 0 ..];
        try pieceTable.delete(8, 4);
        const str7 = str6[0..8] ++ str6[8 + 4 ..];
        try testLinesContent(allocator, str7, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 7" {
        const allocator = std.testing.allocator;
        const str = "\r\n\n\r";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(1, 0);
        const str1 = str[0..1] ++ str[1 + 0 ..];
        try pieceTable.insert(3, "\n\n\n\r", false);
        const str2 = str1[0..3] ++ "\n\n\n\r" ++ str1[3..];
        try pieceTable.insert(7, "\n\n\r\n", false);
        const str3 = str2[0..7] ++ "\n\n\r\n" ++ str2[7..];

        try testLinesContent(allocator, str3, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 8" {
        const allocator = std.testing.allocator;
        const str = "\r\r\n\n";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(4, "\r\n\n\r", false);
        const str1 = str[0..4] ++ "\r\n\n\r" ++ str[4..];
        try pieceTable.insert(7, "\n\r\r\r", false);
        const str2 = str1[0..7] ++ "\n\r\r\r" ++ str1[7..];
        try pieceTable.insert(11, "\n\n\r\n", false);
        const str3 = str2[0..11] ++ "\n\n\r\n" ++ str2[11..];
        try testLinesContent(allocator, str3, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 9" {
        const allocator = std.testing.allocator;
        const str = "qneW";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(0, "YhIl", false);
        const str1 = str[0..0] ++ "YhIl" ++ str[0..];
        try pieceTable.insert(0, "qdsm", false);
        const str2 = str1[0..0] ++ "qdsm" ++ str1[0..];
        try pieceTable.delete(7, 0);
        const str3 = str2[0..7] ++ str2[7 + 0 ..];
        try pieceTable.insert(12, "iiPv", false);
        const str4 = str3[0..12] ++ "iiPv" ++ str3[12..];
        try pieceTable.insert(9, "V\rSA", false);
        const str5 = str4[0..9] ++ "V\rSA" ++ str4[9..];
        try testLinesContent(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random bug 10" {
        const allocator = std.testing.allocator;
        const str = "\n\n\n\n";
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.insert(3, "\n\r\n\r", false);
        const str1 = str[0..3] ++ "\n\r\n\r" ++ str[3..];
        try pieceTable.insert(2, "\n\r\n\n", false);
        const str2 = str1[0..2] ++ "\n\r\n\n" ++ str1[2..];
        try pieceTable.insert(0, "\n\n\r\r", false);
        const str3 = str2[0..0] ++ "\n\n\r\r" ++ str2[0..];
        try pieceTable.insert(3, "\r\r\r\r", false);
        const str4 = str3[0..3] ++ "\r\r\r\r" ++ str3[3..];
        try pieceTable.insert(3, "\n\n\r\r", false);
        const str5 = str4[0..3] ++ "\n\n\r\r" ++ str4[3..];
        try testLinesContent(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random chunk bug 1" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"\n\r\r\n\n\n\r\n\r"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        const str = "\n\r\r\n\n\n\r\n\r";
        try pieceTable.delete(0, 2);
        const str1 = str[0..0] ++ str[0 + 2 ..];
        try pieceTable.insert(1, "\r\r\n\n", false);
        const str2 = str1[0..1] ++ "\r\r\n\n" ++ str1[1..];
        try pieceTable.insert(7, "\r\r\r\r", false);
        const str3 = str2[0..7] ++ "\r\r\r\r" ++ str2[7..];

        try assertRawContent(str3, pieceTable);
        try testLineStarts(allocator, str3, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
    test "random chunk bug 2" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"\n\r\n\n\n\r\n\r\n\r\r\n\n\n\r\r\n\r\n"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "\n\r\n\n\n\r\n\r\n\r\r\n\n\n\r\r\n\r\n";
        try pieceTable.insert(16, "\r\n\r\r", false);
        const str1 = str[0..16] ++ "\r\n\r\r" ++ str[16..];
        try pieceTable.insert(13, "\n\n\r\r", false);
        const str2 = str1[0..13] ++ "\n\n\r\r" ++ str1[13..];
        try pieceTable.insert(19, "\n\n\r\n", false);
        const str3 = str2[0..19] ++ "\n\n\r\n" ++ str2[19..];
        try pieceTable.delete(5, 0);
        const str4 = str3[0..5] ++ str3[5 + 0 ..];
        try pieceTable.delete(11, 2);
        const str5 = str4[0..11] ++ str4[11 + 2 ..];

        try assertRawContent(str5, pieceTable);
        try testLineStarts(allocator, str5, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random chunk bug 3" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"\r\n\n\n\n\n\n\r\n"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "\r\n\n\n\n\n\n\r\n";
        try pieceTable.insert(4, "\n\n\r\n\r\r\n\n\r", false);
        const str1 = str[0..4] ++ "\n\n\r\n\r\r\n\n\r" ++ str[4..];
        try pieceTable.delete(4, 4);
        const str2 = str1[0..4] ++ str1[4 + 4 ..];
        try pieceTable.insert(11, "\r\n\r\n\n\r\r\n\n", false);
        const str3 = str2[0..11] ++ "\r\n\r\n\n\r\r\n\n" ++ str2[11..];
        try pieceTable.delete(1, 2);
        const str4 = str3[0..1] ++ str3[1 + 2 ..];

        try assertRawContent(str4, pieceTable);
        try testLineStarts(allocator, str4, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random chunk bug 4" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"\n\r\n\r"}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "\n\r\n\r";
        try pieceTable.insert(4, "\n\n\r\n", false);
        const str1 = str[0..4] ++ "\n\n\r\n" ++ str[4..];
        try pieceTable.insert(3, "\r\n\n\n", false);
        const str2 = str1[0..3] ++ "\r\n\n\n" ++ str1[3..];

        try assertRawContent(str2, pieceTable);
        try testLineStarts(allocator, str2, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const RandomIsUnsupervisedTests = struct {
    test "splitting large change buffer" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "";

        try pieceTable.insert(0, "WUZ\nXVZY\n", false);
        const str1 = str[0..0] ++ "WUZ\nXVZY\n" ++ str[0..];
        try pieceTable.insert(8, "\r\r\nZXUWVW", false);
        const str2 = str1[0..8] ++ "\r\r\nZXUWVW" ++ str1[8..];
        try pieceTable.delete(10, 7);
        const str3 = str2[0..10] ++ str2[10 + 7 ..];
        try pieceTable.delete(10, 1);
        const str4 = str3[0..10] ++ str3[10 + 1 ..];
        try pieceTable.insert(4, "VX\r\r\nWZVZ", false);
        const str5 = str4[0..4] ++ "VX\r\r\nWZVZ" ++ str4[4..];
        try pieceTable.delete(11, 3);
        const str6 = str5[0..11] ++ str5[11 + 3 ..];
        try pieceTable.delete(12, 4);
        const str7 = str6[0..12] ++ str6[12 + 4 ..];
        try pieceTable.delete(8, 0);
        const str8 = str7[0..8] ++ str7[8 + 0 ..];
        try pieceTable.delete(10, 2);
        const str9 = str8[0..10] ++ str8[10 + 2 ..];
        try pieceTable.insert(0, "VZXXZYZX\r", false);
        const str10 = str9[0..0] ++ "VZXXZYZX\r" ++ str9[0..];

        try assertRawContent(str10, pieceTable);
        try testLineStarts(allocator, str10, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random insert delete" {
        const allocator = std.testing.allocator;
        var str: []const u8 = &[_]u8{};
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{str}, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        // let output = '';
        var toDestory: [1000][]const u8 = undefined;
        for (0..1000) |i| {
            if (rand.float(f64) < 0.6) {
                // insert
                const text = try randomStr(allocator, 100);
                defer allocator.free(text);
                const pos = randomInt(str.len + 1);
                try pieceTable.insert(pos, text, false);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], text, str[pos..] });
                toDestory[i] = str;
                // output += `pieceTable.insert(${pos}, '${text.replace(/\n/g, '\\n').replace(/\r/g, '\\r')}');\n`;
                // output += `str = str.substring(0, ${pos}) + '${text.replace(/\n/g, '\\n').replace(/\r/g, '\\r')}' + str.substring(${pos});\n`;
            } else {
                // delete
                const pos = randomInt(str.len);
                const length = @min(str.len - pos, randomInt(10));
                try pieceTable.delete(pos, length);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], str[pos + length ..] });
                toDestory[i] = str;
                // output += `pieceTable.delete(${pos}, ${length});\n`;
                // output += `str = str.substring(0, ${pos}) + str.substring(${pos} + ${length});\n`

            }
        }

        defer for (toDestory) |s| allocator.free(s);
        // console.log(output);

        try assertRawContent(str, pieceTable);

        try testLineStarts(allocator, str, pieceTable);
        try testLinesContent(allocator, str, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random chunks" {
        const allocator = std.testing.allocator;
        var chunks = ArrayList([]u8).init(allocator);
        defer {
            for (chunks.items) |s| {
                allocator.free(s);
            }
            chunks.deinit();
        }
        for (0..5) |_| {
            try chunks.append(try randomStr(allocator, 1000));
        }

        var pieceTree = try createTextBuffer(allocator, chunks.items, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        var toDestroy = ArrayList([]u8).init(allocator);
        defer {
            for (toDestroy.items) |s| {
                allocator.free(s);
            }
            toDestroy.deinit();
        }

        var str = try std.mem.join(allocator, "", chunks.items);
        try toDestroy.append(str);

        for (0..1000) |_| {
            if (rand.float(f64) < 0.6) {
                // insert
                const text = try randomStr(allocator, 100);
                defer allocator.free(text);
                const pos = randomInt(str.len + 1);
                try pieceTable.insert(pos, text, false);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], text, str[pos..] });
                try toDestroy.append(str);
            } else {
                // delete
                const pos = randomInt(str.len);
                const length = @min(str.len - pos, randomInt(10));
                try pieceTable.delete(pos, length);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], str[pos + length ..] });
                try toDestroy.append(str);
            }
        }

        try assertRawContent(str, pieceTable);
        try testLineStarts(allocator, str, pieceTable);
        try testLinesContent(allocator, str, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "random chunks 2" {
        const allocator = std.testing.allocator;
        var chunks = ArrayList([]u8).init(allocator);
        defer {
            for (chunks.items) |s| {
                allocator.free(s);
            }
            chunks.deinit();
        }
        try chunks.append(try randomStr(allocator, 1000));

        var pieceTree = try createTextBuffer(allocator, chunks.items, false);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        var toDestroy = ArrayList([]u8).init(allocator);
        defer {
            for (toDestroy.items) |s| {
                allocator.free(s);
            }
            toDestroy.deinit();
        }
        var str = try std.mem.join(allocator, "", chunks.items);
        try toDestroy.append(str);

        for (0..50) |_| {
            if (rand.float(f64) < 0.6) {
                // insert
                const text = try randomStr(allocator, 30);
                defer allocator.free(text);
                const pos = randomInt(str.len + 1);
                try pieceTable.insert(pos, text, false);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], text, str[pos..] });
                try toDestroy.append(str);
            } else {
                // delete
                const pos = randomInt(str.len);
                const length = @min(str.len - pos, randomInt(10));
                try pieceTable.delete(pos, length);
                str = try std.mem.join(allocator, "", &[_][]const u8{ str[0..pos], str[pos + length ..] });
                try toDestroy.append(str);
            }
            try testLinesContent(allocator, str, pieceTable);
        }

        try assertRawContent(str, pieceTable);
        try testLineStarts(allocator, str, pieceTable);
        try testLinesContent(allocator, str, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const BufferApiTests = struct {
    test "equal" {
        const allocator = std.testing.allocator;
        var a = try createTextBuffer(allocator, &[_][]const u8{"abc"}, false);
        defer a.deinit();
        var b = try createTextBuffer(allocator, &[_][]const u8{ "ab", "c" }, false);
        defer b.deinit();
        var c = try createTextBuffer(allocator, &[_][]const u8{"abd"}, false);
        defer c.deinit();
        var d = try createTextBuffer(allocator, &[_][]const u8{"abcd"}, false);
        defer d.deinit();

        const pieceTreeA = a.getPieceTree();
        const pieceTreeB = b.getPieceTree();
        const pieceTreeC = c.getPieceTree();
        const pieceTreeD = d.getPieceTree();
        try std.testing.expect(try pieceTreeA.equal(pieceTreeB));
        try std.testing.expect(!try pieceTreeA.equal(pieceTreeC));
        try std.testing.expect(!try pieceTreeA.equal(pieceTreeD));
    }

    test "equal with more chunks" {
        const allocator = std.testing.allocator;
        var a = try createTextBuffer(allocator, &[_][]const u8{ "ab", "cd", "e" }, true);
        defer a.deinit();
        var b = try createTextBuffer(allocator, &[_][]const u8{ "ab", "c", "de" }, true);
        defer b.deinit();
        const pieceTreeA = a.getPieceTree();
        const pieceTreeB = b.getPieceTree();
        try std.testing.expect(try pieceTreeA.equal(pieceTreeB));
    }

    test "equal 2, empty buffer" {
        const allocator = std.testing.allocator;
        var a = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer a.deinit();
        var b = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer b.deinit();

        const pieceTreeA = a.getPieceTree();
        const pieceTreeB = b.getPieceTree();
        try std.testing.expect(try pieceTreeA.equal(pieceTreeB));
    }

    test "equal 3, empty buffer" {
        const allocator = std.testing.allocator;
        var a = try createTextBuffer(allocator, &[_][]const u8{"a"}, true);
        defer a.deinit();
        var b = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer b.deinit();

        const pieceTreeA = a.getPieceTree();
        const pieceTreeB = b.getPieceTree();
        try std.testing.expect(!try pieceTreeA.equal(pieceTreeB));
    }

    test "getLineCharCode - issue #45735" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"LINE1\nline2"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try std.testing.expectEqual('L', pieceTable.getLineCharCode(1, 0));
        try std.testing.expectEqual('I', pieceTable.getLineCharCode(1, 1));
        try std.testing.expectEqual('N', pieceTable.getLineCharCode(1, 2));
        try std.testing.expectEqual('E', pieceTable.getLineCharCode(1, 3));
        try std.testing.expectEqual('1', pieceTable.getLineCharCode(1, 4));
        try std.testing.expectEqual('\n', pieceTable.getLineCharCode(1, 5));
        try std.testing.expectEqual('l', pieceTable.getLineCharCode(2, 0));
        try std.testing.expectEqual('i', pieceTable.getLineCharCode(2, 1));
        try std.testing.expectEqual('n', pieceTable.getLineCharCode(2, 2));
        try std.testing.expectEqual('e', pieceTable.getLineCharCode(2, 3));
        try std.testing.expectEqual('2', pieceTable.getLineCharCode(2, 4));
    }

    test "getLineCharCode - issue #47733" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{ "", "LINE1\n", "line2" }, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try std.testing.expectEqual('L', pieceTable.getLineCharCode(1, 0));
        try std.testing.expectEqual('I', pieceTable.getLineCharCode(1, 1));
        try std.testing.expectEqual('N', pieceTable.getLineCharCode(1, 2));
        try std.testing.expectEqual('E', pieceTable.getLineCharCode(1, 3));
        try std.testing.expectEqual('1', pieceTable.getLineCharCode(1, 4));
        try std.testing.expectEqual('\n', pieceTable.getLineCharCode(1, 5));
        try std.testing.expectEqual('l', pieceTable.getLineCharCode(2, 0));
        try std.testing.expectEqual('i', pieceTable.getLineCharCode(2, 1));
        try std.testing.expectEqual('n', pieceTable.getLineCharCode(2, 2));
        try std.testing.expectEqual('e', pieceTable.getLineCharCode(2, 3));
        try std.testing.expectEqual('2', pieceTable.getLineCharCode(2, 4));
    }

    test "getNearestChunk" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"012345678"}, true);
        defer pieceTree.deinit();
        var pt = pieceTree.getPieceTree();

        try pt.insert(3, "ABC", false);
        try assertLineContent("012ABC345678", pt, 1);
        try std.testing.expectEqualStrings("ABC", pt.getNearestChunk(3));
        try std.testing.expectEqualStrings("345678", pt.getNearestChunk(6));

        try pt.delete(9, 1);
        try assertLineContent("012ABC34578", pt, 1);
        try std.testing.expectEqualStrings("345", pt.getNearestChunk(6));
        try std.testing.expectEqualStrings("78", pt.getNearestChunk(9));
    }
};

const SearchOffsetCacheTests = struct {
    test "render white space exception" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"class Name{\n\t\n\t\t\tget() {\n\n\t\t\t}\n\t\t}"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "class Name{\n\t\n\t\t\tget() {\n\n\t\t\t}\n\t\t}";

        try pieceTable.insert(12, "s", false);
        const str1 = str[0..12] ++ "s" ++ str[12..];

        try pieceTable.insert(13, "e", false);
        const str2 = str1[0..13] ++ "e" ++ str1[13..];

        try pieceTable.insert(14, "t", false);
        const str3 = str2[0..14] ++ "t" ++ str2[14..];

        try pieceTable.insert(15, "()", false);
        const str4 = str3[0..15] ++ "()" ++ str3[15..];

        try pieceTable.delete(16, 1);
        const str5 = str4[0..16] ++ str4[16 + 1 ..];

        try pieceTable.insert(17, "()", false);
        const str6 = str5[0..17] ++ "()" ++ str5[17..];

        try pieceTable.delete(18, 1);
        const str7 = str6[0..18] ++ str6[18 + 1 ..];

        try pieceTable.insert(18, "}", false);
        const str8 = str7[0..18] ++ "}" ++ str7[18..];

        try pieceTable.insert(12, "\n", false);
        const str9 = str8[0..12] ++ "\n" ++ str8[12..];

        try pieceTable.delete(12, 1);
        const str10 = str9[0..12] ++ str9[12 + 1 ..];

        try pieceTable.delete(18, 1);
        const str11 = str10[0..18] ++ str10[18 + 1 ..];

        try pieceTable.insert(18, "}", false);
        const str12 = str11[0..18] ++ "}" ++ str11[18..];

        try pieceTable.delete(17, 2);
        const str13 = str12[0..17] ++ str12[17 + 2 ..];

        try pieceTable.delete(16, 1);
        const str14 = str13[0..16] ++ str13[16 + 1 ..];

        try pieceTable.insert(16, ")", false);
        const str15 = str14[0..16] ++ ")" ++ str14[16..];

        try pieceTable.delete(15, 2);
        const str16 = str15[0..15] ++ str15[15 + 2 ..];

        try assertRawContent(str16, pieceTable);
    }

    test "Line breaks replacement is not necessary when EOL is normalized" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"abc"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "abc";

        try pieceTable.insert(3, "def\nabc", false);
        const str1 = str ++ "def\nabc";

        try testLineStarts(allocator, str1, pieceTable);
        try testLinesContent(allocator, str1, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "Line breaks replacement is not necessary when EOL is normalized 2" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"abc\n"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "abc\n";

        try pieceTable.insert(4, "def\nabc", false);
        const str1 = str ++ "def\nabc";

        try testLineStarts(allocator, str1, pieceTable);
        try testLinesContent(allocator, str1, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "Line breaks replacement is not necessary when EOL is normalized 3" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"abc\n"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "abc\n";

        try pieceTable.insert(2, "def\nabc", false);
        const str1 = str[0..2] ++ "def\nabc" ++ str[2..];

        try testLineStarts(allocator, str1, pieceTable);
        try testLinesContent(allocator, str1, pieceTable);
        try assertTreeInvariants(pieceTable);
    }

    test "Line breaks replacement is not necessary when EOL is normalized 4" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"abc\n"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        const str = "abc\n";

        try pieceTable.insert(3, "def\nabc", false);
        const str1 = str[0..3] ++ "def\nabc" ++ str[3..];

        try testLineStarts(allocator, str1, pieceTable);
        try testLinesContent(allocator, str1, pieceTable);
        try assertTreeInvariants(pieceTable);
    }
};

const ChunkBasedSearchTests = struct {
    test "#45892. For some cases, the buffer is empty but we still try to search" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{""}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();
        try pieceTable.delete(0, 1);
        var regex = try RegExp.init("abc", .{});
        defer regex.deinit();
        var wordSeparators = try WordCharacterClassifier.init(allocator, ",./");
        defer wordSeparators.deinit();
        const ret = try pieceTree.findMatchesLineByLine(Range.init(1, 1, 1, 1), .init(regex, &wordSeparators, "abc"), true, 1000);
        try std.testing.expectEqual(0, ret.items.len);
    }

    test "#45770. FindInNode should not cross node boundary." {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"balabalababalabalababalabalaba\n" ++
            "balabalababalabalababalabalaba\n" ++
            "\n" ++
            "* [ ] task1\n" ++
            "* [x] task2 balabalaba\n" ++
            "* [ ] task 3"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(0, 62);
        try pieceTable.delete(16, 1);

        try pieceTable.insert(16, " ", false);
        var regex = try RegExp.init("\\[", .{ .ignore_case = true, .singleline = false });
        defer regex.deinit();
        var wordSeparators = try WordCharacterClassifier.init(allocator, ",./");
        defer wordSeparators.deinit();
        const ret = try pieceTable.findMatchesLineByLine(.init(1, 1, 4, 13), .init(regex, &wordSeparators, "["), true, 1000);
        defer {
            for (ret.items) |item| {
                item.deinit();
            }
            ret.deinit();
        }
        try std.testing.expectEqual(3, ret.items.len);

        try std.testing.expectEqualDeep(Range.init(2, 3, 2, 4), ret.items[0].range);
        try std.testing.expectEqualDeep(Range.init(3, 3, 3, 4), ret.items[1].range);
        try std.testing.expectEqualDeep(Range.init(4, 3, 4, 4), ret.items[2].range);
    }

    test "search searching from the middle" {
        const allocator = std.testing.allocator;
        var pieceTree = try createTextBuffer(allocator, &[_][]const u8{"def\ndbcabc"}, true);
        defer pieceTree.deinit();
        var pieceTable = pieceTree.getPieceTree();

        try pieceTable.delete(4, 1);
        var regex = try RegExp.init("a", .{ .ignore_case = true });
        defer regex.deinit();
        var ret = try pieceTable.findMatchesLineByLine(.init(2, 3, 2, 6), .init(regex, null, "a"), true, 1000);
        defer {
            for (ret.items) |item| {
                item.deinit();
            }
            ret.deinit();
        }
        try std.testing.expectEqual(1, ret.items.len);
        try std.testing.expectEqualDeep(Range.init(2, 3, 2, 4), ret.items[0].range);

        try pieceTable.delete(4, 1);
        var regex2 = try RegExp.init("a", .{ .ignore_case = true });
        defer regex2.deinit();
        var ret2 = try pieceTable.findMatchesLineByLine(.init(2, 2, 2, 5), .init(regex2, null, "a"), true, 1000);
        defer {
            for (ret2.items) |item| {
                item.deinit();
            }
            ret2.deinit();
        }
        try std.testing.expectEqual(1, ret2.items.len);
        try std.testing.expectEqualDeep(Range.init(2, 2, 2, 3), ret2.items[0].range);
    }
};

test "pieceTreeTextBuffer" {
    _ = InsertAndDeleteTests;
    _ = PrefixSumForLineFeedTests;
    _ = Offset2PositionTests;
    _ = GetTextInRangeTests;
    _ = CRLFTests;
    _ = CentralizedLineStartsWithCRLFTests;
    _ = RandomIsUnsupervisedTests;
    _ = BufferApiTests;
    _ = SearchOffsetCacheTests;
    _ = ChunkBasedSearchTests;
}
