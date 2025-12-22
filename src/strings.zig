const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub fn firstNonWhitespaceIndex(str: []const u8) ?usize {
    for (str, 0..) |c, i| {
        if (c != ' ' and c != '\t') {
            return i;
        }
    }
    return null;
}

test "firstNonWhitespaceIndex" {
    try std.testing.expectEqual(null, firstNonWhitespaceIndex(""));
    try std.testing.expectEqual(null, firstNonWhitespaceIndex("  "));
    try std.testing.expectEqual(0, firstNonWhitespaceIndex("Hello"));
    try std.testing.expectEqual(1, firstNonWhitespaceIndex(" Hello"));
    try std.testing.expectEqual(0, firstNonWhitespaceIndex("Hello "));
}

pub fn lastNonWhitespaceIndex(str: []const u8) ?usize {
    if (str.len == 0) {
        return null;
    }

    var i = str.len - 1;
    while (true) {
        if (str[i] != ' ' and str[i] != '\t') {
            return i;
        }

        if (i > 0) {
            i -= 1;
        } else {
            return null;
        }
    }
}

test "lastNonWhitespaceIndex" {
    try std.testing.expectEqual(null, lastNonWhitespaceIndex(""));
    try std.testing.expectEqual(null, lastNonWhitespaceIndex("  "));
    try std.testing.expectEqual(4, lastNonWhitespaceIndex("Hello"));
    try std.testing.expectEqual(4, lastNonWhitespaceIndex("Hello "));
    try std.testing.expectEqual(5, lastNonWhitespaceIndex(" Hello"));
}

pub fn isBasicASCII(str: []const u8) bool {
    for (str) |c| {
        if (c == '\t' or c == '\n' or c == '\r' or (0x20 <= c and c <= 0x7e)) {
            continue;
        }
        return false;
    }
    return true;
}

test "isBasicASCII" {
    try std.testing.expectEqual(true, isBasicASCII("Hello"));
    try std.testing.expectEqual(false, isBasicASCII("Hello\x0080"));
}

pub fn containsRTL(str: []const u8) bool {
    // https://github.com/alexdima/unicode-utils/blob/main/rtl-test.js
    //(?:[\u05BE\u05C0\u05C3\u05C6\u05D0-\u05F4\u0608\u060B\u060D\u061B-\u064A\u066D-\u066F\u0671-\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u0710\u0712-\u072F\u074D-\u07A5\u07B1-\u07EA\u07F4\u07F5\u07FA\u07FE-\u0815\u081A\u0824\u0828\u0830-\u0858\u085E-\u088E\u08A0-\u08C9\u200F\uFB1D\uFB1F-\uFB28\uFB2A-\uFD3D\uFD50-\uFDC7\uFDF0-\uFDFC\uFE70-\uFEFC]|\uD802[\uDC00-\uDD1B\uDD20-\uDE00\uDE10-\uDE35\uDE40-\uDEE4\uDEEB-\uDF35\uDF40-\uDFFF]|\uD803[\uDC00-\uDD23\uDE80-\uDEA9\uDEAD-\uDF45\uDF51-\uDF81\uDF86-\uDFF6]|\uD83A[\uDC00-\uDCCF\uDD00-\uDD43\uDD4B-\uDFFF]|\uD83B[\uDC00-\uDEBB])/;
    const utf8View = std.unicode.Utf8View.init(str) catch return false;
    var it = utf8View.iterator();
    while (it.nextCodepoint()) |c| {
        if (c == 0x05BE or c == 0x05C0 or c == 0x05C3 or c == 0x05C6 or (0x05D0 <= c and c <= 0x05F4) or c == 0x0608 or c == 0x060B or (0x060D <= c and c <= 0x061B) or (0x064A <= c and c <= 0x064A) or (0x066D <= c and c <= 0x066F) or (0x0671 <= c and c <= 0x06D5) or c == 0x06E5 or c == 0x06E6 or (0x06EE <= c and c <= 0x06EF) or (0x06FA <= c and c <= 0x0710) or (0x0712 <= c and c <= 0x072F) or (0x074D <= c and c <= 0x07A5) or (0x07B1 <= c and c <= 0x07EA) or c == 0x07F4 or c == 0x07F5 or (0x07FA <= c and c <= 0x0815) or c == 0x081A or c == 0x0824 or c == 0x0828 or (0x0830 <= c and c <= 0x0858) or (0x085E <= c and c <= 0x088E) or (0x08A0 <= c and c <= 0x08C9) or c == 0x200F or c == 0xFB1D or (0xFB1F <= c and c <= 0xFB28) or (0xFB2A <= c and c <= 0xFD3D) or (0xFD50 <= c and c <= 0xFDC7) or (0xFDF0 <= c and c <= 0xFDFC) or (0xFE70 <= c and c <= 0xFEFC) or c == 0xD802 or (0xDC00 <= c and c <= 0xDD1B) or (0xDD20 <= c and c <= 0xDE00) or (0xDE10 <= c and c <= 0xDE35) or (0xDE40 <= c and c <= 0xDEE4) or (0xDEEB <= c and c <= 0xDF35) or (0xDF40 <= c and c <= 0xDFFF) or c == 0xD803 or (0xDC00 <= c and c <= 0xDD23) or (0xDE80 <= c and c <= 0xDEA9) or (0xDEAD <= c and c <= 0xDF45) or (0xDF51 <= c and c <= 0xDF81) or (0xDF86 <= c and c <= 0xDFF6) or c == 0xD83A or (0xDC00 <= c and c <= 0xDCCF) or (0xDD00 <= c and c <= 0xDD43) or (0xDD4B <= c and c <= 0xDFFF) or c == 0xD83B or (0xDC00 <= c and c <= 0xDEBB)) {
            return true;
        }
    }
    return false;
}

pub fn containsUnusualLineTerminators(str: []const u8) bool {
    const utf8View = std.unicode.Utf8View.init(str) catch return false;
    var it = utf8View.iterator();
    while (it.nextCodepoint()) |c| {
        if (c == 0x2028 or c == 0x2029) {
            return true;
        }
    }
    return false;
}

pub fn isNullOrEmpty(str: ?[]const u8) bool {
    return str == null or str.?.len == 0;
}

pub const UTF8_BOM_CHARACTER: []const u8 = "\xef\xbb\xbf";

pub fn startsWithUTF8BOM(str: []const u8) bool {
    return str.len >= 3 and std.mem.eql(u8, str[0..3], UTF8_BOM_CHARACTER);
}

test "startsWithUTF8BOM" {
    try std.testing.expectEqual(false, startsWithUTF8BOM(""));
    try std.testing.expectEqual(false, startsWithUTF8BOM("Hello"));
    try std.testing.expectEqual(true, startsWithUTF8BOM("\xef\xbb\xbfHello"));
}

pub fn escapeNewLine(str: []const u8, allocator: Allocator) ![]const u8 {
    var result = ArrayList(u8).init(allocator);
    for (str) |ch| {
        if (ch == '\n') {
            try result.appendSlice("\\n");
        } else if (ch == '\r') {
            try result.appendSlice("\\r");
        } else {
            try result.append(ch);
        }
    }
    return result.toOwnedSlice();
}

test "escapeNewLine" {
    const allocator = std.testing.allocator;

    const result = try escapeNewLine("Hello\nWorld\r\n", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello\\nWorld\\r\\n", result);

    const result2 = try escapeNewLine("Hello\nWorld\r\n", allocator);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Hello\\nWorld\\r\\n", result2);
}
