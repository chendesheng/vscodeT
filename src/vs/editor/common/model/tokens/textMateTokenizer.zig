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
        if (tokens.items.len > 0 and tokens.items[tokens.items.len - 1].metadata == metadata) {
            tokens.items[tokens.items.len - 1].endOffset = @intCast(end);
        } else {
            try tokens.append(.{ .endOffset = @intCast(end), .metadata = metadata });
        }
    }
    if (tokens.items.len == 0) try tokens.append(.{ .endOffset = @intCast(lineLen), .metadata = defaultMetadata() });
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
    } else if (std.mem.startsWith(u8, scope, "keyword") or std.mem.startsWith(u8, scope, "storage")) {
        metadata.foreground = 8;
    } else if (std.mem.startsWith(u8, scope, "constant")) {
        metadata.foreground = 9;
    } else if (std.mem.startsWith(u8, scope, "entity.name.function")) {
        metadata.foreground = 10;
    } else if (std.mem.startsWith(u8, scope, "entity.name.type")) {
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
