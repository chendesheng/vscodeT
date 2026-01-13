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
        try std.testing.expectEqual(expectedToken.metadata.foreground, _actual.getMetadata(i).foreground);
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

    test "single delete 5" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 1, 1, 12), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "",
                .tokens = &[_]TestToken{.init(0, 1)},
            }},
        );
    }

    test "multi delete 6" {
        try testApplyEdits(
            &[_]IBufferLineState{ .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 7), .init(5, 8), .init(6, 9) },
            } },
            &[_]IEdit{.{ .range = .init(1, 6, 3, 6), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 8), .init(6, 9) },
            }},
        );
    }

    test "multi delete 7" {
        try testApplyEdits(
            &[_]IBufferLineState{ .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 7), .init(5, 8), .init(6, 9) },
            } },
            &[_]IEdit{.{ .range = .init(1, 12, 3, 12), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
        );
    }

    test "multi delete 8" {
        try testApplyEdits(
            &[_]IBufferLineState{ .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 7), .init(5, 8), .init(6, 9) },
            } },
            &[_]IEdit{.{ .range = .init(1, 1, 3, 1), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 7), .init(5, 8), .init(6, 9) },
            }},
        );
    }

    test "multi delete 9" {
        try testApplyEdits(
            &[_]IBufferLineState{ .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 7), .init(5, 8), .init(6, 9) },
            } },
            &[_]IEdit{.{ .range = .init(1, 12, 3, 1), .text = "" }},
            &[_]IBufferLineState{.{
                .text = "hello worldhello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3), .init(11, 7), .init(16, 8), .init(17, 9) },
            }},
        );
    }

    test "single insert 1" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 1, 1, 1), .text = "xx" }},
            &[_]IBufferLineState{.{
                .text = "xxhello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(7, 2), .init(8, 3) },
            }},
        );
    }

    test "single insert 2" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 2, 1, 2), .text = "xx" }},
            &[_]IBufferLineState{.{
                .text = "hxxello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(7, 2), .init(8, 3) },
            }},
        );
    }

    test "single insert 3" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 6, 1, 6), .text = "xx" }},
            &[_]IBufferLineState{.{
                .text = "helloxx world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(7, 2), .init(8, 3) },
            }},
        );
    }

    test "single insert 4" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 7, 1, 7), .text = "xx" }},
            &[_]IBufferLineState{.{
                .text = "hello xxworld",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(8, 3) },
            }},
        );
    }

    test "single insert 5" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 12, 1, 12), .text = "xx" }},
            &[_]IBufferLineState{.{
                .text = "hello worldxx",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
        );
    }

    test "multi insert 6" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 1, 1, 1), .text = "\n" }},
            &[_]IBufferLineState{ .{
                .text = "",
                .tokens = &[_]TestToken{.init(0, 1)},
            }, .{
                .text = "hello world",
                .tokens = &[_]TestToken{.init(0, 1)},
            } },
        );
    }

    test "multi insert 7" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 12, 1, 12), .text = "\n" }},
            &[_]IBufferLineState{ .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }, .{
                .text = "",
                .tokens = &[_]TestToken{.init(0, 1)},
            } },
        );
    }

    test "multi insert 8" {
        try testApplyEdits(
            &[_]IBufferLineState{.{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            }},
            &[_]IEdit{.{ .range = .init(1, 7, 1, 7), .text = "\n" }},
            &[_]IBufferLineState{ .{
                .text = "hello ",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2) },
            }, .{
                .text = "world",
                .tokens = &[_]TestToken{.init(0, 1)},
            } },
        );
    }

    test "multi insert 9" {
        try testApplyEdits(&[_]IBufferLineState{
            .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2), .init(6, 3) },
            },
            .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            },
        }, &[_]IEdit{
            .{ .range = .init(1, 7, 1, 7), .text = "xx\nyy" },
        }, &[_]IBufferLineState{
            .{
                .text = "hello xx",
                .tokens = &[_]TestToken{ .init(0, 1), .init(5, 2) },
            },
            .{
                .text = "yyworld",
                .tokens = &[_]TestToken{.init(0, 1)},
            },
            .{
                .text = "hello world",
                .tokens = &[_]TestToken{ .init(0, 4), .init(5, 5), .init(6, 6) },
            },
        });
    }

    fn testLineEditTokens(initialText: []const u8, initialTokens: []const TestToken, lineEdits: []const LineEdit, expectedText: []const u8, expectedTokens: []const TestToken) !void {
        var edits = ArrayList(IEdit).init(allocator);
        defer edits.deinit();
        for (lineEdits) |lineEdit| {
            try edits.append(.{ .range = .init(1, lineEdit.startColumn, 1, lineEdit.endColumn), .text = lineEdit.text });
        }
        try testApplyEdits(
            &[_]IBufferLineState{.{ .text = initialText, .tokens = initialTokens }},
            edits.items,
            &[_]IBufferLineState{.{ .text = expectedText, .tokens = expectedTokens }},
        );
    }

    test "insertion on empty line" {
        var s = ManualTokenizationSupport.init(allocator);
        try TokenizationRegistry.instance(allocator).register("test", &s.interface);

        const model = try createTextModel(allocator, "some text", "test", null);
        defer disposeTextModel(model);
        const tokens = (try TestToken.toTokens(allocator, &[_]TestToken{.init(0, 1)})).?;
        defer allocator.free(tokens);
        LineTokens.convertToEndOffset(tokens, @intCast(model.getLineMaxColumn(1) - 1));
        try s.setLineTokens(1, tokens);

        const editOps = try IEdit.toEditOps(&[_]IEdit{.{ .range = .init(1, 1, 1, 10), .text = "" }});
        defer allocator.free(editOps);
        _ = try model.applyEdits(editOps, null);
        try s.setLineTokens(1, &[_]TokenPacked{});

        const editOps2 = try IEdit.toEditOps(&[_]IEdit{.{ .range = .init(1, 1, 1, 1), .text = "a" }});
        defer allocator.free(editOps2);
        _ = try model.applyEdits(editOps2, null);

        var actualTokens = try model.tokenization().getLineTokens(1);
        defer actualTokens.deinit();
        try assertLineTokens(&[_]TestToken{.init(0, 1)}, actualTokens);
    }

    test "updates tokens on insertion 1" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 1,
                .text = "a",
            }},
            "aabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(5, 2),
                .init(6, 3),
            },
        );
    }

    test "updates tokens on insertion 2" {
        try testLineEditTokens(
            "aabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(5, 2),
                .init(6, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 2,
                .endColumn = 2,
                .text = "x",
            }},
            "axabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(6, 2),
                .init(7, 3),
            },
        );
    }

    test "updates tokens on insertion 3" {
        try testLineEditTokens(
            "axabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(6, 2),
                .init(7, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 3,
                .endColumn = 3,
                .text = "stu",
            }},
            "axstuabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(9, 2),
                .init(10, 3),
            },
        );
    }

    test "updates tokens on insertion 4" {
        try testLineEditTokens(
            "axstuabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(9, 2),
                .init(10, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 10,
                .endColumn = 10,
                .text = "\t",
            }},
            "axstuabcd\t efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(11, 3),
            },
        );
    }

    test "updates tokens on insertion 5" {
        try testLineEditTokens(
            "axstuabcd\t efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(11, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 12,
                .endColumn = 12,
                .text = "dd",
            }},
            "axstuabcd\t ddefgh",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(13, 3),
            },
        );
    }

    test "updates tokens on insertion 6" {
        try testLineEditTokens(
            "axstuabcd\t ddefgh",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(13, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 18,
                .endColumn = 18,
                .text = "xyz",
            }},
            "axstuabcd\t ddefghxyz",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(13, 3),
            },
        );
    }

    test "updates tokens on insertion 7" {
        try testLineEditTokens(
            "axstuabcd\t ddefghxyz",
            &[_]TestToken{
                .init(0, 1),
                .init(10, 2),
                .init(13, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 1,
                .text = "x",
            }},
            "xaxstuabcd\t ddefghxyz",
            &[_]TestToken{
                .init(0, 1),
                .init(11, 2),
                .init(14, 3),
            },
        );
    }

    test "updates tokens on insertion 8" {
        try testLineEditTokens(
            "xaxstuabcd\t ddefghxyz",
            &[_]TestToken{
                .init(0, 1),
                .init(11, 2),
                .init(14, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 22,
                .endColumn = 22,
                .text = "x",
            }},
            "xaxstuabcd\t ddefghxyzx",
            &[_]TestToken{
                .init(0, 1),
                .init(11, 2),
                .init(14, 3),
            },
        );
    }

    test "updates tokens on insertion 9" {
        try testLineEditTokens(
            "xaxstuabcd\t ddefghxyzx",
            &[_]TestToken{
                .init(0, 1),
                .init(11, 2),
                .init(14, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 2,
                .endColumn = 2,
                .text = "",
            }},
            "xaxstuabcd\t ddefghxyzx",
            &[_]TestToken{
                .init(0, 1),
                .init(11, 2),
                .init(14, 3),
            },
        );
    }

    test "updates tokens on insertion 10" {
        try testLineEditTokens(
            "",
            &[_]TestToken{},
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 1,
                .text = "a",
            }},
            "a",
            &[_]TestToken{
                .init(0, 1),
            },
        );
    }

    test "delete second token 2" {
        try testLineEditTokens(
            "abcdefghij",
            &[_]TestToken{
                .init(0, 1),
                .init(3, 2),
                .init(6, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 4,
                .endColumn = 7,
                .text = "",
            }},
            "abcghij",
            &[_]TestToken{
                .init(0, 1),
                .init(3, 3),
            },
        );
    }

    test "insert right before second token" {
        try testLineEditTokens(
            "abcdefghij",
            &[_]TestToken{
                .init(0, 1),
                .init(3, 2),
                .init(6, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 4,
                .endColumn = 4,
                .text = "hello",
            }},
            "abchellodefghij",
            &[_]TestToken{
                .init(0, 1),
                .init(8, 2),
                .init(11, 3),
            },
        );
    }

    test "delete first char" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 2,
                .text = "",
            }},
            "bcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(3, 2),
                .init(4, 3),
            },
        );
    }

    test "delete 2nd and 3rd chars" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 2,
                .endColumn = 4,
                .text = "",
            }},
            "ad efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(2, 2),
                .init(3, 3),
            },
        );
    }

    test "delete first token" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 5,
                .text = "",
            }},
            " efgh",
            &[_]TestToken{
                .init(0, 2),
                .init(1, 3),
            },
        );
    }

    test "delete second token" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 5,
                .endColumn = 6,
                .text = "",
            }},
            "abcdefgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 3),
            },
        );
    }

    test "delete second token + a bit of the third one" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 5,
                .endColumn = 7,
                .text = "",
            }},
            "abcdfgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 3),
            },
        );
    }

    test "delete second and third token" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 5,
                .endColumn = 10,
                .text = "",
            }},
            "abcd",
            &[_]TestToken{
                .init(0, 1),
            },
        );
    }

    test "delete everything" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 10,
                .text = "",
            }},
            "",
            &[_]TestToken{
                .init(0, 1),
            },
        );
    }

    test "noop" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 1,
                .text = "",
            }},
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }

    test "equivalent to deleting first two chars" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 3,
                .text = "",
            }},
            "cd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(2, 2),
                .init(3, 3),
            },
        );
    }

    test "equivalent to deleting from 5 to the end" {
        try testLineEditTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            &[_]LineEdit{.{
                .startColumn = 5,
                .endColumn = 10,
                .text = "",
            }},
            "abcd",
            &[_]TestToken{
                .init(0, 1),
            },
        );
    }

    test "updates tokens on replace 1" {
        try testLineEditTokens(
            "Hello world, ciao",
            &[_]TestToken{
                .init(0, 1),
                .init(5, 0),
                .init(6, 2),
                .init(11, 0),
                .init(13, 0),
            },
            &[_]LineEdit{.{
                .startColumn = 1,
                .endColumn = 6,
                .text = "Hi",
            }},
            "Hi world, ciao",
            &[_]TestToken{
                .init(0, 0),
                .init(3, 2),
                .init(8, 0),
                .init(10, 0),
            },
        );
    }

    test "updates tokens on replace 2" {
        try testLineEditTokens(
            "Hello world, ciao",
            &[_]TestToken{
                .init(0, 1),
                .init(5, 0),
                .init(6, 2),
                .init(11, 0),
                .init(13, 0),
            },
            &[_]LineEdit{
                .{
                    .startColumn = 1,
                    .endColumn = 6,
                    .text = "Hi",
                },
                .{
                    .startColumn = 8,
                    .endColumn = 12,
                    .text = "my friends",
                },
            },
            "Hi wmy friends, ciao",
            &[_]TestToken{
                .init(0, 0),
                .init(3, 2),
                .init(14, 0),
                .init(16, 0),
            },
        );
    }

    fn testLineSplitTokens(initialText: []const u8, initialTokens: []const TestToken, splitColumn: usize, expectedText1: []const u8, expectedText2: []const u8, expectedTokens: []const TestToken) !void {
        try testApplyEdits(
            &[_]IBufferLineState{.{ .text = initialText, .tokens = initialTokens }},
            &[_]IEdit{.{
                .range = .init(1, splitColumn, 1, splitColumn),
                .text = "\n",
            }},
            &[_]IBufferLineState{ .{ .text = expectedText1, .tokens = expectedTokens }, .{
                .text = expectedText2,
                .tokens = &[_]TestToken{.init(0, 1)},
            } },
        );
    }

    test "split at the beginning" {
        try testLineSplitTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            1,
            "",
            "abcd efgh",
            &[_]TestToken{.init(0, 1)},
        );
    }

    test "split at the end" {
        try testLineSplitTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            10,
            "abcd efgh",
            "",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }

    test "split inthe middle 1" {
        try testLineSplitTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            5,
            "abcd",
            " efgh",
            &[_]TestToken{
                .init(0, 1),
            },
        );
    }

    test "split inthe middle 2" {
        try testLineSplitTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            6,
            "abcd ",
            "efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
            },
        );
    }

    fn testLineAppendTokens(aText: []const u8, aTokens: []const TestToken, bText: []const u8, bTokens: []const TestToken, expectedText: []const u8, expectedTokens: []const TestToken) !void {
        try testApplyEdits(
            &[_]IBufferLineState{
                .{ .text = aText, .tokens = aTokens },
                .{ .text = bText, .tokens = bTokens },
            },
            &[_]IEdit{.{
                .range = .init(1, aText.len + 1, 2, 1),
                .text = "",
            }},
            &[_]IBufferLineState{.{ .text = expectedText, .tokens = expectedTokens }},
        );
    }

    test "append empty 1" {
        try testLineAppendTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            "",
            &[_]TestToken{},
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }

    test "append empty 2" {
        try testLineAppendTokens(
            "",
            &[_]TestToken{},
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }

    test "append 1" {
        try testLineAppendTokens(
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
            "abcd efgh",
            &[_]TestToken{
                .init(0, 4),
                .init(4, 5),
                .init(5, 6),
            },
            "abcd efghabcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
                .init(9, 4),
                .init(13, 5),
                .init(14, 6),
            },
        );
    }

    test "append 2" {
        try testLineAppendTokens(
            "abcd ",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
            },
            "efgh",
            &[_]TestToken{
                .init(0, 3),
            },
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }

    test "append 3" {
        try testLineAppendTokens(
            "abcd",
            &[_]TestToken{
                .init(0, 1),
            },
            " efgh",
            &[_]TestToken{
                .init(0, 2),
                .init(1, 3),
            },
            "abcd efgh",
            &[_]TestToken{
                .init(0, 1),
                .init(4, 2),
                .init(5, 3),
            },
        );
    }
};

test "ModelLine" {
    _ = GetIndentLevelTests{};
    _ = ModelLinesTokensTests{};
}
