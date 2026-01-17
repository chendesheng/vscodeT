const std = @import("std");
const ts = @import("tree-sitter");
const Allocator = std.mem.Allocator;
const AbstractSyntaxTokenBackend = @import("../abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const BackgroundTokenizationState = @import("../abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const Emitter = @import("../../basics/event.zig").Emitter;
const LanguageIdCodec = @import("../../services/languageRegistry.zig").LanguageIdCodec;
const ModelContentChangedEvent = @import("../../textModel/textModelEvents.zig").ModelContentChangedEvent;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const TreeSitterTree = @import("./TreeSitterTree.zig");
const LineRange = @import("../../basics/lineRange.zig").LineRange;
const TreeSitterTokenizationImpl = @import("./TreeSitterTokenizationImpl.zig");
const TreeSitterLibraryService = @import("../../services/TreeSitterLibraryService.zig");
const ModelTokensChangedEvent = @import("../../textModel/textModelEvents.zig").ModelTokensChangedEvent;

const TreeSitterSyntaxTokenBackend = @This();

super: AbstractSyntaxTokenBackend,

_treeSitterLibraryService: *TreeSitterLibraryService,
_tree: ?TreeSitterTree,
_tokenizationImpl: ?TreeSitterTokenizationImpl,
_languageId: []const u8,

pub fn init(
    _languageId: []const u8,
    languageIdCodec: *const LanguageIdCodec,
    textModel: *TextModel,
    visibleLineRanges: []const LineRange,
    _treeSitterLibraryService: *TreeSitterLibraryService,
) !TreeSitterSyntaxTokenBackend {
    var self = TreeSitterSyntaxTokenBackend{
        .super = AbstractSyntaxTokenBackend.init(.Completed, languageIdCodec, textModel, &.{
            .todo_resetTokenization = todo_resetTokenization,
            .handleDidChangeAttached = handleDidChangeAttached,
            .handleDidChangeContent = handleDidChangeContent,
            .forceTokenization = forceTokenization,
            .hasAccurateTokensForLine = hasAccurateTokensForLine,
            .isCheapToTokenize = isCheapToTokenize,
            .getLineTokens = getLineTokens,
            .getTokenTypeIfInsertingCharacter = getTokenTypeIfInsertingCharacter,
            .tokenizeLinesAt = tokenizeLinesAt,
            .hasTokens = hasTokens,
            .deinit = deinit,
            .destroy = destroy,
        }),
        ._languageId = _languageId,
        ._treeSitterLibraryService = _treeSitterLibraryService,
        ._tree = null,
        ._tokenizationImpl = null,
    };

    if (try self._treeSitterLibraryService.getLanguage(_languageId, false)) |treeSitterLang| {
        var parser = ts.Parser.create();
        try parser.setLanguage(treeSitterLang);

        if (self._treeSitterLibraryService.getInjectionQueries(_languageId)) |queries| {
            _ = queries;
            self._tree = try TreeSitterTree.init(_languageId, null, parser, textModel);
        }
    }

    if (self._tree) |treeModel| {
        if (self._treeSitterLibraryService.getHighlightingQueries(_languageId)) |queries| {
            self._tokenizationImpl = TreeSitterTokenizationImpl.init(treeModel, queries, languageIdCodec, visibleLineRanges);
        }
    }

    if (self._tokenizationImpl) |tokenizationImpl| {
        tokenizationImpl.onDidChangeTokens(&self, struct {
            fn cb(this: *TreeSitterSyntaxTokenBackend, e: ModelTokensChangedEvent) void {
                this.super._onDidChangeTokens.fire(e);
            }
        }.cb);
        tokenizationImpl.onDidChangeBackgroundTokenization(&self, struct {
            fn cb(this: *TreeSitterSyntaxTokenBackend, _: void) void {
                this.super._backgroundTokenizationState = .Completed;
                this.super._onDidChangeBackgroundTokenizationState.fire({});
            }
        }.cb);
    }
}

pub fn create(
    allocator: Allocator,
    _languageId: []const u8,
    languageIdCodec: *const LanguageIdCodec,
    textModel: *TextModel,
    visibleLineRanges: []const LineRange,
    _treeSitterLibraryService: *TreeSitterLibraryService,
) !*AbstractSyntaxTokenBackend {
    var self = try allocator.create(TreeSitterSyntaxTokenBackend);
    self.* = try init(_languageId, languageIdCodec, textModel, visibleLineRanges, _treeSitterLibraryService);
    return &self.super;
}

pub fn deinit(s: *AbstractSyntaxTokenBackend) void {
    const self = getSelf(s);
    if (self._tokenizationImpl) |tokenizationImpl| {
        tokenizationImpl.deinit();
    }
    if (self._tree) |tree| {
        tree.deinit();
    }
}

pub fn destroy(s: *AbstractSyntaxTokenBackend, allocator: Allocator) void {
    const self = getSelf(s);
    allocator.destroy(self);
}

fn getSelf(s: *AbstractSyntaxTokenBackend) *TreeSitterSyntaxTokenBackend {
    return @fieldParentPtr("super", s);
}

fn getLineTokens(s: *AbstractSyntaxTokenBackend, lineNumber: usize) !LineTokens {
    var self = getSelf(s);
    if (self._tokenizationImpl) |model| {
        return try model.getLineTokens(lineNumber);
    } else {
        var content = try self.super._textModel.getLineContent(lineNumber);
        defer content.deinit();
        return try LineTokens.createEmpty(self.super._textModel.getAllocator(), try content.toOwnedSlice(), self.super._languageIdCodec);
    }
}

pub fn todo_resetTokenization(s: *AbstractSyntaxTokenBackend, fireTokenChangeEvent: bool) !void {
    var self = getSelf(s);
    if (fireTokenChangeEvent) {
        self.super._onDidChangeTokens.fire(.{
            .semanticTokensApplied = false,
            .ranges = .{
                .{
                    .fromLineNumber = 1,
                    .toLineNumber = try self.super._textModel.getLineCount(),
                },
            },
        });
    }
}

pub fn handleDidChangeAttached(s: *AbstractSyntaxTokenBackend) void {
    const self = getSelf(s);
    _ = self;
    // TODO @alexr00 implement for background tokenization
}

pub fn handleDidChangeContent(s: *AbstractSyntaxTokenBackend, e: ModelContentChangedEvent) !void {
    var self = getSelf(s);
    if (e.isFlush) {
        // Don't fire the event, as the view might not have got the text change event yet
        try self.super.todo_resetTokenization(false);
    } else {
        if (self._tokenizationImpl) |*model| {
            try model.handleContentChanged(e);
        }
    }

    if (self._tree) |*treeModel| {
        try treeModel.handleContentChange(e, null);
    }
}

pub fn forceTokenization(s: *AbstractSyntaxTokenBackend, lineNumber: usize) !void {
    const self = getSelf(s);
    if (self._tokenizationImpl) |*model| {
        if (!(try model.hasAccurateTokensForLine(lineNumber))) {
            try model.tokenizeEncoded(lineNumber);
        }
    }
}

pub fn hasAccurateTokensForLine(s: *AbstractSyntaxTokenBackend, lineNumber: usize) !bool {
    const self = getSelf(s);
    if (self._tokenizationImpl) |model| {
        return try model.hasAccurateTokensForLine(lineNumber);
    }
    return false;
}

pub fn isCheapToTokenize(s: *AbstractSyntaxTokenBackend, lineNumber: usize) bool {
    const self = getSelf(s);
    _ = self;
    _ = lineNumber;
    // TODO @alexr00 determine what makes it cheap to tokenize?
    return true;
}

pub fn getTokenTypeIfInsertingCharacter(s: *AbstractSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) !StandardTokenType {
    const self = getSelf(s);
    _ = self;
    _ = lineNumber;
    _ = column;
    _ = character;
    // TODO @alexr00 implement once we have custom parsing and don't just feed in the whole text model value
    return .other;
}

pub fn tokenizeLinesAt(s: *AbstractSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) !?[]LineTokens {
    const self = getSelf(s);
    if (self._tokenizationImpl) |*model| {
        return try model.tokenizeLinesAt(lineNumber, lines);
    }
    return null;
}

pub fn hasTokens(s: *AbstractSyntaxTokenBackend) !bool {
    const self = getSelf(s);
    if (self._tokenizationImpl) |model| {
        return try model.hasTokens(null);
    }
    return false;
}
