//! TUI-local stand-in for a language hover provider.
//!
//! VS Code receives hover contents from language extensions registered in the
//! language-feature registry. The TUI ships grammars but no extensions, so this
//! provider reports the word under the cursor and its language/token type. It
//! exercises the ported hover contribution; it is not upstream behavior and is
//! documented as TUI-specific in `README.md`.
//!
//! The scratch arena is reset on every call. Only one provider is registered
//! today, so the hover contribution copies the result before the next call.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const languages = @import("../vs/editor/common/languages.zig");
const Hover = languages.Hover;
const HoverProvider = languages.HoverProvider;
const IMarkdownString = languages.IMarkdownString;
const token_utils = @import("../vs/editor/common/tokens/lineTokens.zig");
const CancellationToken = @import("../vs/base/common/cancellation.zig").CancellationToken;

pub const TuiHoverProvider = struct {
    allocator: Allocator,
    scratch: std.heap.ArenaAllocator,
    contents: [1]IMarkdownString = undefined,

    pub fn init(allocator: Allocator) TuiHoverProvider {
        return .{
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *TuiHoverProvider) void {
        self.scratch.deinit();
    }

    pub fn interface(self: *TuiHoverProvider) HoverProvider {
        return .{ .context = self, .provide_hover = provideHover };
    }

    pub fn provideHover(
        context: *anyopaque,
        model: *TextModel,
        position: Position,
        _: CancellationToken,
        _: ?*const languages.HoverContext,
    ) anyerror!?Hover {
        const self: *TuiHoverProvider = @ptrCast(@alignCast(context));
        _ = self.scratch.reset(.retain_capacity);

        var word = model.getWordAtPosition(position) orelse return null;
        defer word.deinit();
        if (word.word.items.len == 0) return null;

        const language_id = model.getLanguageIdAtPosition(position.lineNumber, position.column);
        const token_type = token_utils.getStandardTokenTypeAtPosition(model, position) catch null;

        const allocator = self.scratch.allocator();
        var details = std.array_list.Managed(u8).init(allocator);
        if (language_id.len > 0) try details.appendSlice(language_id);
        if (token_type) |kind| {
            if (details.items.len > 0) try details.appendSlice(" · ");
            try details.appendSlice(@tagName(kind));
        }
        const value = try std.fmt.allocPrint(allocator, "**`{s}`**\n\n{s}", .{ word.word.items, details.items });
        self.contents[0] = .{ .value = value };
        return Hover{
            .contents = &self.contents,
            .range = Range.init(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn),
        };
    }
};

test "tui hover provider: reports the word under the cursor" {
    const testing = std.testing;
    const TestModel = @import("../vs/editor/test/common/port/testSupport.zig").TestModel;

    var ctx = try TestModel.init(testing.allocator, "const value = 42;", "zig");
    defer ctx.deinit();

    var provider = TuiHoverProvider.init(testing.allocator);
    defer provider.deinit();

    const hover = try TuiHoverProvider.provideHover(&provider, ctx.model, Position.init(1, 7), .None, null);
    try testing.expect(hover != null);
    try testing.expect(hover.?.range != null);
    try testing.expectEqual(@as(usize, 7), hover.?.range.?.startColumn);
    try testing.expectEqual(@as(usize, 12), hover.?.range.?.endColumn);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents[0].value, "value") != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents[0].value, "zig") != null);

    // `getWordAtPosition` also matches at a word's end column, as upstream does.
    const at_word_end = try TuiHoverProvider.provideHover(&provider, ctx.model, Position.init(1, 6), .None, null);
    try testing.expect(at_word_end != null);
}
