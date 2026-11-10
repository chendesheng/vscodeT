// Port of `src/vs/base/common/search.ts`.
//
// Case preservation needs Unicode case mapping upstream (`toUpperCase` /
// `toLowerCase`). The Zig port maps ASCII letters and leaves other codepoints
// unchanged, which matches the upstream tests and the replace strings the
// editor produces; non-ASCII case folding is a documented limitation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn buildReplaceStringWithCasePreserved(
    allocator: Allocator,
    matches: ?[]const []const u8,
    pattern: []const u8,
) ![]u8 {
    const match: []const u8 = if (matches) |values|
        (if (values.len > 0) values[0] else "")
    else
        "";

    if (match.len == 0) {
        return allocator.dupe(u8, pattern);
    }

    const contains_hyphens = validateSpecificSpecialCharacter(match, pattern, '-');
    const contains_underscores = validateSpecificSpecialCharacter(match, pattern, '_');
    if (contains_hyphens and !contains_underscores) {
        return buildReplaceStringForSpecificSpecialCharacter(allocator, match, pattern, '-');
    } else if (!contains_hyphens and contains_underscores) {
        return buildReplaceStringForSpecificSpecialCharacter(allocator, match, pattern, '_');
    }

    if (isAllUpperCase(match)) {
        return mapAll(allocator, pattern, .upper);
    }
    if (isAllLowerCase(match)) {
        return mapAll(allocator, pattern, .lower);
    }
    if (containsUppercaseCharacter(match[0])) {
        return mapFirst(allocator, pattern, .upper);
    }
    if (!containsUppercaseCharacter(match[0])) {
        return mapFirst(allocator, pattern, .lower);
    }
    return allocator.dupe(u8, pattern);
}

const Case = enum { upper, lower };

fn validateSpecificSpecialCharacter(match: []const u8, pattern: []const u8, special: u8) bool {
    const in_match = std.mem.indexOfScalar(u8, match, special) != null;
    const in_pattern = std.mem.indexOfScalar(u8, pattern, special) != null;
    return in_match and in_pattern and countSegments(match, special) == countSegments(pattern, special);
}

fn buildReplaceStringForSpecificSpecialCharacter(
    allocator: Allocator,
    match: []const u8,
    pattern: []const u8,
    special: u8,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    const segment_count = countSegments(pattern, special);
    var index: usize = 0;
    while (index < segment_count) : (index += 1) {
        const pattern_segment = segmentAt(pattern, special, index);
        const match_segment = segmentAt(match, special, index);
        const replaced = try buildPreservedSegment(allocator, match_segment, pattern_segment);
        defer allocator.free(replaced);
        try result.appendSlice(allocator, replaced);
        try result.append(allocator, special);
    }

    if (result.items.len == 0) return result.toOwnedSlice(allocator);
    _ = result.pop();
    return result.toOwnedSlice(allocator);
}

/// Splits one segment and recurses, mirroring upstream's
/// `buildReplaceStringWithCasePreserved([segment], patternSegment)`.
fn buildPreservedSegment(allocator: Allocator, match: []const u8, pattern: []const u8) ![]u8 {
    if (match.len == 0) return allocator.dupe(u8, pattern);
    if (isAllUpperCase(match)) return mapAll(allocator, pattern, .upper);
    if (isAllLowerCase(match)) return mapAll(allocator, pattern, .lower);
    if (containsUppercaseCharacter(match[0])) return mapFirst(allocator, pattern, .upper);
    if (!containsUppercaseCharacter(match[0])) return mapFirst(allocator, pattern, .lower);
    return allocator.dupe(u8, pattern);
}

fn countSegments(text: []const u8, separator: u8) usize {
    var count: usize = 1;
    for (text) |byte| {
        if (byte == separator) count += 1;
    }
    return count;
}

fn segmentAt(text: []const u8, separator: u8, index: usize) []const u8 {
    var current: usize = 0;
    var start: usize = 0;
    for (text, 0..) |byte, offset| {
        if (byte != separator) continue;
        if (current == index) return text[start..offset];
        current += 1;
        start = offset + 1;
    }
    return text[start..];
}

fn isAllUpperCase(text: []const u8) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        const end = @min(offset + length, text.len);
        if (end == offset + 1 and std.ascii.isLower(text[offset])) return false;
        offset = end;
    }
    return true;
}

fn isAllLowerCase(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn containsUppercaseCharacter(byte: u8) bool {
    return std.ascii.isUpper(byte);
}

fn mapAll(allocator: Allocator, text: []const u8, case: Case) ![]u8 {
    const result = try allocator.dupe(u8, text);
    for (result) |*byte| {
        byte.* = switch (case) {
            .upper => std.ascii.toUpper(byte.*),
            .lower => std.ascii.toLower(byte.*),
        };
    }
    return result;
}

fn mapFirst(allocator: Allocator, text: []const u8, case: Case) ![]u8 {
    const result = try allocator.dupe(u8, text);
    if (result.len == 0) return result;
    result[0] = switch (case) {
        .upper => std.ascii.toUpper(result[0]),
        .lower => std.ascii.toLower(result[0]),
    };
    return result;
}

test "search: case preserved replace strings" {
    const allocator = std.testing.allocator;

    const Expected = struct { match: []const []const u8, pattern: []const u8, expected: []const u8 };
    const cases = [_]Expected{
        .{ .match = &.{"abc"}, .pattern = "Def", .expected = "def" },
        .{ .match = &.{"Abc"}, .pattern = "Def", .expected = "Def" },
        .{ .match = &.{"ABC"}, .pattern = "Def", .expected = "DEF" },
        .{ .match = &.{ "abc", "Abc" }, .pattern = "Def", .expected = "def" },
        .{ .match = &.{ "Abc", "abc" }, .pattern = "Def", .expected = "Def" },
        .{ .match = &.{ "ABC", "abc" }, .pattern = "Def", .expected = "DEF" },
        .{ .match = &.{ "aBc", "abc" }, .pattern = "Def", .expected = "def" },
        .{ .match = &.{"AbC"}, .pattern = "Def", .expected = "Def" },
        .{ .match = &.{"aBC"}, .pattern = "Def", .expected = "def" },
        .{ .match = &.{"aBc"}, .pattern = "DeF", .expected = "deF" },
        .{ .match = &.{"Foo-Bar"}, .pattern = "newfoo-newbar", .expected = "Newfoo-Newbar" },
        .{ .match = &.{"Foo-Bar-Abc"}, .pattern = "newfoo-newbar-newabc", .expected = "Newfoo-Newbar-Newabc" },
        .{ .match = &.{"Foo-Bar-abc"}, .pattern = "newfoo-newbar", .expected = "Newfoo-newbar" },
        .{ .match = &.{"foo-Bar"}, .pattern = "newfoo-newbar", .expected = "newfoo-Newbar" },
        .{ .match = &.{"foo-BAR"}, .pattern = "newfoo-newbar", .expected = "newfoo-NEWBAR" },
        .{ .match = &.{"foO-BAR"}, .pattern = "NewFoo-NewBar", .expected = "newFoo-NEWBAR" },
        .{ .match = &.{"Foo_Bar"}, .pattern = "newfoo_newbar", .expected = "Newfoo_Newbar" },
        .{ .match = &.{"Foo_Bar_Abc"}, .pattern = "newfoo_newbar_newabc", .expected = "Newfoo_Newbar_Newabc" },
        .{ .match = &.{"Foo_Bar_abc"}, .pattern = "newfoo_newbar", .expected = "Newfoo_newbar" },
        .{ .match = &.{"Foo_Bar-abc"}, .pattern = "newfoo_newbar-abc", .expected = "Newfoo_newbar-abc" },
        .{ .match = &.{"foo_Bar"}, .pattern = "newfoo_newbar", .expected = "newfoo_Newbar" },
        .{ .match = &.{"Foo_BAR"}, .pattern = "newfoo_newbar", .expected = "Newfoo_NEWBAR" },
    };

    for (cases) |item| {
        const actual = try buildReplaceStringWithCasePreserved(allocator, item.match, item.pattern);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(item.expected, actual);
    }
}
