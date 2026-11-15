const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const UnmanagedList = std.ArrayList;
const tm = @import("textmate");
const languages = @import("../../languages.zig");
const IState = languages.IState;
const ITokenizationSupport = languages.ITokenizationSupport;
const EncodedTokenizationResult = languages.EncodedTokenizationResult;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;

var initialized = false;

fn ensureInitialized() !void {
    if (initialized) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    try tm.oni.init(&.{tm.oni.Encoding.utf8});
    try tm.GrammarLibrary.initLibrary(io, std.heap.page_allocator);
    try tm.GrammarLibrary.getLibrary().?.addEmbeddedGrammars();
    initialized = true;
}

fn grammarScope(languageId: []const u8) ?[]const u8 {
    const map = .{
        .{ "zig", "source.zig" },
        .{ "json", "source.json" },
        .{ "jsonc", "source.json" },
        .{ "javascript", "source.js" },
        .{ "javascriptreact", "source.js" },
        .{ "typescript", "source.ts" },
        .{ "typescriptreact", "source.ts" },
        .{ "python", "source.python" },
        .{ "rust", "source.rust" },
        .{ "go", "source.go" },
        .{ "c", "source.c" },
        .{ "cpp", "source.cpp" },
        .{ "java", "source.java" },
        .{ "html", "text.html.basic" },
        .{ "css", "source.css" },
        .{ "scss", "source.css.scss" },
        .{ "markdown", "text.html.markdown" },
        .{ "yaml", "source.yaml" },
        .{ "toml", "source.toml" },
        .{ "shellscript", "source.shell" },
        .{ "bash", "source.shell" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, entry[0], languageId)) return entry[1];
    }
    return null;
}

const TextMateState = struct {
    state: tm.ParseState,
    first_line: bool,
    pub const vtable = IState.VTable{ .clone = clone, .equals = equals };

    fn clone(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        const self: *TextMateState = @ptrCast(@alignCast(ctx));
        const result = try allocator.create(TextMateState);
        result.first_line = self.first_line;
        result.state = try tm.ParseState.init(self.state.owner, allocator, self.state.owner.lang.syntax.?);
        var packs: UnmanagedList(tm.StateContextPack) = .empty;
        defer packs.deinit(allocator);
        try self.state.owner.serialize(&self.state, &packs);
        try self.state.owner.deserialize(&result.state, &packs);
        return .{ .context = result, .vtable = &vtable };
    }

    fn equals(ctx: *anyopaque, other: IState) bool {
        const self: *TextMateState = @ptrCast(@alignCast(ctx));
        if (other.vtable != &vtable) return false;
        const b: *TextMateState = @ptrCast(@alignCast(other.context));
        if (self.first_line != b.first_line) return false;
        if (self.state.stack.items.len != b.state.stack.items.len) return false;
        for (self.state.stack.items, b.state.stack.items) |a, c| {
            const pa = @constCast(&a).serialize(self.state.owner);
            const pc = @constCast(&c).serialize(b.state.owner);
            if (pa.syntax != pc.syntax or pa.anchor_start != pc.anchor_start or pa.start != pc.start or pa.rx_end != pc.rx_end or pa.rx_while != pc.rx_while) return false;
        }
        return true;
    }
};

const TextMateSupport = struct {
    allocator: Allocator,
    parser: *tm.Parser,
    processor: tm.Processor,
    language_id: []u8,

    pub fn deinit(self: *TextMateSupport) void {
        self.processor.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
        self.allocator.free(self.language_id);
        self.allocator.destroy(self);
    }

    fn getInitialState(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        const self: *TextMateSupport = @ptrCast(@alignCast(ctx));
        const state = try allocator.create(TextMateState);
        state.first_line = true;
        state.state = try self.parser.initState();
        return .{ .context = state, .vtable = &TextMateState.vtable };
    }

    fn tokenizeEncoded(ctx: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        const self: *TextMateSupport = @ptrCast(@alignCast(ctx));
        const input: *TextMateState = @ptrCast(@alignCast(state.context));
        const next = try allocator.create(TextMateState);
        next.first_line = false;
        next.state = try tm.ParseState.init(self.parser, allocator, self.parser.lang.syntax.?);
        var packs: UnmanagedList(tm.StateContextPack) = .empty;
        defer packs.deinit(allocator);
        try self.parser.serialize(&input.state, &packs);
        try self.parser.deserialize(&next.state, &packs);

        const block = try allocator.alloc(u8, line.len + 1);
        defer allocator.free(block);
        @memcpy(block[0..line.len], line);
        block[line.len] = '\n';

        self.processor.state = &next.state;
        self.parser.processor = &self.processor;
        try self.parser.parseLine(&next.state, block, input.first_line);

        return .{ .tokens = try tokensFromCaptures(allocator, self.processor.captures.items, line.len), .endState = .{ .context = next, .vtable = &TextMateState.vtable } };
    }

    fn dispose(ctx: *anyopaque) void {
        const self: *TextMateSupport = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub const vtable = ITokenizationSupport.VTable{
        .getInitialState = getInitialState,
        .tokenizeEncoded = tokenizeEncoded,
        .dispose = dispose,
    };
};

fn defaultMetadata() TokenMetadata {
    var metadata = TokenMetadata.default;
    metadata.languageId = 0;
    metadata.balancedBrackets = true;
    return metadata;
}

pub fn create(allocator: Allocator, languageId: []const u8) !?ITokenizationSupport {
    const scope = grammarScope(languageId) orelse return null;
    try ensureInitialized();
    const grammar = tm.GrammarLibrary.getLibrary().?.grammarFromScopeName(scope) catch return null;
    const parser = try allocator.create(tm.Parser);
    errdefer allocator.destroy(parser);
    parser.* = try tm.Parser.init(allocator, grammar);
    errdefer parser.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    var processor = try tm.NullProcessor.init(io, allocator);
    errdefer processor.deinit();
    const context = try allocator.create(TextMateSupport);
    context.* = .{
        .allocator = allocator,
        .parser = parser,
        .processor = processor,
        .language_id = try allocator.dupe(u8, languageId),
    };
    return .{ .context = context, .vtable = &TextMateSupport.vtable };
}

test "textmate tokenizer: zig grammar produces scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = (try create(allocator, "zig")) orelse return error.NoSupport;
    defer support.dispose();
    const state = try support.getInitialState(allocator);
    const result = try support.tokenizeEncoded(allocator, "const x = 1; // hi", true, state);
    try std.testing.expect(result.tokens.len >= 2);
    try std.testing.expectEqual(StandardTokenType.Comment, result.tokens[result.tokens.len - 1].metadata.tokenType);
}

pub fn ensureTokenizer(languageId: []const u8) void {
    const registry = &@import("../../tokenizationRegistry.zig").TokenizationRegistry.instance;
    if (registry.get(languageId) != null) return;
    const support = create(std.heap.page_allocator, languageId) catch return orelse return;
    registry.register(languageId, support) catch support.dispose();
}

test "textmate tokenizer: integrated through TextModel" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "const x = 1; // hi", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(1);
    var lineTokens = try ctx.model.tokenization().getLineTokens(1);
    defer lineTokens.deinit();
    var found_comment = false;
    for (0..lineTokens.getCount()) |i| {
        if (lineTokens.getStandardTokenType(i) == .Comment) found_comment = true;
    }
    try std.testing.expect(found_comment);
}

fn tokensFromCaptures(allocator: Allocator, captures: []const tm.ParseCapture, lineLen: usize) ![]TokenPacked {
    var cutPoints = ArrayList(usize).init(allocator);
    defer cutPoints.deinit();
    try cutPoints.append(0);
    try cutPoints.append(lineLen);
    for (captures) |cap| {
        const start = @min(cap.start, lineLen);
        const end = @min(cap.end, lineLen);
        if (start < end) {
            try cutPoints.append(start);
            try cutPoints.append(end);
        }
    }
    std.sort.heap(usize, cutPoints.items, {}, std.sort.asc(usize));

    var tokens = ArrayList(TokenPacked).init(allocator);
    errdefer tokens.deinit();
    var i: usize = 0;
    while (i + 1 < cutPoints.items.len) : (i += 1) {
        const start = cutPoints.items[i];
        const end = cutPoints.items[i + 1];
        if (start >= end) continue;
        var metadata = defaultMetadata();
        for (captures) |cap| {
            if (cap.start <= start and end <= cap.end) metadata = metadataForScope(metadata, cap.scope);
        }
        // The tokenization pipeline converts start offsets to end offsets
        // (`LineTokens.convertToEndOffset`), so emit the segment start here.
        if (tokens.items.len > 0 and tokens.items[tokens.items.len - 1].metadata == metadata) {
            // Keep the previous token's start offset; conversion extends it.
        } else {
            try tokens.append(.{ .endOffset = @intCast(start), .metadata = metadata });
        }
    }
    if (tokens.items.len == 0) try tokens.append(.{ .endOffset = 0, .metadata = defaultMetadata() });
    return try tokens.toOwnedSlice();
}

fn metadataForScope(metadata_: TokenMetadata, scope: []const u8) TokenMetadata {
    var metadata = metadata_;
    if (std.mem.startsWith(u8, scope, "comment")) {
        metadata.tokenType = .Comment;
        metadata.foreground = 5;
    } else if (std.mem.startsWith(u8, scope, "string")) {
        metadata.tokenType = .String;
        metadata.foreground = 6;
    } else if (std.mem.indexOf(u8, scope, "regexp") != null) {
        metadata.tokenType = .RegEx;
        metadata.foreground = 7;
    } else if (std.mem.startsWith(u8, scope, "invalid")) {
        metadata.foreground = 7;
    } else if (std.mem.startsWith(u8, scope, "markup.inline.raw") or
        std.mem.startsWith(u8, scope, "punctuation.definition.raw"))
    {
        // Dark+ colors inline code with the string color. Backticks have a
        // separate punctuation scope in the grammar, so map both.
        metadata.foreground = 6;
    } else if (std.mem.startsWith(u8, scope, "keyword") or std.mem.startsWith(u8, scope, "storage")) {
        metadata.foreground = 8;
    } else if (std.mem.startsWith(u8, scope, "constant")) {
        metadata.foreground = 9;
    } else if (std.mem.startsWith(u8, scope, "support.function") or
        std.mem.startsWith(u8, scope, "entity.name.function") or
        std.mem.startsWith(u8, scope, "entity.name.section"))
    {
        metadata.foreground = 10;
    } else if (std.mem.startsWith(u8, scope, "support.type") or
        std.mem.startsWith(u8, scope, "support.class") or
        std.mem.startsWith(u8, scope, "entity.name.type") or
        std.mem.startsWith(u8, scope, "entity.name.tag"))
    {
        metadata.foreground = 11;
    } else if (std.mem.startsWith(u8, scope, "variable")) {
        metadata.foreground = 12;
    }
    return metadata;
}

test "textmate tokenizer: state survives lines" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "/* comment\nstill */ int x = 1;", "c");
    defer ctx.deinit();
    ctx.model.forceTokenization(2);

    var line1 = try ctx.model.tokenization().getLineTokens(1);
    defer line1.deinit();
    try std.testing.expectEqual(StandardTokenType.Comment, line1.getStandardTokenType(0));

    var line2 = try ctx.model.tokenization().getLineTokens(2);
    defer line2.deinit();
    try std.testing.expectEqual(StandardTokenType.Comment, line2.getStandardTokenType(0));
    try std.testing.expect(line2.getCount() > 1);
}

test "textmate tokenizer: token text and foreground stay aligned" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "const std = @import(\"std\");", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(1);

    var tokens = try ctx.model.tokenization().getLineTokens(1);
    defer tokens.deinit();

    var saw_const = false;
    var saw_std_variable = false;
    var saw_string = false;
    var saw_import = false;
    for (0..tokens.getCount()) |i| {
        const text = tokens.getTokenText(i);
        const fg = tokens.getForeground(i);
        if (std.mem.eql(u8, text, "const")) {
            saw_const = true;
            try std.testing.expectEqual(@as(u9, 8), fg);
        } else if (std.mem.eql(u8, text, "std")) {
            saw_std_variable = true;
            try std.testing.expectEqual(@as(u9, 12), fg);
        } else if (std.mem.eql(u8, text, "\"std\"")) {
            saw_string = true;
            try std.testing.expectEqual(@as(u9, 6), fg);
        } else if (std.mem.eql(u8, text, "@import")) {
            saw_import = true;
            try std.testing.expectEqual(@as(u9, 10), fg);
        }
    }
    try std.testing.expect(saw_const and saw_std_variable and saw_string and saw_import);
}

test "textmate tokenizer: markdown inline raw scopes use the string color" {
    const line = "a `code` span";
    const captures = [_]tm.ParseCapture{
        .{ .start = 0, .end = line.len, .scope = "text.html.markdown" },
        .{ .start = 0, .end = line.len, .scope = "meta.paragraph.markdown" },
        .{ .start = 2, .end = 8, .scope = "markup.inline.raw.string.markdown" },
        .{ .start = 2, .end = 3, .scope = "punctuation.definition.raw.markdown" },
        .{ .start = 7, .end = 8, .scope = "punctuation.definition.raw.markdown" },
    };
    const tokens = try tokensFromCaptures(std.testing.allocator, &captures, line.len);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(@as(u32, 0), tokens[0].endOffset);
    try std.testing.expectEqual(TokenMetadata.default.foreground, tokens[0].metadata.foreground);
    try std.testing.expectEqual(@as(u32, 2), tokens[1].endOffset);
    try std.testing.expectEqual(@as(u9, 6), tokens[1].metadata.foreground);
    try std.testing.expectEqual(@as(u32, 8), tokens[2].endOffset);
    try std.testing.expectEqual(TokenMetadata.default.foreground, tokens[2].metadata.foreground);
}

test "textmate tokenizer: markdown does not break later tokenization" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    var html = try TestModel.init(std.testing.allocator, "<div>hi</div>", "html");
    defer html.deinit();
    html.model.forceTokenization(1);
    var html_tokens = try html.model.tokenization().getLineTokens(1);
    defer html_tokens.deinit();
    try std.testing.expect(html_tokens.getCount() > 0);

    var markdown = try TestModel.init(std.testing.allocator, "a `code` span", "markdown");
    defer markdown.deinit();
    markdown.model.forceTokenization(1);
    var markdown_tokens = try markdown.model.tokenization().getLineTokens(1);
    defer markdown_tokens.deinit();

    // Parsing markdown lazily loads the HTML derivative grammar. Its wildcard
    // injection selector used to spin the package's scope-selector evaluator,
    // hanging every tokenizer used afterwards.
    var zig = try TestModel.init(std.testing.allocator, "const x = 1;", "zig");
    defer zig.deinit();
    zig.model.forceTokenization(1);
    var tokens = try zig.model.tokenization().getLineTokens(1);
    defer tokens.deinit();

    var saw_const = false;
    for (0..tokens.getCount()) |i| {
        if (std.mem.eql(u8, tokens.getTokenText(i), "const")) {
            saw_const = true;
            try std.testing.expectEqual(@as(u9, 8), tokens.getForeground(i));
        }
    }
    try std.testing.expect(saw_const);
}

test "textmate tokenizer: token cache shifts after inserting a line above" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const Range = @import("../../core/range.zig").Range;

    var ctx = try TestModel.init(std.testing.allocator, "const a = 1;\n/// comment\npub fn f() void {}\n", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(3);

    try ctx.applyEdit(Range.init(1, 1, 1, 1), "\n\n");

    var tokens = try ctx.model.tokenization().getLineTokens(4);
    defer tokens.deinit();
    var found_comment = false;
    for (0..tokens.getCount()) |i| {
        if (tokens.getStandardTokenType(i) == .Comment) found_comment = true;
    }
    try std.testing.expect(found_comment);
}
