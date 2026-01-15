const std = @import("std");
const fmt = std.fmt;
const TextLength = @import("text/textLength.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Utf8Iterator = std.unicode.Utf8Iterator;
const re = @import("RegExp.zig");
const RegExp = re.RegExp;
const RegExpOptions = re.Options;
const escapeRegExp = re.escapeRegExp;
const HashMap = std.HashMap;
const EOL = @import("eolCounter.zig").EOL;
const _replaceEOL = @import("eolCounter.zig").replaceEOL;
const firstCodepoint = @import("utf8Helper.zig").firstCodepoint;

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

pub fn isBasicASCIIReader(r: *std.Io.Reader) bool {
    while (true) {
        const c = r.takeByte() catch break;
        if (c == '\t' or c == '\n' or c == '\r' or (0x20 <= c and c <= 0x7e)) {
            continue;
        }
        return false;
    }
    return true;
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

pub const UNUSUAL_LINE_TERMINATORS = "\x20\x28\x20\x29"; // LINE SEPARATOR (LS) or PARAGRAPH SEPARATOR (PS)

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

pub fn htmlAttributeEncodeValue(allocator: Allocator, value: []const u8) ![]const u8 {
    var result = ArrayList(u8).init(allocator);
    for (value) |ch| {
        switch (ch) {
            '<' => try result.appendSlice("&lt;"),
            '>' => try result.appendSlice("&gt;"),
            '"' => try result.appendSlice("&quot;"),
            '\'' => try result.appendSlice("&apos;"),
            '&' => try result.appendSlice("&amp;"),
            else => try result.append(ch),
        }
    }
    return result.toOwnedSlice();
}

test "htmlAttributeEncodeValue" {
    const allocator = std.testing.allocator;
    const result = try htmlAttributeEncodeValue(allocator, "<Hello>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;Hello&gt;", result);
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

pub fn singleLetterHash(n: u64) u8 {
    const LETTERS_CNT: u8 = ('Z' - 'A' + 1);

    const n1 = @as(u8, @intCast(@mod(n, @as(u64, @intCast(2 * LETTERS_CNT)))));

    if (n1 < LETTERS_CNT) {
        return 'a' + n1;
    }

    return 'A' + n1 - LETTERS_CNT;
}

test "singleLetterHash" {
    for (0..25, 'a'..'z') |i, c| {
        try std.testing.expectEqual(c, singleLetterHash(i));
    }
    for (26..51, 'A'..'Z') |i, c| {
        try std.testing.expectEqual(c, singleLetterHash(i));
    }
    for (52..77, 'a'..'z') |i, c| {
        try std.testing.expectEqual(c, singleLetterHash(i));
    }
    for (78..103, 'A'..'Z') |i, c| {
        try std.testing.expectEqual(c, singleLetterHash(i));
    }
}

pub fn concat(allocator: Allocator, stra: []const u8, strb: []const u8) !ArrayList(u8) {
    var result = ArrayList(u8).init(allocator);
    try result.appendSlice(stra);
    try result.appendSlice(strb);
    return result;
}

test "concat" {
    const allocator = std.testing.allocator;
    const result = try concat(allocator, "Hello", "World");
    defer result.deinit();
    try std.testing.expectEqualStrings("HelloWorld", result.items);
}

pub const String = union(enum) {
    owned: ArrayList(u8),
    borrowed1: []const u8,
    borrowed: ArrayList([]const u8),
    empty: void,

    pub const Empty: String = .empty;

    pub fn allocPrint(allocator: Allocator, comptime format: []const u8, args: anytype) !String {
        const str = try fmt.allocPrint(allocator, format, args);
        const arr = ArrayList(u8).fromOwnedSlice(allocator, str);
        return String.initOwned(arr);
    }

    pub fn initOwned(arr: ArrayList(u8)) String {
        return .{ .owned = arr };
    }

    pub fn initBorrowed(str: []const u8) String {
        if (str.len == 0) {
            return .empty;
        }
        return .{ .borrowed1 = str };
    }

    pub fn deinit(self: *String) void {
        switch (self.*) {
            .empty => {},
            .owned => |*list| {
                list.deinit();
                self.* = Empty;
            },
            .borrowed1 => {},
            .borrowed => |arr| {
                arr.deinit();
            },
        }
    }

    pub fn ensureOwned(self: *String, allocator: Allocator) !void {
        switch (self.*) {
            .empty => {},
            .owned => {
                return;
            },
            .borrowed1 => |s| {
                var arr = ArrayList(u8).init(allocator);
                try arr.appendSlice(s);
                self.* = .{ .owned = arr };
            },
            .borrowed => |str| {
                var arr = ArrayList(u8).init(allocator);
                for (str.items) |s| {
                    try arr.appendSlice(s);
                }
                self.* = .{ .owned = arr };
            },
        }
    }

    // fn items(self: *const String) []const u8 {
    //     switch (self.*) {
    //         .empty => return "",
    //         .owned => |list| {
    //             return list.items;
    //         },
    //         .borrowed => |str| {
    //             return str;
    //         },
    //     }
    // }

    pub fn u8At(self: *const String, index: usize) u8 {
        switch (self.*) {
            .empty => unreachable,
            .owned => |list| {
                return list.items[index];
            },
            .borrowed1 => |s| return s[index],
            .borrowed => |list| {
                var i = index;
                for (list.items) |s| {
                    if (i < s.len) {
                        return s[i];
                    }
                    i -= s.len;
                }
                unreachable;
            },
        }
    }

    pub fn last(self: *const String) u8 {
        switch (self.*) {
            .empty => unreachable,
            .owned => |list| return list.items[list.items.len - 1],
            .borrowed1 => |s| return s[s.len - 1],
            .borrowed => |list| {
                const lst = list.items[list.items.len - 1];
                return lst[lst.len - 1];
            },
        }
    }

    fn isOwned(self: *const String) bool {
        return switch (self.*) {
            .empty => false,
            .owned => true,
            .borrowed1 => false,
            .borrowed => false,
        };
    }

    pub fn isEmpty(self: *const String) bool {
        return switch (self.*) {
            .empty => true,
            .owned => |s| s.items.len == 0,
            .borrowed1 => |s| s.len == 0,
            .borrowed => |list| {
                for (list.items) |s| {
                    if (s.len > 0) {
                        return false;
                    }
                }
                return true;
            },
        };
    }

    fn eqlStrVsList(owned: []const u8, borrowed: ArrayList([]const u8)) bool {
        var rest: []const u8 = owned;
        for (borrowed.items) |s| {
            if (s.len <= rest.len) {
                if (std.mem.eql(u8, rest[0..s.len], s)) {
                    rest = rest[s.len..];
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }
        return true;
    }

    fn eqlListVsList(a: ArrayList([]const u8), b: ArrayList([]const u8)) bool {
        var indexA: usize = 0;
        var offsetA: usize = 0;

        var indexB: usize = 0;
        var offsetB: usize = 0;

        while (indexA < a.items.len and indexB < b.items.len) {
            const a_s = a.items[indexA][offsetA..];
            const b_s = b.items[indexB][offsetB..];

            if (a_s.len == b_s.len) {
                if (std.mem.eql(u8, a_s, b_s)) {
                    indexA += 1;
                    offsetA = 0;

                    indexB += 1;
                    offsetB = 0;
                } else {
                    return false;
                }
            } else if (a_s.len < b_s.len) {
                if (std.mem.eql(u8, a_s, b_s[0..a_s.len])) {
                    indexA += 1;
                    offsetA = 0;
                    offsetB += a_s.len;
                } else {
                    return false;
                }
            } else {
                if (std.mem.eql(u8, a_s[0..b_s.len], b_s)) {
                    indexB += 1;
                    offsetB = 0;
                    offsetA += b_s.len;
                } else {
                    return false;
                }
            }
        }

        return indexA == indexB and offsetA == offsetB;
    }

    pub fn eql(self: *const String, other: String) bool {
        switch (self.*) {
            .empty => return other.isEmpty(),
            .owned => |s| {
                switch (other) {
                    .empty => return self.isEmpty(),
                    .owned => |otherList| return std.mem.eql(u8, s.items, otherList.items),
                    .borrowed1 => |otherS| return std.mem.eql(u8, s.items, otherS),
                    .borrowed => |otherStr| return eqlStrVsList(s.items, otherStr),
                }
            },
            .borrowed1 => |s| {
                switch (other) {
                    .empty => return self.isEmpty(),
                    .owned => |otherS| return std.mem.eql(u8, otherS.items, s),
                    .borrowed1 => |otherS| return std.mem.eql(u8, s, otherS),
                    .borrowed => |list| return eqlStrVsList(s, list),
                }
            },
            .borrowed => |list| {
                switch (other) {
                    .empty => return self.isEmpty(),
                    .owned => |otherS| return eqlStrVsList(otherS.items, list),
                    .borrowed1 => |otherS| return eqlStrVsList(otherS, list),
                    .borrowed => |otherList| return eqlListVsList(list, otherList),
                }
            },
        }
    }

    pub fn expectEqual(self: *const String, other: String) !void {
        const allocator = std.testing.allocator;
        std.testing.expect(self.eql(other)) catch |err| {
            const s = try self.display(allocator);
            const o = try other.display(allocator);
            std.debug.print("Expected {s} to be equal to {s}", .{ s, o });
            allocator.free(s);
            allocator.free(o);
            return err;
        };
    }

    pub fn len(self: *const String) usize {
        switch (self.*) {
            .empty => return 0,
            .owned => |list| return list.items.len,
            .borrowed1 => |s| return s.len,
            .borrowed => |str| {
                var l: usize = 0;
                for (str.items) |s| {
                    l += s.len;
                }
                return l;
            },
        }
    }

    pub fn substring(self: *const String, start: usize, end: usize) !String {
        switch (self.*) {
            .empty => unreachable,
            .owned => |list| {
                return String.initBorrowed(list.items[start..end]);
            },
            .borrowed1 => |s| {
                return String.initBorrowed(s[start..end]);
            },
            .borrowed => |str| {
                var result = ArrayList([]const u8).init(str.allocator);
                var i = start;
                for (str.items) |s| {
                    if (s.len <= i) {
                        i -= s.len;
                        try result.append(s);
                    } else {
                        try result.append(s[0..i]);
                    }
                }
                return .{ .borrowed = result };
            },
        }
    }

    pub fn splitAt(self: *const String, allocator: Allocator, index: usize) !struct { String, String } {
        const slice = try self.toSlice(allocator);
        defer slice.deinit();

        var first = ArrayList(u8).init(allocator);
        try first.appendSlice(slice.items[0..index]);

        var second = ArrayList(u8).init(allocator);
        try second.appendSlice(slice.items[index..]);

        return .{ String.initOwned(first), String.initOwned(second) };
    }

    pub fn display(self: *const String, allocator: Allocator) ![]const u8 {
        var result = ArrayList(u8).init(allocator);
        defer result.deinit();
        try self.fillItems(&result);
        return try escapeNewLine(result.items, allocator);
    }

    pub fn toSlice(self: *const String, allocator: Allocator) !ArrayList(u8) {
        var result = ArrayList(u8).init(allocator);
        try self.fillItems(&result);
        return result;
    }

    pub fn replaceEOL(self: *const String, allocator: Allocator, eol: EOL) !String {
        var result = ArrayList(u8).init(allocator);
        try self.fillItems(&result);
        try _replaceEOL(&result, eol);
        return String.initOwned(result);
    }

    pub fn copy(self: *const String, allocator: Allocator) !String {
        return String.initOwned(try self.toSlice(allocator));
    }

    // transfer ownership to the caller
    pub fn move(self: *String) String {
        switch (self.*) {
            .empty => return .empty,
            .owned => |list| {
                self.* = .initBorrowed(list.items);
                return String.initOwned(list);
            },
            .borrowed1 => {
                return self.*;
            },
            .borrowed => {
                return self.*;
            },
        }
    }

    pub fn isBasicASCII_(self: *const String) bool {
        var r = self.reader();
        return isBasicASCIIReader(&r);
    }

    pub fn containsRTL_(self: *const String) bool {
        // TODO
        _ = self;
        return false;
    }

    pub fn containsUnusualLineTerminators_(self: *const String) bool {
        // TODO
        _ = self;
        return false;
    }

    pub fn hash(self: *const String) u64 {
        switch (self.*) {
            .empty => return 0,
            .owned => |list| return std.hash.Wyhash.hash(0, list.items),
            .borrowed1 => |s| return std.hash.Wyhash.hash(0, s),
            .borrowed => |str| {
                var h: u64 = 0;
                for (str.items) |s| {
                    h = std.hash.Wyhash.hash(h, s);
                }
                return h;
            },
        }
    }

    pub fn fillItems(self: *const String, items: *ArrayList(u8)) !void {
        switch (self.*) {
            .empty => return,
            .owned => |list| {
                try items.appendSlice(list.items);
            },
            .borrowed1 => |s| {
                try items.appendSlice(s);
            },
            .borrowed => |list| {
                for (list.items) |s| {
                    try items.appendSlice(s);
                }
            },
        }
    }

    pub fn debugPrint(self: *const String) void {
        const allocator = std.testing.allocator;

        const s = self.display(allocator) catch unreachable;
        defer allocator.free(s);

        switch (self.*) {
            .empty => std.debug.print("empty\n", .{}),
            .owned => {
                std.debug.print("owned: \"{s}\"\n", .{s});
            },
            .borrowed1 => std.debug.print("borrowed1: \"{s}\"\n", .{s}),
            .borrowed => {
                std.debug.print("borrowed: \"{s}\"\n", .{s});
            },
        }
    }

    pub fn concat(self: *const String, allocator: Allocator, other: String) !String {
        var result = ArrayList(u8).init(allocator);
        try self.fillItems(&result);
        try other.fillItems(&result);
        return String.initOwned(result);
    }

    pub fn reader(self: *const String) std.Io.Reader {
        switch (self.*) {
            .empty => return std.Io.Reader.fixed(""),
            .owned => |list| {
                return std.Io.Reader.fixed(list.items);
            },
            .borrowed1 => |s| {
                return std.Io.Reader.fixed(s);
            },
            .borrowed => |list| {
                // FIXME: leaking
                var result = ArrayList(u8).init(list.allocator);
                for (list.items) |s| {
                    result.appendSlice(s) catch unreachable;
                }
                return std.Io.Reader.fixed(result.items);
            },
        }
    }

    pub fn getFistCodepoint(self: *const String) ?u21 {
        switch (self.*) {
            .empty => return null,
            .owned => |list| {
                return firstCodepoint(list.items) catch null;
            },
            .borrowed1 => |s| {
                return firstCodepoint(s) catch null;
            },
            .borrowed => |list| {
                for (list.items) |s| {
                    if (s.len == 0) continue;
                    return firstCodepoint(s) catch null;
                }
                return null;
            },
        }
    }

    pub fn toTextLength(self: *const String) TextLength {
        switch (self.*) {
            .empty => return TextLength.zero,
            .owned => |list| return TextLength.ofText(list.items),
            .borrowed1 => |s| return TextLength.ofText(s),
            .borrowed => |list| return TextLength.sum([]const u8, list.items, TextLength.ofText),
        }
    }
};

pub fn StringHashMap(comptime V: type) type {
    return HashMap(String, V, StringContext, std.hash_map.default_max_load_percentage);
}

pub const StringContext = struct {
    pub fn hash(self: @This(), s: String) u64 {
        _ = self;
        return s.hash();
    }
    pub fn eql(self: @This(), a: String, b: String) bool {
        _ = self;
        return a.eql(b);
    }
};

test "String.empty" {
    const str = String.Empty;
    try std.testing.expectEqual(true, str.isEmpty());
    try std.testing.expectEqual(0, str.len());
}

test "String.initBorrowed" {
    var str = String.initBorrowed("Hello");
    defer str.deinit();
    try std.testing.expect(str.eql(.initBorrowed("Hello")));
}

test "String.initOwned" {
    const allocator = std.testing.allocator;
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice("Hello");
    var str = String.initOwned(arr);
    defer str.deinit();
    try std.testing.expect(str.eql(.initBorrowed("Hello")));
}

test "String.allocPrint" {
    const allocator = std.testing.allocator;
    var str = try String.allocPrint(allocator, "Hello {d}", .{123});
    defer str.deinit();
    try std.testing.expect(str.eql(.initBorrowed("Hello 123")));
}

test "String.ensureOwned" {
    const allocator = std.testing.allocator;
    var str = String.initBorrowed("Hello");
    defer str.deinit();
    try std.testing.expectEqual(false, str.isOwned());
    try str.ensureOwned(allocator);
    try std.testing.expectEqual(true, str.isOwned());
    try str.ensureOwned(allocator);
    try std.testing.expectEqual(true, str.isOwned());
}

test "String.isEmpty" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(true, String.Empty.isEmpty());
    var str = String.initBorrowed("Hello");
    defer str.deinit();
    try std.testing.expectEqual(false, str.isEmpty());

    const arr = ArrayList(u8).init(allocator);
    str = String.initOwned(arr);
    defer str.deinit();
    try std.testing.expectEqual(true, str.isEmpty());
}

test "String.eql" {
    const allocator = std.testing.allocator;
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice("Hello");
    var str = String.initOwned(arr);
    defer str.deinit();
    var str2 = String.initBorrowed("Hello");
    defer str2.deinit();

    try std.testing.expectEqual(true, str.eql(str2));
    try std.testing.expectEqual(false, str.eql(String.initBorrowed("World")));
    try std.testing.expectEqual(true, str.eql(str2));
}

test "String.len" {
    const allocator = std.testing.allocator;
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice("Hello");
    var str = String.initOwned(arr);
    defer str.deinit();
    try std.testing.expectEqual(5, str.len());
    try std.testing.expectEqual(0, String.Empty.len());
}

test "String.move" {
    const allocator = std.testing.allocator;
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice("Hello");
    var str = String.initOwned(arr);

    var str2 = str.move();
    defer str2.deinit();

    // str2 still owns the memory after str is deinitialized
    str.deinit();
    try std.testing.expect(str2.eql(.initBorrowed("Hello")));
}

test "String.move borrowed" {
    var str = String.initBorrowed("Hello");
    defer str.deinit();

    var str2 = str.move();
    defer str2.deinit();

    try std.testing.expect(str2.eql(.initBorrowed("Hello")));
}

pub fn getNextCodePoint(text: []const u8, len: usize, offset: usize) !u21 {
    std.debug.assert(offset < len);
    var it = Utf8Iterator{
        .bytes = text,
        .i = offset,
    };
    return try it.nextCodepoint();
}

pub fn getNextCodePointSize(text: []const u8, len: usize, offset: usize) !usize {
    std.debug.assert(offset < len);
    var it = Utf8Iterator{
        .bytes = text,
        .i = offset,
    };
    return (try it.nextCodepointSlice()).len;
}

fn initArrayList(allocator: Allocator, str: []const u8) !ArrayList(u8) {
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice(str);
    return arr;
}

fn createRegexpPattern(allocator: Allocator, searchString: []const u8, isRegex: bool, wholeWord: bool) ![]const u8 {
    if (searchString.len == 0) {
        return error.CannotCreateRegExpFromEmptyString;
    }

    var escapedSearchString = if (isRegex)
        try initArrayList(allocator, searchString)
    else
        try escapeRegExp(allocator, searchString);

    if (wholeWord) {
        try escapedSearchString.insertSlice(0, "\\b");
        try escapedSearchString.appendSlice("\\b");
    }

    defer escapedSearchString.deinit();

    return try escapedSearchString.toOwnedSlice();
}

pub fn createRegExp(allocator: Allocator, searchString: []const u8, isRegex: bool, wholeWord: bool, options: RegExpOptions) !RegExp {
    const pattern = try createRegexpPattern(allocator, searchString, isRegex, wholeWord);
    errdefer allocator.free(pattern);
    return RegExp.initWithAllocator(allocator, pattern, options);
}

test "createRegExp" {
    const allocator = std.testing.allocator;
    const regex = try createRegExp(allocator, "Hello?", false, false, .{});
    defer regex.deinit();
    try std.testing.expect(regex.isMatch("Hello?"));
}

test "createRegExp wholeWord" {
    const allocator = std.testing.allocator;
    const regex = try createRegExp(allocator, "Hell", false, true, .{});
    defer regex.deinit();
    try std.testing.expect(!regex.isMatch("Hello"));
    try std.testing.expect(!regex.isMatch("eHell"));
    try std.testing.expect(regex.isMatch("Hell"));
    try std.testing.expect(regex.isMatch("e Hell ye"));
}

pub fn containsEnglishLetter(str: []const u8) bool {
    for (str) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z' => return true,
            else => continue,
        }
    }
    return false;
}

test "containsEnglishLetter" {
    try std.testing.expect(containsEnglishLetter("z"));
    try std.testing.expect(containsEnglishLetter("Z"));
    try std.testing.expect(!containsEnglishLetter("123"));
}

pub fn containsLF(str: []const u8) bool {
    return std.mem.indexOf(u8, str, "\n") != null;
}

test "containsLF" {
    try std.testing.expect(containsLF("Hello\nWorld"));
    try std.testing.expect(!containsLF("HelloWorld"));
}

pub fn countLines(str: []const u8) usize {
    var count: usize = 1;
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\r') {
            if (i + 1 < str.len and str[i + 1] == '\n') {
                i += 1;
            }
            count += 1;
        } else if (str[i] == '\n') {
            count += 1;
        }
        i += 1;
    }
    return count;
}

pub fn splitLines(allocator: Allocator, str: []const u8) !ArrayList([]const u8) {
    var lines = ArrayList([]const u8).init(allocator);
    var i: usize = 0;
    var lineStart: usize = 0;
    while (i < str.len) {
        if (str[i] == '\r') {
            try lines.append(str[lineStart..i]);
            if (i + 1 < str.len and str[i + 1] == '\n') {
                i += 1;
            }
            lineStart = i + 1;
        } else if (str[i] == '\n') {
            try lines.append(str[lineStart..i]);
            lineStart = i + 1;
        }

        i += 1;
    }
    if (lineStart <= i) {
        try lines.append(str[lineStart..i]);
    }
    return lines;
}

test "splitLines" {
    const allocator = std.testing.allocator;
    const input = "\n\r\n\r\r\n\r";
    const lines = try splitLines(allocator, input);
    defer lines.deinit();
    try std.testing.expectEqual(6, lines.items.len);
    for (lines.items) |line| {
        try std.testing.expectEqualStrings("", line);
    }
}

test "splitLines empty" {
    const allocator = std.testing.allocator;
    const input = "";
    const lines = try splitLines(allocator, input);
    defer lines.deinit();
    try std.testing.expectEqual(1, lines.items.len);
    try std.testing.expectEqualStrings("", lines.items[0]);
}

test "splitLines 1" {
    const allocator = std.testing.allocator;
    const input = "Hello";
    const lines = try splitLines(allocator, input);
    defer lines.deinit();
    try std.testing.expectEqual(1, lines.items.len);
    try std.testing.expectEqualStrings("Hello", lines.items[0]);
}

test "splitLines 2" {
    const allocator = std.testing.allocator;
    const input = "Hello\nWorld";
    const lines = try splitLines(allocator, input);
    defer lines.deinit();
    try std.testing.expectEqual(2, lines.items.len);
    try std.testing.expectEqualStrings("Hello", lines.items[0]);
    try std.testing.expectEqualStrings("World", lines.items[1]);
}

test "splitLines 2 empty" {
    const allocator = std.testing.allocator;
    const input = "\n";
    const lines = try splitLines(allocator, input);
    defer lines.deinit();
    try std.testing.expectEqual(2, lines.items.len);
    try std.testing.expectEqualStrings("", lines.items[0]);
    try std.testing.expectEqualStrings("", lines.items[1]);
}

test "countLines" {
    const input = "\n\r\n\r\r\n\r";
    try std.testing.expectEqual(6, countLines(input));
}

//

pub fn isNewlineCharacter(charCode: u8) bool {
    return charCode == '\r' or charCode == '\n';
}

pub fn getWordAtText(text: []const u8, offset: usize, wordDefinition: RegExp) !struct { usize, usize } {
    var lineStart = offset;
    while (lineStart > 0 and !isNewlineCharacter(text[lineStart - 1])) {
        lineStart -= 1;
    }
    const offsetInLine = offset - lineStart;

    // make a copy of the regex as to not keep the state
    // const flags = wordDefinition.ignoreCase ? 'gi' : 'g';
    // wordDefinition = new RegExp(wordDefinition.source, flags);

    var iter = wordDefinition.searchIterator(text, lineStart);
    var match = iter.next();
    while (match != null and match.?.index() + match.?.length() < offsetInLine) {
        match = iter.next();
    }
    if (match != null and match.?.index() <= offsetInLine) {
        return .{ match.?.index() + lineStart, match.?.length() };
    }
    return .{ offset, 0 };
}

// Returns the leading whitespace of the string.
// If the string contains only whitespaces, returns entire string
pub fn getLeadingWhitespace(str: []const u8, _start: ?usize, _end: ?usize) []const u8 {
    const start = _start orelse 0;
    const end = _end orelse str.len;

    for (start..end) |i| {
        const chCode = str[i];
        if (chCode != ' ' and chCode != '\t') {
            return str[start..i];
        }
    }
    return str[start..end];
}
