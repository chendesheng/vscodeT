const std = @import("std");
const Emitter = @import("../../basics/event.zig").Emitter;
const Allocator = std.mem.Allocator;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const TreeSitterTree = @import("treeSitterTree.zig").TreeSitterTree;
const TreeSitterSyntaxTokenBackend = @import("treeSitterSyntaxTokenBackend.zig").TreeSitterSyntaxTokenBackend;
const TokenStore = @import("tokenStore.zig").TokenStore;
const TokenUpdate = @import("tokenStore.zig").TokenUpdate;
const TokenQuality = @import("tokenStore.zig").TokenQuality;
const Token = @import("../../languages.zig").Token;
const TokenizationResult = @import("../../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../../languages.zig").EncodedTokenizationResult;
const IState = @import("../../languages.zig").IState;
const LanguageIdCodec = @import("../../services/languageRegistry.zig").LanguageIdCodec;
const LineRange = @import("../../basics/lineRange.zig").LineRange;
const ModelTokensChangedEvent = @import("../../textModel/textModelEvents.zig").ModelTokensChangedEvent;

const Self = @This();

_tokenStore: TokenStore,
_accurateVersion: u32,
_guessVersion: u32,
onDidChangeTokens: Emitter(struct { changes: ModelTokensChangedEvent }),
onDidChangeBackgroundTokenization: Emitter(void),
_tree: TreeSitterTree,
_encodedLanguageId: u8,
_languageIdCodec: *const LanguageIdCodec,

fn init(
    _tree: TreeSitterTree,
    _languageIdCodec: *const LanguageIdCodec,
    _visibleLineRange: []const LineRange,
) !Self {
    const _textModel = _tree.textModel;
    const allocator = _textModel.getAllocator();
    const encodedLanguageId = try _languageIdCodec.encode(_tree.languageId);
    return Self{
        ._tokenStore = try TokenStore.init(_textModel),
        ._accurateVersion = _textModel.getVersionId(),
        ._guessVersion = _textModel.getVersionId(),
        ._tree = _tree,
        ._languageIdCodec = _languageIdCodec,
        .onDidChangeTokens = Emitter(struct { changes: ModelTokensChangedEvent }).init(allocator),
        .onDidChangeBackgroundTokenization = Emitter(void).init(allocator),
        ._encodedLanguageId = encodedLanguageId,
        ._visibleLineRange = _visibleLineRange,
    };
}

fn textModel(self: *Self) *TextModel {
    return self._tree.textModel;
}
