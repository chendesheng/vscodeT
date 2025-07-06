const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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
    // TODO: https://github.com/alexdima/unicode-utils/blob/main/rtl-test.js
    //(?:[\u05BE\u05C0\u05C3\u05C6\u05D0-\u05F4\u0608\u060B\u060D\u061B-\u064A\u066D-\u066F\u0671-\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u0710\u0712-\u072F\u074D-\u07A5\u07B1-\u07EA\u07F4\u07F5\u07FA\u07FE-\u0815\u081A\u0824\u0828\u0830-\u0858\u085E-\u088E\u08A0-\u08C9\u200F\uFB1D\uFB1F-\uFB28\uFB2A-\uFD3D\uFD50-\uFDC7\uFDF0-\uFDFC\uFE70-\uFEFC]|\uD802[\uDC00-\uDD1B\uDD20-\uDE00\uDE10-\uDE35\uDE40-\uDEE4\uDEEB-\uDF35\uDF40-\uDFFF]|\uD803[\uDC00-\uDD23\uDE80-\uDEA9\uDEAD-\uDF45\uDF51-\uDF81\uDF86-\uDFF6]|\uD83A[\uDC00-\uDCCF\uDD00-\uDD43\uDD4B-\uDFFF]|\uD83B[\uDC00-\uDEBB])/;
    _ = str;
    return false;
}

pub fn containsUnusualLineTerminators(str: []const u8) bool {
    // TOOD
    // for (str) |c| {
    //     if (c == "\u2028" or c == "\u2029") {
    //         return true;
    //     }
    // }
    _ = str;
    return false;
}

pub fn isNullOrEmpty(str: ?[]const u8) bool {
    return str == null or str.?.len == 0;
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
