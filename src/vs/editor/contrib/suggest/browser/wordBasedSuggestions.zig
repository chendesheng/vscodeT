// Terminal word provider for the suggest contribution.
//
// This is the default provider until language completion providers are wired
// into the TUI. It scans the current document for identifier-like words that
// start with the word prefix before the caret, case-insensitively.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const completion = @import("../../../common/languages/completion.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

const max_lines: usize = 500;
const max_words: usize = 10_000;
const max_items: usize = 200;

const wordStartColumn = @import("./suggestModel.zig").wordStartColumn;

pub const WordBasedCompletionProvider = struct {
    pub fn init() WordBasedCompletionProvider {
        return .{};
    }

    pub fn interface(self: *WordBasedCompletionProvider) completion.CompletionItemProvider {
        return .{
            .context = self,
            .provide_completion_items = provide,
        };
    }

    fn provide(
        _: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        _: completion.CompletionContext,
        token: CancellationToken,
    ) anyerror!completion.CompletionList {
        var current_line = try model.getLineContent(position.lineNumber);
        defer current_line.deinit();
        const start_column = wordStartColumn(current_line.items, position.column);
        const prefix = current_line.items[start_column - 1 .. position.column - 1];
        if (prefix.len == 0) return .{};

        const range = Range.init(position.lineNumber, start_column, position.lineNumber, position.column);
        const line_count = model.getLineCount();
        const start_line = if (line_count > max_lines) line_count - max_lines + 1 else 1;

        var items = std.array_list.Managed(completion.CompletionItem).init(allocator);
        var seen = std.StringHashMap(void).init(allocator);
        var scanned: usize = 0;

        var line_number = start_line;
        while (line_number <= line_count and items.items.len < max_items) : (line_number += 1) {
            if (token.isCancellationRequested()) break;
            var line = try model.getLineContent(line_number);
            defer line.deinit();

            var i: usize = 0;
            while (i < line.items.len and items.items.len < max_items) {
                if (!isWordStart(line.items[i])) {
                    i += 1;
                    continue;
                }
                const start = i;
                i += 1;
                while (i < line.items.len and isWordPart(line.items[i])) i += 1;
                const word = line.items[start..i];
                scanned += 1;
                if (scanned > max_words) break;

                if (word.len <= prefix.len) continue;
                if (!std.ascii.eqlIgnoreCase(word[0..prefix.len], prefix)) continue;

                var key_buf: [256]u8 = undefined;
                if (word.len > key_buf.len) continue;
                const key = std.ascii.lowerString(key_buf[0..word.len], word);
                if (seen.contains(key)) continue;
                const owned_key = try allocator.dupe(u8, key);
                try seen.put(owned_key, {});
                const label = try allocator.dupe(u8, word);
                try items.append(.{
                    .label = label,
                    .kind = .Text,
                    .sort_text = label,
                    .insert_text = label,
                    .range = range,
                });
            }
            if (scanned > max_words) break;
        }

        return .{ .items = try items.toOwnedSlice() };
    }
};

fn isWordStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isWordPart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "wordBasedSuggestions: word character classification" {
    try std.testing.expect(isWordStart('a'));
    try std.testing.expect(isWordStart('_'));
    try std.testing.expect(!isWordStart('1'));
    try std.testing.expect(isWordPart('1'));
    try std.testing.expect(!isWordPart('-'));
}
