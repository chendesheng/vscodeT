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
