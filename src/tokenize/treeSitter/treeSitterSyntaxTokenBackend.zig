const std = @import("std");
const ts = @import("tree-sitter");
const AbstractSyntaxTokenBackend = @import("../abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const BackgroundTokenizationState = @import("../abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const Emitter = @import("../../basics/event.zig").Emitter;
const LanguageIdCodec = @import("../../services/languageRegistry.zig").LanguageIdCodec;
const ModelContentChangedEvent = @import("../../model/modelContentChangedEvent.zig").ModelContentChangedEvent;
const TextModel = @import("../../model/textModel.zig").TextModel;
const TreeSitterTree = @import("./TreeSitterTree.zig");
const LineRange = @import("../../basics/lineRange.zig");
const TreeSitterTokenizationImpl = @import("./TreeSitterTokenizationImpl.zig");
const TreeSitterLibraryService = @import("../../services/TreeSitterLibraryService.zig");
const ModelTokensChangedEvent = @import("../../textModel/textModelEvents.zig");

const TreeSitterSyntaxTokenBackend = struct {
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
    ) TreeSitterSyntaxTokenBackend {
        var self = TreeSitterSyntaxTokenBackend{
            .super = AbstractSyntaxTokenBackend.init(.Completed, languageIdCodec, textModel, .{}),
            ._languageId = _languageId,
            ._treeSitterLibraryService = _treeSitterLibraryService,
        };

        if (self._treeSitterLibraryService.getLanguage(_languageId, false)) |treeSitterLang| {
            var parser = ts.Parser.create();
            parser.setLanguage(treeSitterLang);

            if (self._treeSitterLibraryService.getInjectionQueries(_languageId)) |queries| {
                _ = queries;
                self._tree = TreeSitterTree.init(_languageId, null, parser, textModel);
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

    pub fn getLineTokens(self: *TreeSitterSyntaxTokenBackend, lineNumber: usize) LineTokens {
        const model = self._tokenizationImpl;
        if (!model) {
            const content = self._textModel.getLineContent(lineNumber);
            return LineTokens.createEmpty(content, self._languageIdCodec);
        }
        return model.getLineTokens(lineNumber);
    }

    pub fn todo_resetTokenization(self: *TreeSitterSyntaxTokenBackend, _fireTokenChangeEvent: ?bool) void {
        if (_fireTokenChangeEvent orelse true) {
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

    pub fn handleDidChangeAttached() void {
        // TODO @alexr00 implement for background tokenization
    }

    pub fn handleDidChangeContent(self: TreeSitterSyntaxTokenBackend, e: ModelContentChangedEvent) void {
        if (e.isFlush) {
            // Don't fire the event, as the view might not have got the text change event yet
            self.todo_resetTokenization(false);
        } else {
            if (self._tokenizationImpl) |model| {
                model.handleContentChanged(e);
            }
        }

        if (self._tree) |treeModel| {
            treeModel.handleContentChange(e);
        }
    }

    pub fn forceTokenization(self: *TreeSitterSyntaxTokenBackend, lineNumber: usize) void {
        if (self._tokenizationImpl) |model| {
            if (!model.hasAccurateTokensForLine(lineNumber)) {
                model.tokenizeEncoded(lineNumber);
            }
        }
    }

    pub fn hasAccurateTokensForLine(self: *TreeSitterSyntaxTokenBackend, lineNumber: usize) bool {
        if (self._tokenizationImpl.get()) |model| {
            return model.hasAccurateTokensForLine(lineNumber);
        }
        return false;
    }

    pub fn isCheapToTokenize(lineNumber: usize) bool {
        _ = lineNumber;
        // TODO @alexr00 determine what makes it cheap to tokenize?
        return true;
    }

    pub fn getTokenTypeIfInsertingCharacter(lineNumber: usize, column: usize, character: []const u8) StandardTokenType {
        _ = lineNumber;
        _ = column;
        _ = character;
        // TODO @alexr00 implement once we have custom parsing and don't just feed in the whole text model value
        return .other;
    }

    pub fn tokenizeLinesAt(self: *TreeSitterSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
        if (self._tokenizationImpl.get()) |model| {
            return model.tokenizeLinesAt(lineNumber, lines);
        }
        return null;
    }

    pub fn hasTokens(self: *TreeSitterSyntaxTokenBackend) bool {
        if (self._tokenizationImpl) |model| {
            return model.hasTokens();
        }
        return false;
    }
};
