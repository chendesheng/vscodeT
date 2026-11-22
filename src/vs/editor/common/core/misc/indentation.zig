// Port of `src/vs/editor/common/core/misc/indentation.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const CursorColumns = @import("../cursorColumns.zig").CursorColumns;

fn normalizeIndentationFromWhitespace(allocator: Allocator, text: []const u8, indent_size: usize, insert_spaces: bool) ![]const u8 {
    var spaces_count: usize = 0;
    for (text) |ch| {
        if (ch == '\t') {
            spaces_count = CursorColumns.nextIndentTabStop(spaces_count, indent_size);
        } else {
            spaces_count += 1;
        }
    }

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    if (!insert_spaces) {
        const tabs_count = spaces_count / indent_size;
        spaces_count = spaces_count % indent_size;
        for (0..tabs_count) |_| try result.append('\t');
    }
    try result.appendNTimes(' ', spaces_count);
    return try result.toOwnedSlice();
}

/// Normalize the leading whitespace of `text` to the configured indentation.
pub fn normalizeIndentation(allocator: Allocator, text: []const u8, indent_size: usize, insert_spaces: bool) ![]const u8 {
    var first_non_whitespace: usize = text.len;
    for (text, 0..) |ch, i| {
        if (ch != ' ' and ch != '\t') {
            first_non_whitespace = i;
            break;
        }
    }

    const leading = try normalizeIndentationFromWhitespace(allocator, text[0..first_non_whitespace], indent_size, insert_spaces);
    defer allocator.free(leading);

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    try result.appendSlice(leading);
    try result.appendSlice(text[first_non_whitespace..]);
    return try result.toOwnedSlice();
}

test "indentation: normalize tabs and spaces" {
    const allocator = std.testing.allocator;
    const spaces = try normalizeIndentation(allocator, "\tfoo", 4, true);
    defer allocator.free(spaces);
    try std.testing.expectEqualStrings("    foo", spaces);

    const tabs = try normalizeIndentation(allocator, "      foo", 4, false);
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("\t  foo", tabs);

    // Upstream's firstNonWhitespaceIndex ignores only spaces and tabs, so a
    // leading CR/LF is preserved verbatim.
    const crlf = try normalizeIndentation(allocator, "\r\n  foo", 4, true);
    defer allocator.free(crlf);
    try std.testing.expectEqualStrings("\r\n  foo", crlf);
}
