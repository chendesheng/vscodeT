// Port of the CRLF/delete and random insert-delete cases from
// `src/vs/editor/test/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const PB = @import("../../../../common/model/pieceTreeTextBuffer/pieceTreeBase.zig");
const PieceTreeBase = PB.PieceTreeBase;
const StringBuffer = PB.StringBuffer;

fn createTree(allocator: Allocator, text: []const u8) !PieceTreeBase {
    var chunks = [_]StringBuffer{try StringBuffer.init(allocator, text)};
    return PieceTreeBase.init(allocator, null, &chunks, .LF, false);
}

fn splitLines(allocator: Allocator, text: []const u8) !ArrayList(ArrayList(u8)) {
    var result = ArrayList(ArrayList(u8)).init(allocator);
    errdefer result.deinit();
    var line = ArrayList(u8).init(allocator);
    errdefer line.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            try result.append(line);
            line = ArrayList(u8).init(allocator);
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
        } else if (text[i] == '\n') {
            try result.append(line);
            line = ArrayList(u8).init(allocator);
            i += 1;
        } else {
            try line.append(text[i]);
            i += 1;
        }
    }
    try result.append(line);
    return result;
}

fn verify(allocator: Allocator, tree: *PieceTreeBase, ref: []const u8) !void {
    var expected = try splitLines(allocator, ref);
    defer {
        for (expected.items) |line| line.deinit();
        expected.deinit();
    }
    try std.testing.expectEqual(expected.items.len, tree.getLineCount());

    var lines = try tree.getLinesContent();
    defer {
        for (lines.items) |line| line.deinit();
        lines.deinit();
    }
    try std.testing.expectEqual(expected.items.len, lines.items.len);
    for (expected.items, lines.items) |want, got| {
        try std.testing.expectEqualStrings(want.items, got.items);
    }
}

test "piece tree CRLF: delete CR/CRLF after inserting a CRLF" {
    const allocator = std.testing.allocator;

    {
        var tree = try createTree(allocator, "");
        defer tree.deinit();
        try tree.insert(0, "a\r\nb", false);
        try tree.delete(0, 2);
        try std.testing.expectEqual(@as(usize, 2), tree.getLineCount());
    }

    {
        var tree = try createTree(allocator, "a\r\nb");
        defer tree.deinit();
        try tree.delete(2, 2);
        try std.testing.expectEqual(@as(usize, 2), tree.getLineCount());
    }
}

test "piece tree: deterministic random insert/delete over CR/LF alphabet" {
    const allocator = std.testing.allocator;
    const alphabet = "abcXYZ\r\n";
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();

    var tree = try createTree(allocator, "");
    defer tree.deinit();
    var ref = ArrayList(u8).init(allocator);
    defer ref.deinit();

    var step: usize = 0;
    while (step < 500) : (step += 1) {
        if (ref.items.len == 0 or rng.boolean()) {
            const offset = rng.uintLessThan(usize, ref.items.len + 1);
            var text: [8]u8 = undefined;
            const len = rng.uintLessThan(usize, 9);
            for (text[0..len]) |*ch| ch.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
            try tree.insert(offset, text[0..len], false);
            try ref.insertSlice(offset, text[0..len]);
        } else {
            const offset = rng.uintLessThan(usize, ref.items.len);
            const count = 1 + rng.uintLessThan(usize, @min(@as(usize, 8), ref.items.len - offset));
            try tree.delete(offset, count);
            try ref.replaceRange(offset, count, &.{});
        }
        try verify(allocator, &tree, ref.items);
    }
}

fn createTreeFromChunks(allocator: Allocator, chunks: []const []const u8) !PieceTreeBase {
    const buffers = try allocator.alloc(StringBuffer, chunks.len);
    defer allocator.free(buffers);
    var initialized: usize = 0;
    errdefer {
        for (buffers[0..initialized]) |*buffer| buffer.deinit();
    }
    for (chunks, 0..) |chunk, i| {
        buffers[i] = try StringBuffer.init(allocator, chunk);
        initialized += 1;
    }
    return PieceTreeBase.init(allocator, null, buffers, .LF, false);
}

test "piece tree buffer api: equal ignores chunk boundaries" {
    const allocator = std.testing.allocator;
    var a = try createTreeFromChunks(allocator, &.{"abc"});
    defer a.deinit();
    var b = try createTreeFromChunks(allocator, &.{ "ab", "c" });
    defer b.deinit();
    var c = try createTreeFromChunks(allocator, &.{"abd"});
    defer c.deinit();
    var d = try createTreeFromChunks(allocator, &.{"abcd"});
    defer d.deinit();
    try std.testing.expect(try a.equal(&b));
    try std.testing.expect(!try a.equal(&c));
    try std.testing.expect(!try a.equal(&d));

    var e = try createTreeFromChunks(allocator, &.{ "ab", "cd", "e" });
    defer e.deinit();
    var f = try createTreeFromChunks(allocator, &.{ "ab", "c", "de" });
    defer f.deinit();
    try std.testing.expect(try e.equal(&f));

    var empty1 = try createTreeFromChunks(allocator, &.{""});
    defer empty1.deinit();
    var empty2 = try createTreeFromChunks(allocator, &.{""});
    defer empty2.deinit();
    try std.testing.expect(try empty1.equal(&empty2));

    var one = try createTreeFromChunks(allocator, &.{"a"});
    defer one.deinit();
    try std.testing.expect(!try one.equal(&empty1));
}

test "piece tree buffer api: getNearestChunk follows edits" {
    const allocator = std.testing.allocator;
    var tree = try createTreeFromChunks(allocator, &.{"012345678"});
    defer tree.deinit();
    try tree.insert(3, "ABC", false);
    var line = try tree.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("012ABC345678", line.items);
    try std.testing.expectEqualStrings("ABC", tree.getNearestChunk(3));
    try std.testing.expectEqualStrings("345678", tree.getNearestChunk(6));

    try tree.delete(9, 1);
    line.deinit();
    line = try tree.getLineContent(1);
    try std.testing.expectEqualStrings("012ABC34578", line.items);
    try std.testing.expectEqualStrings("345", tree.getNearestChunk(6));
    try std.testing.expectEqualStrings("78", tree.getNearestChunk(9));
}

test "piece tree buffer api: getLineCharCode over line breaks" {
    const allocator = std.testing.allocator;
    var tree = try createTreeFromChunks(allocator, &.{"LINE1\nline2"});
    defer tree.deinit();
    const expected_first = "LINE1\n";
    const expected_second = "line2";
    for (expected_first, 0..) |ch, i| {
        try std.testing.expectEqual(ch, tree.getLineCharCode(1, i));
    }
    for (expected_second, 0..) |ch, i| {
        try std.testing.expectEqual(ch, tree.getLineCharCode(2, i));
    }
}
