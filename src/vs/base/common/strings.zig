const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Utf8Iterator = std.unicode.Utf8Iterator;
const re = @import("../../../support/regexp.zig");
const RegExp = re.RegExp;
const RegExpOptions = re.Options;
const escapeRegExp = re.escapeRegExp;

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

/// Returns the leading whitespace of the given string, i.e. the longest
/// prefix consisting of spaces and tabs.
pub fn getLeadingWhitespace(str: []const u8) []const u8 {
    const index = firstNonWhitespaceIndex(str);
    return str[0 .. index orelse str.len];
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

/// Escapes `<`, `>` and `&` for HTML content.
pub fn escape(allocator: Allocator, html: []const u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    for (html) |ch| {
        switch (ch) {
            '<' => try result.appendSlice("&lt;"),
            '>' => try result.appendSlice("&gt;"),
            '&' => try result.appendSlice("&amp;"),
            else => try result.append(ch),
        }
    }
    return result.toOwnedSlice();
}

test "escape" {
    const allocator = std.testing.allocator;

    const result = try escape(allocator, "a < b > c & d");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a &lt; b &gt; c &amp; d", result);

    const unchanged = try escape(allocator, "plain");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("plain", unchanged);
}

/// Do a cheap trick to better support wrapping of wide characters, treat them
/// as 2 columns. See the ranges documented in `isFullWidthCharacter` of
/// `base/common/strings.ts`.
pub fn isFullWidthCharacter(char_code: u21) bool {
    return (char_code >= 0x2E80 and char_code <= 0xD7AF) or
        (char_code >= 0xF900 and char_code <= 0xFAFF) or
        (char_code >= 0xFF01 and char_code <= 0xFF5E) or
        (char_code >= 0xFFE0 and char_code <= 0xFFE6);
}

test "isFullWidthCharacter" {
    try std.testing.expect(isFullWidthCharacter(0x4E00)); // CJK Unified Ideographs
    try std.testing.expect(isFullWidthCharacter(0xAC00)); // Hangul Syllables
    try std.testing.expect(isFullWidthCharacter(0xFF01)); // Fullwidth '!'
    try std.testing.expect(!isFullWidthCharacter('a'));
    try std.testing.expect(!isFullWidthCharacter(0xE000)); // Private Use Area
    try std.testing.expect(!isFullWidthCharacter(0xFF00)); // Halfwidth and Fullwidth Forms (the prefix)
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
    borrowed: []const u8,

    pub const Empty = String{ .borrowed = "" };

    pub fn allocPrint(allocator: Allocator, comptime format: []const u8, args: anytype) !String {
        const str = try fmt.allocPrint(allocator, format, args);
        const arr = ArrayList(u8).fromOwnedSlice(allocator, str);
        return String.initOwned(arr);
    }

    pub fn initOwned(arr: ArrayList(u8)) String {
        return .{ .owned = arr };
    }

    pub fn initBorrowed(str: []const u8) String {
        return .{ .borrowed = str };
    }

    pub fn deinit(self: *String) void {
        switch (self.*) {
            .owned => |*list| {
                list.deinit();
                self.* = Empty;
            },
            .borrowed => {},
        }
    }

    pub fn ensureOwned(self: *String, allocator: Allocator) !void {
        switch (self.*) {
            .owned => {
                return;
            },
            .borrowed => |str| {
                var arr = ArrayList(u8).init(allocator);
                try arr.appendSlice(str);
                self.* = .{ .owned = arr };
            },
        }
    }

    pub fn items(self: *const String) []const u8 {
        switch (self.*) {
            .owned => |list| {
                return list.items;
            },
            .borrowed => |str| {
                return str;
            },
        }
    }

    fn isOwned(self: *const String) bool {
        return switch (self.*) {
            .owned => true,
            .borrowed => false,
        };
    }

    pub fn isEmpty(self: *const String) bool {
        return switch (self.*) {
            .owned => |list| list.items.len == 0,
            .borrowed => |str| str.len == 0,
        };
    }

    pub fn eql(self: *const String, other: String) bool {
        return std.mem.eql(u8, self.items(), other.items());
    }

    pub fn len(self: *const String) usize {
        return self.items().len;
    }

    pub fn substring(self: *const String, start: usize, end: usize) String {
        return String.initBorrowed(self.items()[start..end]);
    }

    // transfer ownership to the caller
    pub fn move(self: *String) String {
        switch (self.*) {
            .owned => |list| {
                self.* = .initBorrowed(list.items);
                return String.initOwned(list);
            },
            .borrowed => |str| {
                return String.initBorrowed(str);
            },
        }
    }

    pub fn isBasicASCII_(self: *const String) bool {
        return isBasicASCII(self.items());
    }

    pub fn containsRTL_(self: *const String) bool {
        return containsRTL(self.items());
    }

    pub fn containsUnusualLineTerminators_(self: *const String) bool {
        return containsUnusualLineTerminators(self.items());
    }
};

test "String.initBorrowed" {
    var str = String.initBorrowed("Hello");
    defer str.deinit();
    try std.testing.expectEqualStrings("Hello", str.items());
}

test "String.initOwned" {
    const allocator = std.testing.allocator;
    var arr = ArrayList(u8).init(allocator);
    try arr.appendSlice("Hello");
    var str = String.initOwned(arr);
    defer str.deinit();
    try std.testing.expectEqualStrings("Hello", str.items());
}

test "String.allocPrint" {
    const allocator = std.testing.allocator;
    var str = try String.allocPrint(allocator, "Hello {d}", .{123});
    defer str.deinit();
    try std.testing.expectEqualStrings("Hello 123", str.items());
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
    try std.testing.expectEqualStrings("Hello", str2.items());
}

test "String.move borrowed" {
    var str = String.initBorrowed("Hello");
    defer str.deinit();

    var str2 = str.move();
    defer str2.deinit();

    try std.testing.expectEqualStrings("Hello", str2.items());
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

pub fn createRegExp(allocator: Allocator, searchString: []const u8, isRegex: bool, wholeWord: bool, options: RegExpOptions) !RegExp {
    if (searchString.len == 0) {
        unreachable;
    }

    if (isRegex and !wholeWord) {
        return try RegExp.init(searchString, options);
    }

    var escapedSearchString = if (isRegex) try initArrayList(allocator, searchString) else try escapeRegExp(allocator, searchString);
    defer escapedSearchString.deinit();

    if (wholeWord) {
        try escapedSearchString.insertSlice(0, "\\b");
        try escapedSearchString.appendSlice("\\b");
    }

    return RegExp.init(escapedSearchString.items, options);
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

/// Splits `str` on `\r\n`, `\r`, and `\n` boundaries. The returned slices
/// point into `str`; the returned list must be deinitialized by the caller.
pub fn splitLines(allocator: Allocator, str: []const u8) !ArrayList([]const u8) {
    var result = ArrayList([]const u8).init(allocator);
    errdefer result.deinit();

    var start: usize = 0;
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\n') {
            try result.append(str[start..i]);
            start = i + 1;
        } else if (str[i] == '\r') {
            try result.append(str[start..i]);
            if (i + 1 < str.len and str[i + 1] == '\n') {
                i += 1;
            }
            start = i + 1;
        }
    }
    try result.append(str[start..]);
    return result;
}

test "splitLines" {
    const allocator = std.testing.allocator;

    var lines = try splitLines(allocator, "a\nb\r\nc\rd");
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0]);
    try std.testing.expectEqualStrings("b", lines.items[1]);
    try std.testing.expectEqualStrings("c", lines.items[2]);
    try std.testing.expectEqualStrings("d", lines.items[3]);

    var empty = try splitLines(allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.items.len);
    try std.testing.expectEqualStrings("", empty.items[0]);

    var trailing = try splitLines(allocator, "a\n");
    defer trailing.deinit();
    try std.testing.expectEqual(@as(usize, 2), trailing.items.len);
    try std.testing.expectEqualStrings("", trailing.items[1]);
}

/// Like `splitLines`, but each returned line keeps its trailing separator.
/// The returned strings are owned by the caller.
pub fn splitLinesIncludeSeparators(allocator: Allocator, str: []const u8) !ArrayList([]u8) {
    var result = ArrayList([]u8).init(allocator);
    errdefer {
        for (result.items) |line| allocator.free(line);
        result.deinit();
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\n') {
            try result.append(try allocator.dupe(u8, str[start .. i + 1]));
            start = i + 1;
        } else if (str[i] == '\r') {
            var end = i + 1;
            if (i + 1 < str.len and str[i + 1] == '\n') {
                i += 1;
                end += 1;
            }
            try result.append(try allocator.dupe(u8, str[start..end]));
            start = i + 1;
        }
    }
    try result.append(try allocator.dupe(u8, str[start..]));
    return result;
}

test "splitLinesIncludeSeparators" {
    const allocator = std.testing.allocator;
    var lines = try splitLinesIncludeSeparators(allocator, "a\nb\r\nc\rd");
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit();
    }

    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expectEqualStrings("a\n", lines.items[0]);
    try std.testing.expectEqualStrings("b\r\n", lines.items[1]);
    try std.testing.expectEqualStrings("c\r", lines.items[2]);
    try std.testing.expectEqualStrings("d", lines.items[3]);
}

/// Returns the length of the common prefix of the two strings.
pub fn commonPrefixLength(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) {
            return i;
        }
    }
    return len;
}

test "commonPrefixLength" {
    try std.testing.expectEqual(@as(usize, 2), commonPrefixLength("abc", "abd"));
    try std.testing.expectEqual(@as(usize, 3), commonPrefixLength("abc", "abc"));
    try std.testing.expectEqual(@as(usize, 0), commonPrefixLength("", "abc"));
    try std.testing.expectEqual(@as(usize, 2), commonPrefixLength("ab", "abc"));
}

/// Returns the length of the common suffix of the two strings.
pub fn commonSuffixLength(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[a.len - 1 - i] != b[b.len - 1 - i]) {
            return i;
        }
    }
    return len;
}

test "commonSuffixLength" {
    try std.testing.expectEqual(@as(usize, 2), commonSuffixLength("abc", "xbc"));
    try std.testing.expectEqual(@as(usize, 3), commonSuffixLength("abc", "abc"));
    try std.testing.expectEqual(@as(usize, 0), commonSuffixLength("", "abc"));
    try std.testing.expectEqual(@as(usize, 2), commonSuffixLength("abc", "bc"));
}

test "getLeadingWhitespace" {
    try std.testing.expectEqualStrings("", getLeadingWhitespace(""));
    try std.testing.expectEqualStrings("", getLeadingWhitespace("abc"));
    try std.testing.expectEqualStrings("  ", getLeadingWhitespace("  abc"));
    try std.testing.expectEqualStrings("\t \t", getLeadingWhitespace("\t \tabc"));
    try std.testing.expectEqualStrings("   ", getLeadingWhitespace("   "));
}
