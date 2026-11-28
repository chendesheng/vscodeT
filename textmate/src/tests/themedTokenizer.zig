// Port of `vscode-textmate/src/tests/themedTokenizer.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const main = @import("../main.zig");
const encoded = @import("../encodedTokenAttributes.zig");
const onigLib = @import("../onigLib.zig");
const theme = @import("../theme.zig");
const Allocator = std.mem.Allocator;

pub const ThemedToken = struct {
    content: []const u8,
    color: []const u8,
};

pub fn tokenizeWithTheme(
    allocator: Allocator,
    color_map: []const []const u8,
    file_contents: []const u8,
    grammar: *main.IGrammar,
) ![]ThemedToken {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    try splitLines(allocator, file_contents, &lines);

    var tokens: std.ArrayList(ThemedToken) = .empty;
    errdefer tokens.deinit(allocator);

    var rule_stack: ?*main.StateStack = null;
    for (lines.items) |line| {
        const result = try grammar.tokenizeLine2(std.testing.io, line, rule_stack, 0);
        const line_string = try onigLib.OnigString.init(std.testing.allocator, line);
        defer line_string.deinit();

        var j: usize = 0;
        const token_count = result.tokens.len / 2;
        while (j < token_count) : (j += 1) {
            const start_index = result.tokens[2 * j];
            const next_start_index = if (j + 1 < token_count) result.tokens[2 * j + 2] else line_string.utf16_len;
            const content = line_string.sliceUtf16(start_index, next_start_index);
            if (content.len == 0) continue;
            const metadata = result.tokens[2 * j + 1];
            const foreground = encoded.getForeground(metadata);
            if (foreground >= color_map.len) return error.MissingColor;
            try tokens.append(allocator, .{
                .content = try allocator.dupe(u8, content),
                .color = try allocator.dupe(u8, color_map[foreground]),
            });
        }

        rule_stack = result.rule_stack;
    }

    return tokens.toOwnedSlice(allocator);
}

fn splitLines(allocator: Allocator, content: []const u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < content.len) {
        if (content[index] == '\r' or content[index] == '\n') {
            try out.append(allocator, content[start..index]);
            if (content[index] == '\r' and index + 1 < content.len and content[index + 1] == '\n') index += 1;
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    try out.append(allocator, content[start..]);
}
