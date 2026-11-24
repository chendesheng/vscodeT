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

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const Hover = languages.Hover;
const HoverProvider = languages.HoverProvider;
const IMarkdownString = languages.IMarkdownString;
const token_utils = @import("../../../common/tokens/lineTokens.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const json_language = @import("../../../../workbench/services/language/common/jsonLanguageClient.zig");

pub const TuiHoverProvider = struct {
    allocator: Allocator,
    scratch: std.heap.ArenaAllocator,
    contents: [1]IMarkdownString = undefined,
    json_document: ?*const json_language.Document = null,
    model: ?*TextModel = null,

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

    pub fn setModel(self: *TuiHoverProvider, model: *TextModel) void {
        self.model = model;
    }

    pub fn provideHover(
        context: *anyopaque,
        model: *TextModel,
        position: Position,
        _: CancellationToken,
        _: ?*const languages.HoverContext,
    ) anyerror!?Hover {
        const self: *TuiHoverProvider = @ptrCast(@alignCast(context));
        if (self.model) |owned_model| {
            if (model != owned_model) return null;
        }
        _ = self.scratch.reset(.retain_capacity);
        const allocator = self.scratch.allocator();

        if (self.json_document) |document| {
            if (document.uri) |uri| {
                const client = document.client.?;
                if (client.hover(allocator, uri, @intCast(position.lineNumber - 1), @intCast(position.column - 1)) catch null) |json_hover| {
                    if (json_hover.text.len > 0) {
                        self.contents[0] = .{ .value = json_hover.text };
                        const range = model.getWordAtPosition(position);
                        return Hover{
                            .contents = &self.contents,
                            .range = if (range) |word_value| blk: {
                                var word = word_value;
                                defer word.deinit();
                                break :blk Range.init(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn);
                            } else null,
                        };
                    }
                }
            }
        }

        var word = model.getWordAtPosition(position) orelse return null;
        defer word.deinit();
        if (word.word.items.len == 0) return null;

        const language_id = model.getLanguageIdAtPosition(position.lineNumber, position.column);
        const token_type = token_utils.getStandardTokenTypeAtPosition(model, position) catch null;

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
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

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

test "tui hover provider: forwards JSON hover from a local schema" {
    std.Io.Dir.cwd().access(@import("../../../../base/common/timeCompat.zig").io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const testing = std.testing;
    const allocator = testing.allocator;
    const client = try json_language.Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(@import("../../../../base/common/timeCompat.zig").io, .{ .sub_path = "schema.json", .data =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "The name field" }
        \\  }
        \\}
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPathFile(@import("../../../../base/common/timeCompat.zig").io, "schema.json", &path_buffer);
    const schema_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path_buffer[0..path_length]});
    defer allocator.free(schema_uri);
    const text = try std.fmt.allocPrint(allocator, "{{\n  \"$schema\": \"{s}\",\n  \"name\": \"demo\"\n}}\n", .{schema_uri});
    defer allocator.free(text);

    const uri = "file:///tmp/json-hover-provider.json";
    var doc_arena = std.heap.ArenaAllocator.init(allocator);
    defer doc_arena.deinit();
    try client.didOpen(doc_arena.allocator(), uri, "json", text);

    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(allocator, text, "json");
    defer ctx.deinit();

    var provider = TuiHoverProvider.init(allocator);
    defer provider.deinit();
    const document = json_language.Document{ .client = client, .uri = uri };
    provider.json_document = &document;

    const hover = try TuiHoverProvider.provideHover(&provider, ctx.model, Position.init(3, 4), .None, null);
    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents[0].value, "The name field") != null);
}
