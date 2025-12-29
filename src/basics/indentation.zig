const std = @import("std");
const strings = @import("strings.zig");
const ArrayList = std.array_list.Managed;
const Allocator = @import("std").mem.Allocator;
const String = strings.String;

fn _normalizeIndentationFromWhitespace(allocator: Allocator, str: []const u8, indentSize: usize, insertSpaces: bool) !ArrayList(u8) {
    var spacesCnt: usize = 0;
    for (0..str.len) |i| {
        if (str[i] == '\t') {
            spacesCnt = nextIndentTabStop(spacesCnt, indentSize);
        } else {
            spacesCnt += 1;
        }
    }

    var result = try ArrayList(u8).initCapacity(allocator, str.len);
    if (!insertSpaces) {
        const tabsCnt = spacesCnt / indentSize;
        spacesCnt = spacesCnt % indentSize;
        for (0..tabsCnt) |_| {
            try result.append('\t');
        }
    }

    for (0..spacesCnt) |_| {
        try result.append(' ');
    }

    return result;
}

pub fn normalizeIndentation(allocator: Allocator, str: []const u8, indentSize: usize, insertSpaces: bool) Allocator.Error!String {
    const firstNonWhitespaceIndex = strings.firstNonWhitespaceIndex(str) orelse str.len;
    var res = try _normalizeIndentationFromWhitespace(allocator, str[0..firstNonWhitespaceIndex], indentSize, insertSpaces);
    try res.appendSlice(str[firstNonWhitespaceIndex..]);
    return String.initOwned(res);
}

fn nextIndentTabStop(visibleColumn: usize, tabSize: usize) usize {
    return visibleColumn + tabSize - (visibleColumn % tabSize);
}
