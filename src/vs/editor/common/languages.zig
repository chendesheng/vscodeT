const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Position = @import("./core/position.zig").Position;
const ContiguousMultilineTokens = @import("./tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TextModel = @import("./model/textModel.zig").TextModel;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;
const LanguageId = @import("./encodedTokenAttributes.zig").LanguageId;
const Range = @import("./core/range.zig").Range;
const ModelContentChangedEvent = @import("./textModelEvents.zig").ModelContentChangedEvent;
const CancellationToken = @import("../../base/common/cancellation.zig").CancellationToken;

pub const NULL_LANGUAGE_ID = "nullLanguage";

// @internal
pub const LanguageIdCodec = struct {
    _languageIdToLanguage: ArrayList([]const u8),
    _languageToLanguageId: std.StringHashMap(u8),

    pub fn init(allocator: Allocator) !LanguageIdCodec {
        var codec = LanguageIdCodec{
            ._languageIdToLanguage = ArrayList([]const u8).init(allocator),
            ._languageToLanguageId = std.StringHashMap(u8).init(allocator),
        };
        errdefer codec.deinit();
        try codec._register(NULL_LANGUAGE_ID, @backingInt(LanguageId.Null));
        try codec._register("plaintext", @backingInt(LanguageId.PlainText));
        return codec;
    }

    pub fn deinit(self: *LanguageIdCodec) void {
        self._languageIdToLanguage.deinit();
        self._languageToLanguageId.deinit();
    }

    fn _register(self: *LanguageIdCodec, language: []const u8, languageId: u8) !void {
        try self._languageIdToLanguage.append(language);
        errdefer _ = self._languageIdToLanguage.pop();
        try self._languageToLanguageId.put(language, languageId);
    }

    pub fn register(self: *LanguageIdCodec, language: []const u8) !void {
        if (self._languageToLanguageId.get(language)) |_| {
            return;
        }
        if (self._languageIdToLanguage.items.len > std.math.maxInt(u8)) return error.TooManyLanguages;
        const languageId: u8 = @intCast(self._languageIdToLanguage.items.len);
        try self._register(language, languageId);
    }

    pub fn encodeLanguageId(self: *const LanguageIdCodec, language: []const u8) !u8 {
        if (self._languageToLanguageId.get(language)) |languageId| {
            return languageId;
        }
        return @backingInt(LanguageId.Null);
    }

    pub fn decodeLanguageId(self: *LanguageIdCodec, languageId: u8) []const u8 {
        if (languageId < self._languageIdToLanguage.items.len) {
            return self._languageIdToLanguage.items[languageId];
        }
        return NULL_LANGUAGE_ID;
    }

    /// Erases the concrete codec behind `ILanguageIdCodec`.
    pub fn interface(self: *LanguageIdCodec) ILanguageIdCodec {
        return .{
            .context = self,
            .encodeLanguageId = struct {
                fn call(context: *anyopaque, languageId: []const u8) !u8 {
                    const codec: *LanguageIdCodec = @ptrCast(@alignCast(context));
                    return codec.encodeLanguageId(languageId);
                }
            }.call,
            .decodeLanguageId = struct {
                fn call(context: *anyopaque, languageId: u8) []const u8 {
                    const codec: *LanguageIdCodec = @ptrCast(@alignCast(context));
                    return codec.decodeLanguageId(languageId);
                }
            }.call,
        };
    }
};

/// A codec which can encode and decode a string `languageId` as a number.
pub const ILanguageIdCodec = struct {
    context: *anyopaque,
    encodeLanguageId: *const fn (context: *anyopaque, languageId: []const u8) anyerror!u8,
    decodeLanguageId: *const fn (context: *anyopaque, languageId: u8) []const u8,

    pub fn encode(self: ILanguageIdCodec, language_id: []const u8) !u8 {
        return self.encodeLanguageId(self.context, language_id);
    }

    pub fn decode(self: ILanguageIdCodec, language_id: u8) []const u8 {
        return self.decodeLanguageId(self.context, language_id);
    }
};

test "ILanguageIdCodec: adapts the concrete codec" {
    var codec = try LanguageIdCodec.init(std.testing.allocator);
    defer codec.deinit();
    try codec.register("zig");

    const codec_iface = codec.interface();
    const zig_id = try codec_iface.encode("zig");
    try std.testing.expectEqualStrings("zig", codec_iface.decode(zig_id));
    try std.testing.expectEqualStrings(NULL_LANGUAGE_ID, codec_iface.decode(@backingInt(LanguageId.Null)));
}

pub const Token = struct {
    offset: usize,
    type_: []const u8,
    language: []const u8,

    pub fn init(
        offset: usize,
        type_: []const u8,
        language: []const u8,
    ) Token {
        return Token{
            .offset = offset,
            .type_ = type_,
            .language = language,
        };
    }

    pub fn toString(self: *Token, writer: *Io.Writer) !void {
        try writer.print("({d}, {s})", .{ self.offset, self.type_ });
    }
};

// @internal
pub const TokenizationSupportChangedEvent = struct {
    changedLanguages: []const []const u8,
    changedColorMap: bool,

    pub fn affects(self: *const TokenizationSupportChangedEvent, languageId: []const u8) bool {
        for (self.changedLanguages) |changedLanguage| {
            if (std.mem.eql(u8, changedLanguage, languageId)) {
                return true;
            }
        }
        return false;
    }
};

// @internal
pub const TokenizationResult = struct {
    tokens: []Token,
    endState: IState,

    pub fn init(tokens: []Token, endState: IState) TokenizationResult {
        return TokenizationResult{
            .tokens = tokens,
            .endState = endState,
        };
    }
};

// @internal
pub const EncodedTokenizationResult = struct {
    tokens: []TokenPacked,
    endState: IState,

    pub fn init(tokens: []TokenPacked, endState: IState) EncodedTokenizationResult {
        return EncodedTokenizationResult{
            .tokens = tokens,
            .endState = endState,
        };
    }
};

pub const SyntaxNode = struct {
    startIndex: usize,
    endIndex: usize,
    startPosition: Position,
    endPosition: Position,
};

pub const QueryCapture = struct {
    name: []u8,
    text: ?[]u8,
    node: SyntaxNode,
    encodedLanguageId: u32,
};

// The state of a tokenizer between two lines.
//
// States are interface objects: `context` points at the concrete state data and
// `vtable` provides the operations. Clones must be allocated with the supplied
// allocator.
pub const IState = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        clone: *const fn (context: *anyopaque, allocator: Allocator) anyerror!IState,
        equals: *const fn (context: *anyopaque, other: IState) bool,
    };

    pub fn clone(self: IState, allocator: Allocator) anyerror!IState {
        return self.vtable.clone(self.context, allocator);
    }

    pub fn equals(self: IState, other: IState) bool {
        return self.vtable.equals(self.context, other);
    }
};

// @internal
pub const ITokenizationSupport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // If true, the background tokenizer will only be used to verify tokens
        // against the default background tokenizer. Used for debugging.
        backgroundTokenizerShouldOnlyVerifyTokens: ?bool = null,
        getInitialState: *const fn (context: *anyopaque, allocator: Allocator) anyerror!IState,
        tokenize: ?*const fn (context: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!TokenizationResult = null,
        tokenizeEncoded: *const fn (context: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult,
        // Can be null if default background tokenization should be used.
        createBackgroundTokenizer: ?*const fn (context: *anyopaque, textModel: *TextModel, store: IBackgroundTokenizationStore) IBackgroundTokenizer = null,
        dispose: ?*const fn (context: *anyopaque) void = null,
    };

    pub fn getInitialState(self: ITokenizationSupport, allocator: Allocator) anyerror!IState {
        return self.vtable.getInitialState(self.context, allocator);
    }

    pub fn tokenizeEncoded(self: ITokenizationSupport, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        return self.vtable.tokenizeEncoded(self.context, allocator, line, hasEOL, state);
    }

    pub fn createBackgroundTokenizer(self: ITokenizationSupport, textModel: *TextModel, store: IBackgroundTokenizationStore) ?IBackgroundTokenizer {
        const create = self.vtable.createBackgroundTokenizer orelse return null;
        return create(self.context, textModel, store);
    }

    pub fn dispose(self: ITokenizationSupport) void {
        if (self.vtable.dispose) |disposeFn| disposeFn(self.context);
    }
};

// @internal
pub const IBackgroundTokenizer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Instructs the background tokenizer to set the tokens for the given
        // range again. This might be necessary if the renderer overwrote those
        // tokens with heuristically computed ones for some viewport, when the
        // change does not even propagate to that viewport.
        requestTokens: *const fn (context: *anyopaque, startLineNumber: usize, endLineNumberExclusive: usize) void,
        reportMismatchingTokens: ?*const fn (context: *anyopaque, lineNumber: usize) void = null,
        dispose: ?*const fn (context: *anyopaque) void = null,
        // Terminal adaptations of upstream's web-worker callbacks. The editor
        // main loop drives `poll` and drains the worker responses; upstream
        // delivers them through the browser message queue instead.
        poll: ?*const fn (context: *anyopaque) bool = null,
        isPending: ?*const fn (context: *anyopaque) bool = null,
        onDidChangeContent: ?*const fn (context: *anyopaque, e: *const ModelContentChangedEvent) void = null,
    };

    pub fn requestTokens(self: IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) void {
        self.vtable.requestTokens(self.context, startLineNumber, endLineNumberExclusive);
    }

    pub fn reportMismatchingTokens(self: IBackgroundTokenizer, lineNumber: usize) void {
        if (self.vtable.reportMismatchingTokens) |report| report(self.context, lineNumber);
    }

    pub fn dispose(self: IBackgroundTokenizer) void {
        if (self.vtable.dispose) |disposeFn| disposeFn(self.context);
    }

    pub fn poll(self: IBackgroundTokenizer) bool {
        const pollFn = self.vtable.poll orelse return false;
        return pollFn(self.context);
    }

    pub fn isPending(self: IBackgroundTokenizer) bool {
        const pendingFn = self.vtable.isPending orelse return false;
        return pendingFn(self.context);
    }

    pub fn onDidChangeContent(self: IBackgroundTokenizer, e: *const ModelContentChangedEvent) void {
        if (self.vtable.onDidChangeContent) |notify| notify(self.context, e);
    }
};

/// Creates a background tokenizer for a model. Upstream installs this factory
/// in the workbench TextMate feature; the terminal registry owns the process
/// worker instead, so the editor backend can ask for it without importing the
/// workbench.
// @internal
pub const IBackgroundTokenizerFactory = struct {
    context: *anyopaque,
    create: *const fn (context: *anyopaque, textModel: *TextModel, store: IBackgroundTokenizationStore) ?IBackgroundTokenizer,
};

// @internal
pub const IBackgroundTokenizationStore = struct {
    context: *anyopaque,
    setTokens: *const fn (context: *anyopaque, tokens: []ContiguousMultilineTokens) void,

    setEndState: *const fn (context: *anyopaque, lineNumber: usize, state: IState) void,

    // Should be called to indicate that the background tokenization has finished for now.
    backgroundTokenizationFinished: *const fn (context: *anyopaque) void,
};

// @internal
pub const LazyTokenizationSupport = struct {
    context: *anyopaque,
    createSupport: *const fn (context: *anyopaque) ?ITokenizationSupport,
    _tokenizationSupport: ?ITokenizationSupport = null,

    pub fn init(context: *anyopaque, createSupport: *const fn (context: *anyopaque) ?ITokenizationSupport) LazyTokenizationSupport {
        return LazyTokenizationSupport{
            .context = context,
            .createSupport = createSupport,
            ._tokenizationSupport = null,
        };
    }

    pub fn getTokenizationSupport(self: *LazyTokenizationSupport) ?ITokenizationSupport {
        if (self._tokenizationSupport) |tokenizationSupport| {
            return tokenizationSupport;
        }
        self._tokenizationSupport = self.createSupport(self.context);
        return self._tokenizationSupport;
    }
};

/// A color in the document, with components normalized to [0, 1].
pub const IColor = struct {
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32,
};

/// A color and the range of the document it was found at.
pub const IColorInformation = struct {
    range: @import("./core/range.zig").Range,
    color: IColor,
};

/// A markdown string used by hover contents.
pub const IMarkdownString = struct {
    value: []const u8,
    is_trusted: ?bool = null,
    support_theme_icons: ?bool = null,
    support_html: ?bool = null,
};

pub const MarkdownString = struct {
    value: []const u8,
    is_trusted: ?bool = null,
    support_theme_icons: ?bool = null,
    support_html: ?bool = null,

    pub fn init(value: []const u8) MarkdownString {
        return .{ .value = value };
    }

    pub fn interface(self: *const MarkdownString) IMarkdownString {
        return .{
            .value = self.value,
            .is_trusted = self.is_trusted,
            .support_theme_icons = self.support_theme_icons,
            .support_html = self.support_html,
        };
    }
};

pub const HoverVerbosityAction = enum(u32) {
    Increase = 0,
    Decrease = 1,
};

/// Additional information for a symbol or word, rendered in a tooltip-like
/// widget by the editor.
pub const Hover = struct {
    contents: []const IMarkdownString,
    range: ?Range = null,
    can_increase_verbosity: ?bool = null,
    can_decrease_verbosity: ?bool = null,
};

pub const HoverVerbosityRequest = struct {
    verbosity_delta: i32,
    previous_hover: Hover,
};

pub const HoverContext = struct {
    verbosity_request: ?HoverVerbosityRequest = null,
};

/// The contract between extensions and the hover feature.
pub const HoverProvider = struct {
    context: *anyopaque,
    provide_hover: *const fn (
        context: *anyopaque,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
        hover_context: ?*const HoverContext,
    ) anyerror!?Hover,
};

/// Port of `DocumentHighlightKind` from
/// `src/vs/editor/common/languages.ts`.
pub const DocumentHighlightKind = enum(u8) {
    /// A textual occurrence.
    Text = 0,
    /// Read-access of a symbol, like reading a variable.
    Read = 1,
    /// Write-access of a symbol, like writing to a variable.
    Write = 2,
};

/// Port of `DocumentHighlight`. The kind defaults to `Text` when omitted.
pub const DocumentHighlight = struct {
    range: Range,
    kind: ?DocumentHighlightKind = null,
};

/// Port of `DocumentHighlightProvider`.
pub const DocumentHighlightProvider = struct {
    context: *anyopaque,
    provide_document_highlights: *const fn (
        context: *anyopaque,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror!?[]const DocumentHighlight,
};

/// Port of `SelectionRange` from
/// `src/vs/editor/common/languages.ts`.
pub const SelectionRange = struct {
    range: Range,
};

/// Port of `SelectionRangeProvider`.
///
/// The provider allocates the returned buckets with the supplied allocator;
/// the caller decides how they are freed (the smart-select helper gives each
/// provider a temporary arena).
pub const SelectionRangeProvider = struct {
    context: *anyopaque,
    provide_selection_ranges: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        positions: []const Position,
        token: CancellationToken,
    ) anyerror![]const []const SelectionRange,
};

/// Port of the definition/location subset of
/// `src/vs/editor/common/languages.ts`.
pub const Location = struct {
    /// Canonical resource key (`scheme://authority/path?query#fragment`).
    /// The editor only needs identity here; the TUI has no go-to-definition
    /// surface yet.
    uri: []const u8,
    range: Range,
};

pub const LocationLink = struct {
    origin_selection_range: ?Range = null,
    uri: []const u8,
    range: Range,
    target_selection_range: Range,
};

pub const DefinitionProvider = struct {
    context: *anyopaque,
    provide_definition: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror![]LocationLink,
};

pub const DeclarationProvider = struct {
    context: *anyopaque,
    provide_declaration: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror![]LocationLink,
};

pub const ImplementationProvider = struct {
    context: *anyopaque,
    provide_implementation: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror![]LocationLink,
};

pub const TypeDefinitionProvider = struct {
    context: *anyopaque,
    provide_type_definition: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror![]LocationLink,
};

/// Port of `ReferenceContext` from `src/vs/editor/common/languages.ts`.
pub const ReferenceContext = struct {
    include_declaration: bool = false,
};

/// Port of `ReferenceProvider`. The provider allocates the returned locations
/// (including each URI) with the supplied allocator.
pub const ReferenceProvider = struct {
    context: *anyopaque,
    provide_references: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        reference_context: ReferenceContext,
        token: CancellationToken,
    ) anyerror![]Location,
};

/// Port of `DocumentSymbol` from `src/vs/editor/common/languages.ts`.
/// Children own their fields through the allocator supplied to the provider.
pub const DocumentSymbol = struct {
    name: []const u8,
    detail: []const u8 = "",
    kind: u32,
    tags: []const u32 = &.{},
    container_name: ?[]const u8 = null,
    range: Range,
    selection_range: Range,
    children: []const DocumentSymbol = &.{},
};

/// Terminal continuation for a provider Promise. Results live in the
/// request allocator. Disposing the pending request prevents delivery.
pub const DocumentSymbolCallback = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, []const DocumentSymbol) void,
};

pub const DocumentSymbolProvider = struct {
    context: *anyopaque,
    display_name: []const u8 = "",
    request_document_symbols: ?*const fn (*anyopaque, Allocator, *TextModel, DocumentSymbolCallback) anyerror!?@import("../../base/common/lifecycle.zig").IDisposable = null,
    provide_document_symbols: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        token: CancellationToken,
    ) anyerror![]const DocumentSymbol,
};

pub const TextEdit = struct {
    range: Range,
    text: []const u8,
};

pub const FormattingOptions = struct {
    tab_size: u32,
    insert_spaces: bool,
};

pub const DocumentFormattingEditProvider = struct {
    context: *anyopaque,
    extension_id: []const u8 = "",
    display_name: []const u8 = "",
    provide_document_formatting_edits: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        options: FormattingOptions,
        token: CancellationToken,
    ) anyerror![]const TextEdit,
};

pub const DocumentRangeFormattingEditProvider = struct {
    context: *anyopaque,
    extension_id: []const u8 = "",
    display_name: []const u8 = "",
    provide_document_range_formatting_edits: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        range: Range,
        options: FormattingOptions,
        token: CancellationToken,
    ) anyerror![]const TextEdit,
};

pub const OnTypeFormattingEditProvider = struct {
    context: *anyopaque,
    extension_id: []const u8 = "",
    auto_format_trigger_characters: []const []const u8 = &.{},
    provide_on_type_formatting_edits: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        ch: []const u8,
        options: FormattingOptions,
        token: CancellationToken,
    ) anyerror![]const TextEdit,
};

pub const Command = struct {
    id: []const u8,
    title: []const u8 = "",
    arguments: ?std.json.Value = null,
};

/// Port of the code-action subset. Workspace edits are kept as the raw
/// `IWorkspaceEditDto` JSON until a bulk-edit service is ported; the TUI has no
/// code-action surface yet.
pub const CodeAction = struct {
    title: []const u8,
    kind: ?[]const u8 = null,
    is_preferred: bool = false,
    disabled: ?[]const u8 = null,
    command: ?Command = null,
    edit_json: ?std.json.Value = null,
};

pub const CodeActionList = struct {
    actions: []const CodeAction = &.{},
};

pub const CodeActionContext = struct {
    only: ?[]const u8 = null,
    trigger_kind: u8 = 1,
    diagnostics: ?std.json.Value = null,
};

pub const CodeActionProvider = struct {
    context: *anyopaque,
    display_name: []const u8 = "",
    extension_id: []const u8 = "",
    provided_kinds: []const []const u8 = &.{},
    provide_code_actions: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        range: Range,
        action_context: CodeActionContext,
        token: CancellationToken,
    ) anyerror!CodeActionList,
};

test "IColorInformation: holds a range and a color" {
    const information = IColorInformation{
        .range = Range.init(1, 1, 1, 7),
        .color = .{ .red = 1, .green = 0.5, .blue = 0, .alpha = 1 },
    };
    try std.testing.expectEqual(@as(usize, 6), information.range.endColumn - information.range.startColumn);
    try std.testing.expectEqual(@as(f32, 0.5), information.color.green);
}
