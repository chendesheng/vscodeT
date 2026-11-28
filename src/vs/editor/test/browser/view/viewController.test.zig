// Port of the bracket-content-selection cases of
// `src/vs/editor/test/browser/view/viewController.test.ts`.
//
// Terminal adaptation: `dispatchMouse` routes its navigation commands to a
// recording sink instead of the browser `CoreNavigationCommands`/`ViewModel`;
// the double-click decision logic itself is the upstream code.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const view_controller = @import("../../../browser/view/viewController.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const browser_config = @import("../../../browser/config/editorConfiguration.zig");
const language_configuration = @import("../../../common/languages/languageConfiguration.zig");
const test_support = @import("../../common/port/testSupport.zig");
const test_stubs = @import("../../common/viewModelTestStubs.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const Position = @import("../../../common/core/position.zig").Position;
const TokenizationRegistry = @import("../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const languages = @import("../../../common/languages.zig");
const null_tokenize = @import("../../../common/languages/nullTokenize.zig");
const line_tokens = @import("../../../common/tokens/lineTokens.zig");
const encoded = @import("../../../common/encodedTokenAttributes.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;

const ViewController = view_controller.ViewController;
const INavigationCommands = view_controller.INavigationCommands;
const IMouseDispatchData = view_controller.IMouseDispatchData;

/// Tokenizes every line as one `Other` token with balanced brackets so the
/// model's bracket-pair part can match `{`, `[`, `(` without a language
/// tokenizer.
const BalancedBracketSupport = struct {
    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!languages.IState {
        return null_tokenize.NullState;
    }

    fn tokenizeEncoded(_: *anyopaque, _: std.Io, allocator: Allocator, line: []const u8, _: bool, state: languages.IState) anyerror!languages.EncodedTokenizationResult {
        var tokens = std.array_list.Managed(line_tokens.TokenPacked).init(allocator);
        errdefer tokens.deinit();

        var offset: usize = 0;
        var start: usize = 0;
        while (offset < line.len) {
            const character = line[offset];
            if (character != '"' and character != '\'' and character != '`') {
                offset += 1;
                continue;
            }
            if (offset > start) try appendToken(&tokens, start, line[start..offset], .Other, true);
            var end = offset + 1;
            while (end < line.len and line[end] != character) end += 1;
            if (end < line.len) end += 1;
            try appendToken(&tokens, offset, line[offset..end], .String, false);
            offset = end;
            start = end;
        }
        if (start < line.len) try appendToken(&tokens, start, line[start..], .Other, true);
        return .{ .tokens = try tokens.toOwnedSlice(), .endState = state };
    }

    fn appendToken(tokens: *std.array_list.Managed(line_tokens.TokenPacked), start_offset: usize, text: []const u8, token_type: encoded.StandardTokenType, balanced: bool) !void {
        _ = text;
        var metadata = encoded.TokenMetadata.default;
        metadata.tokenType = token_type;
        metadata.balancedBrackets = balanced;
        // `EncodedTokenizationResult` stores the start offset of each token;
        // `LineTokens.convertToEndOffset` shifts them into end offsets.
        try tokens.append(.{ .endOffset = @intCast(start_offset), .metadata = metadata });
    }

    fn interface(self: *BalancedBracketSupport) languages.ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

pub const TokenSpan = struct {
    start_index: usize,
    token_type: encoded.StandardTokenType,
};

/// Emits the token spans the upstream string tests specify. `EncodedTokenizationResult`
/// stores token start offsets, so each span contributes its start index.
const SpanSupport = struct {
    spans: []const TokenSpan,

    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!languages.IState {
        return null_tokenize.NullState;
    }

    fn tokenizeEncoded(context: *anyopaque, _: std.Io, allocator: Allocator, line: []const u8, _: bool, state: languages.IState) anyerror!languages.EncodedTokenizationResult {
        const self: *SpanSupport = @ptrCast(@alignCast(context));
        var tokens = std.array_list.Managed(line_tokens.TokenPacked).init(allocator);
        errdefer tokens.deinit();
        for (self.spans) |span| {
            if (span.start_index >= line.len and tokens.items.len > 0) continue;
            var metadata = encoded.TokenMetadata.default;
            metadata.tokenType = span.token_type;
            metadata.balancedBrackets = span.token_type != .String;
            try tokens.append(.{ .endOffset = @intCast(span.start_index), .metadata = metadata });
        }
        return .{ .tokens = try tokens.toOwnedSlice(), .endState = state };
    }

    fn interface(self: *SpanSupport) languages.ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

const Sink = struct {
    selection: ?Selection = null,
    word_select_position: ?Position = null,
    model: ?*@import("../../../common/model/textModel.zig").TextModel = null,

    fn setSelection(context: *anyopaque, selection: Selection) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.selection = selection;
    }
    fn wordSelect(context: *anyopaque, pos: Position) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.word_select_position = pos;
        const model = self.model orelse return;
        self.selection = wordSelectionAt(model, pos) catch null;
    }

    fn wordSelectionAt(model: *@import("../../../common/model/textModel.zig").TextModel, pos: Position) !?Selection {
        var content = try model.getLineContent(pos.lineNumber);
        defer content.deinit();
        const bytes = content.items;
        if (bytes.len == 0) return null;
        var index = (pos.column - 1);
        if (index >= bytes.len) index = bytes.len - 1;
        if (!isWordByte(bytes[index])) return null;
        var start = index;
        while (start > 0 and isWordByte(bytes[start - 1])) start -= 1;
        var end = index + 1;
        while (end < bytes.len and isWordByte(bytes[end])) end += 1;
        return Selection.init(pos.lineNumber, start + 1, pos.lineNumber, end + 1);
    }

    fn isWordByte(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
    }
    fn position(_: *anyopaque, _: Position) void {}
    fn columnSelect(_: *anyopaque, _: Position, _: usize, _: bool) void {}
    fn createCursor(_: *anyopaque, _: Position, _: bool) void {}
    fn selectAll(_: *anyopaque) void {}

    fn interface(self: *Sink) INavigationCommands {
        return .{
            .context = self,
            .set_selection = setSelection,
            .move_to = position,
            .move_to_select = position,
            .column_select = columnSelect,
            .create_cursor = createCursor,
            .last_cursor_move_to_select = position,
            .word_select = wordSelect,
            .word_select_drag = position,
            .last_cursor_word_select = position,
            .line_select = position,
            .line_select_drag = position,
            .last_cursor_line_select = position,
            .last_cursor_line_select_drag = position,
            .select_all = selectAll,
        };
    }
};

const Harness = struct {
    allocator: Allocator,
    model: test_support.TestModel,
    tokenization_support: BalancedBracketSupport = .{},
    span_support: ?SpanSupport = null,
    brackets: [3]language_configuration.CharacterPair = .{
        .{ "{", "}" },
        .{ "[", "]" },
        .{ "(", ")" },
    },
    language_config: language_configuration.LanguageConfiguration = undefined,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    sink: Sink,
    controller: ViewController,

    fn init(self: *Harness, allocator: Allocator, text: []const u8) !void {
        try self.initWithSpans(allocator, text, null);
    }

    fn initWithSpans(self: *Harness, allocator: Allocator, text: []const u8, spans: ?[]const TokenSpan) !void {
        self.allocator = allocator;
        self.tokenization_support = .{};
        if (spans) |token_spans| {
            self.span_support = .{ .spans = token_spans };
            try TokenizationRegistry.instance.register("vcLang", self.span_support.?.interface());
        } else {
            try TokenizationRegistry.instance.register("vcLang", self.tokenization_support.interface());
        }
        errdefer TokenizationRegistry.instance.unregister("vcLang");
        self.model = try test_support.TestModel.init(allocator, text, "vcLang");
        errdefer self.model.deinit();

        self.brackets = .{
            .{ "{", "}" },
            .{ "[", "]" },
            .{ "(", ")" },
        };
        self.language_config = language_configuration.empty();
        self.language_config.brackets = &self.brackets;
        try self.model.languageService.registerLanguageConfiguration("vcLang", self.language_config);

        self.options = browser_config.ComputedEditorOptions.init();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.sink = .{ .model = self.model.model };
        self.controller = ViewController.init(
            &self.configuration,
            self.view_model.interface(),
            self.model.model,
            self.sink.interface(),
        );
    }

    fn deinit(self: *Harness) void {
        TokenizationRegistry.instance.unregister("vcLang");
        self.model.deinit();
    }

    fn doubleClickAt(self: *Harness, position: Position) void {
        self.controller.dispatchMouse(.{
            .position = position,
            .mouseColumn = position.column,
            .revealType = .minimal,
            .startedOnLineNumbers = false,
            .inSelectionMode = false,
            .mouseDownCount = 2,
            .altKey = false,
            .ctrlKey = false,
            .metaKey = false,
            .shiftKey = false,
            .leftButton = true,
            .middleButton = false,
            .onInjectedText = false,
        });
    }

    fn selectedText(self: *Harness) ![]u8 {
        const selection = self.sink.selection orelse return error.NoSelection;
        var value = try self.model.model.getValueInRange(
            Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn),
            null,
        );
        defer value.deinit();
        return self.allocator.dupe(u8, value.items);
    }
};

fn expectStringSelection(allocator: Allocator, text: []const u8, position: Position, expected: []const u8) !void {
    var harness: Harness = undefined;
    try harness.init(allocator, text);
    defer harness.deinit();

    harness.doubleClickAt(position);
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings(expected, selected);
}

fn expectBracketSelection(allocator: Allocator, text: []const u8, position: Position, expected: []const u8) !void {
    var harness: Harness = undefined;
    try harness.init(allocator, text);
    defer harness.deinit();

    harness.doubleClickAt(position);
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings(expected, selected);
}

test "view controller: selects content after an opening curly brace" {
    try expectBracketSelection(testing.allocator, "var x = { hello };", Position.init(1, 10), " hello ");
}

test "view controller: selects content before a closing curly brace" {
    try expectBracketSelection(testing.allocator, "var x = { hello };", Position.init(1, 17), " hello ");
}

test "view controller: selects content after an opening parenthesis" {
    try expectBracketSelection(testing.allocator, "function foo(arg1, arg2) {}", Position.init(1, 14), "arg1, arg2");
}

test "view controller: selects content before a closing parenthesis" {
    try expectBracketSelection(testing.allocator, "function foo(arg1, arg2) {}", Position.init(1, 24), "arg1, arg2");
}

test "view controller: selects content after an opening square bracket" {
    try expectBracketSelection(testing.allocator, "const arr = [ 1, 2, 3 ];", Position.init(1, 14), " 1, 2, 3 ");
}

test "view controller: selects content before a closing square bracket" {
    try expectBracketSelection(testing.allocator, "const arr = [ 1, 2, 3 ];", Position.init(1, 23), " 1, 2, 3 ");
}

test "view controller: selects the innermost bracket content with nested brackets" {
    try expectBracketSelection(testing.allocator, "var x = { a: { b: 123 }};", Position.init(1, 15), " b: 123 ");
}

test "view controller: empty brackets create an empty selection" {
    try expectBracketSelection(testing.allocator, "var x = {};", Position.init(1, 10), "");
}

test "view controller: falls back to word select when no block is found" {
    const allocator = testing.allocator;
    var harness: Harness = undefined;
    try harness.init(allocator, "var x = abc;");
    defer harness.deinit();

    harness.doubleClickAt(Position.init(1, 10));
    try testing.expect(harness.sink.word_select_position != null);
    try testing.expectEqual(@as(usize, 10), harness.sink.word_select_position.?.column);
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("abc", selected);
}

test "view controller: disabling doubleClickSelectsBlock falls back to word select" {
    const allocator = testing.allocator;
    var harness: Harness = undefined;
    try harness.init(allocator, "var x = { hello };");
    defer harness.deinit();
    harness.options.set(.doubleClickSelectsBlock, false);

    harness.doubleClickAt(Position.init(1, 10));
    try testing.expect(harness.sink.selection == null);
    try testing.expect(harness.sink.word_select_position != null);
}

test "view controller: selects string content after an opening double quote" {
    try expectStringSelection(testing.allocator, "var x = \"hello\";", Position.init(1, 10), "hello");
}

test "view controller: selecting at the closing double quote selects the string content" {
    try expectStringSelection(testing.allocator, "var x = \"hello\";", Position.init(1, 15), "hello");
}

test "view controller: selects single-quoted string content" {
    try expectStringSelection(testing.allocator, "var x = 'hello';", Position.init(1, 10), "hello");
}

test "view controller: selects backtick-quoted string content" {
    try expectStringSelection(testing.allocator, "var x = `hello`;", Position.init(1, 10), "hello");
}

test "view controller: clicking in the middle of a string falls back to word select" {
    const allocator = testing.allocator;
    var harness: Harness = undefined;
    try harness.init(allocator, "var x = \"hello world\";");
    defer harness.deinit();

    harness.doubleClickAt(Position.init(1, 16));
    try testing.expect(harness.sink.word_select_position != null);
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("world", selected);
}

test "view controller: selects string content with escape characters" {
    const allocator = testing.allocator;
    const spans = [_]TokenSpan{
        .{ .start_index = 0, .token_type = .Other },
        .{ .start_index = 8, .token_type = .String },
        .{ .start_index = 9, .token_type = .String },
        .{ .start_index = 14, .token_type = .String },
        .{ .start_index = 16, .token_type = .String },
        .{ .start_index = 21, .token_type = .String },
        .{ .start_index = 22, .token_type = .Other },
    };
    var harness: Harness = undefined;
    try harness.initWithSpans(allocator, "var x = \"hello\\\"world\";", &spans);
    defer harness.deinit();
    harness.doubleClickAt(Position.init(1, 10));
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("hello\\\"world", selected);
}

test "view controller: separate quote tokens fall back to word select" {
    const allocator = testing.allocator;
    const spans = [_]TokenSpan{
        .{ .start_index = 0, .token_type = .Other },
        .{ .start_index = 8, .token_type = .Other },
        .{ .start_index = 9, .token_type = .String },
        .{ .start_index = 20, .token_type = .Other },
        .{ .start_index = 21, .token_type = .Other },
    };
    var harness: Harness = undefined;
    try harness.initWithSpans(allocator, "var x = \"hello world\";", &spans);
    defer harness.deinit();
    harness.doubleClickAt(Position.init(1, 10));
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("hello", selected);
}

test "view controller: RTL content in a string falls back to word select" {
    const allocator = testing.allocator;
    // UTF-8 byte offsets: prefix 0..8, quote 8, the Hebrew phrase 9 bytes? The
    // phrase has 17 bytes; closing quote at 26, semicolon at 27.
    const spans = [_]TokenSpan{
        .{ .start_index = 0, .token_type = .Other },
        .{ .start_index = 8, .token_type = .String },
        .{ .start_index = 27, .token_type = .Other },
    };
    var harness: Harness = undefined;
    try harness.initWithSpans(allocator, "var x = \"שלום עולם\";", &spans);
    defer harness.deinit();
    harness.doubleClickAt(Position.init(1, 10));
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("שלום", selected);
}

test "view controller: mismatched quotes fall back to word select" {
    const allocator = testing.allocator;
    const spans = [_]TokenSpan{
        .{ .start_index = 0, .token_type = .Other },
        .{ .start_index = 8, .token_type = .String },
        .{ .start_index = 11, .token_type = .Other },
        .{ .start_index = 13, .token_type = .String },
        .{ .start_index = 16, .token_type = .Other },
    };
    var harness: Harness = undefined;
    try harness.initWithSpans(allocator, "var x = \"a {} b\";", &spans);
    defer harness.deinit();
    harness.doubleClickAt(Position.init(1, 10));
    const selected = try harness.selectedText();
    defer allocator.free(selected);
    try testing.expectEqualStrings("a", selected);
}
