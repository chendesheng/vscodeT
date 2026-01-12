const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const Set = @import("../basics/Set.zig").Set;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const IState = @import("../languages.zig").IState;
const TokenizationResult = @import("../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TestLineTokenFactory = @import("./core/testLineToken.zig").TestLineTokenFactory;
const computeIndentLevel = @import("../basics/utils.zig").computeIndentLevel;
const Range = @import("../basics/range.zig").Range;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TokenizationRegistry = @import("../tokenize/tokenizationRegistry.zig").TokenizationRegistry;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const String = @import("../basics/strings.zig").String;

const LineEdit = struct {
    startColumn: usize,
    endColumn: usize,
    text: []const u8,
};

fn assertLineTokens(_expected: []const TestToken, _actual: LineTokens) !void {
    const allocator = std.testing.allocator;
    const tmp = (try TestToken.toTokens(allocator, _expected)).?;
    defer allocator.free(tmp);
    LineTokens.convertToEndOffset(tmp, @intCast(_actual.getLineContent().len));

    for (tmp, 0..) |expectedToken, i| {
        try std.testing.expectEqual(expectedToken.endOffset, _actual.getEndOffset(i));
        try std.testing.expectEqual(expectedToken.metadata, _actual.getMetadata(i));
    }
}

const GetIndentLevelTests = struct {
    fn assertIndentLevel(text: []const u8, expected: isize, _tabSize: ?usize) !void {
        const tabSize = _tabSize orelse 4;
        const actual = computeIndentLevel(text, tabSize);
        try std.testing.expectEqual(expected, actual);
    }

    test "getIndentLevel" {
        try assertIndentLevel("", -1, null);
        try assertIndentLevel(" ", -1, null);
        try assertIndentLevel("   \t", -1, null);
        try assertIndentLevel("Hello", 0, null);
        try assertIndentLevel(" Hello", 1, null);
        try assertIndentLevel("   Hello", 3, null);
        try assertIndentLevel("\tHello", 4, null);
        try assertIndentLevel(" \tHello", 4, null);
        try assertIndentLevel("  \tHello", 4, null);
        try assertIndentLevel("   \tHello", 4, null);
        try assertIndentLevel("    \tHello", 8, null);
        try assertIndentLevel("     \tHello", 8, null);
        try assertIndentLevel("\t Hello", 5, null);
        try assertIndentLevel("\t \tHello", 8, null);
    }
};

const TestToken = struct {
    startOffset: u32,
    color: u9,

    pub fn init(startOffset: u32, color: u9) TestToken {
        return TestToken{
            .startOffset = startOffset,
            .color = color,
        };
    }

    pub fn toTokens(allocator: Allocator, _tokens: ?[]const TestToken) !?[]TokenPacked {
        if (_tokens) |tokens| {
            var result = ArrayList(TokenPacked).init(allocator);
            defer result.deinit();
            for (tokens) |token| {
                try result.append(TokenPacked.init(token.startOffset, .{ .foreground = token.color }));
            }
            return try result.toOwnedSlice();
        }
        return null;
    }
};

const NullBackgroundTokenizer = struct {
    interface: IBackgroundTokenizer,
    pub fn init() NullBackgroundTokenizer {
        return .{
            .interface = .{
                .vtable = &.{
                    .requestTokens = requestTokens,
                    .reportMismatchingTokens = null,
                    .destroy = destroy,
                },
            },
        };
    }

    fn requestTokens(self: *IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) !void {
        _ = self;
        _ = startLineNumber;
        _ = endLineNumberExclusive;
    }
    fn destroy(b: *IBackgroundTokenizer, allocator: Allocator) void {
        const self = getSelf(b);
        allocator.destroy(self);
    }
    fn getSelf(b: *IBackgroundTokenizer) *NullBackgroundTokenizer {
        return @alignCast(@fieldParentPtr("interface", b));
    }
};

const ManualTokenizationSupport = struct {
    interface: ITokenizationSupport,
    allocator: Allocator,
    tokens: AutoHashMap(usize, []TokenPacked),
    stores: ArrayList(*IBackgroundTokenizationStore),

    const nullBackgroundTokenizer = NullBackgroundTokenizer.init().interface;

    pub fn init(allocator: Allocator) ManualTokenizationSupport {
        return ManualTokenizationSupport{
            .interface = .{
                .vtable = &.{
                    .getInitialState = getInitialState,
                    .tokenize = tokenize,
                    .tokenizeEncoded = tokenizeEncoded,
                    .createBackgroundTokenizer = createBackgroundTokenizer,
                    .destroy = destroy,
                },
            },
            .allocator = allocator,
            .tokens = AutoHashMap(usize, []TokenPacked).init(allocator),
            .stores = ArrayList(*IBackgroundTokenizationStore).init(allocator),
        };
    }

    fn destroy(t: *ITokenizationSupport, allocator: Allocator) void {
        const self = getSelf(t);
        self.tokens.deinit();
        for (self.stores.items) |s| {
            s.destroy(allocator);
        }
        self.stores.deinit();
    }

    pub fn setLineTokens(self: *ManualTokenizationSupport, lineNumber: usize, tokens: []const TokenPacked) !void {
        var b = ContiguousMultilineTokensBuilder.init(self.allocator);
        defer b.deinit();
        try b.add(lineNumber, tokens);
        for (self.stores.items) |s| {
            try s.setTokens(b.finalize().items);
        }
    }

    pub fn getInitialState(_: *ITokenizationSupport) !IState {
        return .init(LineState, &.{ .lineNumber = 1 });
    }

    pub fn tokenize(self: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !TokenizationResult {
        _ = self;
        _ = line;
        _ = hasEOL;
        _ = state;
        return error.NotImplemented;
    }

    pub fn tokenizeEncoded(t: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
        const self = getSelf(t);
        const allocator = self.allocator;
        _ = line;
        _ = hasEOL;
        const s = state.getPtr(LineState);

        var nextState = try allocator.create(LineState);
        nextState.lineNumber = s.lineNumber + 1;
        const endState = IState.init(LineState, nextState);

        return EncodedTokenizationResult.init(self.tokens.get(s.lineNumber).?, endState);
    }

    // Can be/return undefined if default background tokenization should be used.
    pub fn createBackgroundTokenizer(t: *ITokenizationSupport, textModel: *TextModel, store: *IBackgroundTokenizationStore) !?IBackgroundTokenizer {
        _ = textModel;
        try getSelf(t).stores.append(store);
        return nullBackgroundTokenizer;
    }

    fn getSelf(s: *ITokenizationSupport) *ManualTokenizationSupport {
        return @alignCast(@fieldParentPtr("interface", s));
    }
};

const LineState = struct {
    lineNumber: usize,

    pub fn init(lineNumber: usize) LineState {
        return LineState{
            .lineNumber = lineNumber,
        };
    }
};

const ModelLinesTokensTests = struct {
    const allocator = std.testing.allocator;

    const IBufferLineState = struct {
        text: []const u8,
        tokens: []const TestToken,

        pub fn unlines(lines: []const IBufferLineState) ![]const u8 {
            var result = ArrayList(u8).init(allocator);
            defer result.deinit();
            for (lines, 0..) |line, i| {
                try result.appendSlice(line.text);
                if (i < lines.len - 1) {
                    try result.append('\n');
                }
            }
            return try result.toOwnedSlice();
        }
    };

    const IEdit = struct {
        range: Range,
        text: []const u8,

        pub fn toEditOps(edits: []const IEdit) ![]IdentifiedSingleEditOperation {
            var result = ArrayList(IdentifiedSingleEditOperation).init(allocator);
            defer result.deinit();
            for (edits) |edit| {
                try result.append(.init(edit.range, String.initBorrowed(edit.text)));
            }
            return try result.toOwnedSlice();
        }
    };

    fn testApplyEdits(initial: []const IBufferLineState, edits: []const IEdit, expected: []const IBufferLineState) !void {
        const initialText = try IBufferLineState.unlines(initial);
        defer allocator.free(initialText);

        var s = ManualTokenizationSupport.init(allocator);
        try TokenizationRegistry.instance(allocator).register("test", &s.interface);

        const model = try createTextModel(allocator, initialText, "test", null);
        defer disposeTextModel(model);
        // model.onBeforeAttached();
        for (0..initial.len) |lineIndex| {
            const lineTokens = initial[lineIndex].tokens;
            const lineTextLength = model.getLineMaxColumn(lineIndex + 1) - 1;
            const tokens = (try TestToken.toTokens(allocator, lineTokens)).?;
            defer allocator.free(tokens);
            LineTokens.convertToEndOffset(tokens, @intCast(lineTextLength));
            try s.setLineTokens(lineIndex + 1, tokens);
        }
        const editOps = try IEdit.toEditOps(edits);
        defer allocator.free(editOps);
        _ = try model.applyEdits(editOps, null);

        for (0..expected.len) |lineIndex| {
            const actualLine = try model.getLineContent(lineIndex + 1);
            defer actualLine.deinit();
            var actualTokens = try model.tokenization().getLineTokens(lineIndex + 1);
            defer actualTokens.deinit();
            try std.testing.expectEqualStrings(actualLine.items, expected[lineIndex].text);
            try assertLineTokens(expected[lineIndex].tokens, actualTokens);
        }
    }

    test "single delete 1" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 1, 1, 2), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "ello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(4, 2), .init(5, 3) },
            }},
        );
    }

    test "single delete 2" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "helloworld",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2) },
            }},
            &[_]IEdit{.{ .range = .init(1, 3, 1, 8), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "herld",
                .tokens = &[_]TestToken{ .init(0, 1), .init(2, 2) },
            }},
        );
    }

    test "single delete 3" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 1, 1, 6), .text = "" }},
            &[_]IBufferLineState{.{
                .text = " world",
                .tokens = &[_]TestToken{ .init(0, 2), .init(1, 3) },
            }},
        );
    }

    test "single delete 4" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 2, 1, 7), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "hworld",
                .tokens = &[_]TestToken{ .init(0, 1), .init(1, 3) },
            }},
        );
    }

};

test "ModelLine" {
    _ = GetIndentLevelTests{};
    _ = ModelLinesTokensTests{};
}
