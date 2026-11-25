// Terminal editor widget: port of the model/view/controller subset of
// `src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts`, its
// `ViewModelImpl` and `CursorsController`.
//
// Terminal adaptation: upstream separates the `TextModel` from each editor's
// `CodeEditorWidget`/view model. This file keeps that split as
// `EditorDocument` (shared model, undo, language services, saved/dirty state)
// plus `Editor` (one independent view: wrapping, cursors, folding, scroll).
// Split editor groups create a second `Editor` over the same document.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const editorBrowser = @import("../../editorBrowser.zig");
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../../../common/model.zig").TextModelCreationOptions;
const PositionAffinity = @import("../../../common/model.zig").PositionAffinity;
const IdentifiedSingleEditOperation = @import("../../../common/model.zig").IdentifiedSingleEditOperation;
const ValidEditOperation = @import("../../../common/model.zig").ValidEditOperation;
const CursorStateComputer = @import("../../../common/model/editStack.zig").CursorStateComputer;
const UndoRedoService = @import("../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;
const LanguageIdCodec = @import("../../../common/languages.zig").LanguageIdCodec;
const languages = @import("../../../common/languages.zig");
const position_converter = @import("../../../../workbench/api/common/positionConverter.zig");
const ProjectedViewModelLines = @import("../../../common/viewModel/viewModelLines.zig").ProjectedViewModelLines;
const ViewLayout = @import("../../../common/viewLayout/viewLayout.zig").ViewLayout;
const scrollable_mod = @import("../../../../base/common/scrollable.zig");
const ViewModelEventDispatcher = @import("../../../common/viewModelEventDispatcher.zig").ViewModelEventDispatcher;
const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const view_events = @import("../../../common/viewEvents.zig");
const CoordinatesConverter = @import("../../../common/viewModel/viewModelLines.zig").CoordinatesConverter;
const ViewLineData = @import("../../../common/viewModel.zig").ViewLineData;
const WordBreak = @import("../../../common/modelLineProjectionData.zig").WordBreak;
const WrappingIndent = @import("../../../common/config/editorOptions.zig").WrappingIndent;
const WordWrap = @import("../../../common/config/editorOptions.zig").WordWrap;
const terminal_editor_config = @import("../../config/terminalEditorConfiguration.zig");
const resolved_keybinding_item = @import("../../../../platform/keybinding/common/resolvedKeybindingItem.zig");
const EditorAutoIndentStrategy = @import("../../../common/config/editorOptions.zig").EditorAutoIndentStrategy;
const cursorCommon = @import("../../../common/cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const CursorContext = @import("../../../common/cursor/cursorContext.zig").CursorContext;
const CursorState = cursorCommon.CursorState;
const CursorChangeReason = @import("../../../common/cursorEvents.zig").CursorChangeReason;
const ICursorPositionChangedEvent = @import("../../../common/cursorEvents.zig").ICursorPositionChangedEvent;
const ICursorSelectionChangedEvent = @import("../../../common/cursorEvents.zig").ICursorSelectionChangedEvent;
const TextEditorSelectionSource = @import("../../../common/cursorEvents.zig").TextEditorSelectionSource;
const PartialCursorState = cursorCommon.PartialCursorState;
const SingleCursorState = cursorCommon.SingleCursorState;
const EditOperationType = cursorCommon.EditOperationType;
const CursorCollection = @import("../../../common/cursor/cursorCollection.zig").CursorCollection;
const TextModelCursorSimpleModel = @import("../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const CursorMoveCommands = @import("../../../common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const CursorMoveDirection = @import("../../../common/cursor/cursorMoveCommands.zig").Direction;
const CursorMoveUnit = @import("../../../common/cursor/cursorMoveCommands.zig").Unit;
const CursorWordDirection = @import("../../../common/cursor/cursorMoveCommands.zig").WordDirection;
const DeleteOperations = @import("../../../common/cursor/cursorDeleteOperations.zig").DeleteOperations;
const TypeWithoutInterceptorsOperation = @import("../../../common/cursor/cursorTypeEditOperations.zig").TypeWithoutInterceptorsOperation;
const EnterOperation = @import("../../../common/cursor/cursorTypeEditOperations.zig").EnterOperation;
const AutoIndentOperation = @import("../../../common/cursor/cursorTypeEditOperations.zig").AutoIndentOperation;
const EditOperationResult = cursorCommon.EditOperationResult;

const WordCharacterClassifier = @import("../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const DefaultWordSeparators = @import("../../../common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const InternalModelContentChangeEvent = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
const ModelDecorationsChangedEvent = @import("../../../common/textModelEvents.zig").ModelDecorationsChangedEvent;
const String = @import("../../../../base/common/strings.zig").String;
const strings = @import("../../../../base/common/strings.zig");
const language = @import("../../../../workbench/services/language/common/bundledLanguages.zig");
const language_configuration = @import("../../../common/languages/languageConfiguration.zig");
const encoding_mod = @import("../../../../workbench/services/textfile/common/encoding.zig");
const EOL = @import("../../../common/core/misc/eolCounter.zig").EOL;
const countEOL = @import("../../../common/core/misc/eolCounter.zig").countEOL;
const editor_status = @import("../../../../workbench/browser/parts/editor/editorStatus.zig");
const editor_common = @import("../../../common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const command_runner = @import("../../../common/commands/commandRunner.zig");
const ReplaceCommandCommand = @import("../../../common/commands/replaceCommand.zig").ReplaceCommand;
const lines_ops = @import("../../../contrib/linesOperations/browser/linesOperations.zig");
const line_selection = @import("../../../contrib/lineSelection/browser/lineSelection.zig");
const LineCommentCommand = @import("../../../contrib/comment/browser/lineCommentCommand.zig").LineCommentCommand;
const CommentType = @import("../../../contrib/comment/browser/lineCommentCommand.zig").Type;
const BlockCommentCommand = @import("../../../contrib/comment/browser/blockCommentCommand.zig").BlockCommentCommand;
const InsertFinalNewLineCommand = @import("../../../contrib/insertFinalNewLine/browser/insertFinalNewLineCommand.zig").InsertFinalNewLineCommand;
const bracket_matching = @import("../../../contrib/bracketMatching/browser/bracketMatching.zig");
const BracketMatchingController = bracket_matching.BracketMatchingController;
const folding = @import("../../../contrib/folding/browser/folding.zig");
const FoldingRules = @import("../../../common/languages/languageConfiguration.zig").FoldingRules;
const language_configuration_registry = @import("../../../common/languages/languageConfigurationRegistry.zig");
const LanguageConfigurationService = language_configuration_registry.LanguageConfigurationService;
const completion = @import("../../../common/languages/completion.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const extensions_registry = @import("../../../../workbench/services/extensions/common/extensionsRegistry.zig");
const language_config_point = @import("../../../../workbench/services/language/common/languageConfigurationExtensionPoint.zig");
const text_mate_tokenizer = @import("../../../common/model/tokens/textMateTokenizer.zig");
const AttachedView = @import("../../../common/model/tokens/abstractSyntaxTokenBackend.zig").AttachedView;
const MirrorTextModel = @import("../../../common/model/mirrorTextModel.zig").MirrorTextModel;
const JsonContentChange = json_language.Client.ContentChange;
const json_language = @import("../../../../workbench/services/language/common/jsonLanguageClient.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
const languagesAssociations = @import("../../../common/services/languagesAssociations.zig");
const input = @import("ui").input;
const ui_scroll = @import("ui").scroll;
const keybinding_service = @import("../../../../workbench/services/keybinding/browser/keybindingService.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const keybinding_registry = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const CommandRegistry = @import("../../../../platform/commands/common/commands.zig").CommandRegistry;
const ShiftCommand = @import("../../../common/commands/shiftCommand.zig").ShiftCommand;
const IShiftCommandOpts = @import("../../../common/commands/shiftCommand.zig").IShiftCommandOpts;
const indentation_commands = @import("../../../contrib/indentation/browser/indentation.zig");
const IndentationToSpacesCommand = indentation_commands.IndentationToSpacesCommand;
const IndentationToTabsCommand = indentation_commands.IndentationToTabsCommand;
const ISingleEditOperation = @import("../../../common/core/editOperation.zig").ISingleEditOperation;
const multicursor = @import("../../../contrib/multicursor/browser/multicursor.zig");
const auto_closing = @import("../../../common/cursor/autoClosing.zig");
const CharacterPairSupport = @import("../../../common/languages/supports/characterPair.zig");
const smart_select = @import("../../../contrib/smartSelect/browser/smartSelect.zig");
const in_place_replace = @import("../../../contrib/inPlaceReplace/browser/inPlaceReplace.zig");
const InPlaceReplaceCommand = @import("../../../contrib/inPlaceReplace/browser/inPlaceReplaceCommand.zig").InPlaceReplaceCommand;
const model_module = @import("../../../common/model.zig");
const ModelDecorationOptions = model_module.ModelDecorationOptions;
const ModelDeltaDecoration = model_module.ModelDeltaDecoration;
const LanguageFeaturesService = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const MarkerDecorationsService = @import("../../../common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers = @import("../../../../platform/markers/common/markers.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

const SymbolPositions = struct {
    arena: Allocator,
    mirror: *const MirrorTextModel,
    lines: std.AutoHashMapUnmanaged(u32, position_converter.LineIndex) = .empty,

    fn column(self: *SymbolPositions, line: u32, character: u32) !usize {
        if (line >= self.mirror.getLineCount()) return @as(usize, character) + 1;
        const slot = try self.lines.getOrPut(self.arena, line);
        if (!slot.found_existing) slot.value_ptr.* = try position_converter.LineIndex.init(self.arena, self.mirror.getLineContent(@as(usize, line) + 1));
        return slot.value_ptr.column(character);
    }

    fn range(self: *SymbolPositions, r: json_language.LspRange) !Range {
        return Range.init(@as(usize, r.start_line) + 1, try self.column(r.start_line, r.start_character), @as(usize, r.end_line) + 1, try self.column(r.end_line, r.end_character));
    }
};

fn convertJsonDocumentSymbol(allocator: Allocator, positions: *SymbolPositions, symbol: json_language.JsonDocumentSymbol) !languages.DocumentSymbol {
    const name = try allocator.dupe(u8, symbol.name);
    errdefer allocator.free(name);
    const detail = try allocator.dupe(u8, symbol.detail);
    errdefer allocator.free(detail);
    const tags = try allocator.dupe(u32, symbol.tags);
    errdefer allocator.free(tags);
    const container_name = if (symbol.container_name) |value| try allocator.dupe(u8, value) else null;
    errdefer {
        if (container_name) |value| allocator.free(value);
    }

    const children = try allocator.alloc(languages.DocumentSymbol, symbol.children.len);
    var converted: usize = 0;
    errdefer {
        for (children[0..converted]) |child| freeJsonDocumentSymbolContents(allocator, child);
        allocator.free(children);
    }
    for (symbol.children, 0..) |child, index| {
        children[index] = try convertJsonDocumentSymbol(allocator, positions, child);
        converted += 1;
    }

    return .{
        .name = name,
        .detail = detail,
        .kind = symbol.kind,
        .tags = tags,
        .container_name = container_name,
        .range = try positions.range(symbol.range),
        .selection_range = try positions.range(symbol.selection_range),
        .children = children,
    };
}

fn freeJsonDocumentSymbols(allocator: Allocator, symbols: []const languages.DocumentSymbol) void {
    for (symbols) |symbol| freeJsonDocumentSymbolContents(allocator, symbol);
    allocator.free(symbols);
}

fn freeJsonDocumentSymbolContents(allocator: Allocator, symbol: languages.DocumentSymbol) void {
    allocator.free(symbol.name);
    allocator.free(symbol.detail);
    allocator.free(symbol.tags);
    if (symbol.container_name) |name| allocator.free(name);
    freeJsonDocumentSymbols(allocator, symbol.children);
}

fn jsonColumnToEditorColumn(model: *TextModel, line_number: usize, character: u32) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return @as(usize, character) + 1;
    var line = model.getLineContent(line_number) catch return @as(usize, character) + 1;
    defer line.deinit();
    return position_converter.columnForUtf16Offset(line.items, @as(usize, character) + 1);
}

const MAX_STATUS: usize = 512;

/// In-place replace is rendered as an outline in the browser. A terminal cell
/// cannot draw an outline, so the view underlines the range instead.
var value_set_replacement_options = blk: {
    var options = ModelDecorationOptions.init("in-place-replace", .NeverGrowsWhenTypingAtEdges);
    options.className = "valueSetReplacement";
    options.inlineClassName = "valueSetReplacement";
    break :blk options;
};

const AfterEditComputer = struct {
    model: *TextModel,
    scratch: [8]Selection = undefined,

    fn compute(context: *anyopaque, inverse_edit_operations: []ValidEditOperation) ?[]Selection {
        const self: *AfterEditComputer = @ptrCast(@alignCast(context));
        if (inverse_edit_operations.len == 0) return null;
        const count = @min(inverse_edit_operations.len, self.scratch.len);
        for (inverse_edit_operations[0..count], 0..) |op, i| {
            const position = op.range.getEndPosition();
            self.scratch[i] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        }
        return self.scratch[0..count];
    }

    fn state(self: *AfterEditComputer) CursorStateComputer {
        return .{ .context = self, .compute = compute };
    }
};

const ReplaceCursorTarget = struct {
    present: bool = false,
    line_offset: isize = 0,
    column_offset: isize = 0,
};

/// Computes cursor selections for `executeReplaceCommands`. Commands carry an
/// identifier, so each inverse edit operation lands on its own target even
/// when the model reverses/sorts the operations. Offsets mirror upstream
/// `ReplaceCommandWithOffsetCursorState`.
const ReplaceCursorComputer = struct {
    before: []const Selection,
    targets: []const ReplaceCursorTarget,
    scratch: []Selection,

    fn compute(context: *anyopaque, inverse_operations: []ValidEditOperation) ?[]Selection {
        const self: *ReplaceCursorComputer = @ptrCast(@alignCast(context));
        @memcpy(self.scratch, self.before);
        for (inverse_operations) |operation| {
            const identifier = operation.identifier orelse continue;
            if (identifier.major < 0) continue;
            const index: usize = @intCast(identifier.major);
            if (index >= self.targets.len or index >= self.scratch.len) continue;
            const target = self.targets[index];
            if (!target.present) continue;
            const position = operation.range.getEndPosition().delta(target.line_offset, target.column_offset);
            self.scratch[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        }
        return self.scratch;
    }

    fn state(self: *ReplaceCursorComputer) CursorStateComputer {
        return .{ .context = self, .compute = compute };
    }
};

pub const TextEdit = struct {
    range: Range,
    text: []const u8,
};

/// The most recent model change, used by the extension-host bridge to mirror
/// the *actual* edit (including auto-indent and auto-closing text) instead of
/// only the requested character.
pub const LastContentChange = struct {
    range: Range,
    text: []u8,
};

/// The position of an applied edit after all edits in the batch were applied.
pub const AppliedTextEdit = struct {
    start: Position,
    end: Position,
};

pub const ChangeListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

const text_files = @import("../../../../workbench/services/textfile/common/textFileService.zig");
const LoadedText = text_files.ResolvedTextFile;

/// The shared document behind one or more editor views.
///
/// Upstream splits `TextModel`, the working copy and the editor pane: a split
/// editor opens the same `EditorInput` in two groups and each group creates
/// its own `CodeEditorWidget`/`ViewModel`, while both share the model, undo
/// stack and language services. This port used to fold all of those into
/// `Editor`, so splitting could only move the single editor. `EditorDocument`
/// is the shared half: it owns the model and everything the model references,
/// and each `Editor` is a view over it.
///
/// The document is reference counted by its editors. A tab-close destroys only
/// that tab's `Editor`; the model, undo history and dirty/saved state survive
/// until the last view closes.
pub const EditorDocument = struct {
    allocator: Allocator,
    io: Io,
    path: []u8,
    model: *TextModel,
    undo_redo: *UndoRedoService,
    codec: *LanguageIdCodec,
    language_service: *LanguageService,
    language_config_service: *LanguageConfigurationService,
    /// Owns the strings of the configured `files.associations` patterns; the
    /// language service stores slices into this arena.
    associations_arena: std.heap.ArenaAllocator,
    /// Owns language-configuration strings loaded from declarative extensions.
    declarative_arena: std.heap.ArenaAllocator,
    declarative: ?*const extensions_registry.Registry = null,
    encoding: encoding_mod.Encoding = .utf8,
    on_did_change_encoding: Emitter(void),
    /// Alternative version id at the last successful save. Shared by every
    /// view so both split panes flip clean together.
    saved_version: u32,
    /// True when the file changed on disk while it had unsaved edits.
    conflict: bool = false,
    json: json_language.Document = .{},
    json_version: u32 = 0,
    json_mirror: ?MirrorTextModel = null,
    diagnostic_request: ?u32 = null,
    json_document_symbol_registration: ?IDisposable = null,
    json_error_count: usize = 0,
    json_warning_count: usize = 0,
    refs: usize,
    editors: std.array_list.Managed(*Editor),

    fn init(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        text: ?[]const u8,
        declarative: ?*const extensions_registry.Registry,
        loaded: ?*const LoadedText,
    ) !*EditorDocument {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        const codec = try allocator.create(LanguageIdCodec);
        errdefer allocator.destroy(codec);
        codec.* = try LanguageIdCodec.init(allocator);
        errdefer codec.deinit();

        const language_service = try allocator.create(LanguageService);
        errdefer allocator.destroy(language_service);
        language_service.* = LanguageService.init(allocator, codec);
        errdefer language_service.deinit();
        for (language.bundled_languages) |bundled| {
            try language_service.registerLanguage(.{ .id = bundled.id, .aliases = bundled.names, .extensions = bundled.extensions });
        }
        if (declarative) |registry| {
            for (registry.languages) |contribution| {
                try language_service.registerLanguage(.{
                    .id = contribution.id,
                    .aliases = contribution.aliases,
                    .extensions = contribution.extensions,
                    .filenames = contribution.filenames,
                    .filenamePatterns = contribution.filename_patterns,
                    .firstLine = contribution.first_line,
                    .mimetypes = contribution.mimetypes,
                });
            }
        }

        // Path matching goes through the ported language associations, which the
        // service derives from the registered language contributions.
        const path_language = language_service.guessLanguageIdByFilepathOrFirstLine(path, null);
        const language_id = path_language orelse "plaintext";
        try codec.register(language_id);

        var declarative_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer declarative_arena.deinit();

        const language_config_service = try allocator.create(LanguageConfigurationService);
        errdefer allocator.destroy(language_config_service);
        language_config_service.* = try LanguageConfigurationService.init(allocator, language_service);
        errdefer language_config_service.deinit();

        const undo_redo = try allocator.create(UndoRedoService);
        errdefer allocator.destroy(undo_redo);
        undo_redo.* = UndoRedoService.init(allocator);
        errdefer undo_redo.deinit();

        var encoding: encoding_mod.Encoding = .utf8;
        const model = try createModel(allocator, io, path, language_id, undo_redo, language_service, text, loaded, &encoding);
        errdefer {
            model.deinit();
            allocator.destroy(model);
        }
        const detected = path_language orelse (try guessFromFirstLine(language_service, model)) orelse "plaintext";
        try configureDocumentLanguage(allocator, io, language_service, declarative_arena.allocator(), declarative, detected);
        if (!std.mem.eql(u8, language_id, detected)) {
            try codec.register(detected);
            model.setLanguage(detected);
        }
        // The fallback bracket matcher resolves RichEditBrackets through the
        // terminal language-configuration host; the AST path does not need it.
        model.bracketPairs().setLanguageConfigurationProvider(.{
            .context = language_config_service,
            .get = resolvedLanguageConfigurationForBrackets,
        });

        const self = try allocator.create(EditorDocument);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .path = path_copy,
            .model = model,
            .undo_redo = undo_redo,
            .codec = codec,
            .language_service = language_service,
            .language_config_service = language_config_service,
            .associations_arena = std.heap.ArenaAllocator.init(allocator),
            .declarative_arena = declarative_arena,
            .declarative = declarative,
            .encoding = encoding,
            .on_did_change_encoding = Emitter(void).init(allocator),
            .saved_version = model.getAlternativeVersionId(),
            .refs = 1,
            .editors = std.array_list.Managed(*Editor).init(allocator),
        };
        try model.onDidChangeLanguage(self, languageChanged);
        try model.onDidChangeContentWithContext(self, contentChanged);
        return self;
    }

    fn languageChanged(_: @import("../../../common/textModelEvents.zig").ModelLanguageChangedEvent, self: *EditorDocument) anyerror!void {
        if (self.json.client == null or self.editors.items.len == 0) return;
        self.editors.items[0].detachJsonLanguage();
        self.editors.items[0].attachJsonLanguage() catch |err| self.editors.items[0].setMessage("JSON attach failed: {s}", .{@errorName(err)});
        for (self.editors.items) |editor| editor.updateJsonProviders();
    }

    fn contentChanged(event: InternalModelContentChangeEvent, self: *EditorDocument) anyerror!void {
        if (self.json.uri == null or self.editors.items.len == 0) return;
        self.editors.items[0].changeJsonDocument(&event.contentChangedEvent) catch |err| self.editors.items[0].setMessage("JSON sync failed: {s}", .{@errorName(err)});
    }

    pub fn retain(self: *EditorDocument) void {
        self.refs += 1;
    }

    pub fn release(self: *EditorDocument) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.deinit();
    }

    fn deinit(self: *EditorDocument) void {
        std.debug.assert(self.editors.items.len == 0);
        self.editors.deinit();
        self.on_did_change_encoding.deinit();
        // Mirror the old single-owner teardown order: registry/arena data
        // before the model, then undo, then the language service and codec.
        self.language_config_service.deinit();
        self.allocator.destroy(self.language_config_service);
        self.declarative_arena.deinit();
        self.model.deinit();
        self.allocator.destroy(self.model);
        self.undo_redo.deinit();
        self.allocator.destroy(self.undo_redo);
        self.associations_arena.deinit();
        self.language_service.deinit();
        self.allocator.destroy(self.language_service);
        self.codec.deinit();
        self.allocator.destroy(self.codec);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn isDirty(self: *const EditorDocument) bool {
        return self.model.getAlternativeVersionId() != self.saved_version;
    }

    fn addEditor(self: *EditorDocument, editor: *Editor) !void {
        try self.editors.append(editor);
        // Once a document has two views, every pane must track its selections
        // in the model so remote edits can move the other panes' cursors.
        if (self.editors.items.len >= 2) {
            for (self.editors.items) |view| view.startTrackingCursorSelections();
        }
    }

    fn removeEditor(self: *EditorDocument, editor: *Editor) void {
        for (self.editors.items, 0..) |candidate, index| {
            if (candidate != editor) continue;
            _ = self.editors.orderedRemove(index);
            break;
        }
        if (self.editors.items.len == 1) {
            self.editors.items[0].stopTrackingCursorSelections();
        }
    }

    /// Notifies every view of a shared dirty/save/conflict transition. The
    /// per-editor emitter stays view-local, matching `IWorkingCopy` listeners
    /// that observe the same document through different editor panes.
    fn refreshDirtyState(self: *EditorDocument) void {
        for (self.editors.items) |editor| editor.refreshDirtyState();
    }
};

pub const Editor = struct {
    allocator: Allocator,
    io: Io,
    document: *EditorDocument,
    /// Path of the shared document. Borrowed from `document`; it lives as long
    /// as this view.
    path: []const u8,
    model: *TextModel,
    undo_redo: *UndoRedoService,
    codec: *LanguageIdCodec,
    language_service: *LanguageService,
    content_listener_id: Emitter(InternalModelContentChangeEvent).ListenerId = 0,
    decorations_listener_id: Emitter(ModelDecorationsChangedEvent).ListenerId = 0,
    /// True while this view keeps selection markers in the shared model so
    /// edits in another pane can move its cursors.
    cursor_tracking: bool = false,
    view_lines: ProjectedViewModelLines,
    /// Upstream `ViewModelImpl` owns the view-event dispatcher and emits the
    /// events for line-mapping changes, content flushes and decorations. The
    /// terminal editor applies hidden areas and edits directly, so it owns the
    /// same dispatcher here and the terminal view registers its handlers with
    /// it.
    view_event_dispatcher: ViewModelEventDispatcher,
    converter: CoordinatesConverter,
    cursor_config: CursorConfiguration,
    cursor_context: ?*CursorContext,
    cursors: ?CursorCollection,
    model_adapter: TextModelCursorSimpleModel,
    word_separators: WordCharacterClassifier,
    bracket_matching: BracketMatchingController,
    /// Folding ranges, collapse state and the hidden model-line projection.
    folding: *folding.Controller,
    /// Content or language changes make the provider ranges stale. Recompute
    /// them on the next view rebuild rather than inside the model change event,
    /// where moving selections would be re-entrant.
    folding_dirty: bool,
    /// Upstream Delayer for folding model updates.
    folding_task: window_dispatch.Task = .{},
    folding_delay_ms: i64,
    smart_select: smart_select.SmartSelectController,
    in_place_replace_task: window_dispatch.Task = .{},
    language_config_service: *LanguageConfigurationService,
    character_pair: ?CharacterPairSupport,
    multicursor_session: ?multicursor.SearchSession,
    after_edit: AfterEditComputer,
    /// Last observed dirty state. Content changes and saves fire
    /// `on_did_change_dirty` only when this flips, so tab labels can follow
    /// the editor without polling.
    dirty_state: bool,
    working_copy_dirty_listeners: std.array_list.Managed(ChangeListener),
    working_copy_content_listeners: std.array_list.Managed(ChangeListener),
    scroll_listeners: std.array_list.Managed(ChangeListener),
    working_copy_save_listeners: std.array_list.Managed(ChangeListener),
    on_did_change_dirty: Emitter(void),
    screen_width: usize,
    screen_height: usize,
    /// Terminal default is soft wrap on; a configured `editor.wordWrap`
    /// overrides it. Zero wrapping column means no soft wrap.
    wrap_mode: WordWrap = .on,
    wrap_column: i32 = 80,
    wrapping_indent: WrappingIndent = .Same,
    word_wrap_indicator: bool = false,
    top_inset_rows: usize = 0,
    /// The screen height includes a one-row status line when true. The
    /// multi-group workbench uses a workbench-level status bar and disables
    /// this fallback row for its editor panes.
    status_row: bool,
    gutter_width: usize,
    /// Cell widths of the three gutter columns. The number width follows
    /// `editor.lineNumbers`, `editor.lineNumbersMinChars` and the digit count;
    /// the fold width follows `editor.folding`/`showFoldingControls`.
    gutter_number_width: usize,
    gutter_fold_width: usize,
    /// Glyph-margin cells before the line numbers. The terminal reserves this
    /// only while a glyph decoration exists, so an unused gutter stays compact.
    gutter_glyph_width: usize = 0,
    gutter_line_numbers: bool = true,
    gutter_line_numbers_min_chars: usize = 5,
    gutter_folding: bool = true,
    /// Extra gutter cells after the fold cell used by quick-diff markers.
    /// `0` hides the marker column; `1` is the terminal representation of the
    /// upstream `scm.diffDecorationsGutterWidth` gutter.
    line_decorations_width: usize,
    /// Optional display line numbers for a read-only snapshot editor. Indexed by
    /// 1-based view line; `null` entries render a blank (filler) number. The
    /// slice is borrowed and owned by the caller (the diff widget).
    line_number_map: ?[]const ?usize,
    /// Read-only snapshot editors still support navigation, selection and find,
    /// but every text mutation and save is rejected with `error.ReadOnly`.
    read_only: bool,
    on_did_change_read_only: Emitter(bool),
    /// Rightmost columns reserved by the view for the overview ruler and
    /// scrollbar. Zero for the read-only preview and for editors used without
    /// the TUI view.
    scrollbar_width: usize,
    /// Vertical scroll state of this editor. Upstream keeps it on the view
    /// model's `ViewLayout`; the terminal editor is the view model, so it owns
    /// the layout directly. `top_view_line` is derived from it.
    view_layout: ViewLayout,
    /// Selection slices owned by the last `ViewCursorStateChanged` event.
    /// Upstream's arrays stay alive until the next event; view parts retain
    /// these slices for their next render pass.
    cursor_event_view_selections: []Selection = &.{},
    cursor_event_model_selections: []Selection = &.{},
    on_did_change_cursor_position: Emitter(ICursorPositionChangedEvent),
    on_did_change_cursor_selection: Emitter(ICursorSelectionChangedEvent),
    on_will_type: Emitter([]const u8),
    on_did_type: Emitter([]const u8),
    cursor_event_model_version: u32 = 0,
    cursor_event_source: ?[]const u8 = null,
    cursor_event_reason: ?CursorChangeReason = null,
    /// Source attached to the next cursor/selection event. Callers that are
    /// restoring history or performing a navigation set this first; it resets
    /// to USER after the event is emitted.
    cursor_selection_source: TextEditorSelectionSource = .USER,
    status: [MAX_STATUS]u8,
    status_len: usize,
    prev_edit_operation_type: EditOperationType,
    pending_selection: [8]Selection,
    pending_selection_count: usize,
    /// Nesting depth of an explicit undo group. While non-zero, the editor's
    /// internal stack pushes are suppressed so one user action becomes one
    /// undo element; `beginUndoGroup`/`endUndoGroup` own the boundary.
    undo_group_depth: usize,
    /// Every content change from the latest model event. The extension-host
    /// bridge mirrors the whole batch so multi-range commands (indent, comment,
    /// format) cannot leave the host document stale.
    last_content_changes: std.array_list.Managed(LastContentChange),
    tokens_need_refresh: bool,
    /// Model-line interval whose tokens were forced for the current content
    /// version (0 = none). Scrolling forward tokenizes only the new lines; a
    /// jump tokenizes the visible range from a guessed start state.
    tokenized_viewport_start: usize,
    tokenized_viewport_end: usize,
    tokenized_viewport_version: u32,
    decoration_generation: usize,
    /// The model stays attached for the lifetime of the terminal editor, so
    /// the ported default background tokenizer can run from the main loop.
    attached_view: ?*AttachedView = null,
    /// Whether multi-cursor paste spreads clipboard lines over cursors. The
    /// terminal has no settings service yet; upstream's default is `spread`.
    multi_cursor_paste_spread: bool = true,
    /// Ctrl/Alt character shortcuts are resolved through the ported keybinding
    /// registry; text editing itself stays on the editor methods below.
    keybindings: ?*keybinding_service.KeybindingService = null,
    /// User-keybinding removals that apply to this editor's shortcut rules.
    keybinding_overrides: []const *const resolved_keybinding_item.ResolvedKeybindingItem = &.{},
    shortcut_commands: CommandRegistry,
    /// Find controller hooks, installed by the per-tab controllers.
    find_context: ?*anyopaque = null,
    find_start_fn: ?*const fn (context: *anyopaque, replace: bool) anyerror!void = null,
    /// Sink for the vim/helix incremental-search highlights, installed by the
    /// view owner. The editor forwards portable ranges; only the sink knows
    /// class names and colors.
    search_highlight_sink: ?editorBrowser.DecorationSink = null,
    language_features: ?*LanguageFeaturesService = null,
    marker_service: ?*MarkerService = null,
    marker_decorations: ?*MarkerDecorationsService = null,
    /// One marker-decoration registration per editor view; repeated language
    /// feature attachment must not inflate the shared-model refcount.
    marker_model_registered: bool = false,
    json_completion_registration: ?IDisposable = null,

    /// Terminal host options. `reserve_scrollbar` makes the first wrapping
    /// pass use the final text width, avoiding a second full-file wrap when
    /// the View attaches.
    pub const CreateOptions = struct {
        reserve_scrollbar: bool = false,
    };

    pub fn overviewRulerWidthFor(screen_width: usize, gutter: usize) usize {
        const available = screen_width -| gutter;
        return if (available >= 3) 2 else 0;
    }

    pub fn create(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, null, null, .{}, null);
    }

    pub fn createWithOptions(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        options: CreateOptions,
    ) !*Editor {
        return createInternal(allocator, io, path, width, height, null, null, options, null);
    }

    pub fn createWithDeclarative(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
    ) !*Editor {
        return createInternal(allocator, io, path, width, height, null, declarative, .{}, null);
    }

    pub fn createWithDeclarativeOptions(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
        options: CreateOptions,
    ) !*Editor {
        return createInternal(allocator, io, path, width, height, null, declarative, options, null);
    }

    pub fn createWithExtensions(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
        json_client: ?*json_language.Client,
    ) !*Editor {
        return createWithExtensionsOptions(allocator, io, path, width, height, declarative, json_client, .{});
    }

    pub fn createWithExtensionsOptions(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
        json_client: ?*json_language.Client,
        options: CreateOptions,
    ) !*Editor {
        const editor = try createInternal(allocator, io, path, width, height, null, declarative, options, null);
        editor.setJsonLanguageClient(json_client);
        return editor;
    }

    pub fn createFromText(allocator: Allocator, io: Io, text: []const u8, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, text, null, .{}, null);
    }

    pub fn createFromTextWithOptions(allocator: Allocator, io: Io, text: []const u8, path: []const u8, width: usize, height: usize, options: CreateOptions) !*Editor {
        return createInternal(allocator, io, path, width, height, text, null, options, null);
    }

    /// Builds an editor from text the caller already read and decoded on a
    /// worker thread. Used by `Workbench.requestOpenPath` so the TUI thread
    /// never performs the disk read/realpath.
    pub fn createFromLoadedText(
        allocator: Allocator,
        io: Io,
        loaded: *const LoadedText,
        path: []const u8,
        width: usize,
        height: usize,
        options: CreateOptions,
    ) !*Editor {
        return createInternal(allocator, io, path, width, height, null, null, options, loaded);
    }

    pub fn createWithExtensionsFromLoadedText(
        allocator: Allocator,
        io: Io,
        loaded: *const LoadedText,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
        json_client: ?*json_language.Client,
        options: CreateOptions,
    ) !*Editor {
        const editor = try createInternal(allocator, io, path, width, height, null, declarative, options, loaded);
        editor.setJsonLanguageClient(json_client);
        return editor;
    }

    fn createInternal(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize, text: ?[]const u8, declarative: ?*const extensions_registry.Registry, options: CreateOptions, loaded: ?*const LoadedText) !*Editor {
        const document = try EditorDocument.init(allocator, io, path, text, declarative, loaded);
        errdefer document.release();
        return createView(allocator, document, width, height, options);
    }

    /// Creates one editor view over an existing document. The view owns its
    /// wrapping model, cursors, folding and scroll state; the model, undo
    /// stack and language services stay on `document`.
    fn createView(allocator: Allocator, document: *EditorDocument, width: usize, height: usize, options: CreateOptions) !*Editor {
        const editor = try allocator.create(Editor);
        errdefer allocator.destroy(editor);

        const model = document.model;
        const language_service = document.language_service;
        const language_config_service = document.language_config_service;
        const language_id = model.getLanguageId();
        const resolved = model.getOptions();
        const initial_number_width = @max(digitsFor(model.getLineCount()), 5);
        const initial_fold_width: usize = 1;
        const gutter = initial_number_width + initial_fold_width;
        const initial_scrollbar = if (options.reserve_scrollbar)
            overviewRulerWidthFor(width, gutter)
        else
            0;
        const text_width = @max(1, width -| gutter -| initial_scrollbar);

        var view_lines = try ProjectedViewModelLines.init(
            allocator,
            model,
            text_width,
            resolved.tabSize,
            .Same,
            .normal,
        );
        errdefer view_lines.deinit();

        var word_separators = try WordCharacterClassifier.init(allocator, DefaultWordSeparators);
        errdefer word_separators.deinit();

        var character_pair: ?CharacterPairSupport = null;
        if (language_service.getLanguageConfiguration(language_id)) |config| {
            character_pair = try CharacterPairSupport.init(config);
        }

        // Materialize the prefix sum before the view lines are moved into the
        // editor. Calling `getViewLineCount` inside the struct literal would
        // mutate the moved-from local and leak its refreshed buffers.
        const initial_view_line_count = view_lines.getViewLineCount();

        const cursor_config = CursorConfiguration{
            .tabSize = resolved.tabSize,
            .indentSize = resolved.indentSize,
            .insertSpaces = resolved.insertSpaces,
            .pageSize = @max(1, height - 1),
            .languageConfigurationService = language_config_service.interface(),
        };

        editor.* = Editor{
            .allocator = allocator,
            .io = document.io,
            .document = document,
            .path = document.path,
            .model = model,
            .undo_redo = document.undo_redo,
            .codec = document.codec,
            .language_service = language_service,
            .view_lines = view_lines,
            .view_event_dispatcher = ViewModelEventDispatcher.init(allocator),
            .on_did_change_cursor_position = Emitter(ICursorPositionChangedEvent).init(allocator),
            .on_did_change_cursor_selection = Emitter(ICursorSelectionChangedEvent).init(allocator),
            .on_will_type = Emitter([]const u8).init(allocator),
            .on_did_type = Emitter([]const u8).init(allocator),
            .converter = undefined,
            .cursor_config = cursor_config,
            .cursor_context = null,
            .cursors = null,
            .model_adapter = TextModelCursorSimpleModel.init(allocator, model),
            .word_separators = word_separators,
            .bracket_matching = BracketMatchingController.init(allocator, model),
            .folding = undefined,
            .folding_dirty = false,
            .folding_delay_ms = folding_debounce_min_ms,
            .smart_select = smart_select.SmartSelectController.init(allocator, &.{}, .{}),
            .language_config_service = language_config_service,
            .character_pair = character_pair,
            .multicursor_session = null,
            .after_edit = .{ .model = model },
            .dirty_state = document.isDirty(),
            .working_copy_dirty_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .working_copy_content_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .scroll_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .working_copy_save_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .on_did_change_dirty = Emitter(void).init(allocator),
            .screen_width = @max(width, 1),
            .screen_height = @max(height, 1),
            .status_row = true,
            .gutter_width = gutter,
            .gutter_number_width = initial_number_width,
            .gutter_fold_width = initial_fold_width,
            .gutter_glyph_width = 0,
            .line_decorations_width = 0,
            .line_number_map = null,
            .read_only = false,
            .on_did_change_read_only = .init(allocator),
            .scrollbar_width = initial_scrollbar,
            .view_layout = try ViewLayout.init(allocator, initial_view_line_count, text_width, @max(height -| 1, 1)),
            .status = undefined,
            .status_len = 0,
            .prev_edit_operation_type = .Other,
            .pending_selection = undefined,
            .pending_selection_count = 0,
            .undo_group_depth = 0,
            .last_content_changes = std.array_list.Managed(LastContentChange).init(allocator),
            .tokens_need_refresh = false,
            .tokenized_viewport_start = 0,
            .tokenized_viewport_end = 0,
            .tokenized_viewport_version = 0,
            .decoration_generation = 0,
            .keybindings = null,
            .shortcut_commands = CommandRegistry.init(allocator),
            .find_context = null,
            .find_start_fn = null,
        };
        errdefer editor.view_event_dispatcher.deinit();
        errdefer editor.on_did_change_cursor_position.deinit();
        errdefer editor.on_did_change_cursor_selection.deinit();
        errdefer editor.on_will_type.deinit();
        errdefer editor.on_did_type.deinit();
        errdefer editor.on_did_change_read_only.deinit();
        editor.converter = CoordinatesConverter.init(&editor.view_lines);
        _ = try editor.view_layout.onDidScroll().listen(editor, onViewLayoutScroll);
        if (editor.character_pair) |*pair_support| {
            editor.cursor_config.auto_closing_pairs = pair_support.getAutoClosingPairs();
            editor.cursor_config.auto_close_before_quotes = pair_support.getAutoCloseBeforeSet(true);
            editor.cursor_config.auto_close_before_brackets = pair_support.getAutoCloseBeforeSet(false);
        }

        const context = try allocator.create(CursorContext);
        errdefer allocator.destroy(context);
        context.* = CursorContext.init(
            model,
            editor.view_lines.interface(),
            editor.converter.interface(),
            &editor.cursor_config,
        );
        editor.cursor_context = context;

        editor.cursors = try CursorCollection.init(allocator, context);
        errdefer if (editor.cursors) |*cursors| cursors.deinit();
        editor.refreshAutoIndent();

        const folding_controller = try folding.Controller.init(allocator, model, &editor.view_lines);
        errdefer folding_controller.deinit();
        editor.folding = folding_controller;
        try editor.refreshFoldingRules();
        editor.triggerFoldingUpdate(time_compat.milliTimestamp());

        editor.content_listener_id = try model.onDidChangeContentWithContextId(editor, contentChangedCallback);
        editor.decorations_listener_id = try model.onDidChangeDecorationsWithContextId(editor, decorationChangedCallback);
        editor.attached_view = try model.onBeforeAttached();
        try document.addEditor(editor);
        // Establish the initial model selection before any contribution or
        // view attaches; attaching a view is not a public cursor move.
        editor.emitCursorStateChangedForce(.NotSet);

        return editor;
    }

    /// Creates a second editor view over `source`'s document, matching
    /// upstream `EditorInput.copy()` plus the new editor pane that a split
    /// group opens. The text model, undo history, language services and
    /// saved/dirty state are shared; wrapping, cursors, folding, selection and
    /// scroll position are independent view state.
    pub fn createViewFromEditor(source: *Editor, width: usize, height: usize) !*Editor {
        source.document.retain();
        errdefer source.document.release();

        const editor = try createView(source.allocator, source.document, width, height, .{
            .reserve_scrollbar = source.scrollbar_width != 0,
        });
        editor.read_only = source.read_only;
        editor.status_row = source.status_row;
        editor.gutter_line_numbers = source.gutter_line_numbers;
        editor.gutter_line_numbers_min_chars = source.gutter_line_numbers_min_chars;
        editor.gutter_folding = source.gutter_folding;
        editor.line_decorations_width = source.line_decorations_width;
        if (source.language_features) |features| {
            editor.attachLanguageServices(features, source.marker_service, source.marker_decorations);
        }

        // `fillActiveEditorViewState`: carry the visible range and selections
        // into the copied pane so a split looks like a duplicate, not a reset.
        const selections = source.getSelections() catch null;
        if (selections) |value| {
            defer source.allocator.free(value);
            editor.setTextEditorSelectionSource(.PROGRAMMATIC);
            editor.setSelections(value) catch {};
        }
        _ = editor.setTopViewLine(source.topViewLine());
        editor.refreshLayout() catch {};
        return editor;
    }

    /// Installs the find/replace callbacks used by the editor keybindings.
    pub fn setFindController(
        self: *Editor,
        context: *anyopaque,
        start_fn: *const fn (context: *anyopaque, replace: bool) anyerror!void,
    ) void {
        self.find_context = context;
        self.find_start_fn = start_fn;
    }

    /// Installs the sink that paints vim/helix incremental-search matches.
    /// `null` detaches it when the owning tab is destroyed.
    pub fn setSearchHighlightSink(self: *Editor, sink: ?editorBrowser.DecorationSink) void {
        self.search_highlight_sink = sink;
    }

    /// Replaces the incremental-search highlights. `matches` reuse the
    /// find-match decoration kind and `current` the current-find-match kind,
    /// so both modal engines paint with the same colors as Ctrl+F. An empty
    /// slice clears the highlights.
    pub fn setSearchHighlights(self: *Editor, matches: []const Range, current: ?Range) void {
        const sink = self.search_highlight_sink orelse return;
        const set = sink.set orelse return;

        var decorations = ArrayList(editorBrowser.Decoration).init(self.allocator);
        defer decorations.deinit();
        decorations.ensureTotalCapacity(matches.len + 1) catch {
            set(sink.context, &.{});
            return;
        };
        for (matches) |range| {
            decorations.appendAssumeCapacity(.{
                .range = range,
                .kind = if (Range.equalsRange(range, current)) .current_find_match else .find_match,
            });
        }
        if (current) |range| {
            var included = false;
            for (matches) |match| {
                if (Range.equalsRange(match, range)) {
                    included = true;
                    break;
                }
            }
            if (!included) decorations.appendAssumeCapacity(.{ .range = range, .kind = .current_find_match });
        }
        set(sink.context, decorations.items);
    }

    pub fn lookupShortcut(self: *Editor, id: []const u8) !?@import("../../../../base/common/keybindings.zig").ResolvedKeybinding {
        try self.ensureShortcutKeybindings();
        return self.keybindings.?.service.lookupKeybinding(self.allocator, id, false);
    }

    fn ensureShortcutKeybindings(self: *Editor) !void {
        if (self.keybindings != null) return;

        for (shortcut_specs) |spec| {
            try self.shortcut_commands.register(.{
                .id = spec.id,
                .context = self,
                .run = spec.run,
            });
        }

        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &shortcut_keybinding_rules,
            .executor = .{ .context = self, .execute = executeShortcutCommand },
            .overrides = self.keybinding_overrides,
        });
        self.keybindings = service;
    }

    /// Rebuilds the shortcut host after the user keymap changed. The removals
    /// stay borrowed from the workbench's user-keybindings owner, which must
    /// outlive the editor's next dispatch.
    pub fn reloadShortcutKeybindings(
        self: *Editor,
        overrides: []const *const resolved_keybinding_item.ResolvedKeybindingItem,
    ) void {
        if (self.keybindings) |service| {
            service.deinit();
            self.keybindings = null;
        }
        self.keybinding_overrides = overrides;
    }

    fn executeShortcutCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(context));
        _ = try self.shortcut_commands.execute(command_id);
    }

    /// Resolves a shortcut through the keybinding registry. Ctrl/Alt character
    /// combinations are always consumed (they can never type text); navigation
    /// keys are consumed only when a keybinding matched (or started a chord),
    /// so unregistered combinations keep falling back to the legacy switch.
    pub fn dispatchShortcut(self: *Editor, event: input.KeyEvent) !bool {
        const is_char = std.meta.activeTag(event.key) == .char;
        const is_navigation = switch (event.key) {
            .left, .right, .up, .down, .home, .end, .page_up, .page_down => true,
            else => false,
        };
        const is_editing = switch (event.key) {
            .enter, .tab, .backtab, .backspace, .delete, .escape => true,
            else => false,
        };
        const blocked = event.mods.ctrl or event.mods.alt;
        if (!is_navigation and !is_editing) {
            if (!is_char or !blocked) return false;
        }
        if (is_editing and blocked) return false;

        try self.ensureShortcutKeybindings();
        const consumed = self.keybindings.?.dispatch(event);
        if (is_navigation or is_editing) return consumed;
        return true;
    }

    /// Attaches a shared JSON language server to this editor and opens its
    /// document. Only JSON/JSONC editors are attached.
    pub fn setJsonLanguageClient(self: *Editor, client: ?*json_language.Client) void {
        if (self.document.json.client == client) return;
        self.detachJsonLanguage();
        self.document.json.client = client;
        self.attachJsonLanguage() catch |err| self.setMessage("JSON attach failed: {s}", .{@errorName(err)});
        for (self.document.editors.items) |editor| editor.updateJsonProviders();
    }

    fn updateJsonProviders(self: *Editor) void {
        if (self.json_completion_registration) |registration| registration.dispose();
        self.json_completion_registration = null;
        self.registerJsonCompletion();
        self.registerJsonDocumentSymbols();
    }

    fn detachJsonLanguage(self: *Editor) void {
        const uri = self.document.json.uri orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        self.document.json.client.?.didClose(arena.allocator(), uri) catch |err| std.log.warn("JSON close failed: {s}", .{@errorName(err)});
        if (self.document.diagnostic_request) |id| self.document.json.client.?.cancel(id);
        self.document.diagnostic_request = null;
        if (self.document.json_mirror) |*mirror| mirror.deinit();
        self.document.json_mirror = null;
        self.publishJsonDiagnostics(&.{});
        self.document.json.uri = null;
        if (self.document.json_document_symbol_registration) |registration| registration.dispose();
        self.document.json_document_symbol_registration = null;
        self.allocator.free(uri);
        self.document.json_error_count = 0;
        self.document.json_warning_count = 0;
        for (self.document.editors.items) |editor| {
            if (std.mem.startsWith(u8, editor.message(), "JSON ")) editor.clearMessage();
        }
    }

    fn attachJsonLanguage(self: *Editor) !void {
        const client = self.document.json.client orelse return;
        const language_id = self.languageId();
        if (!std.mem.eql(u8, language_id, "json") and !std.mem.eql(u8, language_id, "jsonc")) return;
        if (self.document.json.uri != null) return;
        const uri = try std_uri.resourceKey(self.allocator, self.model.uri());
        errdefer self.allocator.free(uri);
        const text = try self.model.getValue(.TextDefined, false);
        defer text.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var mirror = try self.createJsonMirror(uri, text.items);
        errdefer mirror.deinit();
        try client.didOpenVersion(arena.allocator(), uri, language_id, self.model.getVersionId(), text.items);
        self.document.json_mirror = mirror;
        self.document.json.uri = uri;
        self.document.json_version = self.model.getVersionId();
        self.pullJsonDiagnostics() catch |err| self.setMessage("JSON diagnostics failed: {s}", .{@errorName(err)});
    }

    fn createJsonMirror(self: *Editor, uri: []const u8, text: []const u8) !MirrorTextModel {
        var lines = try @import("../../../../base/common/strings.zig").splitLines(self.allocator, text);
        defer lines.deinit();
        return MirrorTextModel.init(self.allocator, uri, lines.items, self.model.getEOL(), self.model.getVersionId());
    }

    fn changeJsonDocument(self: *Editor, event: *const @import("../../../common/textModelEvents.zig").ModelContentChangedEvent) !void {
        const doc = self.document;
        if (event.isEolChange or event.isFlush or doc.json_mirror == null or doc.json_version != doc.json_mirror.?.version()) return self.syncJsonDocument();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var edits = std.array_list.Managed(JsonContentChange).init(arena.allocator());
        // A failed allocation or write invalidates the mirror until resync.
        errdefer {
            doc.json_mirror.?.deinit();
            doc.json_mirror = null;
        }
        try doc.json_mirror.?.onEventsWithContext(event, &edits, struct {
            fn before(list: *std.array_list.Managed(JsonContentChange), mirror: *const MirrorTextModel, change: *const @import("../../../common/textModelEvents.zig").ModelContentChange) !void {
                const r = change.range;
                try list.append(.{ .range = .{
                    .start_line = @intCast(r.startLineNumber - 1),
                    .start_character = @intCast(position_converter.utf16OffsetForColumn(mirror.getLineContent(r.startLineNumber), r.startColumn) - 1),
                    .end_line = @intCast(r.endLineNumber - 1),
                    .end_character = @intCast(position_converter.utf16OffsetForColumn(mirror.getLineContent(r.endLineNumber), r.endColumn) - 1),
                }, .text = change.text.items() });
            }
        }.before);
        try doc.json.client.?.didChangeContent(arena.allocator(), doc.json.uri.?, self.model.getVersionId(), edits.items);
        doc.json_version = self.model.getVersionId();
        try self.pullJsonDiagnostics();
    }

    fn syncJsonDocument(self: *Editor) !void {
        const client = self.document.json.client orelse return;
        const uri = self.document.json.uri orelse return;
        const text = try self.model.getValue(.TextDefined, false);
        defer text.deinit();
        const version = self.model.getVersionId();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var mirror = try self.createJsonMirror(uri, text.items);
        errdefer mirror.deinit();
        try client.didChange(arena.allocator(), uri, version, text.items);
        if (self.document.json_mirror) |*previous| previous.deinit();
        self.document.json_mirror = mirror;
        self.document.json_version = version;
        self.pullJsonDiagnostics() catch |err| self.setMessage("JSON diagnostics failed: {s}", .{@errorName(err)});
    }

    fn pullJsonDiagnostics(self: *Editor) !void {
        const client = self.document.json.client orelse return;
        const uri = self.document.json.uri orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (self.document.diagnostic_request) |id| client.cancel(id);
        self.document.diagnostic_request = null;
        self.document.diagnostic_request = try client.requestDocument(arena.allocator(), "textDocument/diagnostic", uri, .{
            .context = self.document,
            .complete = diagnosticsReady,
        });
    }

    fn diagnosticsReady(context: *anyopaque, result: std.json.Value) void {
        const doc: *EditorDocument = @ptrCast(@alignCast(context));
        doc.diagnostic_request = null;
        if (doc.editors.items.len == 0 or doc.json_version != doc.model.getVersionId() or result == .null) return;
        const self = doc.editors.items[0];
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const diagnostics = json_language.Client.parseDiagnostics(arena.allocator(), result) catch return;
        self.document.json_error_count = 0;
        self.document.json_warning_count = 0;
        var first_message: ?[]const u8 = null;
        for (diagnostics) |diagnostic| {
            if (diagnostic.severity == 1) {
                self.document.json_error_count += 1;
                if (first_message == null) first_message = diagnostic.message;
            } else if (diagnostic.severity == 2) {
                self.document.json_warning_count += 1;
                if (first_message == null) first_message = diagnostic.message;
            }
        }
        self.publishJsonDiagnostics(diagnostics);
        for (self.document.editors.items) |editor| {
            if (first_message) |message_text| {
                editor.setMessage("JSON {d} error(s), {d} warning(s): {s}", .{
                    self.document.json_error_count, self.document.json_warning_count, message_text,
                });
            } else if (std.mem.startsWith(u8, editor.message(), "JSON ")) {
                editor.clearMessage();
            }
        }
    }

    /// Publishes the JSON server's diagnostics to the shared marker service so
    /// the Problems panel and the status count see them. LSP positions are
    /// 0-based UTF-16; markers store 1-based UTF-8 editor columns.
    fn publishJsonDiagnostics(self: *Editor, diagnostics: []const json_language.Diagnostic) void {
        const service = self.marker_service orelse return;
        const uri_text = self.document.json.uri orelse return;
        const uri = std.Uri.parse(uri_text) catch return;
        var resource = markers.Resource.fromUri(self.allocator, uri) catch return;
        defer resource.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var data = std.array_list.Managed(markers.MarkerData).init(arena.allocator());
        for (diagnostics) |diagnostic| {
            const start_line = @as(usize, diagnostic.start_line) + 1;
            const end_line = @as(usize, diagnostic.end_line) + 1;
            const severity = switch (diagnostic.severity) {
                1 => markers.MarkerSeverity.Error,
                2 => markers.MarkerSeverity.Warning,
                3 => markers.MarkerSeverity.Info,
                else => markers.MarkerSeverity.Hint,
            };
            data.append(.{
                .severity = severity,
                .message = diagnostic.message,
                .source = "json",
                .start_line_number = @intCast(start_line),
                .start_column = @intCast(jsonColumnToEditorColumn(self.model, start_line, diagnostic.start_character)),
                .end_line_number = @intCast(end_line),
                .end_column = @intCast(jsonColumnToEditorColumn(self.model, end_line, diagnostic.end_character)),
                .model_version_id = self.model.getVersionId(),
                .origin = "json",
            }) catch continue;
        }
        service.changeOne("json", resource, data.items, null) catch {};
    }

    pub fn formatJson(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const client = self.document.json.client orelse {
            self.setMessage("No JSON language server", .{});
            return;
        };
        if (self.document.json.uri == null) {
            self.setMessage("Not a JSON document", .{});
            return;
        }
        if (self.model.getVersionId() != self.document.json_version) self.syncJsonDocument() catch {};
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const edits = try client.formatting(
            arena.allocator(),
            self.document.json.uri.?,
            @intCast(self.cursor_config.tabSize),
            self.cursor_config.insertSpaces,
        );
        if (edits.len == 0) {
            self.setMessage("JSON already formatted", .{});
            return;
        }
        const text_edits = try self.allocator.alloc(TextEdit, edits.len);
        defer self.allocator.free(text_edits);
        for (edits, 0..) |edit, index| {
            text_edits[index] = .{
                .range = Range.init(
                    @intCast(edit.start_line + 1),
                    @intCast(edit.start_character + 1),
                    @intCast(edit.end_line + 1),
                    @intCast(edit.end_character + 1),
                ),
                .text = edit.new_text,
            };
        }
        try self.applyTextEdits(text_edits, &.{});
        self.setMessage("Formatted JSON", .{});
    }

    pub fn jsonProvideCompletion(
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        trigger: completion.CompletionContext,
        token: CancellationToken,
    ) anyerror!completion.CompletionList {
        _ = model;
        _ = trigger;
        _ = token;
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.jsonCompletion(allocator, position);
    }

    pub fn jsonCompletion(
        self: *Editor,
        allocator: Allocator,
        position: Position,
    ) !completion.CompletionList {
        const client = self.document.json.client orelse return .{};
        const uri = self.document.json.uri orelse return .{};
        if (self.model.getVersionId() != self.document.json_version) {
            self.syncJsonDocument() catch {};
        }
        const items = try client.completion(
            allocator,
            uri,
            if (position.lineNumber > 0) @intCast(position.lineNumber - 1) else 0,
            if (position.column > 0) @intCast(position.column - 1) else 0,
        );
        if (items.len == 0) return .{};
        const result = try allocator.alloc(completion.CompletionItem, items.len);
        for (items, 0..) |item, index| {
            result[index] = .{
                .label = item.label,
                .insert_text = item.insert_text orelse item.label,
                .kind = .Text,
            };
        }
        return .{ .items = result };
    }

    /// Attaches the workbench's shared language services. Idempotent so both
    /// pre-existing and newly opened tabs can be wired.
    pub fn attachLanguageServices(
        self: *Editor,
        features: ?*LanguageFeaturesService,
        marker_service: ?*MarkerService,
        marker_decorations: ?*MarkerDecorationsService,
    ) void {
        const had_marker_service = self.marker_service != null;
        self.language_features = features;
        self.marker_service = marker_service;
        self.marker_decorations = marker_decorations;
        if (marker_decorations) |service| {
            if (!self.marker_model_registered) {
                service.registerModel(self.model) catch {};
                self.marker_model_registered = true;
            }
        }
        // Tabs created before `enableLanguageFeatures` have already pulled
        // their JSON diagnostics; republish them now that the marker service
        // exists.
        if (!had_marker_service and marker_service != null and self.document.json.uri != null) {
            self.pullJsonDiagnostics() catch {};
        }
        self.registerJsonCompletion();
        self.registerJsonDocumentSymbols();
    }

    fn registerJsonCompletion(self: *Editor) void {
        if (self.json_completion_registration != null) return;
        const features = self.language_features orelse return;
        if (self.document.json.client == null) return;
        self.json_completion_registration = features.completion_provider.register(.{ .list = &.{
            .{ .filter = .{ .language = "json" } },
            .{ .filter = .{ .language = "jsonc" } },
        } }, .{
            .context = self,
            .provide_completion_items = jsonProvideCompletion,
            .trigger_characters = &.{ "\"", ":" },
        }) catch null;
    }

    fn registerJsonDocumentSymbols(self: *Editor) void {
        if (self.document.json_document_symbol_registration != null) return;
        const features = self.language_features orelse return;
        if (self.document.json.client == null or self.document.json.uri == null) return;
        const language_id = self.languageId();
        if (!std.mem.eql(u8, language_id, "json") and !std.mem.eql(u8, language_id, "jsonc")) return;
        self.document.json_document_symbol_registration = features.document_symbol_provider.register(.{ .list = &.{
            .{ .filter = .{ .language = "json" } },
            .{ .filter = .{ .language = "jsonc" } },
        } }, .{
            .context = self.document,
            .display_name = "JSON",
            .provide_document_symbols = jsonProvideDocumentSymbols,
            .request_document_symbols = requestJsonSymbols,
        }) catch null;
    }

    const JsonSymbolRequest = struct {
        allocator: Allocator,
        document: *EditorDocument,
        client: *json_language.Client,
        version: u32,
        id: u32,
        callback: languages.DocumentSymbolCallback,

        fn cancel(context: *anyopaque) void {
            const self: *JsonSymbolRequest = @ptrCast(@alignCast(context));
            self.client.cancel(self.id);
            self.document.release();
        }

        fn ready(context: *anyopaque, result: std.json.Value) void {
            const self: *JsonSymbolRequest = @ptrCast(@alignCast(context));
            const doc = self.document;
            defer doc.release();
            var scratch = std.heap.ArenaAllocator.init(doc.allocator);
            defer scratch.deinit();
            const symbols = if (doc.json_mirror != null and doc.json.client == self.client and doc.model.getVersionId() == self.version)
                json_language.parseDocumentSymbols(scratch.allocator(), result) catch &.{}
            else
                &.{};
            var positions = SymbolPositions{ .arena = scratch.allocator(), .mirror = if (doc.json_mirror) |*m| m else {
                self.callback.complete(self.callback.context, &.{});
                return;
            } };
            const converted = convertJsonSymbols(self.allocator, &positions, symbols) catch &.{};
            self.callback.complete(self.callback.context, converted);
        }
    };

    fn requestJsonSymbols(context: *anyopaque, arena: Allocator, model: *TextModel, callback: languages.DocumentSymbolCallback) !?IDisposable {
        const doc: *EditorDocument = @ptrCast(@alignCast(context));
        if (doc.model != model or doc.editors.items.len == 0) return null;
        const editor = doc.editors.items[0];
        const client = doc.json.client orelse return null;
        const uri = doc.json.uri orelse return null;
        if (doc.json_version != model.getVersionId()) try editor.syncJsonDocument();
        const request = try arena.create(JsonSymbolRequest);
        request.* = .{ .allocator = arena, .document = doc, .client = client, .id = undefined, .version = model.getVersionId(), .callback = callback };
        request.id = try client.requestDocument(arena, "textDocument/documentSymbol", uri, .{ .context = request, .complete = JsonSymbolRequest.ready });
        doc.retain();
        return .{ .context = request, .disposeFn = JsonSymbolRequest.cancel };
    }

    pub fn jsonProvideDocumentSymbols(
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        token: CancellationToken,
    ) anyerror![]languages.DocumentSymbol {
        _ = token;
        const doc: *EditorDocument = @ptrCast(@alignCast(context));
        if (doc.model != model or doc.editors.items.len == 0) return &.{};
        const self = doc.editors.items[0];
        const client = self.document.json.client orelse return &.{};
        const uri = self.document.json.uri orelse return &.{};
        if (self.model.getVersionId() != self.document.json_version) self.syncJsonDocument() catch {};

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const symbols = client.documentSymbols(arena.allocator(), uri) catch return &.{};
        const mirror = if (doc.json_mirror) |*value| value else return &.{};
        var positions = SymbolPositions{ .arena = arena.allocator(), .mirror = mirror };
        return convertJsonSymbols(allocator, &positions, symbols);
    }

    fn convertJsonSymbols(allocator: Allocator, positions: *SymbolPositions, symbols: []const json_language.JsonDocumentSymbol) ![]languages.DocumentSymbol {
        const result = try allocator.alloc(languages.DocumentSymbol, symbols.len);
        var converted: usize = 0;
        errdefer {
            for (result[0..converted]) |symbol| freeJsonDocumentSymbolContents(allocator, symbol);
            allocator.free(result);
        }
        for (symbols, 0..) |symbol, index| {
            result[index] = try convertJsonDocumentSymbol(allocator, positions, symbol);
            converted += 1;
        }
        return result;
    }

    pub fn formatDocument(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        if (self.language_features) |features| {
            // Port of `getRealAndSyntheticDocumentFormattersOrdered` from
            // `editor/contrib/format/browser/format.ts`: range formatters that
            // are not shadowed by a document formatter from the same extension
            // format the full model range. The TypeScript extension registers
            // only a range formatter.
            var seen = std.array_list.Managed([]const u8).init(self.allocator);
            defer seen.deinit();
            const providers = try features.document_formatting_edit_provider.ordered(self.allocator, self.model, false);
            defer self.allocator.free(providers);
            for (providers) |provider| {
                if (provider.extension_id.len > 0) {
                    var already_seen = false;
                    for (seen.items) |extension_id| {
                        if (std.mem.eql(u8, extension_id, provider.extension_id)) {
                            already_seen = true;
                            break;
                        }
                    }
                    if (!already_seen) try seen.append(provider.extension_id);
                }
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const edits = provider.provide_document_formatting_edits(
                    provider.context,
                    arena.allocator(),
                    self.model,
                    .{ .tab_size = @intCast(self.cursor_config.tabSize), .insert_spaces = self.cursor_config.insertSpaces },
                    CancellationToken.None,
                ) catch continue;
                if (edits.len == 0) continue;
                const text_edits = try self.allocator.alloc(TextEdit, edits.len);
                defer self.allocator.free(text_edits);
                for (edits, 0..) |edit, index| text_edits[index] = .{ .range = edit.range, .text = edit.text };
                try self.applyTextEdits(text_edits, &.{});
                self.setMessage("Formatted document", .{});
                return;
            }
            const range_providers = try features.document_range_formatting_edit_provider.ordered(self.allocator, self.model, false);
            defer self.allocator.free(range_providers);
            const line_count = self.model.getLineCount();
            const full_range = Range.init(1, 1, line_count, self.model.getLineMaxColumn(line_count));
            for (range_providers) |provider| {
                if (provider.extension_id.len > 0) {
                    var already_seen = false;
                    for (seen.items) |extension_id| {
                        if (std.mem.eql(u8, extension_id, provider.extension_id)) {
                            already_seen = true;
                            break;
                        }
                    }
                    if (already_seen) continue;
                    try seen.append(provider.extension_id);
                }
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const edits = provider.provide_document_range_formatting_edits(
                    provider.context,
                    arena.allocator(),
                    self.model,
                    full_range,
                    .{ .tab_size = @intCast(self.cursor_config.tabSize), .insert_spaces = self.cursor_config.insertSpaces },
                    CancellationToken.None,
                ) catch continue;
                if (edits.len == 0) continue;
                const text_edits = try self.allocator.alloc(TextEdit, edits.len);
                defer self.allocator.free(text_edits);
                for (edits, 0..) |edit, index| text_edits[index] = .{ .range = edit.range, .text = edit.text };
                try self.applyTextEdits(text_edits, &.{});
                self.setMessage("Formatted document", .{});
                return;
            }
        }
        return self.formatJson();
    }

    /// Port of `FormatSelectionAction`: run the range formatter for each
    /// selection. The first provider that returns edits wins, matching the
    /// document formatter's provider ordering.
    pub fn formatSelection(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const features = self.language_features orelse return;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        if (selections.len == 0) return;

        const providers = try features.document_range_formatting_edit_provider.ordered(self.allocator, self.model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) return;

        for (selections) |selection| {
            const range = Range.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
            for (providers) |provider| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const edits = provider.provide_document_range_formatting_edits(
                    provider.context,
                    arena.allocator(),
                    self.model,
                    range,
                    .{ .tab_size = @intCast(self.cursor_config.tabSize), .insert_spaces = self.cursor_config.insertSpaces },
                    CancellationToken.None,
                ) catch continue;
                if (edits.len == 0) continue;
                const text_edits = try self.allocator.alloc(TextEdit, edits.len);
                defer self.allocator.free(text_edits);
                for (edits, 0..) |edit, index| text_edits[index] = .{ .range = edit.range, .text = edit.text };
                try self.applyTextEdits(text_edits, &.{});
                break;
            }
        }
        self.setMessage("Formatted selection", .{});
    }

    /// Applies declarative language contributions to an editor created before
    /// the extension scan completed. The document owns the registration, so a
    /// split copy reuses it instead of registering the same contributions
    /// twice.
    pub fn applyDeclarativeExtensions(self: *Editor, registry: *const extensions_registry.Registry) !void {
        if (self.document.declarative == registry) return;
        self.document.declarative = registry;
        for (registry.languages) |contribution| {
            try self.language_service.registerLanguage(.{
                .id = contribution.id,
                .aliases = contribution.aliases,
                .extensions = contribution.extensions,
                .filenames = contribution.filenames,
                .filenamePatterns = contribution.filename_patterns,
                .firstLine = contribution.first_line,
                .mimetypes = contribution.mimetypes,
            });
        }
        const guessed = self.language_service.guessLanguageIdByFilepathOrFirstLine(self.path, null) orelse (try guessFromFirstLine(self.language_service, self.model)) orelse self.languageId();
        if (std.mem.eql(u8, guessed, self.languageId())) {
            try configureDocumentLanguage(self.allocator, self.io, self.language_service, self.document.declarative_arena.allocator(), registry, guessed);
            for (self.document.editors.items) |editor| try editor.applyLanguageState(guessed);
        } else {
            try self.setLanguage(guessed);
        }
    }

    pub fn deinit(self: *Editor) void {
        self.folding_task.schedule(null);
        self.in_place_replace_task.schedule(null);
        if (self.document.editors.items.len == 1) self.detachJsonLanguage();
        // Unregister the shared-model listeners first: the model may outlive
        // this view while a split copy stays open.
        self.model.removeDidChangeContentListener(self.content_listener_id);
        self.model.removeDidChangeDecorationsListener(self.decorations_listener_id);
        if (self.json_completion_registration) |registration| registration.dispose();
        if (self.marker_decorations) |service| {
            if (self.marker_model_registered) {
                service.unregisterModel(self.model);
                self.marker_model_registered = false;
            }
        }
        if (self.marker_service) |service| {
            // Only the last view of a document clears its diagnostics; a split
            // copy must keep showing the same markers.
            if (self.document.editors.items.len <= 1) {
                const resource = markers.Resource.fromUri(self.allocator, self.model.uri()) catch null;
                if (resource) |value| {
                    var owned = value;
                    defer owned.deinit(self.allocator);
                    service.changeOne("json", owned, &.{}, null) catch {};
                }
            }
        }
        self.folding.deinit();
        if (self.cursors) |*cursors| cursors.deinit();
        if (self.cursor_context) |context| self.allocator.destroy(context);
        self.model_adapter.deinit();
        self.bracket_matching.deinit();
        self.smart_select.deinit();

        if (self.multicursor_session) |*session| session.deinit();
        self.word_separators.deinit();
        if (self.cursor_event_view_selections.len > 0) self.allocator.free(self.cursor_event_view_selections);
        if (self.cursor_event_model_selections.len > 0) self.allocator.free(self.cursor_event_model_selections);
        self.on_did_change_cursor_position.deinit();
        self.on_did_change_cursor_selection.deinit();
        self.on_will_type.deinit();
        self.on_did_type.deinit();
        self.on_did_change_read_only.deinit();
        self.view_event_dispatcher.deinit();
        self.view_layout.deinit();
        self.view_lines.deinit();
        if (self.attached_view) |view| {
            self.model.onBeforeDetached(view) catch {};
            self.allocator.destroy(view);
            self.attached_view = null;
        }
        self.working_copy_dirty_listeners.deinit();
        self.working_copy_content_listeners.deinit();
        self.scroll_listeners.deinit();
        self.working_copy_save_listeners.deinit();
        if (self.keybindings) |service| service.deinit();
        self.shortcut_commands.deinit();
        self.on_did_change_dirty.deinit();
        for (self.last_content_changes.items) |change| self.allocator.free(change.text);
        self.last_content_changes.deinit();

        self.document.removeEditor(self);
        self.document.release();
    }

    fn contentChangedCallback(event: InternalModelContentChangeEvent, editor: *Editor) anyerror!void {
        editor.onModelContentChanged(event);
    }

    fn decorationChangedCallback(event: @import("../../../common/textModelEvents.zig").ModelDecorationsChangedEvent, editor: *Editor) anyerror!void {
        editor.decoration_generation +%= 1;
        editor.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(event) });
    }

    fn emitModelContentChangedEvents(self: *Editor) void {
        // Port of the conservative event set emitted by
        // `ViewModelImpl.onModelContentChanged` for content changes.
        const line_count = self.view_lines.getViewLineCount();
        self.emitViewEvent(.{ .ViewFlushed = .{} });
        self.emitViewEvent(.{ .ViewLineMappingChanged = .{} });
        self.emitViewEvent(.{ .ViewLinesChanged = .{
            .fromLineNumber = 1,
            .count = line_count,
        } });
        self.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(null) });
        var token_ranges = [_]view_events.ViewTokensChangedRange{.{
            .fromLineNumber = 1,
            .toLineNumber = line_count,
        }};
        self.emitViewEvent(.{ .ViewTokensChanged = .{ .ranges = &token_ranges } });
    }

    fn onModelContentChanged(self: *Editor, event: InternalModelContentChangeEvent) void {
        if (event.rawContentChangedEvent.isUndoing or event.rawContentChangedEvent.isRedoing) {
            if (event.rawContentChangedEvent.resultingSelection) |selections| {
                const count = @min(selections.len, self.pending_selection.len);
                for (selections[0..count], 0..) |selection, i| self.pending_selection[i] = selection;
                self.pending_selection_count = count;
            }
        }
        if (event.contentChangedEvent.changes.items.len > 0) {
            for (self.last_content_changes.items) |old| self.allocator.free(old.text);
            self.last_content_changes.clearRetainingCapacity();
            for (event.contentChangedEvent.changes.items) |change| {
                const text = self.allocator.dupe(u8, change.text.items()) catch continue;
                self.last_content_changes.append(.{ .range = change.range, .text = text }) catch {
                    self.allocator.free(text);
                };
            }
        }
        // Apply the change to the wrapping model incrementally. Upstream's
        // ViewModelLines does this on every content event; the terminal
        // editor previously bypassed it with a full rebuild in afterEdit.
        self.view_lines.applyRawChanges(&event.rawContentChangedEvent) catch {
            self.tokens_need_refresh = true;
            self.view_lines.rebuildAll() catch return;
        };
        var has_line_changes = false;
        for (event.contentChangedEvent.changes.items) |change| {
            if (change.range.endLineNumber != change.range.startLineNumber or countEOL(change.text.items()).eolCount != 0) {
                has_line_changes = true;
                break;
            }
        }
        self.folding.hidden_model.notifyChangeModelContent(has_line_changes);
        self.refreshDirtyState();
        self.triggerFoldingUpdate(time_compat.milliTimestamp());
        self.emitModelContentChangedEvents();
        self.recoverCursorFromModel(event);
        for (self.working_copy_content_listeners.items) |listener| listener.callback(listener.context);
    }

    /// Port of `CursorsController.onModelContentChanged` for a view that did
    /// not initiate the edit: move this pane's cursors with the shared model's
    /// tracked selection markers. The editing pane receives the same event and
    /// then overwrites its state from `pushEditOperations`' resulting
    /// selections, so recovering here is idempotent for it.
    fn recoverCursorFromModel(self: *Editor, event: InternalModelContentChangeEvent) void {
        if (!self.cursor_tracking) return;
        var flushed = false;
        for (event.rawContentChangedEvent.changes.items) |change| {
            if (change == .flush) {
                flushed = true;
                break;
            }
        }
        if (flushed) {
            self.updateSelections(&[_]Selection{Selection.init(1, 1, 1, 1)}) catch {};
            return;
        }
        const tracked = self.cursorsRef().readSelectionFromMarkers(self.allocator) catch return;
        defer self.allocator.free(tracked);
        self.updateSelections(tracked) catch {};
    }

    /// Transfers ownership of the queued change batch to the caller. Each
    /// `LastContentChange.text` and the returned slice must be freed by it.
    pub fn takeContentChanges(self: *Editor, allocator: Allocator) ![]LastContentChange {
        const result = try allocator.alloc(LastContentChange, self.last_content_changes.items.len);
        for (self.last_content_changes.items, 0..) |change, index| result[index] = change;
        self.last_content_changes.clearRetainingCapacity();
        return result;
    }

    /// Recomputes the dirty bit and emits the change event when it flips.
    /// Called after content changes and saves.
    pub fn refreshDirtyState(self: *Editor) void {
        const dirty = self.isDirty();
        if (dirty == self.dirty_state) return;
        self.dirty_state = dirty;
        self.on_did_change_dirty.fire({}) catch {};
        for (self.working_copy_dirty_listeners.items) |listener| listener.callback(listener.context);
    }

    fn cursorsRef(self: *Editor) *CursorCollection {
        return &self.cursors.?;
    }

    /// Enables model-backed selection markers for a shared document. Used when
    /// a split creates the second view of this model.
    pub fn startTrackingCursorSelections(self: *Editor) void {
        if (self.cursor_tracking) return;
        self.cursor_tracking = true;
        if (self.cursors) |*cursors| cursors.startTrackingSelections();
    }

    pub fn stopTrackingCursorSelections(self: *Editor) void {
        if (!self.cursor_tracking) return;
        self.cursor_tracking = false;
        if (self.cursors) |*cursors| cursors.stopTrackingSelections();
    }

    pub fn textHeight(self: *const Editor) usize {
        const reserved: usize = if (self.status_row) 1 else 0;
        return @max(@as(usize, 1), self.screen_height -| reserved -| self.top_inset_rows);
    }

    /// Terminal find view zone: blank rows reserved at the top of the editor.
    pub fn setTopInset(self: *Editor, rows: usize) void {
        const clamped = @min(rows, self.screen_height -| 1);
        if (clamped == self.top_inset_rows) return;
        self.top_inset_rows = clamped;
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    /// Enables or disables the editor's own fallback status row. Workbench
    /// panes disable it because the status bar is a workbench part.
    pub fn setStatusRow(self: *Editor, visible: bool) void {
        if (self.status_row == visible) return;
        self.status_row = visible;
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    pub fn viewLineCount(self: *Editor) usize {
        return self.view_lines.getViewLineCount();
    }

    pub fn tabSize(self: *const Editor) usize {
        return self.cursor_config.tabSize;
    }

    pub fn indentSize(self: *const Editor) usize {
        return self.cursor_config.indentSize;
    }

    pub fn topViewLine(self: *const Editor) usize {
        const top = self.view_layout.getCurrentScrollTop();
        if (top <= 0) return 1;
        return @as(usize, @intFromFloat(top)) + 1;
    }

    /// The vertical scroll state (upstream `IViewModel.viewLayout`).
    pub fn viewLayout(self: *Editor) *ViewLayout {
        return &self.view_layout;
    }

    pub fn viewLayoutConst(self: *const Editor) *const ViewLayout {
        return &self.view_layout;
    }

    pub fn gutterWidth(self: *const Editor) usize {
        return self.gutter_width;
    }

    /// Width of the glyph-margin column (0 or 1 in the terminal).
    pub fn gutterGlyphWidth(self: *const Editor) usize {
        return self.gutter_glyph_width;
    }

    /// Reserves or releases the single terminal glyph-margin cell.
    pub fn setGlyphMarginWidth(self: *Editor, width: usize) void {
        const clamped = @min(width, 3);
        if (self.gutter_glyph_width == clamped) return;
        self.gutter_glyph_width = clamped;
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    /// Width of the line-number column.
    pub fn gutterNumberWidth(self: *const Editor) usize {
        return self.gutter_number_width;
    }

    /// Width of the folding-control column (0 or 1).
    pub fn gutterFoldWidth(self: *const Editor) usize {
        return self.gutter_fold_width;
    }

    pub fn hasFoldControl(self: *const Editor) bool {
        return self.gutter_fold_width > 0;
    }

    /// Applies `editor.lineNumbers`, `editor.lineNumbersMinChars` and the
    /// folding options to the gutter layout.
    pub fn setGutterOptions(
        self: *Editor,
        line_numbers: bool,
        line_numbers_min_chars: usize,
        folding_enabled: bool,
    ) void {
        const min_chars = @max(line_numbers_min_chars, 1);
        if (self.gutter_line_numbers == line_numbers and
            self.gutter_line_numbers_min_chars == min_chars and
            self.gutter_folding == folding_enabled)
        {
            return;
        }
        self.gutter_line_numbers = line_numbers;
        self.gutter_line_numbers_min_chars = min_chars;
        self.gutter_folding = folding_enabled;
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    /// Extra gutter cells reserved for the quick-diff marker column.
    pub fn lineDecorationsWidth(self: *const Editor) usize {
        return self.line_decorations_width;
    }

    /// Enables the quick-diff marker cell after the fold cell. The terminal
    /// maps the upstream `scm.diffDecorationsGutterWidth` to one cell.
    pub fn setLineDecorationsWidth(self: *Editor, width: usize) void {
        const clamped = @min(width, 3);
        if (clamped == self.line_decorations_width) return;
        self.line_decorations_width = clamped;
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    /// Column of the folding control cell in the gutter.
    pub fn foldCellColumn(self: *const Editor) usize {
        return self.gutter_glyph_width + self.gutter_number_width;
    }

    /// Column of the quick-diff marker cell in the gutter.
    pub fn quickDiffCellColumn(self: *const Editor) usize {
        if (self.line_decorations_width == 0) return 0;
        return self.gutter_glyph_width + self.gutter_number_width + self.gutter_fold_width;
    }

    /// Sets the borrowed display line-number map used by diff snapshot editors.
    pub fn setLineNumberMap(self: *Editor, map: ?[]const ?usize) void {
        self.line_number_map = map;
    }

    pub fn clearLineNumberMap(self: *Editor) void {
        self.line_number_map = null;
    }

    /// The number rendered in the gutter for a view line: the snapshot map
    /// value when one is set, otherwise the model line. `null` means a filler
    /// row with a blank number.
    pub fn displayLineNumber(self: *Editor, view_line: usize) ?usize {
        if (view_line == 0) return null;
        if (self.line_number_map) |map| {
            if (view_line > map.len) return null;
            return map[view_line - 1];
        }
        if (view_line > self.viewLineCount()) return null;
        return self.modelLineNumber(view_line);
    }

    pub fn setReadOnly(self: *Editor, read_only: bool) void {
        if (self.read_only == read_only) return;
        self.read_only = read_only;
        self.on_did_change_read_only.fire(read_only) catch {};
    }

    pub fn isReadOnly(self: *const Editor) bool {
        return self.read_only;
    }

    /// Width of the visible text columns after the gutter and the view's
    /// scrollbar/overview-ruler columns.
    pub fn textAreaWidth(self: *const Editor) usize {
        return @max(
            @as(usize, 1),
            self.screen_width -| self.gutter_width -| self.scrollbar_width,
        );
    }

    /// First terminal column after the text area.
    pub fn textAreaRight(self: *const Editor) usize {
        return @min(self.screen_width, self.gutter_width + self.textAreaWidth());
    }

    /// Scrollable height in view lines. This port has no
    /// `scrollBeyondLastLine`, so the viewport and the content never require
    /// more than the line count, but a short document still reports its
    /// viewport height.
    pub fn scrollHeight(self: *Editor) usize {
        return @max(self.viewLineCount(), self.textHeight());
    }

    pub fn viewLineData(self: *Editor, view_line: usize) !ViewLineData {
        return self.view_lines.getViewLineData(view_line);
    }

    pub fn modelLineNumber(self: *Editor, view_line: usize) usize {
        return self.view_lines.getModelLineNumber(view_line);
    }

    pub fn outputLineIndex(self: *Editor, view_line: usize) usize {
        return self.view_lines.getOutputLineIndex(view_line);
    }

    pub fn viewCursorPosition(self: *Editor) Position {
        return self.cursorsRef().getPrimaryCursor().viewState.position;
    }

    pub fn modelCursorPosition(self: *Editor) Position {
        return self.cursorsRef().getPrimaryCursor().modelState.position;
    }

    pub fn viewSelection(self: *Editor) Selection {
        return self.cursorsRef().getPrimaryCursor().viewState.selection;
    }

    pub fn modelSelection(self: *Editor) Selection {
        return self.cursorsRef().getPrimaryCursor().modelState.selection;
    }

    pub fn isDirty(self: *Editor) bool {
        return self.document.isDirty();
    }

    /// Reads the language's folding rules into the folding controller. This
    /// deliberately reads the language service directly: promoting the config
    /// into the shared registry here would cache it before a later language
    /// contribution (for example a test's indentation rules) is registered.
    pub fn refreshFoldingRules(self: *Editor) !void {
        var rules = FoldingRules{ .offSide = null, .markers = null };
        if (self.language_service.getLanguageConfiguration(self.languageId())) |config| {
            if (config.folding) |folding_rules| rules = folding_rules;
        }
        self.folding.setFoldingRules(rules);
    }

    /// Recomputes the provider ranges and applies the resulting hidden areas.
    fn refreshFolding(self: *Editor) !void {
        self.folding_task.schedule(null);
        const start_us = std.Io.Timestamp.now(time_compat.io, .awake).toMicroseconds();
        // A line-count change may leave the wrapping model one change behind;
        // rebuild it before a hidden range can point past its projections.
        self.ensureTokensVisible();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        try self.folding.refresh(selections);
        self.folding_dirty = false;
        try self.applyFoldingVisibility();
        const elapsed_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(time_compat.io, .awake).toMicroseconds() - start_us, 1000));
        if (elapsed_ms > 0) {
            self.folding_delay_ms = @max(folding_debounce_min_ms, @min(elapsed_ms, folding_debounce_max_ms));
        }
    }

    /// Applies the fold controller's hidden ranges to the view model and keeps
    /// selections out of them, mirroring `onHiddenRangesChanges`.
    fn applyFoldingVisibility(self: *Editor) !void {
        // Keep the model line at the top of the viewport stable across the
        // mapping change. Revealing the cursor here would jump a scrolled
        // viewport back to the cursor whenever a fold is toggled.
        const top_model_line = self.modelLineNumber(self.topViewLine());
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const adjusted = self.folding.adjustSelections(selections);
        const changed = try self.view_lines.setHiddenAreas(self.folding.hiddenRanges());
        if (changed) {
            // Port of the event emission in `ViewModelImpl.setHiddenAreas`.
            // `ViewLines.onFlushed` drops its rendered-line window and
            // `onLineMappingChanged` resets the decoration resolver.
            self.emitViewEvent(.{ .ViewFlushed = .{} });
            self.emitViewEvent(.{ .ViewLineMappingChanged = .{} });
            self.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(null) });
        }
        if (changed or adjusted) {
            try self.updateSelections(selections);
        }
        if (changed) {
            const top_position = self.viewPositionOfModelPosition(Position.init(top_model_line, 1));
            _ = self.setTopViewLine(top_position.lineNumber);
        }
        if (adjusted) self.ensureCursorVisible();
    }

    const folding_debounce_min_ms: i64 = 200;
    const folding_debounce_max_ms: i64 = 40_000;
    pub fn attachWindow(self: *Editor, window: *window_dispatch.Queue) void {
        if (self.folding_task.queue == window) return;
        self.folding_task.schedule(null);
        self.folding_task = .{ .queue = window, .context = self, .run = onFoldingDeadline };
        self.in_place_replace_task.schedule(null);
        self.in_place_replace_task = .{ .queue = window, .context = self, .run = onInPlaceReplaceDeadline };
        if (self.folding_dirty) self.triggerFoldingUpdate(time_compat.milliTimestamp());
        self.model.tokenization().tokens.attachWindow(window);
    }

    /// Content and language changes reset the folding model update deadline.
    fn triggerFoldingUpdate(self: *Editor, now_ms: i64) void {
        self.folding_dirty = true;
        self.folding_task.schedule(now_ms + self.folding_delay_ms);
    }

    fn onFoldingDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Editor = @ptrCast(@alignCast(context));
        self.refreshFoldingIfDirty();
        return true;
    }

    pub fn setTextEditorSelectionSource(self: *Editor, source: TextEditorSelectionSource) void {
        self.cursor_selection_source = source;
    }

    pub fn addViewEventHandler(self: *Editor, handler: *ViewEventHandler) void {
        self.view_event_dispatcher.addViewEventHandler(handler);
    }

    pub fn removeViewEventHandler(self: *Editor, handler: *ViewEventHandler) void {
        self.view_event_dispatcher.removeViewEventHandler(handler);
    }

    pub fn emitViewEvent(self: *Editor, event: view_events.ViewEvent) void {
        // Vertical layout state follows the line-count changes, exactly like
        // upstream `ViewLayout.onFlushed/onLinesInserted/onLinesDeleted`.
        switch (event) {
            .ViewFlushed => self.view_layout.onFlushed(self.view_lines.getViewLineCount()),
            .ViewLinesInserted => |e| self.view_layout.onLinesInserted(e.fromLineNumber, e.toLineNumber),
            .ViewLinesDeleted => |e| self.view_layout.onLinesDeleted(e.fromLineNumber, e.toLineNumber),
            else => {},
        }
        self.view_event_dispatcher.emitSingleViewEvent(event);
    }

    fn onViewLayoutScroll(event: scrollable_mod.ScrollEvent, editor: *Editor) anyerror!void {
        editor.emitViewEvent(.{ .ViewScrollChanged = view_events.ViewScrollChangedEvent.init(event) });
        for (editor.scroll_listeners.items) |listener| listener.callback(listener.context);
    }

    pub fn refreshFoldingIfDirty(self: *Editor) void {
        if (!self.folding_dirty) return;
        self.refreshFolding() catch |err| {
            self.folding_dirty = false;
            self.setMessage("folding failed: {s}", .{@errorName(err)});
        };
    }

    pub fn foldStateAtModelLine(self: *Editor, line: usize) folding.FoldState {
        return self.folding.foldStateAtLine(line);
    }

    /// Port of the folding-model access used by the sticky-scroll widget.
    pub fn foldingModel(self: *Editor) *@import("../../../contrib/folding/browser/foldingModel.zig").FoldingModel {
        return self.folding.folding_model;
    }

    /// Folding rules currently applied to this editor.
    pub fn foldingRules(self: *const Editor) FoldingRules {
        return self.folding.rules;
    }

    /// Port of the sticky-scroll fold-toggle path: toggle the region starting
    /// at a model line and update the projected view model.
    pub fn toggleFoldAtModelLine(self: *Editor, line: usize) !bool {
        self.refreshFoldingIfDirty();
        if (!self.folding.toggleAtLine(line)) return false;
        try self.applyFoldingVisibility();
        return true;
    }

    /// Port of `ICodeEditor.setHiddenAreas`. Folding remains the normal writer
    /// of hidden ranges; this entry point exists for callers/tests that hide
    /// model lines directly.
    pub fn setHiddenAreas(self: *Editor, ranges: []const Range) !void {
        const top_model_line = self.modelLineNumber(self.topViewLine());
        const changed = try self.view_lines.setHiddenAreas(ranges);
        if (!changed) return;
        self.emitViewEvent(.{ .ViewFlushed = .{} });
        self.emitViewEvent(.{ .ViewLineMappingChanged = .{} });
        self.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(null) });
        const top_position = self.viewPositionOfModelPosition(Position.init(top_model_line, 1));
        _ = self.setTopViewLine(top_position.lineNumber);
    }

    /// Hidden model lines still have content, but no view row. View parts that
    /// translate a model line (such as indentation guides) must skip them: the
    /// converter maps a hidden line to the preceding visible line, which would
    /// paint the hidden line's guides over that line's text.
    pub fn isModelLineVisible(self: *Editor, line: usize) bool {
        return self.view_lines.isModelLineVisible(line);
    }

    /// Gutter fold control for a view line. Only the first output line of a
    /// wrapped model line owns the control.
    pub fn toggleFoldAtViewLine(self: *Editor, view_line: usize) !bool {
        self.refreshFoldingIfDirty();
        if (view_line < 1 or view_line > self.viewLineCount()) return false;
        if (self.outputLineIndex(view_line) != 0) return false;
        const line = self.modelLineNumber(view_line);
        if (!self.folding.toggleAtLine(line)) return false;
        try self.applyFoldingVisibility();
        return true;
    }

    pub fn foldAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.foldLevels(self.modelCursorPosition().lineNumber, null, null);
        try self.applyFoldingVisibility();
    }

    pub fn unfoldAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.unfoldLevels(self.modelCursorPosition().lineNumber, null, .down);
        try self.applyFoldingVisibility();
    }

    pub fn toggleFoldAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.toggleLevels(self.modelCursorPosition().lineNumber, 1);
        try self.applyFoldingVisibility();
    }

    /// Port of the `editor.fold` command's `levels`/`direction` arguments.
    /// Adds collapsed user-defined folding ranges; used by the diff editor's
    /// hide-unchanged regions.
    pub fn addFoldingRanges(
        self: *Editor,
        ranges: []const @import("../../../contrib/folding/browser/foldingRanges.zig").FoldRange,
    ) !void {
        self.refreshFoldingIfDirty();
        try self.foldingModel().addManualRanges(ranges);
        try self.applyFoldingVisibility();
    }

    pub fn foldLines(
        self: *Editor,
        lines: []const usize,
        levels: ?usize,
        direction: ?folding.Direction,
    ) !void {
        self.refreshFoldingIfDirty();
        for (lines) |line| try self.folding.foldLevels(line, levels, direction);
        try self.applyFoldingVisibility();
    }

    pub fn unfoldLines(
        self: *Editor,
        lines: []const usize,
        levels: ?usize,
        direction: ?folding.Direction,
    ) !void {
        self.refreshFoldingIfDirty();
        for (lines) |line| try self.folding.unfoldLevels(line, levels, direction);
        try self.applyFoldingVisibility();
    }

    pub fn toggleFoldLines(self: *Editor, lines: []const usize, levels: usize) !void {
        self.refreshFoldingIfDirty();
        for (lines) |line| try self.folding.toggleLevels(line, levels);
        try self.applyFoldingVisibility();
    }

    pub fn createFoldingRangeFromSelection(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        try self.folding.createManualRanges(selections);
        try self.applyFoldingVisibility();
    }

    pub fn removeManualFoldingRanges(self: *Editor) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        try self.folding.removeManualRanges(selections);
        // Upstream calls `triggerFoldingModelChanged` after removing manual
        // ranges; recompute provider ranges so a manual range that shadowed a
        // provider range does not leave the region absent.
        try self.refreshFolding();
        try self.applyFoldingVisibility();
    }

    pub fn foldRecursivelyAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.foldRecursively(self.modelCursorPosition().lineNumber);
        try self.applyFoldingVisibility();
    }

    pub fn unfoldRecursivelyAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.unfoldRecursively(self.modelCursorPosition().lineNumber);
        try self.applyFoldingVisibility();
    }

    pub fn foldAll(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        self.folding.foldAll();
        try self.applyFoldingVisibility();
    }

    pub fn unfoldAll(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        self.folding.unfoldAll();
        try self.applyFoldingVisibility();
    }

    pub fn languageId(self: *Editor) []const u8 {
        return self.model.getLanguageId();
    }

    /// Applies configured `files.associations` patterns and re-detects the
    /// editor's language when the detected id changes. The association strings
    /// are copied into an editor-owned arena because the language service keeps
    /// slices into them.
    pub fn applyFileAssociations(self: *Editor, associations: []const languagesAssociations.ILanguageAssociation) !void {
        _ = self.document.associations_arena.reset(.retain_capacity);
        const arena = self.document.associations_arena.allocator();
        self.language_service.clearConfiguredLanguageAssociations();
        for (associations) |association| {
            try self.language_service.registerConfiguredLanguageAssociation(.{
                .id = try arena.dupe(u8, association.id),
                .mime = try arena.dupe(u8, association.mime),
                .filename = if (association.filename) |value| try arena.dupe(u8, value) else null,
                .extension = if (association.extension) |value| try arena.dupe(u8, value) else null,
                .filepattern = if (association.filepattern) |value| try arena.dupe(u8, value) else null,
                .firstline = association.firstline,
            });
        }

        const language_id = self.language_service.guessLanguageIdByFilepathOrFirstLine(self.path, null) orelse (try guessFromFirstLine(self.language_service, self.model)) orelse "plaintext";
        try self.setLanguage(language_id);
    }

    /// Switches the active language and refreshes every view of the shared
    /// document. Mirrors the model-language branch of the browser status item:
    /// the model language changes once, then each editor pane updates its
    /// cursor/auto-closing/folding view state.
    pub fn setLanguage(self: *Editor, language_id: []const u8) !void {
        if (std.mem.eql(u8, language_id, self.model.getLanguageId())) return;

        try configureDocumentLanguage(self.allocator, self.io, self.language_service, self.document.declarative_arena.allocator(), self.document.declarative, language_id);
        try self.codec.register(language_id);
        self.model.setLanguage(language_id);
        for (self.document.editors.items) |editor| {
            try editor.applyLanguageState(language_id);
        }
    }

    fn applyLanguageState(self: *Editor, language_id: []const u8) !void {
        self.refreshAutoIndent();
        if (self.language_service.getLanguageConfiguration(language_id)) |resolved_config| {
            self.character_pair = try CharacterPairSupport.init(resolved_config);
            if (self.character_pair) |*pair_support| {
                self.cursor_config.auto_closing_pairs = pair_support.getAutoClosingPairs();
                self.cursor_config.auto_close_before_quotes = pair_support.getAutoCloseBeforeSet(true);
                self.cursor_config.auto_close_before_brackets = pair_support.getAutoCloseBeforeSet(false);
            }
        } else {
            self.character_pair = null;
        }
        try self.refreshFoldingRules();
        self.triggerFoldingUpdate(time_compat.milliTimestamp());
    }

    pub fn getEncoding(self: *const Editor) encoding_mod.Encoding {
        return self.document.encoding;
    }

    pub fn setEncoding(self: *Editor, encoding: encoding_mod.Encoding) void {
        if (self.document.encoding == encoding) return;
        self.document.encoding = encoding;
        self.document.on_did_change_encoding.fire({}) catch {};
    }

    pub fn statusTarget(self: *Editor) editor_status.IEditorStatusTarget {
        return .{
            .context = self,
            .selection = statusSelection,
            .indentation = statusIndentation,
            .eol = statusEOL,
            .encoding = statusEncoding,
            .language_id = statusLanguageId,
            .language_name = statusLanguageName,
            .languages = statusLanguages,
            .goto_line = statusGotoLine,
            .change_indentation = statusChangeIndentation,
            .detect_indentation = statusDetectIndentation,
            .indentation_to_spaces = statusIndentationToSpaces,
            .indentation_to_tabs = statusIndentationToTabs,
            .set_eol = statusSetEOL,
            .set_encoding = statusSetEncoding,
            .set_language = statusSetLanguage,
            .subscribe = statusSubscribe,
        };
    }

    const StatusSubscription = struct {
        allocator: Allocator,
        editor: *Editor,
        listener: editor_status.StatusListener,
        cursor_id: usize = undefined,
        content_id: usize = undefined,
        options_id: usize = undefined,
        language_id: usize = undefined,
        encoding_id: usize = undefined,

        fn dispose(self: *StatusSubscription) void {
            self.editor.on_did_change_cursor_position.unlisten(self.cursor_id);
            self.editor.model.removeDidChangeContentListener(self.content_id);
            self.editor.model.removeDidChangeOptionsListener(self.options_id);
            self.editor.model.removeDidChangeLanguageListener(self.language_id);
            self.editor.document.on_did_change_encoding.unlisten(self.encoding_id);
            self.allocator.destroy(self);
        }

        fn notify(self: *StatusSubscription, change: editor_status.StatusChange) void {
            self.listener.on_change(self.listener.context, change);
        }

        fn onCursor(_: ICursorPositionChangedEvent, self: *StatusSubscription) !void {
            self.notify(.selection);
        }
        fn onContent(event: InternalModelContentChangeEvent, self: *StatusSubscription) !void {
            self.notify(.eol);
            const selections = try self.editor.getSelections();
            defer self.editor.allocator.free(selections);
            for (event.contentChangedEvent.changes.items) |change| {
                for (selections) |selection| {
                    const range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
                    if (@import("../../../common/core/range.zig").areIntersecting(&range, &change.range)) {
                        self.notify(.selection);
                        return;
                    }
                }
            }
        }
        fn onOptions(_: @import("../../../common/textModelEvents.zig").ModelOptionsChangedEvent, self: *StatusSubscription) !void {
            self.notify(.indentation);
        }
        fn onLanguage(_: @import("../../../common/textModelEvents.zig").ModelLanguageChangedEvent, self: *StatusSubscription) !void {
            self.notify(.language);
        }
        fn onEncoding(_: void, self: *StatusSubscription) !void {
            self.notify(.encoding);
        }
    };

    fn statusSubscribe(context: *anyopaque, allocator: Allocator, listener: editor_status.StatusListener) !IDisposable {
        const self: *Editor = @ptrCast(@alignCast(context));
        const subscription = try allocator.create(StatusSubscription);
        errdefer allocator.destroy(subscription);
        subscription.* = .{ .allocator = allocator, .editor = self, .listener = listener };
        subscription.cursor_id = try self.on_did_change_cursor_position.listen(subscription, StatusSubscription.onCursor);
        errdefer self.on_did_change_cursor_position.unlisten(subscription.cursor_id);
        subscription.content_id = try self.model.onDidChangeContentWithContextId(subscription, StatusSubscription.onContent);
        errdefer self.model.removeDidChangeContentListener(subscription.content_id);
        subscription.options_id = try self.model.listenDidChangeOptions(subscription, StatusSubscription.onOptions);
        errdefer self.model.removeDidChangeOptionsListener(subscription.options_id);
        subscription.language_id = try self.model.listenDidChangeLanguage(subscription, StatusSubscription.onLanguage);
        errdefer self.model.removeDidChangeLanguageListener(subscription.language_id);
        subscription.encoding_id = try self.document.on_did_change_encoding.listen(subscription, StatusSubscription.onEncoding);
        return IDisposable.from(StatusSubscription, subscription, StatusSubscription.dispose);
    }

    fn statusSelection(context: *anyopaque) editor_status.SelectionStatus {
        const self: *Editor = @ptrCast(@alignCast(context));
        const selections = self.getSelections() catch return .{};
        defer self.allocator.free(selections);
        if (selections.len == 0) return .{};

        var characters: usize = 0;
        for (selections) |selection| {
            characters += self.model.getCharacterCountInRange(
                Range.init(
                    selection.startLineNumber,
                    selection.startColumn,
                    selection.endLineNumber,
                    selection.endColumn,
                ),
                null,
            );
        }

        if (selections.len != 1) {
            return .{ .selections = selections.len, .characters = characters };
        }

        const selection = selections[0];
        const position = Position.init(selection.positionLineNumber, selection.positionColumn);
        const line = self.model.getLineContent(position.lineNumber) catch null;
        defer if (line) |value| value.deinit();
        const column = if (line) |value|
            CursorColumns.toStatusbarColumn(value.items, position.column, self.tabSize())
        else
            position.column;
        // Diff snapshot editors report the display line (the gutter number),
        // not the model line; filler rows have no line of their own.
        var display_line = position.lineNumber;
        const view_position = self.viewPositionOfModelPosition(position);
        if (self.displayLineNumber(view_position.lineNumber)) |value| {
            display_line = value;
        }
        return .{
            .line = display_line,
            .column = column,
            .selections = 1,
            .characters = characters,
        };
    }

    fn statusIndentation(context: *anyopaque) editor_status.IndentationStatus {
        const self: *Editor = @ptrCast(@alignCast(context));
        const options = self.model.getOptions();
        return .{
            .tab_size = options.tabSize,
            .indent_size = options.indentSize,
            .insert_spaces = options.insertSpaces,
        };
    }

    fn statusEOL(context: *anyopaque) EOL {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.model.getEOL();
    }

    fn statusEncoding(context: *anyopaque) encoding_mod.Encoding {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.document.encoding;
    }

    fn statusLanguageId(context: *anyopaque) []const u8 {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.languageId();
    }

    fn statusLanguageName(context: *anyopaque) []const u8 {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.language_service.getLanguageName(self.languageId()) orelse self.languageId();
    }

    fn statusLanguages(
        context: *anyopaque,
        allocator: Allocator,
    ) ![]const editor_status.LanguageNameIdPair {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.language_service.getSortedRegisteredLanguageNames(allocator);
    }

    fn statusGotoLine(context: *anyopaque, line: usize, column: usize) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        const line_number = @min(@max(line, 1), self.model.getLineCount());
        const column_number = @min(
            @max(column, 1),
            self.model.getLineMaxColumn(line_number),
        );
        try self.setCursorPosition(Position.init(line_number, column_number));
        self.ensureCursorVisible();
    }

    fn statusChangeIndentation(
        context: *anyopaque,
        tab_size: usize,
        insert_spaces: bool,
        display_only: bool,
    ) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        if (self.read_only) return;
        self.changeIndentation(tab_size, insert_spaces, display_only);
    }

    fn statusDetectIndentation(context: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        if (self.read_only) return;
        self.detectIndentation();
    }

    fn statusIndentationToSpaces(context: *anyopaque) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        try self.indentationToSpaces();
    }

    fn statusIndentationToTabs(context: *anyopaque) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        try self.indentationToTabs();
    }

    fn statusSetEOL(context: *anyopaque, eol: EOL) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        if (self.read_only) return error.ReadOnly;
        if (self.model.getEOL() == eol) return;
        self.pushUndoStop();
        try self.model.pushEOL(eol);
        self.pushUndoStop();
    }

    fn statusSetEncoding(context: *anyopaque, encoding: encoding_mod.Encoding) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        self.setEncoding(encoding);
    }

    fn statusSetLanguage(context: *anyopaque, language_id: []const u8) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        try self.setLanguage(language_id);
    }

    pub fn message(self: *Editor) []const u8 {
        return self.status[0..self.status_len];
    }

    pub fn setMessage(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.status, fmt, args) catch self.status[0..0];
        self.status_len = written.len;
    }

    pub fn clearMessage(self: *Editor) void {
        self.status_len = 0;
    }

    /// Applies completed async worker deltas without advancing the fallback
    /// tokenizer.
    pub fn drainBackgroundTokenization(self: *Editor) bool {
        return self.model.drainBackgroundTokenization();
    }

    /// Advances the ported default background tokenizer by one ~1 ms chunk.
    /// Returns true when tokens changed and the view should repaint.
    pub fn pollBackgroundTokenization(self: *Editor) bool {
        return self.model.pollBackgroundTokenization();
    }

    pub fn backgroundTokenizationPending(self: *Editor) bool {
        return self.model.backgroundTokenizationPending();
    }

    /// Forces the visible-range tokenization after the first paint. Returns
    /// true when a repaint with syntax colors is needed.
    fn ensureLinesTokenized(self: *Editor, selections: []const Selection) void {
        for (selections) |selection| {
            const line = selection.getStartPosition().lineNumber;
            if (!self.model.hasAccurateTokensForLine(line)) {
                self.model.forceTokenization(line);
            }
        }
    }

    pub fn ensureTokensVisible(self: *Editor) void {
        const line_count = self.model.getLineCount();
        if (self.view_lines.projections.items.len != line_count) {
            // A failed or interrupted undo/redo can leave the wrapping model
            // out of step with the text model. Rebuild before asking for
            // tokens so an out-of-range line never reaches forceTokenization.
            self.view_lines.rebuildAll() catch return;
            self.resetCursorViewState() catch {};
            self.ensureCursorVisible();
        }

        const count = self.view_lines.getViewLineCount();
        if (count == 0) return;
        const last = @min(self.topViewLine() + self.textHeight() - 1, count);
        const model_line = @min(self.view_lines.getModelLineNumber(last), line_count);
        if (self.tokens_need_refresh) {
            const first_model_line = self.view_lines.getModelLineNumber(self.topViewLine());
            self.model.tokenization().forceRefreshRange(first_model_line, model_line);
            self.tokens_need_refresh = false;
            self.tokenized_viewport_start = first_model_line;
            self.tokenized_viewport_end = model_line;
            self.tokenized_viewport_version = self.model.getVersionId();
            return;
        }
        // Tokenize only the viewport. An edit or a short scroll walks
        // sequentially from the first invalid line (cheap and exact); a jump
        // tokenizes the visible range from a guessed start state instead of
        // every line in between. The content version makes an edit inside the
        // forced interval re-tokenize, while the prefix gap a jump leaves
        // behind does not force the viewport on every later frame.
        const version = self.model.getVersionId();
        const first_model_line = self.view_lines.getModelLineNumber(self.topViewLine());
        const same_version = self.tokenized_viewport_version == version;
        const height = self.textHeight();

        if (same_version and
            self.tokenized_viewport_start > 0 and
            model_line >= self.tokenized_viewport_start and
            model_line <= self.tokenized_viewport_end)
        {
            return;
        }

        if (same_version and
            self.tokenized_viewport_end > 0 and
            model_line > self.tokenized_viewport_end and
            first_model_line <= self.tokenized_viewport_end + 1 + height)
        {
            // Continue the forced range instead of re-tokenizing the overlap.
            self.model.tokenization().forceTokenizeRange(self.tokenized_viewport_end + 1, model_line);
        } else if (!self.model.hasAccurateTokensForLine(model_line) and blk: {
            const first_invalid = self.model.tokenization().firstInvalidTokenLine() orelse break :blk false;
            break :blk first_invalid + height >= first_model_line;
        }) {
            // The first invalid line is at/after the viewport (an edit or a
            // small forward scroll): walk from it to the viewport end.
            self.model.forceTokenization(model_line);
        } else if (!self.model.hasAccurateTokensForLine(model_line)) {
            self.model.tokenization().forceTokenizeRange(first_model_line, model_line);
        }

        self.tokenized_viewport_start = first_model_line;
        self.tokenized_viewport_end = model_line;
        self.tokenized_viewport_version = version;
    }

    fn recoverWrapping(self: *Editor) void {
        self.tokens_need_refresh = true;
        self.view_lines.rebuildAll() catch return;
        self.resetCursorViewState() catch {};
        self.refreshLayout() catch {};
        self.ensureCursorVisible();
    }

    pub fn setViewport(self: *Editor, width: usize, height: usize) void {
        self.screen_width = @max(width, 1);
        self.screen_height = @max(height, 1);
        self.refreshLayout() catch |err| self.setMessage("layout error: {s}", .{@errorName(err)});
        self.ensureCursorVisible();
    }

    /// Reserves rightmost text columns for the view's scrollbar/overview ruler.
    /// The editor wraps around them so text never paints underneath. The value
    /// is clamped so at least one text column remains.
    pub fn setScrollbarWidth(self: *Editor, width: usize) void {
        const available = self.screen_width -| self.gutter_width;
        const clamped = @min(width, available -| 1);
        if (clamped == self.scrollbar_width) return;
        self.scrollbar_width = clamped;
        self.refreshLayout() catch |err| self.setMessage("layout error: {s}", .{@errorName(err)});
        self.ensureCursorVisible();
    }

    /// Applies `editor.wordWrap`, `editor.wordWrapColumn` and
    /// `editor.wrappingIndent`; rewraps when any value changes.
    pub fn setWordWrapOptions(
        self: *Editor,
        mode: WordWrap,
        column: i32,
        indent: WrappingIndent,
        indicator: bool,
    ) void {
        if (self.wrap_mode == mode and
            self.wrap_column == column and
            self.wrapping_indent == indent and
            self.word_wrap_indicator == indicator)
        {
            return;
        }
        self.wrap_mode = mode;
        self.wrap_column = column;
        self.wrapping_indent = indent;
        self.word_wrap_indicator = indicator;
        self.refreshLayout() catch |err| self.setMessage("layout error: {s}", .{@errorName(err)});
        if (self.wrap_mode != .off) _ = self.setScrollLeft(0);
        self.ensureCursorVisible();
    }

    /// Upstream `EditorLayoutInfoComputer` wrapping decision, expressed in
    /// terminal cells. Zero means no soft wrap.
    fn effectiveWrappingColumn(self: *const Editor, text_width: usize) usize {
        const viewport_column = @max(
            @as(usize, 1),
            text_width -| @intFromBool(self.word_wrap_indicator),
        );
        return switch (self.wrap_mode) {
            .off => 0,
            .on => viewport_column,
            .bounded => @min(viewport_column, @as(usize, @intCast(@max(self.wrap_column, 1)))),
            .word_wrap_column => @intCast(@max(self.wrap_column, 1)),
        };
    }

    fn refreshLayout(self: *Editor) !void {
        const digits = digitsFor(self.model.getLineCount());
        self.gutter_number_width = if (self.gutter_line_numbers)
            @max(digits, self.gutter_line_numbers_min_chars)
        else
            0;
        self.gutter_fold_width = if (self.gutter_folding) 1 else 0;
        const new_gutter = self.gutter_glyph_width + self.gutter_number_width +
            self.gutter_fold_width + self.line_decorations_width;
        const available = self.screen_width -| new_gutter;
        const text_width = @max(@as(usize, 1), available -| self.scrollbar_width);
        self.gutter_width = new_gutter;
        self.cursor_config.pageSize = self.textHeight();
        self.syncViewportDimensions();

        if (try self.view_lines.setWrappingOptions(
            self.effectiveWrappingColumn(text_width),
            self.wrapping_indent,
        )) {
            self.view_layout.onFlushed(self.view_lines.getViewLineCount());
            self.emitViewEvent(.{ .ViewFlushed = .{} });
            self.emitViewEvent(.{ .ViewLineMappingChanged = .{} });
            self.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(null) });
            try self.resetCursorViewState();
        }
    }

    /// Keeps the view layout's viewport size and content height in step with
    /// the terminal size, status row and scrollbar reservation.
    fn syncViewportDimensions(self: *Editor) void {
        self.view_layout.onFlushed(self.view_lines.getViewLineCount());
        self.view_layout.setViewport(self.textAreaWidth(), self.textHeight());
    }

    fn resetCursorViewState(self: *Editor) !void {
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        try self.updateSelections(selections);
    }

    /// Emits the current cursor and scroll state for a view that has just
    /// attached. Upstream normally delivers these through the events raised
    /// while the view model applies its initial state; the terminal view is
    /// created after the editor, so the first frame asks for them explicitly.
    pub fn emitCurrentViewState(self: *Editor) void {
        self.emitCursorStateChangedForce(.NotSet);
        self.emitCurrentScrollState();
    }

    fn emitCurrentScrollState(self: *Editor) void {
        self.emitViewEvent(.{ .ViewScrollChanged = .{
            .scrollWidth = self.view_layout.getScrollWidth(),
            .scrollLeft = self.view_layout.getCurrentScrollLeft(),
            .scrollHeight = self.view_layout.getScrollHeight(),
            .scrollTop = self.view_layout.getCurrentScrollTop(),
            .scrollWidthChanged = false,
            .scrollLeftChanged = false,
            .scrollHeightChanged = true,
            .scrollTopChanged = true,
        } });
        for (self.scroll_listeners.items) |listener| listener.callback(listener.context);
    }

    pub fn addScrollListener(self: *Editor, listener: ChangeListener) void {
        self.scroll_listeners.append(listener) catch {};
    }

    pub fn removeScrollListener(self: *Editor, listener: ChangeListener) void {
        removeChangeListener(&self.scroll_listeners, listener);
    }

    pub fn ensureCursorVisible(self: *Editor) void {
        const top = self.topViewLine();
        const position = self.viewCursorPosition();
        const height = self.textHeight();
        var next = top;
        if (position.lineNumber < top) {
            next = position.lineNumber;
        } else if (position.lineNumber >= top + height) {
            next = position.lineNumber - height + 1;
        }
        if (next != top) _ = self.applyTopViewLine(next);
        self.ensureCursorVisibleHorizontal();
    }

    /// First visible text cell (upstream `ViewLayout.getCurrentScrollLeft`).
    pub fn scrollLeft(self: *const Editor) usize {
        return @intFromFloat(self.view_layout.getCurrentScrollLeft());
    }

    /// Maximum horizontal offset for the current content width.
    pub fn maxScrollLeft(self: *const Editor) usize {
        const scroll_width: usize = @intFromFloat(self.view_layout.getScrollWidth());
        return scroll_width -| self.textAreaWidth();
    }

    /// Sets the horizontal offset without moving the cursor.
    pub fn setScrollLeft(self: *Editor, cell: usize) bool {
        const wanted = @min(cell, self.maxScrollLeft());
        if (wanted == self.scrollLeft()) return false;
        self.view_layout.setScrollPositionNow(.{ .scrollLeft = @floatFromInt(wanted) });
        return true;
    }

    /// Scrolls horizontally by `delta` cells without moving the cursor.
    pub fn scrollColumns(self: *Editor, delta: isize) bool {
        const current: isize = @intCast(self.scrollLeft());
        const max: isize = @intCast(self.maxScrollLeft());
        const wanted: usize = @intCast(@max(0, @min(max, current + delta)));
        return self.setScrollLeft(wanted);
    }

    /// Brings the primary caret column into the text viewport. This is the
    /// terminal equivalent of the browser's horizontal reveal request.
    fn ensureCursorVisibleHorizontal(self: *Editor) void {
        const position = self.viewCursorPosition();
        if (position.lineNumber == 0) return;
        const data = self.viewLineData(position.lineNumber) catch return;
        const column = @min(@max(position.column, data.minColumn), data.maxColumn);
        const visible = CursorColumns.visibleColumnFromColumn(
            data.content,
            column,
            self.cursor_config.tabSize,
        );
        const viewport = self.textAreaWidth();
        const width = @max(self.maxScrollLeft() +| viewport, visible +| 1);
        var window = ui_scroll.ScrollWindow.init(viewport, width, self.scrollLeft());
        if (window.ensureVisible(visible, visible +| 1, 1)) {
            _ = self.setScrollLeft(window.offset);
        }
    }

    fn maxTopViewLine(self: *Editor) usize {
        const total = self.view_lines.getViewLineCount();
        const height = self.textHeight();
        return if (total <= height) 1 else total - height + 1;
    }

    /// Scrolls the viewport by `delta` view lines without moving the cursor.
    /// Returns whether the top line changed; the wheel uses this so a cursor
    /// may stay off-screen until the next cursor move reveals it.
    pub fn scrollViewLines(self: *Editor, delta: isize) bool {
        const max_top = self.maxTopViewLine();
        const current: isize = @intCast(@min(self.topViewLine(), max_top));
        const max: isize = @intCast(max_top);
        const next = std.math.clamp(current + delta, 1, max);
        return self.applyTopViewLine(@intCast(next));
    }

    /// Sets the first visible view line without moving the cursor. Used by the
    /// terminal scrollbar, whose scroll position is expressed in lines.
    pub fn setTopViewLine(self: *Editor, line: usize) bool {
        return self.applyTopViewLine(line);
    }

    /// Applies a whole-line top position through the view layout, which emits
    /// `ViewScrollChanged` when it changes.
    fn applyTopViewLine(self: *Editor, line: usize) bool {
        const next = std.math.clamp(line, 1, self.maxTopViewLine());
        if (next == self.topViewLine()) return false;
        self.view_layout.setScrollPositionNow(.{ .scrollTop = @floatFromInt(next - 1) });
        return true;
    }

    pub const ScrollDirection = enum { up, down };

    pub const ScrollUnit = enum {
        line,
        wrapped_line,
        page,
        half_page,
        editor,
    };

    /// Port of the vertical part of `EditorScrollImpl._computeDesiredScrollTop`
    /// in `src/vs/editor/browser/coreCommands.ts`.
    pub fn scrollEditor(
        self: *Editor,
        direction: ScrollDirection,
        unit: ScrollUnit,
        value: usize,
        reveal_cursor: bool,
        select: bool,
    ) bool {
        const steps = @max(value, 1);
        const height = self.textHeight();
        var changed = false;
        switch (unit) {
            .line => {
                const top_model_line = self.modelLineNumber(self.topViewLine());
                const signed: isize = if (direction == .up)
                    -@as(isize, @intCast(steps))
                else
                    @as(isize, @intCast(steps));
                const target_model = std.math.clamp(
                    @as(isize, @intCast(top_model_line)) + signed,
                    1,
                    @as(isize, @intCast(self.model.getLineCount())),
                );
                const view_position = self.viewPositionOfModelPosition(Position.init(@intCast(target_model), 1));
                changed = self.setTopViewLine(view_position.lineNumber);
            },
            .wrapped_line => {
                const delta: isize = if (direction == .up)
                    -@as(isize, @intCast(steps))
                else
                    @as(isize, @intCast(steps));
                changed = self.scrollViewLines(delta);
            },
            .page, .half_page => {
                const base = if (unit == .page) height else @max(@as(usize, 1), (height + 1) / 2);
                const lines = base * steps;
                const delta: isize = if (direction == .up)
                    -@as(isize, @intCast(lines))
                else
                    @as(isize, @intCast(lines));
                changed = self.scrollViewLines(delta);
            },
            .editor => {
                changed = switch (direction) {
                    .up => self.setTopViewLine(1),
                    .down => self.setTopViewLine(self.maxTopViewLine()),
                };
            },
        }
        if (reveal_cursor and changed) self.moveCursorsIntoViewport(select);
        return changed;
    }

    /// Port of ViewLines' `_computeScrollTopToRevealRange`, expressed in view
    /// lines. The terminal has no sub-line scrolling, so the desired top is
    /// clamped to a 1-based view line before it reaches `setTopViewLine`.
    pub fn revealViewLines(
        self: *Editor,
        start_view_line: usize,
        end_view_line: usize,
        vertical_type: view_events.VerticalRevealType,
    ) bool {
        const count = self.viewLineCount();
        if (count == 0) return false;
        const start = std.math.clamp(start_view_line, 1, count);
        const end = std.math.clamp(end_view_line, start, count);
        const height = self.textHeight();
        const top = self.topViewLine();
        const top0: isize = @intCast(top - 1);
        const box_start: isize = @intCast(start - 1);
        const box_end: isize = @intCast(end);
        const box_length = box_end - box_start;
        const viewport_end = top0 + @as(isize, @intCast(height));

        var desired: isize = top0;
        switch (vertical_type) {
            .Top => desired = box_start,
            .Bottom => {
                const padded_end = box_end + 1;
                desired = @max(0, padded_end - @as(isize, @intCast(height)));
            },
            .Center, .CenterIfOutsideViewport => {
                const fully_visible = start >= top and end <= top + height -| 1;
                if (vertical_type == .CenterIfOutsideViewport and fully_visible) {
                    desired = top0;
                } else if (box_length > @as(isize, @intCast(height))) {
                    desired = box_start;
                } else {
                    const middle = (@as(f64, @floatFromInt(box_start)) + @as(f64, @floatFromInt(box_end))) / 2.0;
                    desired = @intFromFloat(@max(0.0, @floor(middle - @as(f64, @floatFromInt(height)) / 2.0)));
                }
            },
            .NearTop, .NearTopIfOutsideViewport => {
                const fully_visible = start >= top and end <= top + height -| 1;
                if (vertical_type == .NearTopIfOutsideViewport and fully_visible) {
                    desired = top0;
                } else {
                    const gap = @max(@as(isize, 5), @as(isize, @intCast((height + 4) / 5)));
                    const desired_gap = box_start - gap;
                    const min_top = box_end - @as(isize, @intCast(height));
                    desired = @max(min_top, desired_gap);
                    if (desired < 0) desired = 0;
                }
            },
            .Simple => {
                // Upstream's `_computeMinimumScrolling`; `Simple` includes one
                // extra line below so revealing a line does not leave it under
                // the scrollbar.
                const padded_end = box_end + 1;
                if (padded_end - box_start >= @as(isize, @intCast(height))) {
                    desired = box_start;
                } else if (box_start < top0) {
                    desired = box_start;
                } else if (padded_end > viewport_end) {
                    desired = @max(0, padded_end - @as(isize, @intCast(height)));
                } else {
                    desired = top0;
                }
            },
        }
        return self.setTopViewLine(@intCast(desired + 1));
    }

    /// Converts a model range to view lines, matching
    /// `ViewModelImpl.revealRange` -> ViewLines' reveal request.
    pub fn revealRange(self: *Editor, range: Range, vertical_type: view_events.VerticalRevealType) bool {
        const converter = self.converter.interface();
        const view_range = converter.convertModelRangeToViewRange(converter.context, range, .None);
        return self.revealViewLines(
            view_range.startLineNumber,
            view_range.endLineNumber,
            vertical_type,
        );
    }

    pub fn revealLine(self: *Editor, line_number: usize, vertical_type: view_events.VerticalRevealType) bool {
        const line = std.math.clamp(line_number, 1, self.model.getLineCount());
        const range = Range.init(line, 1, line, self.model.getLineMaxColumn(line));
        return self.revealRange(range, vertical_type);
    }

    /// The completely visible see view range, with an exclusive end line like
    /// upstream's `getCompletelyVisibleViewRange`.
    pub fn visibleViewRange(self: *Editor) Range {
        const start = self.topViewLine();
        const end = @min(start + self.textHeight(), self.viewLineCount() + 1);
        return Range.init(start, 1, end, 1);
    }

    pub fn visibleModelRange(self: *Editor) Range {
        const converter = self.converter.interface();
        return converter.convertViewRangeToModelRange(converter.context, self.visibleViewRange());
    }

    /// Matches `CursorMoveImpl._runCursorMove` after a `cursorMove` command:
    /// keep every resulting cursor visible using the Simple reveal strategy.
    fn revealCursorStates(self: *Editor) void {
        const states = self.cursorsRef().getAll(self.allocator) catch return;
        defer self.allocator.free(states);
        if (states.len == 0) return;
        var start = states[0].viewState.selection.startLineNumber;
        var end = states[0].viewState.selection.endLineNumber;
        for (states[1..]) |state| {
            start = @min(start, state.viewState.selection.startLineNumber);
            end = @max(end, state.viewState.selection.endLineNumber);
        }
        _ = self.revealViewLines(start, end, .Simple);
    }

    /// Port of `CursorMoveCommands.viewportMove(.viewport_if_outside)` used by
    /// `editorScroll`'s `revealCursor` option.
    fn moveCursorsIntoViewport(self: *Editor, select: bool) void {
        const cursors = self.cursorsRef().getAll(self.allocator) catch return;
        defer self.allocator.free(cursors);
        if (cursors.len == 0) return;
        const visible_view = self.visibleViewRange();
        const visible_model = self.visibleModelRange();
        const states = CursorMoveCommands.viewportMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            visible_view,
            visible_model,
            .viewport_if_outside,
            select,
            1,
        ) catch return;
        defer self.allocator.free(states);
        self.cursorsRef().setStates(states) catch return;
        self.cursorsRef().normalize() catch {};
        self.emitCursorStateChanged(.Explicit);
    }

    /// Port of `CursorMoveImpl` and the portable `CursorMoveCommands`. The
    /// adapter parses the raw command arguments; this method owns the cursor,
    /// history and reveal behavior.
    pub fn cursorMove(self: *Editor, parsed: CursorMoveCommands.ParsedArguments) !bool {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);
        if (cursors.len == 0) return false;

        const model = self.model_adapter.interface();
        const view = self.view_lines.interface();
        const states = switch (parsed.direction) {
            .viewport_top, .viewport_center, .viewport_bottom, .viewport_if_outside => try CursorMoveCommands.viewportMove(
                self.allocator,
                &self.cursor_config,
                model,
                view,
                cursors,
                self.visibleViewRange(),
                self.visibleModelRange(),
                parsed.direction,
                parsed.select,
                parsed.value,
            ),
            else => try CursorMoveCommands.simpleMove(
                self.allocator,
                &self.cursor_config,
                model,
                view,
                cursors,
                parsed.direction,
                parsed.select,
                parsed.value,
                parsed.unit,
            ),
        };
        defer self.allocator.free(states);
        if (states.len == 0) return false;

        self.pushUndoStop();
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
        self.emitCursorStateChanged(.Explicit);
        self.revealCursorStates();
        return true;
    }

    /// The model column of a 1-based column in a view line's output content.
    pub fn modelColumnOfViewPosition(self: *Editor, view_line_number: usize, view_column: usize) usize {
        return self.view_lines.getModelColumnOfViewPosition(view_line_number, view_column);
    }

    /// The view position of a model position, following wrapped view lines.
    /// Content widgets anchor to model positions, so the view needs the same
    /// model-to-view conversion the cursor uses.
    pub fn viewPositionOfModelPosition(self: *Editor, model_position: Position) Position {
        const converter = self.converter.interface();
        return converter.convertModelPositionToViewPosition(converter.context, model_position, .None, false, false);
    }

    /// Maps a visible cell offset within a view line to the model position.
    /// This is a terminal adaptation of the upstream view-model point mapping:
    /// `visible_column` counts cells after tab expansion, not model columns.
    pub fn positionAtViewPoint(self: *Editor, view_line_number: usize, visible_column: usize) !Position {
        const view_line = @min(@max(view_line_number, 1), self.viewLineCount());
        const data = try self.viewLineData(view_line);
        const target = data.startVisibleColumn + visible_column;
        const output_column = CursorColumns.columnFromVisibleColumnFrom(
            data.content,
            target,
            self.cursor_config.tabSize,
            data.startVisibleColumn,
        );
        const column = self.view_lines.getModelColumnOfViewPosition(view_line, output_column);
        const min_column = self.view_lines.getModelColumnOfViewPosition(view_line, data.minColumn);
        const max_column = self.view_lines.getModelColumnOfViewPosition(view_line, data.maxColumn);
        return Position.init(
            self.modelLineNumber(view_line),
            std.math.clamp(column, min_column, max_column),
        );
    }

    /// Closes the current undo element unless a Vim-style undo group is
    /// active. Internal typing/newline/command boundaries call this; the group
    /// boundary is the only stack push that matters inside the group.
    fn pushUndoStop(self: *Editor) void {
        if (self.undo_group_depth == 0) self.model.pushStackElement();
    }

    /// Starts one undo element. Nested calls are allowed; the outer group owns
    /// the boundary. Callers must pair this with `endUndoGroup` (use `defer`).
    pub fn beginUndoGroup(self: *Editor) void {
        if (self.undo_group_depth == 0) self.model.pushStackElement();
        self.undo_group_depth += 1;
    }

    /// Ends the innermost undo group and closes it when the outer group ends.
    pub fn endUndoGroup(self: *Editor) void {
        if (self.undo_group_depth == 0) return;
        self.undo_group_depth -= 1;
        if (self.undo_group_depth == 0) self.model.pushStackElement();
    }

    fn closeTypingGroup(self: *Editor) void {
        self.pushUndoStop();
        self.prev_edit_operation_type = .Other;
    }

    /// Moves one logical line at a time (Vim `j`/`k`), preserving the desired
    /// visible column through the cursor's `leftoverVisibleColumns` state.
    /// Unlike `cursorMove`, a motion does not open an undo boundary.
    /// Puts a normal-mode caret back on the last character of its line while
    /// preserving the desired visible column. Vim `j`/`k` may land one cell
    /// after a short line; setting the position without carrying
    /// `leftoverVisibleColumns` would lose the remembered column.
    pub fn clampCursorToLastChar(self: *Editor) !void {
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try self.allocator.alloc(PartialCursorState, cursors.len);
        for (cursors, 0..) |cursor, index| {
            const selection = cursor.modelState.selection;
            if (!selection.isEmpty()) {
                states[index] = .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
                continue;
            }
            const position = cursor.modelState.position;
            const line = self.model.getLineContent(position.lineNumber) catch {
                states[index] = .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
                continue;
            };
            defer line.deinit();
            var last_column: usize = 1;
            var byte_index: usize = 0;
            while (byte_index < line.items.len) {
                last_column = byte_index + 1;
                byte_index += std.unicode.utf8ByteSequenceLength(line.items[byte_index]) catch 1;
            }
            if (position.column <= last_column) {
                states[index] = .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
                continue;
            }
            const old_visible = CursorColumns.visibleColumnFromColumn(line.items, position.column, self.cursor_config.tabSize);
            const new_visible = CursorColumns.visibleColumnFromColumn(line.items, last_column, self.cursor_config.tabSize);
            const desired = @as(isize, @intCast(old_visible)) + cursor.modelState.leftoverVisibleColumns;
            const new_leftover = desired - @as(isize, @intCast(new_visible));
            states[index] = cursorCommon.CursorState.fromModelState(SingleCursorState.init(
                Range.init(position.lineNumber, last_column, position.lineNumber, last_column),
                .Simple,
                0,
                Position.init(position.lineNumber, last_column),
                new_leftover,
            ));
        }
        try self.applyCursorStates(states);
    }

    pub fn moveLogicalLine(self: *Editor, down: bool, select: bool, count: usize) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            if (down) .down else .up,
            select,
            @max(count, 1),
            .line,
        );
        try self.applyCursorStates(states);
    }

    pub fn viewCursorStates(self: *Editor) ![]CursorState {
        return self.cursorsRef().getAll(self.allocator);
    }

    pub fn cursorCount(self: *Editor) usize {
        return self.cursorsRef().cursors.items.len;
    }

    pub fn removeSecondaryCursors(self: *Editor) !void {
        try self.cursorsRef().killSecondaryCursors();
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    fn resetMultiCursorSession(self: *Editor) void {
        if (self.multicursor_session) |*session| session.deinit();
        self.multicursor_session = null;
    }

    fn ensureMultiCursorSession(self: *Editor) !?*multicursor.SearchSession {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        if (self.multicursor_session) |*session| {
            if (session.primary.equalsSelection(&selections[0])) return session;
            self.resetMultiCursorSession();
        }

        self.multicursor_session = try multicursor.SearchSession.create(self.allocator, self.model, selections);
        return if (self.multicursor_session) |*session| session else null;
    }

    pub fn addCursorAbove(self: *Editor) !void {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);
        const states = try multicursor.addCursorUp(self.allocator, &self.cursor_config, self.model_adapter.interface(), cursors);
        defer self.allocator.free(states);
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    pub fn addCursorBelow(self: *Editor) !void {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);
        const states = try multicursor.addCursorDown(self.allocator, &self.cursor_config, self.model_adapter.interface(), cursors);
        defer self.allocator.free(states);
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    pub fn selectNextOccurrence(self: *Editor) !void {
        var session = (try self.ensureMultiCursorSession()) orelse return;
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const result = try session.addSelectionToNext(self.model, selections) orelse return;
        defer self.allocator.free(result);
        try self.updateSelectionsWithReason(result, .Explicit);
        self.ensureCursorVisible();
    }

    pub fn selectAllOccurrences(self: *Editor) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        var session = (try multicursor.SearchSession.create(self.allocator, self.model, selections)) orelse return;
        defer session.deinit();

        const result = try session.selectAll(self.model) orelse return;
        defer self.allocator.free(result);
        try self.updateSelectionsWithReason(result, .Explicit);
        self.ensureCursorVisible();
    }

    fn cursorStatesCopy(self: *Editor) ![]CursorState {
        return self.cursorsRef().getAll(self.allocator);
    }

    fn applyCursorStates(self: *Editor, states: []PartialCursorState) !void {
        defer self.allocator.free(states);
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    pub fn moveLeft(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .left,
            select,
            1,
            .character,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveRight(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .right,
            select,
            1,
            .character,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveUp(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .up,
            select,
            1,
            .wrapped_line,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveDown(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .down,
            select,
            1,
            .wrapped_line,
        );
        try self.applyCursorStates(states);
    }

    pub fn movePageUp(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .up,
            select,
            self.cursor_config.pageSize,
            .wrapped_line,
        );
        try self.applyCursorStates(states);
    }

    pub fn movePageDown(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.simpleMove(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            .down,
            select,
            self.cursor_config.pageSize,
            .wrapped_line,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveWordLeft(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveWord(
            self.allocator,
            self.model_adapter.interface(),
            cursors,
            .left,
            &self.word_separators,
            select,
            cursors.len > 1,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveWordRight(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveWord(
            self.allocator,
            self.model_adapter.interface(),
            cursors,
            .right,
            &self.word_separators,
            select,
            cursors.len > 1,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveLineStart(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveToBeginningOfLine(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            select,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveLineEnd(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveToEndOfLine(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            self.view_lines.interface(),
            cursors,
            select,
            false,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveDocStart(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveToBeginningOfBuffer(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            cursors,
            select,
        );
        try self.applyCursorStates(states);
    }

    pub fn moveDocEnd(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursors = try self.cursorStatesCopy();
        defer self.allocator.free(cursors);
        const states = try CursorMoveCommands.moveToEndOfBuffer(
            self.allocator,
            &self.cursor_config,
            self.model_adapter.interface(),
            cursors,
            select,
        );
        try self.applyCursorStates(states);
    }

    pub fn selectAll(self: *Editor) !void {
        self.closeTypingGroup();
        const range = self.model.getFullModelRange();
        const selection = Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn);
        try self.updateSelectionsWithReason(&[_]Selection{selection}, .Explicit);
        self.ensureCursorVisible();
    }

    pub fn cancelSelection(self: *Editor) !void {
        const cursor = self.cursorsRef().getPrimaryCursor();
        const partial = CursorMoveCommands.cancelSelection(cursor);
        try self.cursorsRef().setStates(&[_]PartialCursorState{partial});
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    fn executeReplaceCommands(self: *Editor, commands: []const ?cursorCommon.ReplaceCommand) !void {
        const before_selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(before_selections);
        return self.executeReplaceCommandsFor(before_selections, commands);
    }

    fn executeReplaceCommandsFor(self: *Editor, before_selections: []const Selection, commands: []const ?cursorCommon.ReplaceCommand) !void {
        if (commands.len == 0) return;

        var operations = ArrayList(IdentifiedSingleEditOperation).init(self.allocator);
        defer operations.deinit();
        var targets = ArrayList(ReplaceCursorTarget).init(self.allocator);
        defer targets.deinit();
        for (commands, 0..) |command, index| {
            const cmd = command orelse {
                try targets.append(.{});
                continue;
            };
            const text = if (cmd.text.len == 0) null else String.initBorrowed(cmd.text);
            var operation = IdentifiedSingleEditOperation.init(cmd.range, text);
            operation.identifier = .{ .major = @intCast(index), .minor = 0 };
            try operations.append(operation);
            try targets.append(.{
                .present = true,
                .line_offset = cmd.cursor_line_offset,
                .column_offset = cmd.cursor_column_offset,
            });
        }
        if (operations.items.len == 0) return;

        const scratch = try self.allocator.alloc(Selection, before_selections.len);
        defer self.allocator.free(scratch);
        var computer = ReplaceCursorComputer{
            .before = before_selections,
            .targets = targets.items,
            .scratch = scratch,
        };

        const after_selections = try self.model.pushEditOperations(
            @constCast(before_selections),
            operations.items,
            computer.state(),
            null,
        );

        try self.afterEdit();

        if (after_selections) |selections| {
            try self.updateSelections(selections);
        } else {
            try self.updateSelections(before_selections);
        }
        self.ensureCursorVisible();
    }

    fn afterEdit(self: *Editor) !void {
        // Ordinary edits are applied incrementally to the wrapping model and
        // the token store invalidates the edited line via `acceptEdit`.
        // Forcing a refresh of the whole visible range here re-tokenizes every
        // visible line on every keystroke; `ensureTokensVisible` can continue
        // from the first invalid line instead.
        if (self.view_lines.projections.items.len != self.model.getLineCount()) {
            try self.view_lines.rebuildAll();
            self.tokens_need_refresh = true;
        }
        self.resetCursorViewState() catch {};
        try self.refreshLayout();
    }

    fn executeTypeResult(self: *Editor, result: EditOperationResult) !void {
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        return self.executeTypeResultFor(result, selections);
    }

    fn executeTypeResultFor(self: *Editor, result: EditOperationResult, before_selections: []const Selection) !void {
        if (result.shouldPushStackElementBefore) self.pushUndoStop();
        try self.executeReplaceCommandsFor(before_selections, result.commands);
        if (result.shouldPushStackElementAfter) self.pushUndoStop();
        self.prev_edit_operation_type = result.type;
    }

    pub fn insertText(self: *Editor, text: []const u8) !void {
        const previous_source = self.cursor_event_source;
        if (previous_source == null) self.cursor_event_source = "api";
        defer self.cursor_event_source = previous_source;
        if (self.read_only) return error.ReadOnly;
        if (text.len == 0) return;
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        var result = try TypeWithoutInterceptorsOperation.getEdits(self.allocator, self.prev_edit_operation_type, selections, text);
        defer result.deinit(self.allocator);
        try self.executeTypeResult(result);
    }

    pub fn pasteText(self: *Editor, text: []const u8) !void {
        const previous_source = self.cursor_event_source;
        const previous_reason = self.cursor_event_reason;
        self.cursor_event_source = "paste";
        self.cursor_event_reason = .Paste;
        defer {
            self.cursor_event_source = previous_source;
            self.cursor_event_reason = previous_reason;
        }
        try self.insertText(text);
    }

    pub fn typeCharacter(self: *Editor, text: []const u8) !void {
        if (self.read_only) return error.ReadOnly;
        if (text.len == 0) return;
        const previous_source = self.cursor_event_source;
        self.cursor_event_source = "keyboard";
        defer self.cursor_event_source = previous_source;
        self.on_will_type.fire(text) catch {};
        try self.typeCharacterImpl(text);
        self.on_did_type.fire(text) catch {};
    }

    fn typeCharacterImpl(self: *Editor, text: []const u8) !void {
        if (self.read_only) return error.ReadOnly;
        if (text.len == 0) return;
        // `default:type` from the extension host sends a newline as text rather
        // than going through the key handler; keep Enter's auto-indent for it.
        if (std.mem.eql(u8, text, "\n")) {
            try self.newline();
            return;
        }
        self.refreshAutoIndent();

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        self.ensureLinesTokenized(selections);

        var auto_indent_result = try AutoIndentOperation.getEdits(
            self.allocator,
            &self.cursor_config,
            self.model,
            selections,
            text,
            false,
        );
        if (auto_indent_result) |*result| {
            defer result.deinit(self.allocator);
            try self.executeTypeResult(result.*);
            return;
        }

        if (try auto_closing.shouldOvertypeClose(&self.cursor_config, self.model, selections, text)) {
            try self.moveRight(false);
            return;
        }

        if (try auto_closing.findAutoClosingPair(&self.cursor_config, self.model, selections, text, false)) |pair| {
            const commands = try self.allocator.alloc(auto_closing.TypeWithAutoClosingCommand, selections.len);
            defer self.allocator.free(commands);
            const interfaces = try self.allocator.alloc(?ICommand, selections.len);
            defer self.allocator.free(interfaces);

            for (selections, 0..) |selection, i| {
                commands[i] = auto_closing.TypeWithAutoClosingCommand.init(
                    self.allocator,
                    selection,
                    pair.open,
                    pair.close,
                    true,
                );
                interfaces[i] = commands[i].interface();
            }
            try self.executeCommands(interfaces);
            return;
        }

        try self.insertText(text);
    }

    pub fn newline(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        self.refreshAutoIndent();

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        var result = (try EnterOperation.getEdits(
            self.allocator,
            &self.cursor_config,
            self.model,
            selections,
            "\n",
            false,
        )) orelse return;
        defer result.deinit(self.allocator);
        try self.executeTypeResultFor(result, selections);
        self.pushUndoStop();
    }

    /// `editor.action.insertLineAfter`: run Enter at each cursor's line end.
    pub fn insertLineAfter(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        return self.insertLineAtEdge(false);
    }

    /// `editor.action.insertLineBefore`: run Enter at each cursor's line start.
    pub fn insertLineBefore(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        return self.insertLineAtEdge(true);
    }

    fn insertLineAtEdge(self: *Editor, before: bool) !void {
        self.closeTypingGroup();
        self.refreshAutoIndent();

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        self.ensureLinesTokenized(selections);
        const targets = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(targets);
        for (selections, 0..) |selection, index| {
            const line = if (before) selection.startLineNumber else selection.endLineNumber;
            const column = if (before) 1 else self.model.getLineMaxColumn(line);
            targets[index] = Selection.init(line, column, line, column);
        }

        var result = (try EnterOperation.getEdits(
            self.allocator,
            &self.cursor_config,
            self.model,
            targets,
            "\n",
            false,
        )) orelse return;
        defer result.deinit(self.allocator);
        try self.executeTypeResultFor(result, selections);
        self.pushUndoStop();
    }

    pub fn insertTab(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        if (!self.modelSelection().isEmpty()) {
            try self.indentLines();
            return;
        }
        const position = self.modelCursorPosition();
        const line = try self.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const visible = CursorColumns.visibleColumnFromColumn(line.items, position.column, self.cursor_config.tabSize);
        const next = CursorColumns.nextRenderTabStop(visible, self.cursor_config.tabSize);
        const count = next - visible;
        if (self.cursor_config.insertSpaces) {
            var spaces: [64]u8 = undefined;
            const n = @min(count, spaces.len);
            @memset(spaces[0..n], ' ');
            try self.insertText(spaces[0..n]);
        } else {
            try self.insertText("\t");
        }
    }

    pub fn outdent(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        if (!self.modelSelection().isEmpty()) {
            try self.outdentLines();
            return;
        }
        self.closeTypingGroup();
        const position = self.modelCursorPosition();
        const line = try self.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const first_non_ws = strings.firstNonWhitespaceIndex(line.items) orelse 0;
        if (first_non_ws == 0) return;

        var new_len = first_non_ws;
        if (line.items[new_len - 1] == '\t') {
            new_len -= 1;
        } else {
            var removed: usize = 0;
            while (new_len > 0 and removed < self.cursor_config.indentSize and line.items[new_len - 1] == ' ') {
                new_len -= 1;
                removed += 1;
            }
        }
        if (new_len == first_non_ws) return;

        const command = cursorCommon.ReplaceCommand.init(
            Range.init(position.lineNumber, 1, position.lineNumber, first_non_ws + 1),
            line.items[0..new_len],
        );
        try self.executeReplaceCommands(&[_]?cursorCommon.ReplaceCommand{command});
    }

    fn refreshCursorOptions(self: *Editor) void {
        const options = self.model.getOptions();
        self.cursor_config.tabSize = options.tabSize;
        self.cursor_config.indentSize = options.indentSize;
        self.cursor_config.insertSpaces = options.insertSpaces;
        self.refreshAutoIndent();
    }

    /// Full auto-indent needs language indentation rules. The build embeds the
    /// upstream language configurations for the bundled VS Code languages, so
    /// languages with `indentationRules` use the full strategy; languages
    /// without a ported configuration (for example Zig) keep their previous
    /// keep-indentation behavior instead of guessing at rules.
    fn refreshAutoIndent(self: *Editor) void {
        const has_rules = if (self.language_service.getLanguageConfiguration(self.languageId())) |config|
            config.indentationRules != null
        else
            false;
        self.cursor_config.autoIndent = if (has_rules) .Full else .Keep;
    }

    fn applyEditOperations(self: *Editor, operations: []const ISingleEditOperation) !void {
        const before = try self.getSelectionsCopy();
        defer self.allocator.free(before);

        var identified = ArrayList(IdentifiedSingleEditOperation).init(self.allocator);
        defer identified.deinit();
        for (operations) |operation| {
            try identified.append(IdentifiedSingleEditOperation.init(
                operation.range,
                if (operation.text) |text| String.initBorrowed(text) else null,
            ));
        }

        _ = try self.model.pushEditOperations(before, identified.items, null, null);
        try self.afterEdit();
        try self.updateSelections(before);
        self.ensureCursorVisible();
    }

    fn indentLinesImpl(self: *Editor, is_unshift: bool) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const opts = IShiftCommandOpts{
            .isUnshift = is_unshift,
            .tabSize = self.cursor_config.tabSize,
            .indentSize = self.cursor_config.indentSize,
            .insertSpaces = self.cursor_config.insertSpaces,
            .useTabStops = false,
            .autoIndent = .None,
        };

        const commands = try self.allocator.alloc(ShiftCommand, selections.len);
        defer self.allocator.free(commands);
        const interfaces = try self.allocator.alloc(?ICommand, selections.len);
        defer self.allocator.free(interfaces);

        for (selections, 0..) |selection, i| {
            commands[i] = ShiftCommand.init(self.allocator, selection, opts, self.language_config_service.interface());
            interfaces[i] = commands[i].interface();
        }

        try self.executeCommands(interfaces);
    }

    pub fn indentLines(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        try self.indentLinesImpl(false);
    }

    pub fn outdentLines(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        try self.indentLinesImpl(true);
    }

    pub fn reindentLines(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        var edits = try indentation_commands.reindentLines(
            arena_state.allocator(),
            self.model,
            self.language_config_service.interface(),
        );
        defer edits.deinit();
        if (edits.items.len == 0) return;

        try self.applyEditOperations(edits.items);
        self.pushUndoStop();
    }

    pub fn reindentSelectedLines(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        var edits = try indentation_commands.reindentSelectedLines(
            arena_state.allocator(),
            self.model,
            self.language_config_service.interface(),
            selections,
        );
        defer edits.deinit();
        if (edits.items.len == 0) return;

        try self.applyEditOperations(edits.items);
        self.pushUndoStop();
    }

    pub fn indentationToSpaces(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selection = self.modelSelection();
        var command = IndentationToSpacesCommand.init(self.allocator, selection, self.cursor_config.tabSize);
        try self.executeCommands(&[_]?ICommand{command.interface()});
        self.model.updateOptions(.{
            .tabSize = null,
            .indentSize = null,
            .insertSpaces = true,
            .trimAutoWhitespace = null,
            .bracketColorizationOptions = null,
        });
        self.refreshCursorOptions();
    }

    pub fn indentationToTabs(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selection = self.modelSelection();
        var command = IndentationToTabsCommand.init(self.allocator, selection, self.cursor_config.tabSize);
        try self.executeCommands(&[_]?ICommand{command.interface()});
        self.model.updateOptions(.{
            .tabSize = null,
            .indentSize = null,
            .insertSpaces = false,
            .trimAutoWhitespace = null,
            .bracketColorizationOptions = null,
        });
        self.refreshCursorOptions();
    }

    pub fn detectIndentation(self: *Editor) void {
        if (self.read_only) return;
        indentation_commands.detectIndentation(self.model);
        self.refreshCursorOptions();
        self.ensureCursorVisible();
    }

    /// Applies the configured indentation and bracket-colorization settings to
    /// the model and keeps the cursor/wrapping configuration in sync. Returns
    /// true when a model option changed.
    pub fn applyEditorSettings(
        self: *Editor,
        reader: terminal_editor_config.Reader,
        language_id: ?[]const u8,
        resource: ?[]const u8,
    ) !bool {
        const value = terminal_editor_config.readInt(reader, "editor.maxTokenizationLineLength", language_id, resource) orelse @as(i64, @import("../../../../workbench/services/textMate/browser/tokenizationSupport/tokenizationSupportWithLineLimit.zig").default_limit);
        const limit: usize = @intCast(@max(value, 0));
        const changed = self.model.max_tokenization_line_length != limit;
        if (changed) {
            self.model.max_tokenization_line_length = limit;
            self.model.tokenization().resetTokenization();
        }
        if (!terminal_editor_config.applyModelSettings(self.model, reader, language_id, resource)) return changed;
        self.refreshCursorOptions();
        _ = try self.view_lines.setTabSize(self.model.getOptions().tabSize);
        try self.refreshLayout();
        self.ensureCursorVisible();
        return true;
    }

    pub fn changeIndentation(self: *Editor, tab_size: usize, insert_spaces: bool, display_size_only: bool) void {
        if (self.read_only) return;
        indentation_commands.changeIndentation(self.model, tab_size, insert_spaces, display_size_only);
        self.refreshCursorOptions();
        self.ensureCursorVisible();
    }

    pub fn deleteLeft(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.cursor_event_source = "deleteLeft";
        defer self.cursor_event_source = null;
        if (try auto_closing.autoClosingDeleteRange(&self.cursor_config, self.model, self.modelSelection())) |range| {
            self.closeTypingGroup();
            const command = cursorCommon.ReplaceCommand.init(range, "");
            try self.executeReplaceCommands(&[_]?cursorCommon.ReplaceCommand{command});
            self.prev_edit_operation_type = .DeletingLeft;
            return;
        }

        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        var result = try DeleteOperations.deleteLeft(
            self.allocator,
            self.prev_edit_operation_type,
            &self.cursor_config,
            self.model_adapter.interface(),
            selections,
        );
        defer result.deinit(self.allocator);
        if (result.shouldPushStackElementBefore) self.pushUndoStop();
        try self.executeReplaceCommands(result.commands);
        self.prev_edit_operation_type = .DeletingLeft;
    }

    pub fn deleteRight(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        var result = try DeleteOperations.deleteRight(
            self.allocator,
            self.prev_edit_operation_type,
            &self.cursor_config,
            self.model_adapter.interface(),
            selections,
        );
        defer result.deinit(self.allocator);
        if (result.shouldPushStackElementBefore) self.pushUndoStop();
        try self.executeReplaceCommands(result.commands);
        self.prev_edit_operation_type = .DeletingRight;
    }

    pub fn undo(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.model.pushStackElement();
        self.pending_selection_count = 0;
        self.model.undo() catch |err| {
            self.recoverWrapping();
            return err;
        };
        try self.afterUndoRedo(.Undo);
    }

    pub fn redo(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.model.pushStackElement();
        self.pending_selection_count = 0;
        self.model.redo() catch |err| {
            self.recoverWrapping();
            return err;
        };
        try self.afterUndoRedo(.Redo);
    }

    fn afterUndoRedo(self: *Editor, reason: CursorChangeReason) !void {
        self.tokens_need_refresh = true;
        // Undo/redo can restore text that the incremental token store only
        // knows heuristically. Refresh the visible range before the next paint
        // so token colors cannot lag behind the restored buffer.
        self.ensureTokensVisible();
        if (self.view_lines.projections.items.len != self.model.getLineCount()) {
            try self.view_lines.rebuildAll();
        }
        if (self.pending_selection_count > 0) {
            try self.updateSelectionsWithReason(self.pending_selection[0..self.pending_selection_count], reason);
            self.pending_selection_count = 0;
        } else {
            try self.resetCursorViewState();
        }
        try self.refreshLayout();
        self.ensureCursorVisible();
    }

    /// Applies a cursor selection and emits upstream's view event when the
    /// state actually changed. `CursorCollection` has no event surface of its
    /// own; the editor is the terminal replacement for `CursorsController`,
    /// which emits `ViewCursorStateChangedEvent` after `setStates`.
    fn updateSelections(self: *Editor, selections: []const Selection) !void {
        try self.updateSelectionsWithReason(selections, self.cursor_event_reason orelse .NotSet);
    }

    fn updateSelectionsFromApi(self: *Editor, selections: []const Selection) !void {
        // CodeEditorWidget.setSelections defaults to source "api" and
        // CursorChangeReason.NotSet; explicit cursor commands use their own
        // source and reason. Preserve a caller-specified navigation source.
        if (self.cursor_selection_source == .USER) self.cursor_selection_source = .PROGRAMMATIC;
        defer self.cursor_selection_source = .USER;
        try self.updateSelectionsWithReason(selections, .NotSet);
    }

    fn updateSelectionsWithReason(self: *Editor, selections: []const Selection, reason: CursorChangeReason) !void {
        try self.cursorsRef().setSelections(self.allocator, selections);
        self.emitCursorStateChanged(reason);
    }

    fn selectionsEqual(a: []const Selection, b: []const Selection) bool {
        if (a.len != b.len) return false;
        for (a, b) |*left, *right| {
            if (!Selection.equalsSelection(left, right)) return false;
        }
        return true;
    }

    fn emitCursorStateChanged(self: *Editor, reason: CursorChangeReason) void {
        self.emitCursorStateChangedIfNeeded(reason, false);
    }

    fn emitCursorStateChangedForce(self: *Editor, reason: CursorChangeReason) void {
        self.emitCursorStateChangedIfNeeded(reason, true);
    }

    fn emitCursorStateChangedIfNeeded(self: *Editor, reason: CursorChangeReason, force: bool) void {
        const view = self.getViewSelections() catch return;
        const model = self.getModelSelections() catch {
            self.allocator.free(view);
            return;
        };
        const model_changed = !selectionsEqual(self.cursor_event_model_selections, model);
        const view_changed = !selectionsEqual(self.cursor_event_view_selections, view);
        const model_version = self.model.getVersionId();
        if (!force and !model_changed and !view_changed) {
            self.allocator.free(view);
            self.allocator.free(model);
            return;
        }
        const event_source = self.cursor_event_source orelse switch (self.cursor_selection_source) {
            .PROGRAMMATIC => "api",
            .NAVIGATION => "navigation",
            .JUMP => "jump",
            .USER => "keyboard",
        };
        const selection_source = self.cursor_selection_source;
        self.cursor_selection_source = .USER;

        // CodeEditorWidget fires the public position and selection events
        // from a model CursorStateChanged event. View remapping/attachment is
        // not a model move. Content-only changes arrive on the separate
        // model-content event.
        const public_changed = !force and model_changed and model.len > 0;
        const position: ?Position = if (public_changed) model[0].getPosition() else null;
        const secondary = if (public_changed and self.on_did_change_cursor_position.hasListeners()) self.allocator.alloc(Position, model.len - 1) catch null else null;
        defer if (secondary) |values| self.allocator.free(values);
        if (secondary) |values| {
            for (model[1..], values) |selection, *value| value.* = selection.getPosition();
        }
        const selection_copy = if (public_changed and self.on_did_change_cursor_selection.hasListeners()) self.allocator.dupe(Selection, model) catch null else null;
        defer if (selection_copy) |values| self.allocator.free(values);
        const old_model = self.cursor_event_model_selections;
        const old_version = self.cursor_event_model_version;
        defer if (old_model.len > 0) self.allocator.free(old_model);
        if (self.cursor_event_view_selections.len > 0) self.allocator.free(self.cursor_event_view_selections);
        self.cursor_event_view_selections = view;
        self.cursor_event_model_selections = model;
        if (public_changed or self.cursor_event_model_version == 0) self.cursor_event_model_version = model_version;
        if (force or view_changed or model_changed) self.emitViewEvent(.{ .ViewCursorStateChanged = .{
            .selections = view,
            .modelSelections = model,
            .reason = reason,
            .source = selection_source,
        } });
        if (position) |primary| self.on_did_change_cursor_position.fire(.{
            .position = primary,
            .secondaryPositions = secondary orelse &.{},
            .reason = reason,
            .source = event_source,
        }) catch {};
        if (selection_copy) |selections| self.on_did_change_cursor_selection.fire(.{
            .selection = selections[0],
            .secondarySelections = selections[1..],
            .modelVersionId = model_version,
            .oldSelections = if (old_model.len == 0) null else old_model,
            .oldModelVersionId = old_version,
            .reason = reason,
            .source = event_source,
        }) catch {};
    }

    pub fn getModelSelections(self: *Editor) ![]Selection {
        return self.cursorsRef().getSelections(self.allocator);
    }

    fn getSelectionsCopy(self: *Editor) ![]Selection {
        return self.getModelSelections();
    }

    /// Model selections, allocated with the editor allocator. The caller owns
    /// the returned slice.
    pub fn getSelections(self: *Editor) ![]Selection {
        return self.cursorsRef().getSelections(self.allocator);
    }

    /// The selections in view coordinates, matching the selections upstream
    /// dispatches to view parts.
    pub fn getViewSelections(self: *Editor) ![]Selection {
        return self.cursorsRef().getViewSelections(self.allocator);
    }

    fn applyCommandResult(self: *Editor, after: ?[]Selection) !void {
        const selections = after orelse return;
        defer self.allocator.free(selections);

        try self.afterEdit();
        try self.updateSelections(selections);
        self.ensureCursorVisible();
        self.pushUndoStop();
    }

    fn executeCommands(self: *Editor, commands: []const ?ICommand) !void {
        const before = try self.getSelectionsCopy();
        defer self.allocator.free(before);

        const after = try command_runner.executeCommands(self.allocator, self.model, commands, before);
        try self.applyCommandResult(after);
    }

    pub fn moveLines(self: *Editor, down: bool) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.moveLines(self.allocator, self.model, selections, down);
        try self.applyCommandResult(after);
    }

    pub fn copyLines(self: *Editor, down: bool) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.copyLines(self.allocator, self.model, selections, down);
        try self.applyCommandResult(after);
    }

    pub fn sortLines(self: *Editor, descending: bool) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.sortLines(self.allocator, self.model, selections, descending);
        try self.applyCommandResult(after);
    }

    pub fn duplicateSelection(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.duplicateSelection(self.allocator, self.model, selections);
        try self.applyCommandResult(after);
    }

    pub fn trimTrailingWhitespace(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.trimTrailingWhitespace(self.allocator, self.model, selections);
        try self.applyCommandResult(after);
    }

    pub fn setCursorPosition(self: *Editor, position: Position) !void {
        self.closeTypingGroup();
        try self.updateSelectionsFromApi(&[_]Selection{Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)});
        self.ensureCursorVisible();
    }

    /// Replaces the editor selection with one range. Used by find to put the
    /// selection on a match.
    pub fn setSelection(self: *Editor, range: Range) !void {
        self.closeTypingGroup();
        try self.updateSelectionsFromApi(&[_]Selection{
            Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn),
        });
        self.ensureCursorVisible();
    }

    pub fn setSelections(self: *Editor, selections: []const Selection) !void {
        self.closeTypingGroup();
        try self.updateSelectionsFromApi(selections);
        self.ensureCursorVisible();
    }

    /// Mouse moveTo/moveToSelect begins an explicit cursor operation. Motion
    /// after the press reuses updateDragSelection without another undo stop.
    pub fn setMouseSelection(self: *Editor, anchor: Position, position: Position) !void {
        self.closeTypingGroup();
        try self.updateDragSelection(anchor, position);
    }

    /// Updates the selection during a mouse drag. The press already closed the
    /// typing group, so motion must not start a new undo stop per report.
    pub fn updateDragSelection(self: *Editor, anchor: Position, position: Position) !void {
        self.cursor_event_source = "mouse";
        defer self.cursor_event_source = null;
        try self.updateSelectionsWithReason(&[_]Selection{
            Selection.init(anchor.lineNumber, anchor.column, position.lineNumber, position.column),
        }, .Explicit);
        self.ensureCursorVisible();
    }

    /// Replaces one range through the command runner (no auto-closing or
    /// typing interceptors). The cursor lands at the end of the replaced text.
    pub fn replaceRange(self: *Editor, range: Range, text: []const u8) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        var command = ReplaceCommandCommand.init(range, text, false);
        try self.executeCommands(&[_]?ICommand{command.interface()});
    }

    /// Applies several edits atomically and places one cursor at each supplied
    /// position. Used by completion acceptance for additional text edits and
    /// multi-cursor inserts.
    pub fn applyTextEdits(self: *Editor, edits: []const TextEdit, cursors: []const Position) !void {
        if (self.read_only) return error.ReadOnly;
        if (edits.len == 0) {
            if (cursors.len > 0) {
                const selections = try self.allocator.alloc(Selection, cursors.len);
                defer self.allocator.free(selections);
                for (cursors, 0..) |position, index| {
                    selections[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
                }
                try self.updateSelections(selections);
                self.ensureCursorVisible();
            }
            return;
        }

        const applied = try self.applyTextEditsWithPositions(edits);
        defer self.allocator.free(applied);

        if (cursors.len > 0) {
            const selections = try self.allocator.alloc(Selection, cursors.len);
            defer self.allocator.free(selections);
            for (cursors, 0..) |position, index| {
                selections[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
            }
            try self.updateSelections(selections);
        }
        self.ensureCursorVisible();
    }

    /// Applies a batch of edits and returns where each edit landed. The
    /// returned positions are computed against the fully applied document,
    /// mirroring the `textChange.newPosition` values the upstream snippet
    /// session receives from `executeEdits`.
    pub fn applyTextEditsWithPositions(self: *Editor, edits: []const TextEdit) ![]AppliedTextEdit {
        if (self.read_only) return error.ReadOnly;
        const result = try self.allocator.alloc(AppliedTextEdit, edits.len);
        errdefer self.allocator.free(result);
        if (edits.len == 0) return result;

        const order = try self.allocator.alloc(usize, edits.len);
        defer self.allocator.free(order);
        for (order, 0..) |*slot, index| slot.* = index;
        const SortContext = struct {
            editor: *Editor,
            edits: []const TextEdit,

            pub fn lessThan(context: @This(), a: usize, b: usize) bool {
                const a_start = context.editor.model.getOffsetAt(context.edits[a].range.startPosition());
                const b_start = context.editor.model.getOffsetAt(context.edits[b].range.startPosition());
                return a_start < b_start;
            }
        };
        std.mem.sort(usize, order, SortContext{ .editor = self, .edits = edits }, SortContext.lessThan);

        const offsets = try self.allocator.alloc(struct { start: usize, end: usize }, edits.len);
        defer self.allocator.free(offsets);
        var delta: isize = 0;
        for (order) |index| {
            const edit = edits[index];
            const start = self.model.getOffsetAt(edit.range.startPosition());
            const end = self.model.getOffsetAt(edit.range.endPosition());
            const adjusted: isize = @as(isize, @intCast(start)) + delta;
            const adjusted_start: usize = if (adjusted < 0) 0 else @intCast(adjusted);
            offsets[index] = .{ .start = adjusted_start, .end = adjusted_start + edit.text.len };
            delta += @as(isize, @intCast(edit.text.len)) - @as(isize, @intCast(end - start));
        }

        self.closeTypingGroup();
        const before = try self.getSelectionsCopy();
        defer self.allocator.free(before);

        var operations = ArrayList(IdentifiedSingleEditOperation).init(self.allocator);
        defer operations.deinit();
        for (edits) |edit| {
            try operations.append(IdentifiedSingleEditOperation.init(
                edit.range,
                if (edit.text.len == 0) null else String.initBorrowed(edit.text),
            ));
        }

        _ = try self.model.pushEditOperations(before, operations.items, null, null);
        try self.afterEdit();
        for (offsets, 0..) |offset, index| {
            result[index] = .{
                .start = self.model.getPositionAt(offset.start),
                .end = self.model.getPositionAt(offset.end),
            };
        }
        self.ensureCursorVisible();
        return result;
    }

    /// Runs a command against the model and applies its cursor state.
    pub fn executeCommand(self: *Editor, command: ICommand) !void {
        if (self.read_only) return error.ReadOnly;
        self.closeTypingGroup();
        try self.executeCommands(&[_]?ICommand{command});
    }

    fn runExpandLineSelectionAction(context: *anyopaque) anyerror!void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        return editor.expandLineSelection();
    }

    pub fn expandLineSelectionAction(self: *Editor) line_selection.ExpandLineSelectionAction {
        return line_selection.ExpandLineSelectionAction.init(self, runExpandLineSelectionAction);
    }

    pub fn expandLineSelection(self: *Editor) !void {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);

        const states = try line_selection.expandLineSelection(self.allocator, self.view_lines.interface(), cursors);
        defer self.allocator.free(states);

        try self.cursorsRef().setStates(states);
        self.emitCursorStateChanged(.Explicit);
        self.ensureCursorVisible();
    }

    /// Expands or shrinks every selection through the ported smart-select
    /// controller. Upstream drives this from `editor.action.smartSelect.*`.
    pub fn growSelection(self: *Editor, forward: bool) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const updated = (try self.smart_select.run(self.model, selections, forward)) orelse return;
        defer self.allocator.free(updated);
        try self.updateSelectionsWithReason(updated, .Explicit);
        self.ensureCursorVisible();
    }

    fn runSmartSelectExpandAction(context: *anyopaque) anyerror!void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        return editor.growSelection(true);
    }

    fn runSmartSelectShrinkAction(context: *anyopaque) anyerror!void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        return editor.growSelection(false);
    }

    pub fn smartSelectExpandAction(self: *Editor) smart_select.ExpandSelectionAction {
        return smart_select.ExpandSelectionAction.init(self, runSmartSelectExpandAction);
    }

    pub fn smartSelectShrinkAction(self: *Editor) smart_select.ShrinkSelectionAction {
        return smart_select.ShrinkSelectionAction.init(self, runSmartSelectShrinkAction);
    }

    /// Replaces the value at the primary selection with the previous/next value
    /// in its value set. Kills secondary cursors first, matching upstream
    /// `executeCommand` semantics.
    pub fn inPlaceReplace(self: *Editor, up: bool) !bool {
        self.closeTypingGroup();
        const selection = self.modelSelection();
        var result = (try in_place_replace.compute(self.allocator, self.model, selection, up)) orelse return false;
        defer result.deinit(self.allocator);

        try self.cursorsRef().killSecondaryCursors();
        const primary = self.modelSelection();
        const before = [_]Selection{primary};
        var command = InPlaceReplaceCommand.init(result.range, result.selection, result.value);
        const after = try command_runner.executeCommands(
            self.allocator,
            self.model,
            &[_]?ICommand{command.interface()},
            &before,
        );
        try self.applyCommandResult(after);
        self.setInPlaceReplaceDecoration(result.highlight_range) catch {};
        self.in_place_replace_task.schedule(time_compat.milliTimestamp() + 350);
        return true;
    }

    fn runInPlaceReplaceUpAction(context: *anyopaque) anyerror!void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        _ = try editor.inPlaceReplace(false);
    }

    fn runInPlaceReplaceDownAction(context: *anyopaque) anyerror!void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        _ = try editor.inPlaceReplace(true);
    }

    pub fn inPlaceReplaceUpAction(self: *Editor) in_place_replace.InPlaceReplaceUpAction {
        return in_place_replace.InPlaceReplaceUpAction.init(self, runInPlaceReplaceUpAction);
    }

    pub fn inPlaceReplaceDownAction(self: *Editor) in_place_replace.InPlaceReplaceDownAction {
        return in_place_replace.InPlaceReplaceDownAction.init(self, runInPlaceReplaceDownAction);
    }

    fn setInPlaceReplaceDecoration(self: *Editor, range: Range) !void {
        try self.model.removeAllDecorationsWithOwnerId(5);
        const decorations = [_]ModelDeltaDecoration{.{
            .range = range,
            .options = &value_set_replacement_options,
        }};
        const ids = try self.model.deltaDecorations(&.{}, &decorations, 5);
        self.allocator.free(ids);
    }

    fn clearInPlaceReplaceDecoration(self: *Editor) void {
        self.model.removeAllDecorationsWithOwnerId(5) catch {};
    }

    fn onInPlaceReplaceDeadline(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx));
        self.clearInPlaceReplaceDecoration();
        return true;
    }

    /// Recomputes the bracket highlights for the current cursors. `has_focus`
    /// mirrors upstream's `hasWidgetFocus`: a focused widget hides the hints.
    pub fn updateBracketMatches(self: *Editor, has_focus: bool) ![]const bracket_matching.BracketsData {
        self.bracket_matching.has_focus = has_focus;
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        return self.bracket_matching.updateBrackets(selections);
    }

    pub fn bracketMatchGeneration(self: *const Editor) usize {
        return self.bracket_matching.matchGeneration();
    }

    pub fn decorationGeneration(self: *const Editor) usize {
        return self.decoration_generation;
    }

    pub fn jumpToBracket(self: *Editor) !void {
        const selection = self.modelSelection();
        const target = self.bracket_matching.jumpToBracket(selection) orelse return;
        try self.updateSelectionsWithReason(&[_]Selection{target}, .Explicit);
        self.ensureCursorVisible();
    }

    pub fn selectToBracket(self: *Editor, select_brackets: bool) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const selected = try self.bracket_matching.selectToBracket(selections, select_brackets) orelse return;
        defer self.allocator.free(selected);

        try self.updateSelectionsWithReason(selected, .Explicit);
        self.ensureCursorVisible();
    }

    pub fn removeBrackets(self: *Editor) !void {
        const selection = self.modelSelection();
        const pair = self.bracket_matching.removeBracketsForSelection(selection) orelse return;

        self.closeTypingGroup();
        const commands = [_]?cursorCommon.ReplaceCommand{
            cursorCommon.ReplaceCommand.init(pair[0], ""),
            cursorCommon.ReplaceCommand.init(pair[1], ""),
        };
        try self.executeReplaceCommands(&commands);
        try self.cursorsRef().killSecondaryCursors();
        self.emitCursorStateChanged(.NotSet);
        self.pushUndoStop();
    }

    pub fn toggleLineComment(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const rule = language.commentRuleFor(self.model.getLanguageId()) orelse {
            self.setMessage("No comment configuration for {s}", .{self.model.getLanguageId()});
            return;
        };
        if (rule.lineComment == null and rule.blockComment == null) {
            self.setMessage("Comments are not supported for {s}", .{self.model.getLanguageId()});
            return;
        }

        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const commands = try self.allocator.alloc(LineCommentCommand, selections.len);
        defer self.allocator.free(commands);
        const interfaces = try self.allocator.alloc(?ICommand, selections.len);
        defer self.allocator.free(interfaces);

        for (selections, 0..) |selection, i| {
            commands[i] = LineCommentCommand.init(
                self.allocator,
                self.language_service,
                selection,
                self.cursor_config.indentSize,
                .Toggle,
                true,
                true,
                false,
            );
            interfaces[i] = commands[i].interface();
        }

        try self.executeCommands(interfaces);
    }

    pub fn toggleBlockComment(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const rule = language.commentRuleFor(self.model.getLanguageId()) orelse {
            self.setMessage("No comment configuration for {s}", .{self.model.getLanguageId()});
            return;
        };
        if (rule.blockComment == null) {
            self.setMessage("Block comments are not supported for {s}", .{self.model.getLanguageId()});
            return;
        }

        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const commands = try self.allocator.alloc(BlockCommentCommand, selections.len);
        defer self.allocator.free(commands);
        const interfaces = try self.allocator.alloc(?ICommand, selections.len);
        defer self.allocator.free(interfaces);

        for (selections, 0..) |selection, i| {
            commands[i] = BlockCommentCommand.init(self.allocator, selection, true, self.language_service);
            interfaces[i] = commands[i].interface();
        }

        try self.executeCommands(interfaces);
    }

    pub fn insertFinalNewLine(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const selection = self.modelSelection();
        self.closeTypingGroup();

        var command = InsertFinalNewLineCommand.init(selection);
        try self.executeCommands(&[_]?ICommand{command.interface()});
    }

    /// Applies a reloaded file on the TUI thread. Replacement starts a new edit
    /// history, like VS Code's `_setValueFromTextBuffer` clearing the command
    /// manager; the caller keeps ownership of the decoded text.
    pub fn applyReloadedContent(self: *Editor, text: []const u8, encoding: encoding_mod.Encoding) !void {
        if (self.read_only) return error.ReadOnly;
        self.setEncoding(encoding);
        try self.replaceGeneratedContents(text, true);
    }

    /// Replaces the text of a generated editor, such as the Search Editor.
    /// The producer owns the text and updates the model independently of
    /// the text editor's read-only user input mode.
    pub fn replaceGeneratedContents(self: *Editor, text: []const u8, reset_cursor: bool) !void {
        const position = if (reset_cursor) Position.init(1, 1) else self.modelCursorPosition();
        var current = try self.model.getValue(.TextDefined, true);
        defer current.deinit();
        if (std.mem.eql(u8, current.items, text)) return;

        const last_line = self.model.getLineCount();
        const last_column = self.model.getLineMaxColumn(last_line);
        var operations = [_]IdentifiedSingleEditOperation{.init(
            Range.init(1, 1, last_line, last_column),
            if (text.len == 0) null else String.initBorrowed(text),
        )};
        _ = try self.model.applyEdits(&operations, false);
        self.model.clearUndoRedo();
        self.document.saved_version = self.model.getAlternativeVersionId();
        self.clearConflict();
        self.document.refreshDirtyState();
        try self.setCursorPosition(self.model.validatePosition(position));
    }

    /// Reloads the editor content from disk (used for external file changes).
    /// Synchronous wrapper for tests/commands; the watcher path uses
    /// the text-file service on the async Io and applies the result here.
    pub fn reloadFromDisk(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(self.allocator, self.io);
        defer files.deinit();
        var service = text_files.TextFileService.init(self.allocator, &files);
        defer service.deinit();
        var content = try service.readWithEncoding(self.path, self.allocator);
        defer content.deinit(self.allocator);
        try self.applyReloadedContent(content.text, content.encoding);
    }

    /// Marks an external-change conflict (the file changed while dirty).
    pub fn addWorkingCopyDirtyListener(self: *Editor, listener: ChangeListener) void {
        self.working_copy_dirty_listeners.append(listener) catch {};
    }

    pub fn removeWorkingCopyDirtyListener(self: *Editor, listener: ChangeListener) void {
        removeChangeListener(&self.working_copy_dirty_listeners, listener);
    }

    pub fn addWorkingCopyContentListener(self: *Editor, listener: ChangeListener) void {
        self.working_copy_content_listeners.append(listener) catch {};
    }

    pub fn removeWorkingCopyContentListener(self: *Editor, listener: ChangeListener) void {
        removeChangeListener(&self.working_copy_content_listeners, listener);
    }

    pub fn addWorkingCopySaveListener(self: *Editor, listener: ChangeListener) void {
        self.working_copy_save_listeners.append(listener) catch {};
    }

    pub fn removeWorkingCopySaveListener(self: *Editor, listener: ChangeListener) void {
        removeChangeListener(&self.working_copy_save_listeners, listener);
    }

    fn removeChangeListener(list: *std.array_list.Managed(ChangeListener), listener: ChangeListener) void {
        var index: usize = 0;
        while (index < list.items.len) : (index += 1) {
            const current = list.items[index];
            if (current.context == listener.context and current.callback == listener.callback) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    pub fn markConflict(self: *Editor) void {
        self.document.conflict = true;
        for (self.document.editors.items) |editor| {
            editor.setMessage("Conflict: file changed on disk", .{});
        }
    }

    pub fn hasConflict(self: *const Editor) bool {
        return self.document.conflict;
    }

    pub fn clearConflict(self: *Editor) void {
        self.document.conflict = false;
        for (self.document.editors.items) |editor| {
            if (std.mem.startsWith(u8, editor.message(), "Conflict:")) editor.clearMessage();
        }
    }

    pub fn save(self: *Editor) !void {
        if (self.read_only) return error.ReadOnly;
        const value = try self.model.getValue(.TextDefined, true);
        defer value.deinit();

        const path = self.document.path;
        const cwd = Io.Dir.cwd();
        var exists = true;
        const maybe_file = cwd.openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                exists = false;
                break :blk null;
            },
            else => return err,
        };
        if (maybe_file) |file| file.close(self.io);

        var atomic = try cwd.createFileAtomic(self.io, path, .{ .replace = exists });
        defer atomic.deinit(self.io);
        const encoded = try encoding_mod.encode(self.allocator, value.items, self.document.encoding);
        defer self.allocator.free(encoded);
        try atomic.file.writeStreamingAll(self.io, encoded);
        if (exists) {
            try atomic.replace(self.io);
        } else {
            try atomic.link(self.io);
        }

        self.document.saved_version = self.model.getAlternativeVersionId();
        self.clearConflict();
        self.document.refreshDirtyState();
        for (self.document.editors.items) |editor| {
            for (editor.working_copy_save_listeners.items) |listener| listener.callback(listener.context);
            editor.setMessage("Saved {s}", .{path});
        }
    }

    /// Escape behavior: drop secondary cursors first, otherwise cancel the
    /// current selection.
    pub fn cancelSelectionOrCursors(self: *Editor) !void {
        if (self.cursorCount() > 1) {
            return self.removeSecondaryCursors();
        }
        return self.cancelSelection();
    }
};

fn digitsFor(line_count: usize) usize {
    var digits: usize = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn resolvedLanguageConfigurationForBrackets(
    context: *anyopaque,
    language_id: []const u8,
) ?*const language_configuration_registry.ResolvedLanguageConfiguration {
    const service: *LanguageConfigurationService = @ptrCast(@alignCast(context));
    return service.resolved(language_id);
}

fn createModel(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    language_id: []const u8,
    undo_redo: *UndoRedoService,
    language_service: *LanguageService,
    text: ?[]const u8,
    loaded: ?*const LoadedText,
    encoding_out: *encoding_mod.Encoding,
) !*TextModel {
    const options = TextModelCreationOptions{
        .tabSize = 4,
        .indentSize = .{ .number = 4 },
        .insertSpaces = true,
        .detectIndentation = true,
        .trimAutoWhitespace = true,
        .defaultEOL = .LF,
        .isForSimpleWidget = false,
        .largeFileOptimizations = true,
        // Upstream default: bracket-pair colorization is on unless a setting
        // disables it. `View.rebuild` prepares the AST before decorations and
        // defers the initial build for large documents.
        .bracketPairColorizationOptions = .{ .enabled = true, .independentColorPoolPerBracketType = false },
    };

    var owned: ?LoadedText = null;
    defer if (owned) |*value| value.deinit(allocator);
    const value = loaded orelse blk: {
        if (text) |bytes| {
            const encoding = if (encoding_mod.detectBOM(bytes)) |bom| bom.encoding else .utf8;
            const decoded = try encoding_mod.decode(allocator, bytes, encoding);
            errdefer allocator.free(decoded);
            owned = .{ .text = decoded, .encoding = encoding, .absolute_path = try text_files.absolutePath(allocator, io, path) };
        } else {
            var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
            defer files.deinit();
            var service = text_files.TextFileService.init(allocator, &files);
            defer service.deinit();
            owned = try service.resolve(path, true);
        }
        break :blk &owned.?;
    };
    encoding_out.* = value.encoding;
    var fixed = Io.Reader.fixed(value.text);
    const associated = std.Uri{
        .scheme = "file",
        .user = null,
        .password = null,
        .host = .{ .raw = "" },
        .port = null,
        .path = .{ .raw = try allocator.dupe(u8, value.absolute_path) },
        .query = null,
        .fragment = null,
    };
    return try TextModel.init(allocator, &fixed, language_id, options, associated, undo_redo, language_service);
}

fn guessFromFirstLine(service: *LanguageService, model: *TextModel) !?[]const u8 {
    const end = @min(1001, model.getLineMaxColumn(1));
    var line = try model.getValueInRange(Range.init(1, 1, 1, end), null);
    defer line.deinit();
    return service.guessLanguageIdByFilepathOrFirstLine(null, line.items);
}

fn configureDocumentLanguage(
    allocator: Allocator,
    io: Io,
    service: *LanguageService,
    arena: Allocator,
    registry: ?*const extensions_registry.Registry,
    language_id: []const u8,
) !void {
    var config: ?language_configuration.LanguageConfiguration = null;
    if (registry) |catalog| {
        if (catalog.grammarForLanguage(language_id)) |grammar| {
            registerDeclarativeGrammar(io, allocator, grammar.root, grammar);
        }
        if (catalog.language(language_id)) |definition| {
            if (definition.configuration) |path| config = language_config_point.load(arena, definition.root, path) catch null;
        }
    }
    if (config == null) {
        if (language.bundledLanguageConfiguration(language_id)) |data| config = language_config_point.loadText(arena, data) catch null;
    }
    if (config == null) {
        var fallback = language_configuration.empty();
        fallback.comments = language.commentRuleFor(language_id);
        fallback.brackets = language.bracketsFor(language_id);
        fallback.folding = language.foldingRulesFor(language_id);
        if (fallback.comments != null or fallback.brackets != null or fallback.folding != null) config = fallback;
    }
    if (config) |*value| {
        errdefer value.deinit();
        try service.registerLanguageConfiguration(language_id, value.*);
    }
}

fn registerDeclarativeGrammar(io: Io, allocator: Allocator, root: []const u8, grammar: extensions_registry.Grammar) void {
    if (text_mate_tokenizer.hasCatalogGrammar(grammar.location, grammar.scope)) return;
    const path = std.fs.path.join(allocator, &.{ root, grammar.path }) catch return;
    defer allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return;
    defer allocator.free(data);
    text_mate_tokenizer.registerGrammar(grammar.language, grammar.scope, data);
}

test "Editor: split copy shares the model and keeps view state independent" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = try Editor.createFromText(
        allocator,
        io,
        "0\n1\n2\n3\n4\n5\n6\n7\n8\n9",
        "split-copy.txt",
        30,
        6,
    );
    defer {
        source.deinit();
        allocator.destroy(source);
    }

    const copy = try Editor.createViewFromEditor(source, 30, 6);
    try std.testing.expect(source.model == copy.model);
    try source.setCursorPosition(Position.init(1, 2));
    try copy.setCursorPosition(Position.init(3, 1));
    try std.testing.expectEqual(Position.init(1, 2), source.modelCursorPosition());
    try std.testing.expectEqual(Position.init(3, 1), copy.modelCursorPosition());

    _ = source.setTopViewLine(1);
    _ = copy.setTopViewLine(4);
    try std.testing.expectEqual(@as(usize, 1), source.topViewLine());
    try std.testing.expectEqual(@as(usize, 4), copy.topViewLine());

    try copy.insertText("X");
    const changed = try source.model.getLineContent(3);
    defer changed.deinit();
    try std.testing.expectEqualStrings("X2", changed.items);
    try std.testing.expectEqual(Position.init(1, 2), source.modelCursorPosition());
    try std.testing.expect(source.isDirty());
    try std.testing.expect(copy.isDirty());

    // Closing one view leaves the shared document alive for the other.
    copy.deinit();
    allocator.destroy(copy);
    try source.setCursorPosition(Position.init(1, 1));
    try source.insertText("Y");
    const after_close = try source.model.getLineContent(1);
    defer after_close.deinit();
    try std.testing.expectEqualStrings("Y0", after_close.items);
}

test "Editor: viewport reflows wrapping" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 11, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    editor.setViewport(20, 5);
    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
}

test "Editor: scrollbar width reserves wrapping and text columns" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdefghijk", "test.txt", 17, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 11), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 17), editor.textAreaRight());

    editor.setScrollbarWidth(2);
    try std.testing.expectEqual(@as(usize, 2), editor.scrollbar_width);
    try std.testing.expectEqual(@as(usize, 9), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 15), editor.textAreaRight());
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());

    editor.setScrollbarWidth(0);
    try std.testing.expectEqual(@as(usize, 0), editor.scrollbar_width);
    try std.testing.expectEqual(@as(usize, 11), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
}

test "Editor: scroll height and absolute top line follow the viewport" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(
        allocator,
        io,
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11",
        "test.txt",
        40,
        5,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqual(@as(usize, 12), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 12), editor.scrollHeight());

    try std.testing.expect(editor.setTopViewLine(99));
    try std.testing.expectEqual(@as(usize, 9), editor.topViewLine());
    try std.testing.expect(editor.setTopViewLine(0));
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());
    try std.testing.expect(!editor.setTopViewLine(1));
}

test "Editor: save writes the model value" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/save.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var editor = try Editor.createFromText(allocator, io, "hello", path, 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.insertText("X");
    try editor.save();
    try std.testing.expect(!editor.isDirty());

    var buffer: [64]u8 = undefined;
    const content = try tmp.dir.readFile(io, "save.txt", &buffer);
    try std.testing.expectEqualStrings("Xhello", content);

    try editor.insertText("Y");
    try editor.save();
    const content2 = try tmp.dir.readFile(io, "save.txt", &buffer);
    try std.testing.expectEqualStrings("XYhello", content2);
}

test "Editor: cursor and deletion across a wrap boundary" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 11, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // Gutter is 6 columns, so the text wraps at 5 columns: abcde / fghij.
    var i: usize = 0;
    while (i < 5) : (i += 1) try editor.moveRight(false);
    try std.testing.expectEqual(@as(usize, 2), editor.viewCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 6), editor.modelCursorPosition().column);

    try editor.deleteLeft();
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("abcdfghij", line.items);
    try std.testing.expectEqual(@as(usize, 5), editor.modelCursorPosition().column);
}

test "Editor: save preserves CRLF" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/crlf.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var editor = try Editor.createFromText(allocator, io, "a\r\nb\r\n", path, 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.insertText("X");
    try editor.save();

    var buffer: [64]u8 = undefined;
    const content = try tmp.dir.readFile(io, "crlf.txt", &buffer);
    try std.testing.expectEqualStrings("Xa\r\nb\r\n", content);
}

test "Editor: save preserves the BOM" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bom.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var editor = try Editor.createFromText(allocator, io, "\xEF\xBB\xBFhi", path, 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.insertText("X");
    try editor.save();

    var buffer: [64]u8 = undefined;
    const content = try tmp.dir.readFile(io, "bom.txt", &buffer);
    try std.testing.expectEqualStrings("\xEF\xBB\xBFXhi", content);
}

test "Editor: selecting an encoding controls load and save" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/encoding.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var editor = try Editor.createFromText(allocator, io, "hi", path, 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqual(encoding_mod.Encoding.utf8, editor.getEncoding());
    editor.setEncoding(.utf8_with_bom);
    try editor.save();

    var buffer: [64]u8 = undefined;
    const content = try tmp.dir.readFile(io, "encoding.txt", &buffer);
    try std.testing.expectEqualStrings("\xEF\xBB\xBFhi", content);

    var reloaded = try Editor.create(allocator, io, path, 40, 8);
    defer {
        reloaded.deinit();
        allocator.destroy(reloaded);
    }
    try std.testing.expectEqual(encoding_mod.Encoding.utf8_with_bom, reloaded.getEncoding());
    const text = try reloaded.model.getValue(.TextDefined, false);
    defer text.deinit();
    try std.testing.expectEqualStrings("hi", text.items);
}

test "Editor: missing file opens empty and save creates it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/new.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var editor = try Editor.create(allocator, io, path, 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqual(@as(usize, 1), editor.model.getLineCount());
    try std.testing.expect(!editor.isDirty());
    try editor.insertText("hi");
    try editor.save();

    var buffer: [64]u8 = undefined;
    const content = try tmp.dir.readFile(io, "new.txt", &buffer);
    try std.testing.expectEqualStrings("hi", content);
}

test "Editor: discarding future and removed undo elements releases their memory" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.insertText("a");
    try editor.undo();
    try editor.insertText("b");
    try editor.undo();
    try editor.insertText("c");

    try editor.undo_redo.removeElements(editor.model.uri());
}

test "Editor: random edits release token storage" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = @embedFile("../../../../base/common/arrays.zig");

    var editor = try Editor.createFromText(allocator, io, source, "test.zig", 100, 30);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var prng = std.Random.DefaultPrng.init(0x1234);
    const random = prng.random();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        switch (random.uintLessThan(u8, 8)) {
            0 => try editor.insertText("a"),
            1 => try editor.newline(),
            2 => try editor.deleteLeft(),
            3 => try editor.deleteRight(),
            4 => try editor.undo(),
            5 => try editor.redo(),
            6 => try editor.moveDown(false),
            else => try editor.moveUp(false),
        }
    }
}

test "Editor: a closing brace stays on the newly inserted line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\n\n/// comment\n", "test.zig", 80, 20);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(false);
    try editor.insertText("fn hello() {");
    try editor.newline();

    const selection = editor.modelSelection();
    try std.testing.expectEqual(selection.startLineNumber, selection.endLineNumber);
    try std.testing.expectEqual(selection.startColumn, selection.endColumn);

    try editor.insertText("}");

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    const line3 = try editor.model.getLineContent(3);
    defer line3.deinit();
    const line4 = try editor.model.getLineContent(4);
    defer line4.deinit();
    try std.testing.expectEqualStrings("fn hello() {", line2.items);
    try std.testing.expectEqualStrings("}", line3.items);
    try std.testing.expectEqualStrings("/// comment", line4.items);
}

test "Editor: multi-cursor edit across shifted lines is undoable" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb\nc\nd", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // One cursor removes the first line, the other edits the last line. The
    // raw change for the last line is computed after the line count shifted.
    try editor.setSelections(&[_]Selection{
        Selection.init(1, 1, 2, 1),
        Selection.init(4, 2, 4, 2),
    });
    try editor.insertText("X");

    const after = try editor.model.getValue(.LF, false);
    defer after.deinit();
    try std.testing.expectEqualStrings("Xb\nc\ndX", after.items);

    try editor.undo();
    const undone = try editor.model.getValue(.LF, false);
    defer undone.deinit();
    try std.testing.expectEqualStrings("a\nb\nc\nd", undone.items);

    try editor.redo();
    const redone = try editor.model.getValue(.LF, false);
    defer redone.deinit();
    try std.testing.expectEqualStrings("Xb\nc\ndX", redone.items);
}

test "Editor: undo restores cursor state for following edits" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 6));
    try editor.insertText("X");
    try std.testing.expectEqual(Position.init(1, 7), editor.modelCursorPosition());

    try editor.undo();
    const undone = try editor.model.getValue(.LF, false);
    defer undone.deinit();
    try std.testing.expectEqualStrings("hello", undone.items);
    try std.testing.expectEqual(Position.init(1, 6), editor.modelCursorPosition());

    // The restored selection must be usable by the next edit.
    try editor.insertText("Y");
    const retyped = try editor.model.getValue(.LF, false);
    defer retyped.deinit();
    try std.testing.expectEqualStrings("helloY", retyped.items);
    try std.testing.expectEqual(Position.init(1, 7), editor.modelCursorPosition());
}

test "Editor: undo of grouped typing restores the original text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "var", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.insertText(" ");
    try editor.insertText("q");
    try editor.insertText("u");
    try editor.insertText("e");
    try editor.insertText("u");
    try editor.insertText("e");
    try editor.undo();

    const value = try editor.model.getValue(.LF, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("var", value.items);
}

test "Editor: grouped undo restores consecutive edits" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "var queue = ArrayQueue(i32).init();\n", "test.zig", 80, 20);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const cases = [_][]const u8{ "insert", "deleteLeft", "deleteRight", "replaceThenType" };
    for (cases) |kind| {
        const before = try editor.model.getValue(.LF, false);
        defer before.deinit();
        editor.model.pushStackElement();

        if (std.mem.eql(u8, kind, "insert")) {
            try editor.insertText(" ");
            try editor.insertText("a");
            try editor.insertText("b");
            try editor.insertText("c");
            try editor.insertText("d");
        } else if (std.mem.eql(u8, kind, "deleteLeft")) {
            try editor.moveLineEnd(false);
            try editor.deleteLeft();
            try editor.deleteLeft();
            try editor.deleteLeft();
            try editor.deleteLeft();
            try editor.deleteLeft();
        } else if (std.mem.eql(u8, kind, "deleteRight")) {
            try editor.moveLineStart(false);
            try editor.deleteRight();
            try editor.deleteRight();
            try editor.deleteRight();
            try editor.deleteRight();
            try editor.deleteRight();
        } else {
            try editor.moveLineStart(false);
            try editor.moveRight(true);
            try editor.moveRight(true);
            try editor.moveRight(true);
            try editor.insertText("a");
            try editor.insertText("b");
            try editor.insertText("c");
        }

        const after = try editor.model.getValue(.LF, false);
        defer after.deinit();
        editor.undo() catch {
            std.debug.print("UNDOERR {s}\n", .{kind});
            return error.TestUnexpectedResult;
        };
        const undone = try editor.model.getValue(.LF, false);
        defer undone.deinit();
        if (!std.mem.eql(u8, before.items, undone.items)) {
            std.debug.print("GROUP MISMATCH {s}\nbefore=[{s}]\nafter=[{s}]\nundone=[{s}]\n", .{ kind, before.items, after.items, undone.items });
            return error.TestUnexpectedResult;
        }
        try editor.redo();
    }
}

test "Editor: move and copy lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveLines(true);
    const moved = try editor.model.getLineContent(1);
    defer moved.deinit();
    try std.testing.expectEqualStrings("b", moved.items);

    var copy_editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 8);
    defer {
        copy_editor.deinit();
        allocator.destroy(copy_editor);
    }
    try copy_editor.moveDown(false);
    try copy_editor.copyLines(false);
    const copied = try copy_editor.model.getLineContent(2);
    defer copied.deinit();
    try std.testing.expectEqualStrings("b", copied.items);
    const copied2 = try copy_editor.model.getLineContent(3);
    defer copied2.deinit();
    try std.testing.expectEqualStrings("b", copied2.items);
}

test "Editor: line comments toggle back to the original text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "let x = 1;", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.toggleLineComment();
    const commented = try editor.model.getLineContent(1);
    defer commented.deinit();
    try std.testing.expectEqualStrings("// let x = 1;", commented.items);

    try editor.toggleLineComment();
    const uncommented = try editor.model.getLineContent(1);
    defer uncommented.deinit();
    try std.testing.expectEqualStrings("let x = 1;", uncommented.items);
}

test "Editor: block comment shortcut is language aware" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "abc", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.toggleBlockComment();
    try std.testing.expect(std.mem.indexOf(u8, editor.message(), "Block comments are not supported") != null);
}

test "Editor: expand line selection and insert final newline" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.expandLineSelection();
    const selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), selection.endLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selection.endColumn);

    try editor.insertFinalNewLine();
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("a\nb\n", value.items);
}

test "Editor: jump to, select to, and remove matching brackets" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try editor.jumpToBracket();
        try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().column);
    }

    {
        var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try editor.selectToBracket(true);
        const selection = editor.modelSelection();
        try std.testing.expectEqual(@as(usize, 1), selection.startColumn);
        try std.testing.expectEqual(@as(usize, 4), selection.endColumn);
    }

    {
        var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try editor.removeBrackets();
        const value = try editor.model.getValue(.TextDefined, false);
        defer value.deinit();
        try std.testing.expectEqualStrings("a", value.items);
    }
}

test "Editor: indent and outdent a selected line block" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(true); // select line 1
    try editor.insertTab();
    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    try std.testing.expectEqualStrings("    a", first.items);
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("b", second.items);

    try editor.moveUp(false);
    try editor.outdent();
    const unindented = try editor.model.getLineContent(1);
    defer unindented.deinit();
    try std.testing.expectEqualStrings("a", unindented.items);
}

test "Editor: conversion between tab and space indentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "\ta", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.indentationToSpaces();
    const spaces = try editor.model.getLineContent(1);
    defer spaces.deinit();
    try std.testing.expectEqualStrings("    a", spaces.items);

    try editor.indentationToTabs();
    const tabs = try editor.model.getLineContent(1);
    defer tabs.deinit();
    try std.testing.expectEqualStrings("\ta", tabs.items);
}

test "Editor: folding survives an edit on the folded start line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expect(try editor.toggleFoldAtViewLine(1));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());

    try editor.setCursorPosition(Position.init(1, 10));
    try editor.insertText("!");
    editor.refreshFoldingIfDirty();

    try std.testing.expectEqual(folding.FoldState.collapsed, editor.foldStateAtModelLine(1));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("class A {!", line.items);
}

test "Editor: folding hides a region and unfolds it again" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.refreshFoldingIfDirty();
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
    try std.testing.expectEqual(folding.FoldState.expanded, editor.foldStateAtModelLine(1));

    // A caret inside the region is moved to the line before the hidden range.
    try editor.setCursorPosition(Position.init(3, 1));
    try std.testing.expect(try editor.toggleFoldAtViewLine(1));
    try std.testing.expectEqual(folding.FoldState.collapsed, editor.foldStateAtModelLine(1));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 5), editor.modelLineNumber(2));
    try std.testing.expectEqual(Position.init(1, 1), editor.modelCursorPosition());

    try editor.moveDown(false);
    try std.testing.expectEqual(@as(usize, 5), editor.modelCursorPosition().lineNumber);
    try editor.moveUp(false);
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);

    try editor.unfoldAll();
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
    try std.testing.expectEqual(folding.FoldState.expanded, editor.foldStateAtModelLine(1));
}

test "Editor: reindent lines uses language indentation rules" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const RegExp = @import("../../../../../support/regexp.zig").RegExp;

    const increase = try RegExp.init("\\{$", .{});
    const decrease = try RegExp.init("^\\s*\\}", .{});
    // The language service owns and frees both regexes on deinit.

    var editor = try Editor.createFromText(allocator, io, "if (a) {\nb\n}", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var config = language_configuration.empty();
    config.indentationRules = .{
        .decreaseIndentPattern = decrease,
        .increaseIndentPattern = increase,
        .indentNextLinePattern = null,
        .unIndentedLinePattern = null,
    };
    try editor.language_service.registerLanguageConfiguration("zig", config);

    try editor.reindentLines();
    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    b", line2.items);
}

test "Editor: Enter honors increaseIndentPattern" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const RegExp = @import("../../../../../support/regexp.zig").RegExp;

    const increase = try RegExp.init("^\\s*for\\b", .{});
    const decrease = try RegExp.init("^\\s*end\\b", .{});

    var editor = try Editor.createFromText(allocator, io, "for", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var config = language_configuration.empty();
    config.indentationRules = .{
        .decreaseIndentPattern = decrease,
        .increaseIndentPattern = increase,
        .indentNextLinePattern = null,
        .unIndentedLinePattern = null,
    };
    try editor.language_service.registerLanguageConfiguration("zig", config);

    try editor.setCursorPosition(Position.init(1, 4));
    try editor.newline();

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    ", line2.items);
    try std.testing.expectEqual(Position.init(2, 5), editor.modelCursorPosition());
}

test "Editor: JSON Enter indents inside braces" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "{\n}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 2));
    try editor.newline();

    const line1 = try editor.model.getLineContent(1);
    defer line1.deinit();
    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    const line3 = try editor.model.getLineContent(3);
    defer line3.deinit();
    try std.testing.expectEqualStrings("{", line1.items);
    try std.testing.expectEqualStrings("    ", line2.items);
    try std.testing.expectEqualStrings("}", line3.items);
    try std.testing.expectEqual(Position.init(2, 5), editor.modelCursorPosition());
}

test "Editor: JSON Enter ignores braces inside strings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "\"a {\"", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 6));
    try editor.newline();

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("", line2.items);
    try std.testing.expectEqual(Position.init(2, 1), editor.modelCursorPosition());
}

test "Editor: JSON Enter between braces indents and leaves the closing brace" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "{}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 2));
    try editor.newline();

    const line1 = try editor.model.getLineContent(1);
    defer line1.deinit();
    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    const line3 = try editor.model.getLineContent(3);
    defer line3.deinit();
    try std.testing.expectEqualStrings("{", line1.items);
    try std.testing.expectEqualStrings("    ", line2.items);
    try std.testing.expectEqualStrings("}", line3.items);
    try std.testing.expectEqual(Position.init(2, 5), editor.modelCursorPosition());
}

test "Editor: extension-host newline typing honors JSON indentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "{\n}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 2));
    // `default:type` from the extension host inserts "\n" through typeCharacter.
    try editor.typeCharacter("\n");

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    ", line2.items);
    try std.testing.expectEqual(Position.init(2, 5), editor.modelCursorPosition());
}

test "Editor: insertLineAfter honors JSON indentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "{\n}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 1));
    try editor.insertLineAfter();

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    ", line2.items);
    try std.testing.expectEqual(Position.init(2, 5), editor.modelCursorPosition());
}

test "Editor: typing a JSON closing brace outdents the line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "{\n    \n}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(2, 5));
    try editor.typeCharacter("}");

    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("}", line2.items);
    try std.testing.expectEqual(Position.init(2, 2), editor.modelCursorPosition());
}

test "Editor: add cursor below and edit both lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.addCursorBelow();
    try std.testing.expectEqual(@as(usize, 2), editor.cursorCount());

    try editor.insertText("x");
    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("xa", first.items);
    try std.testing.expectEqualStrings("xb", second.items);
}

test "Editor: select next occurrence and replace all selections" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "foo foo", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.selectNextOccurrence();
    try editor.selectNextOccurrence();
    try std.testing.expectEqual(@as(usize, 2), editor.cursorCount());

    try editor.insertText("bar");
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("bar bar", value.items);
}

test "Editor: auto-closes brackets and deletes the pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.typeCharacter("(");
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("()", value.items);
    try std.testing.expectEqual(Position.init(1, 2), editor.modelCursorPosition());

    try editor.deleteLeft();
    const after_delete = try editor.model.getValue(.TextDefined, false);
    defer after_delete.deinit();
    try std.testing.expectEqualStrings("", after_delete.items);
    try std.testing.expectEqual(Position.init(1, 1), editor.modelCursorPosition());
}

test "Editor: overtypes an existing closing bracket" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.typeCharacter("(");
    try editor.typeCharacter(")");
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("()", value.items);
    try std.testing.expectEqual(Position.init(1, 3), editor.modelCursorPosition());
}

test "Editor: movement applies to every cursor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.addCursorBelow();
    try editor.moveRight(false);
    try editor.insertText("x");

    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("ax", first.items);
    try std.testing.expectEqualStrings("bx", second.items);
}

test "Editor: word movement applies to every cursor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "foo bar\nbaz qux", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.addCursorBelow();
    try editor.moveWordRight(false);

    const cursors = try editor.viewCursorStates();
    defer allocator.free(cursors);
    try std.testing.expectEqual(@as(usize, 2), cursors.len);
    try std.testing.expectEqual(@as(usize, 5), cursors[0].viewState.position.column);
    try std.testing.expectEqual(@as(usize, 5), cursors[1].viewState.position.column);
}

const shortcut_specs = [_]struct {
    id: []const u8,
    run: *const fn (*anyopaque) anyerror!void,
}{
    .{ .id = "workbench.action.files.save", .run = cmdSave },
    .{ .id = "editor.action.formatDocument", .run = cmdFormatDocument },
    .{ .id = "undo", .run = cmdUndo },
    .{ .id = "redo", .run = cmdRedo },
    .{ .id = "editor.action.selectAll", .run = cmdSelectAll },
    .{ .id = "expandLineSelection", .run = cmdExpandLineSelection },
    .{ .id = "editor.action.commentLine", .run = cmdToggleLineComment },
    .{ .id = "editor.action.blockComment", .run = cmdToggleBlockComment },
    .{ .id = "editor.action.jumpToBracket", .run = cmdJumpToBracket },
    .{ .id = "editor.action.indentLines", .run = cmdIndentLines },
    .{ .id = "editor.action.selectNextOccurrence", .run = cmdSelectNextOccurrence },
    .{ .id = "editor.action.inPlaceReplace.up", .run = cmdInPlaceReplaceUp },
    .{ .id = "editor.action.inPlaceReplace.down", .run = cmdInPlaceReplaceDown },
    .{ .id = "editor.action.selectToBracket", .run = cmdSelectToBracket },
    .{ .id = "editor.action.removeBrackets", .run = cmdRemoveBrackets },
    .{ .id = "editor.action.selectAllOccurrences", .run = cmdSelectAllOccurrences },
    .{ .id = "editor.action.reindentselectedlines", .run = cmdReindentSelectedLines },
    .{ .id = "editor.action.reindentlines", .run = cmdReindentLines },
    .{ .id = "editor.fold", .run = cmdFold },
    .{ .id = "editor.unfold", .run = cmdUnfold },
    .{ .id = "editor.toggleFold", .run = cmdToggleFold },
    .{ .id = "editor.foldAll", .run = cmdFoldAll },
    .{ .id = "editor.unfoldAll", .run = cmdUnfoldAll },
    .{ .id = "editor.foldRecursively", .run = cmdFoldRecursively },
    .{ .id = "editor.unfoldRecursively", .run = cmdUnfoldRecursively },
    .{ .id = "cursorLeft", .run = cmd_cursorLeft },
    .{ .id = "cursorLeftSelect", .run = cmd_cursorLeftSelect },
    .{ .id = "cursorRight", .run = cmd_cursorRight },
    .{ .id = "cursorRightSelect", .run = cmd_cursorRightSelect },
    .{ .id = "cursorWordLeft", .run = cmd_cursorWordLeft },
    .{ .id = "cursorWordLeftSelect", .run = cmd_cursorWordLeftSelect },
    .{ .id = "cursorWordRight", .run = cmd_cursorWordRight },
    .{ .id = "cursorWordRightSelect", .run = cmd_cursorWordRightSelect },
    .{ .id = "cursorUp", .run = cmd_cursorUp },
    .{ .id = "cursorUpSelect", .run = cmd_cursorUpSelect },
    .{ .id = "cursorDown", .run = cmd_cursorDown },
    .{ .id = "cursorDownSelect", .run = cmd_cursorDownSelect },
    .{ .id = "cursorPageUp", .run = cmd_cursorPageUp },
    .{ .id = "cursorPageUpSelect", .run = cmd_cursorPageUpSelect },
    .{ .id = "cursorPageDown", .run = cmd_cursorPageDown },
    .{ .id = "cursorPageDownSelect", .run = cmd_cursorPageDownSelect },
    .{ .id = "cursorLineStart", .run = cmd_cursorLineStart },
    .{ .id = "cursorLineStartSelect", .run = cmd_cursorLineStartSelect },
    .{ .id = "cursorLineEnd", .run = cmd_cursorLineEnd },
    .{ .id = "cursorLineEndSelect", .run = cmd_cursorLineEndSelect },
    .{ .id = "cursorTop", .run = cmd_cursorTop },
    .{ .id = "cursorTopSelect", .run = cmd_cursorTopSelect },
    .{ .id = "cursorBottom", .run = cmd_cursorBottom },
    .{ .id = "cursorBottomSelect", .run = cmd_cursorBottomSelect },
    .{ .id = "scrollLeft", .run = cmd_scrollLeft },
    .{ .id = "scrollRight", .run = cmd_scrollRight },
    .{ .id = "editor.action.moveLinesUp", .run = cmd_editor_action_moveLinesUp },
    .{ .id = "editor.action.copyLinesUp", .run = cmd_editor_action_copyLinesUp },
    .{ .id = "editor.action.moveLinesDown", .run = cmd_editor_action_moveLinesDown },
    .{ .id = "editor.action.copyLinesDown", .run = cmd_editor_action_copyLinesDown },
    .{ .id = "editor.action.insertCursorAbove", .run = cmd_editor_action_insertCursorAbove },
    .{ .id = "editor.action.insertCursorBelow", .run = cmd_editor_action_insertCursorBelow },
    .{ .id = "editor.action.smartSelect.shrink", .run = cmd_editor_action_smartSelect_shrink },
    .{ .id = "editor.action.smartSelect.expand", .run = cmd_editor_action_smartSelect_expand },
    .{ .id = "lineBreakInsert", .run = cmd_lineBreakInsert },
    .{ .id = "tab", .run = cmd_tab },
    .{ .id = "outdent", .run = cmd_outdent },
    .{ .id = "deleteLeft", .run = cmd_deleteLeft },
    .{ .id = "deleteRight", .run = cmd_deleteRight },
    .{ .id = "editor.action.cancelSelection", .run = cmd_editor_action_cancelSelection },
    .{ .id = "actions.find", .run = cmdFind },
    .{ .id = "editor.action.startFindReplaceAction", .run = cmdStartFindReplace },
};

fn editorOf(context: *anyopaque) *Editor {
    return @ptrCast(@alignCast(context));
}

fn cmdFormatDocument(context: *anyopaque) anyerror!void {
    return editorOf(context).formatDocument();
}
fn cmdSave(context: *anyopaque) anyerror!void {
    return editorOf(context).save();
}
fn cmdUndo(context: *anyopaque) anyerror!void {
    return editorOf(context).undo();
}
fn cmdRedo(context: *anyopaque) anyerror!void {
    return editorOf(context).redo();
}
fn cmdSelectAll(context: *anyopaque) anyerror!void {
    return editorOf(context).selectAll();
}
fn cmdExpandLineSelection(context: *anyopaque) anyerror!void {
    return editorOf(context).expandLineSelection();
}
fn cmdToggleLineComment(context: *anyopaque) anyerror!void {
    return editorOf(context).toggleLineComment();
}
fn cmdToggleBlockComment(context: *anyopaque) anyerror!void {
    return editorOf(context).toggleBlockComment();
}
fn cmdJumpToBracket(context: *anyopaque) anyerror!void {
    return editorOf(context).jumpToBracket();
}
fn cmdIndentLines(context: *anyopaque) anyerror!void {
    return editorOf(context).indentLines();
}
fn cmdSelectNextOccurrence(context: *anyopaque) anyerror!void {
    return editorOf(context).selectNextOccurrence();
}
fn cmdInPlaceReplaceUp(context: *anyopaque) anyerror!void {
    _ = try editorOf(context).inPlaceReplace(false);
}
fn cmdInPlaceReplaceDown(context: *anyopaque) anyerror!void {
    _ = try editorOf(context).inPlaceReplace(true);
}
fn cmdSelectToBracket(context: *anyopaque) anyerror!void {
    return editorOf(context).selectToBracket(true);
}
fn cmdRemoveBrackets(context: *anyopaque) anyerror!void {
    return editorOf(context).removeBrackets();
}
fn cmdSelectAllOccurrences(context: *anyopaque) anyerror!void {
    return editorOf(context).selectAllOccurrences();
}
fn cmdReindentSelectedLines(context: *anyopaque) anyerror!void {
    return editorOf(context).reindentSelectedLines();
}
fn cmdReindentLines(context: *anyopaque) anyerror!void {
    return editorOf(context).reindentLines();
}
fn cmdFold(context: *anyopaque) anyerror!void {
    return editorOf(context).foldAtCursor();
}
fn cmdUnfold(context: *anyopaque) anyerror!void {
    return editorOf(context).unfoldAtCursor();
}
fn cmdToggleFold(context: *anyopaque) anyerror!void {
    return editorOf(context).toggleFoldAtCursor();
}
fn cmdFoldAll(context: *anyopaque) anyerror!void {
    return editorOf(context).foldAll();
}
fn cmdUnfoldAll(context: *anyopaque) anyerror!void {
    return editorOf(context).unfoldAll();
}
fn cmdFoldRecursively(context: *anyopaque) anyerror!void {
    return editorOf(context).foldRecursivelyAtCursor();
}
fn cmdUnfoldRecursively(context: *anyopaque) anyerror!void {
    return editorOf(context).unfoldRecursivelyAtCursor();
}

fn cmd_cursorLeft(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLeft(false);
}
fn cmd_cursorLeftSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLeft(true);
}
fn cmd_cursorRight(context: *anyopaque) anyerror!void {
    return editorOf(context).moveRight(false);
}
fn cmd_cursorRightSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveRight(true);
}
fn cmd_cursorWordLeft(context: *anyopaque) anyerror!void {
    return editorOf(context).moveWordLeft(false);
}
fn cmd_cursorWordLeftSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveWordLeft(true);
}
fn cmd_cursorWordRight(context: *anyopaque) anyerror!void {
    return editorOf(context).moveWordRight(false);
}
fn cmd_cursorWordRightSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveWordRight(true);
}
fn cmd_cursorUp(context: *anyopaque) anyerror!void {
    return editorOf(context).moveUp(false);
}
fn cmd_cursorUpSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveUp(true);
}
fn cmd_cursorDown(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDown(false);
}
fn cmd_cursorDownSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDown(true);
}
fn cmd_cursorPageUp(context: *anyopaque) anyerror!void {
    return editorOf(context).movePageUp(false);
}
fn cmd_cursorPageUpSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).movePageUp(true);
}
fn cmd_cursorPageDown(context: *anyopaque) anyerror!void {
    return editorOf(context).movePageDown(false);
}
fn cmd_cursorPageDownSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).movePageDown(true);
}
fn cmd_cursorLineStart(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLineStart(false);
}
fn cmd_cursorLineStartSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLineStart(true);
}
fn cmd_cursorLineEnd(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLineEnd(false);
}
fn cmd_cursorLineEndSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLineEnd(true);
}
fn cmd_cursorTop(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDocStart(false);
}
fn cmd_cursorTopSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDocStart(true);
}
fn cmd_cursorBottom(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDocEnd(false);
}
fn cmd_cursorBottomSelect(context: *anyopaque) anyerror!void {
    return editorOf(context).moveDocEnd(true);
}
fn cmd_scrollLeft(context: *anyopaque) anyerror!void {
    _ = editorOf(context).scrollColumns(-2);
}
fn cmd_scrollRight(context: *anyopaque) anyerror!void {
    _ = editorOf(context).scrollColumns(2);
}

fn cmd_editor_action_moveLinesUp(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLines(false);
}
fn cmd_editor_action_copyLinesUp(context: *anyopaque) anyerror!void {
    return editorOf(context).copyLines(false);
}
fn cmd_editor_action_moveLinesDown(context: *anyopaque) anyerror!void {
    return editorOf(context).moveLines(true);
}
fn cmd_editor_action_copyLinesDown(context: *anyopaque) anyerror!void {
    return editorOf(context).copyLines(true);
}
fn cmd_editor_action_insertCursorAbove(context: *anyopaque) anyerror!void {
    return editorOf(context).addCursorAbove();
}
fn cmd_editor_action_insertCursorBelow(context: *anyopaque) anyerror!void {
    return editorOf(context).addCursorBelow();
}
fn cmd_editor_action_smartSelect_shrink(context: *anyopaque) anyerror!void {
    return editorOf(context).growSelection(false);
}
fn cmd_editor_action_smartSelect_expand(context: *anyopaque) anyerror!void {
    return editorOf(context).growSelection(true);
}
fn cmd_lineBreakInsert(context: *anyopaque) anyerror!void {
    return editorOf(context).newline();
}
fn cmd_tab(context: *anyopaque) anyerror!void {
    return editorOf(context).insertTab();
}
fn cmd_outdent(context: *anyopaque) anyerror!void {
    return editorOf(context).outdent();
}
fn cmd_deleteLeft(context: *anyopaque) anyerror!void {
    return editorOf(context).deleteLeft();
}
fn cmd_deleteRight(context: *anyopaque) anyerror!void {
    return editorOf(context).deleteRight();
}
fn cmd_editor_action_cancelSelection(context: *anyopaque) anyerror!void {
    return editorOf(context).cancelSelectionOrCursors();
}

fn cmdFind(context: *anyopaque) anyerror!void {
    const editor = editorOf(context);
    const start = editor.find_start_fn orelse return;
    return start(editor.find_context.?, false);
}

fn cmdStartFindReplace(context: *anyopaque) anyerror!void {
    const editor = editorOf(context);
    const start = editor.find_start_fn orelse return;
    return start(editor.find_context.?, true);
}

const shortcut_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{ .id = "workbench.action.files.save", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyS) } },
    .{
        .id = "editor.action.formatDocument",
        .weight = 100,
        .bindings = .{
            .primary = key_codes.KeyMod.Shift | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyF),
            // Terminals usually cannot report Shift alongside Alt for letters;
            // ESC F arrives as Alt+F and is VS Code's format shortcut in practice.
            .secondary = &.{key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyF)},
        },
    },
    .{ .id = "undo", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyZ) } },
    .{ .id = "redo", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyY) } },
    .{ .id = "editor.action.selectAll", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyA) } },
    .{ .id = "expandLineSelection", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyL) } },
    .{ .id = "editor.action.commentLine", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Slash) } },
    .{ .id = "editor.action.blockComment", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Slash) } },
    .{ .id = "editor.action.jumpToBracket", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Backslash) } },
    .{ .id = "editor.action.indentLines", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.BracketRight) } },
    .{ .id = "editor.action.selectNextOccurrence", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyD) } },
    .{ .id = "editor.action.insertCursorAbove", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "editor.action.insertCursorBelow", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "editor.action.inPlaceReplace.up", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Comma) } },
    .{ .id = "editor.action.inPlaceReplace.down", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Period) } },
    .{ .id = "editor.action.selectToBracket", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyB) } },
    .{ .id = "editor.action.removeBrackets", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyB) } },
    .{ .id = "editor.action.selectAllOccurrences", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyD) } },
    .{ .id = "editor.action.reindentselectedlines", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyR) } },
    .{ .id = "editor.action.reindentlines", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyR) } },
    .{ .id = "editor.fold", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.BracketLeft) } },
    .{ .id = "editor.unfold", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.BracketRight) } },
    .{ .id = "editor.toggleFold", .weight = 100, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyL)) } },
    .{ .id = "editor.foldAll", .weight = 100, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Digit0)) } },
    .{ .id = "editor.unfoldAll", .weight = 100, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyJ)) } },
    .{ .id = "editor.foldRecursively", .weight = 100, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.BracketLeft)) } },
    .{ .id = "editor.unfoldRecursively", .weight = 100, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.BracketRight)) } },
    .{ .id = "cursorLeft", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "cursorLeftSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "cursorRight", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "cursorRightSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "cursorWordLeft", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "cursorWordLeftSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "cursorWordRight", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "cursorWordRightSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "cursorUp", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "cursorUpSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "cursorDown", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "cursorDownSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "cursorPageUp", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.PageUp) } },
    .{ .id = "cursorPageUpSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.PageUp) } },
    .{ .id = "cursorPageDown", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.PageDown) } },
    .{ .id = "cursorPageDownSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.PageDown) } },
    .{ .id = "cursorLineStart", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Home) } },
    .{ .id = "cursorLineStartSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Home) } },
    .{ .id = "cursorLineEnd", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.End) } },
    .{ .id = "cursorLineEndSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.End) } },
    .{ .id = "cursorTop", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Home) } },
    .{ .id = "cursorTopSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Home) } },
    .{ .id = "cursorBottom", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.End) } },
    .{ .id = "cursorBottomSelect", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.End) } },
    .{ .id = "editor.action.moveLinesUp", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "editor.action.copyLinesUp", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "editor.action.moveLinesDown", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "editor.action.copyLinesDown", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "editor.action.insertCursorAbove", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "editor.action.insertCursorBelow", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "editor.action.smartSelect.shrink", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "editor.action.smartSelect.expand", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "lineBreakInsert", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Enter), .secondary = &.{key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Enter)} } },
    .{ .id = "tab", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Tab) } },
    .{ .id = "outdent", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Tab) } },
    .{ .id = "deleteLeft", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Backspace) } },
    .{ .id = "deleteRight", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Delete) } },
    .{ .id = "editor.action.cancelSelection", .weight = 100, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Escape) } },
    .{ .id = "actions.find", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyF) } },
    .{ .id = "editor.action.startFindReplaceAction", .weight = 100, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyR) } },
};

// ---------------------------------------------------------------------------
// Workbench `IWorkingCopy` adapter
//
// Upstream a text editor input owns a `TextFileEditorModel` that is itself a
// working copy. The TUI editor already owns the text model and dirty/save
// state, so this adapter exposes that state to `WorkingCopyService` without a
// second model.
// ---------------------------------------------------------------------------

const working_copy = @import("../../../../workbench/services/workingCopy/common/workingCopy.zig");
const IWorkingCopy = working_copy.IWorkingCopy;
const WorkingCopyListener = working_copy.WorkingCopyListener;

pub const TYPE_ID = "workbench.editors.files.textFileEditor";

fn wcResource(context: *anyopaque) []const u8 {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return editor.path;
}
fn wcTypeId(_: *anyopaque) []const u8 {
    return TYPE_ID;
}
fn wcName(context: *anyopaque) []const u8 {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return std.fs.path.basename(editor.path);
}
fn wcIsDirty(context: *anyopaque) bool {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return editor.isDirty();
}
fn wcIsModified(context: *anyopaque) bool {
    return wcIsDirty(context);
}

fn wcAddDirty(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopyDirtyListener(.{ .context = listener.context, .callback = listener.callback });
}
fn wcRemoveDirty(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopyDirtyListener(.{ .context = listener.context, .callback = listener.callback });
}
fn wcAddContent(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopyContentListener(.{ .context = listener.context, .callback = listener.callback });
}
fn wcRemoveContent(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopyContentListener(.{ .context = listener.context, .callback = listener.callback });
}
fn wcAddSave(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopySaveListener(.{ .context = listener.context, .callback = listener.callback });
}
fn wcRemoveSave(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopySaveListener(.{ .context = listener.context, .callback = listener.callback });
}

pub fn workingCopyInterface(editor: *Editor) IWorkingCopy {
    return .{
        .context = editor,
        .resource = wcResource,
        .type_id = wcTypeId,
        .name = wcName,
        .is_dirty = wcIsDirty,
        .is_modified = wcIsModified,
        .add_dirty_listener = wcAddDirty,
        .remove_dirty_listener = wcRemoveDirty,
        .add_content_listener = wcAddContent,
        .remove_content_listener = wcRemoveContent,
        .add_save_listener = wcAddSave,
        .remove_save_listener = wcRemoveSave,
    };
}

test "Editor: bundled languages are registered on the language service" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "const x = 1;", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqualStrings("zig", editor.language_service.guessLanguageIdByFilepathOrFirstLine("src/main.zig", null).?);
    try std.testing.expectEqualStrings("typescript", editor.language_service.guessLanguageIdByFilepathOrFirstLine("app.ts", null).?);
    try std.testing.expectEqualStrings("markdown", editor.language_service.guessLanguageIdByFilepathOrFirstLine("README.md", null).?);
    const selection = try editor.language_service.createByFilepathOrFirstLine("src/component.tsx", null);
    defer selection.deinit();
    try std.testing.expectEqualStrings("typescriptreact", selection.interface().languageId());
}

test "editor applies configured files.associations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "body", "sample.custom", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqualStrings("plaintext", editor.languageId());

    const associations = [_]languagesAssociations.ILanguageAssociation{
        .{ .id = "zig", .mime = "", .filepattern = "*.custom" },
    };
    try editor.applyFileAssociations(&associations);
    try std.testing.expectEqualStrings("zig", editor.languageId());

    // Clearing the configured associations restores the bundled detection.
    try editor.applyFileAssociations(&.{});
    try std.testing.expectEqualStrings("plaintext", editor.languageId());
}

test "declarative markdown-basics configuration reaches the editor" {
    const allocator = std.testing.allocator;
    var registry = extensions_registry.scan(allocator, &.{"vscode/extensions/markdown-basics"}) catch return error.SkipZigTest;
    defer registry.deinit();
    if (registry.language("markdown") == null) return error.SkipZigTest;

    const editor = try Editor.createWithDeclarative(allocator, time_compat.io, "README.md", 40, 8, &registry);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqualStrings("markdown", editor.languageId());
    const config = editor.language_service.getLanguageConfiguration("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(config.comments != null);
    try std.testing.expect(config.comments.?.blockComment != null);
    try std.testing.expectEqualStrings("<!--", config.comments.?.blockComment.?[0]);
    try std.testing.expectEqualStrings("-->", config.comments.?.blockComment.?[1]);
    try std.testing.expect(config.folding != null);
    try std.testing.expect(config.folding.?.offSide orelse false);
    try std.testing.expect(config.brackets != null and config.brackets.?.len >= 3);
}

test "Editor: a late language contribution configures file detection and manual language changes" {
    const allocator = std.testing.allocator;
    std.Io.Dir.cwd().access(time_compat.io, "vscode/extensions/lua/package.json", .{}) catch return error.SkipZigTest;
    var catalog = try extensions_registry.scan(allocator, &.{"vscode/extensions/lua"});
    defer catalog.deinit();
    const editor = try Editor.createFromText(allocator, time_compat.io, "-- hello", "script.lua", 32, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.applyDeclarativeExtensions(&catalog);
    try std.testing.expectEqualStrings("lua", editor.languageId());
    try editor.setLanguage("plaintext");
    try editor.setLanguage("lua");
    const config = editor.language_service.getLanguageConfiguration("lua") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("--", config.comments.?.lineComment.?.comment);
}

test "Editor: manifest first-line and MIME associations survive configuration reload" {
    const allocator = std.testing.allocator;
    std.Io.Dir.cwd().access(time_compat.io, "vscode/extensions/python/package.json", .{}) catch return error.SkipZigTest;
    var registry = try extensions_registry.scan(allocator, &.{ "vscode/extensions/python", "vscode/extensions/javascript" });
    defer registry.deinit();
    const editor = try Editor.createFromText(allocator, time_compat.io, "#!/usr/bin/env python3.12\npass", "executable", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.applyDeclarativeExtensions(&registry);
    try std.testing.expectEqualStrings("python", editor.languageId());
    try editor.applyFileAssociations(&.{});
    try std.testing.expectEqualStrings("python", editor.languageId());
    try std.testing.expectEqualStrings("javascript", editor.language_service.getLanguageIdByMimeType("text/javascript").?);
    try std.testing.expectEqualStrings("javascript", editor.language_service.guessLanguageIdByFilepathOrFirstLine("extension.js", "#!/usr/bin/python").?);
}

test "Editor: JSON language features populate diagnostics and completion" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try json_language.Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "broken.json", .data = "{\n  \"a\": 1\n" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(time_compat.io, "broken.json", &buffer);

    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    const editor = try Editor.createWithExtensions(allocator, time_compat.io, buffer[0..length], 40, 8, null, client);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.attachLanguageServices(null, &marker_service, null);
    try std.testing.expectEqualStrings("json", editor.languageId());
    try std.testing.expect(client.dispatchResponses(true));
    try std.testing.expect(editor.document.json_error_count > 0);
    try std.testing.expect(std.mem.startsWith(u8, editor.message(), "JSON "));
    try std.testing.expect(marker_service.getStatistics().errors > 0);
}

test "Editor: formats JSON through the language server" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try json_language.Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "format.json", .data = "{\"a\":1}" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(time_compat.io, "format.json", &buffer);

    const editor = try Editor.createWithExtensions(allocator, time_compat.io, buffer[0..length], 40, 8, null, client);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.formatJson();
    var value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expect(std.mem.indexOf(u8, value.items, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.items, ": 1") != null);
}

test "Editor: Alt+F dispatches formatDocument" {
    const allocator = std.testing.allocator;
    const io = @import("../../../../base/common/timeCompat.zig").io;
    const editor = try Editor.createFromText(allocator, io, "{}", "test.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const event = input.KeyEvent{ .key = .{ .char = 'F' }, .mods = .{ .alt = true } };
    try std.testing.expect(try editor.dispatchShortcut(event));
    try std.testing.expectEqualStrings("No JSON language server", editor.message());
}

test "Editor: incremental edits do not rebuild the whole wrapping model" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (0..100) |i| try text.writer.print("const line_{d} = {d};\n", .{ i, i });

    var editor = try Editor.createFromText(allocator, io, text.written(), "test.zig", 80, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqual(@as(usize, 101), editor.model.getLineCount());
    const rebuilds_before = editor.view_lines.rebuildAllCount();
    try editor.insertText("x");
    try std.testing.expectEqual(rebuilds_before, editor.view_lines.rebuildAllCount());

    try editor.insertText("\n");
    try std.testing.expectEqual(rebuilds_before, editor.view_lines.rebuildAllCount());
    try std.testing.expectEqual(@as(usize, 102), editor.model.getLineCount());
    try std.testing.expectEqual(editor.model.getLineCount(), editor.viewLineCount());
}

test "Editor: folding is scheduled with the upstream debounce" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    var window = window_dispatch.Queue{ .io = std.testing.io };
    editor.attachWindow(&window);
    const now = time_compat.milliTimestamp();
    // Re-arm with a known "now" so a slow create cannot already have passed
    // the initial 200 ms deadline.
    editor.triggerFoldingUpdate(now);
    try std.testing.expect(editor.folding_dirty);
    try std.testing.expectEqual(folding.FoldState.none, editor.foldStateAtModelLine(1));
    _ = window.dispatch(now);
    try std.testing.expect(editor.folding_dirty);
    while (window.nextTimeout(now + 200, 1) == 0) _ = window.dispatch(now + 200);
    try std.testing.expectEqual(folding.FoldState.expanded, editor.foldStateAtModelLine(1));
    try std.testing.expect(!editor.folding_dirty);
    try std.testing.expect(editor.folding_task.at == null);
}

test "Editor: inline edits do not request a full visible refresh" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "const x = 1;\nconst y = 2;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.ensureTokensVisible();
    try std.testing.expect(!editor.tokens_need_refresh);
    try editor.insertText("z");
    try std.testing.expect(!editor.tokens_need_refresh);
    editor.ensureTokensVisible();
    try std.testing.expect(editor.model.tokenization().hasAccurateTokensForLine(1));
    try std.testing.expect(editor.model.tokenization().hasAccurateTokensForLine(2));
}

test "Editor: forcing accurate tokens does not dirty bracket pairs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "if (a) {\n  b();\n}\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.ensureTokensVisible();
    const pairs = editor.model.bracketPairs();
    try pairs.updateNow();
    try std.testing.expect(!pairs.isDirty());
    editor.model.forceTokenization(1);
    try std.testing.expect(!pairs.isDirty());
}

fn disableBracketColorization(model: *TextModel) void {
    model.updateOptions(.{
        .tabSize = null,
        .indentSize = null,
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = .{
            .enabled = false,
            .independentColorPoolPerBracketType = false,
        },
    });
}

test "Editor: bracket colorization is enabled by default" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "{\n  x\n}", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.model.getOptions().bracketPairColorizationOptions.enabled);
    try std.testing.expect(!editor.model.getOptions().bracketPairColorizationOptions.independentColorPoolPerBracketType);
    editor.ensureTokensVisible();
    try editor.model.bracketPairs().updateNow();
    const pair = editor.model.bracketPairs().matchBracket(Position.init(1, 1), null);
    try std.testing.expect(pair != null);
    try std.testing.expectEqual(Position.init(3, 1), pair.?[1].getStartPosition());
}

test "Editor: large document builds bracket AST on request" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (0..600) |i| {
        try text.writer.print("const value_{d} = {{\n}};\n", .{i});
    }
    var editor = try Editor.createFromText(allocator, io, text.written(), "test.zig", 80, 20);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const pairs = editor.model.bracketPairs();
    try std.testing.expect(pairs.isDirty());
    var brackets = try pairs.getBracketsInRange(Range.init(1, 1, 1, editor.model.getLineMaxColumn(1)), false);
    defer brackets.deinit();
    try std.testing.expect(brackets.items.len > 0);
    try std.testing.expect(!pairs.isDirty());
    try std.testing.expect(pairs.hasDocument());
}

test "Editor: AST bracket matching (colorization disabled)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    disableBracketColorization(editor.model);
    editor.ensureTokensVisible();
    // Match upstream: colorization settings do not switch matching to the
    // legacy fallback scanner.
    try std.testing.expect(!editor.model.bracketPairs().useFallbackMatcher());
    const bracket_pairs = editor.model.bracketPairs();
    const matched = bracket_pairs.matchBracket(Position.init(1, 2), null);
    try std.testing.expect(matched != null);
    try std.testing.expectEqual(@as(usize, 1), matched.?[0].startColumn);
    try std.testing.expectEqual(@as(usize, 3), matched.?[1].startColumn);
    const enclosing = bracket_pairs.findEnclosingBrackets(Position.init(1, 2), null);
    try std.testing.expect(enclosing != null);
    try std.testing.expectEqual(@as(usize, 1), enclosing.?[0].startColumn);

    var multi = try Editor.createFromText(allocator, io, "if (a) {\n  b();\n}\n", "test.zig", 40, 8);
    defer {
        multi.deinit();
        allocator.destroy(multi);
    }
    disableBracketColorization(multi.model);
    multi.ensureTokensVisible();
    const multi_pairs = multi.model.bracketPairs();
    const braces = multi_pairs.matchBracket(Position.init(1, 8), null).?;
    try std.testing.expectEqual(Position.init(1, 8), braces[0].getStartPosition());
    try std.testing.expectEqual(Position.init(3, 1), braces[1].getStartPosition());
    const outer = multi_pairs.findEnclosingBrackets(Position.init(2, 3), null).?;
    try std.testing.expectEqual(Position.init(1, 8), outer[0].getStartPosition());
    const next = multi_pairs.findNextBracket(Position.init(1, 1)).?;
    try std.testing.expectEqual(@as(usize, 4), next.range.startColumn);
    try std.testing.expectEqualStrings("(", next.bracketText);
    const previous = multi_pairs.findPrevBracket(Position.init(1, 7)).?;
    try std.testing.expectEqual(@as(usize, 6), previous.range.startColumn);
    try std.testing.expectEqualStrings(")", previous.bracketText);

    // Brackets inside strings are ignored by the fallback token filter.
    var stringed = try Editor.createFromText(allocator, io, "const s = \"{\";", "test.zig", 40, 8);
    defer {
        stringed.deinit();
        allocator.destroy(stringed);
    }
    disableBracketColorization(stringed.model);
    stringed.ensureTokensVisible();
    try std.testing.expect(stringed.model.bracketPairs().matchBracket(Position.init(1, 12), null) == null);
}

test "Editor: read-only guards, line-number map and gutter width" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expect(!editor.isReadOnly());
    editor.setReadOnly(true);
    try std.testing.expect(editor.isReadOnly());
    try std.testing.expectError(error.ReadOnly, editor.insertText("x"));
    try std.testing.expectError(error.ReadOnly, editor.typeCharacter("x"));
    try std.testing.expectError(error.ReadOnly, editor.newline());
    try std.testing.expectError(error.ReadOnly, editor.deleteLeft());
    try std.testing.expectError(error.ReadOnly, editor.deleteRight());
    try std.testing.expectError(error.ReadOnly, editor.undo());
    try std.testing.expectError(error.ReadOnly, editor.redo());
    try std.testing.expectError(error.ReadOnly, editor.insertTab());
    try std.testing.expectError(error.ReadOnly, editor.indentLines());
    try std.testing.expectError(error.ReadOnly, editor.outdentLines());
    try std.testing.expectError(error.ReadOnly, editor.toggleLineComment());
    try std.testing.expectError(error.ReadOnly, editor.formatDocument());
    try std.testing.expectError(error.ReadOnly, editor.save());
    var value = try editor.model.getValue(.TextDefined, true);
    defer value.deinit();
    try std.testing.expectEqualStrings("one\ntwo", value.items);

    // Navigation and selection still work on a read-only snapshot.
    try editor.moveDown(false);
    try editor.selectAll();

    editor.setReadOnly(false);
    const map = [_]?usize{ 10, null };
    editor.setLineNumberMap(&map);
    try std.testing.expectEqual(@as(?usize, 10), editor.displayLineNumber(1));
    try std.testing.expectEqual(@as(?usize, null), editor.displayLineNumber(2));
    editor.clearLineNumberMap();
    try std.testing.expectEqual(@as(?usize, 2), editor.displayLineNumber(2));

    // The status selection follows the display line map.
    editor.setLineNumberMap(&map);
    editor.setCursorPosition(.{ .lineNumber = 1, .column = 1 }) catch {};
    const target = editor.statusTarget();
    const status = target.selection(target.context);
    try std.testing.expectEqual(@as(usize, 10), status.line);
    editor.clearLineNumberMap();

    try std.testing.expectEqual(@as(usize, 6), editor.gutterWidth());
    editor.setLineDecorationsWidth(1);
    try std.testing.expectEqual(@as(usize, 7), editor.gutterWidth());
    try std.testing.expectEqual(@as(usize, 5), editor.foldCellColumn());
    try std.testing.expectEqual(@as(usize, 6), editor.quickDiffCellColumn());
}

test "Editor: gutter follows line-number and folding options" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // Defaults: five number cells and one folding cell.
    try std.testing.expectEqual(@as(usize, 6), editor.gutterWidth());
    try std.testing.expectEqual(@as(usize, 5), editor.gutterNumberWidth());
    try std.testing.expectEqual(@as(usize, 5), editor.foldCellColumn());
    try std.testing.expect(editor.hasFoldControl());

    // `editor.lineNumbers: off` removes the number cells but keeps folding.
    editor.setGutterOptions(false, 5, true);
    try std.testing.expectEqual(@as(usize, 1), editor.gutterWidth());
    try std.testing.expectEqual(@as(usize, 0), editor.gutterNumberWidth());
    try std.testing.expect(editor.hasFoldControl());

    // `editor.lineNumbersMinChars` widens a short line-number column.
    editor.setGutterOptions(true, 3, true);
    try std.testing.expectEqual(@as(usize, 4), editor.gutterWidth());
    try std.testing.expectEqual(@as(usize, 3), editor.gutterNumberWidth());

    // Folding disabled removes the fold cell.
    editor.setGutterOptions(true, 3, false);
    try std.testing.expectEqual(@as(usize, 3), editor.gutterWidth());
    try std.testing.expect(!editor.hasFoldControl());

    editor.setGutterOptions(true, 5, true);
    try std.testing.expectEqual(@as(usize, 6), editor.gutterWidth());
}

test "Editor: reveal centers, tops and bottoms a line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\n" ++
        "line10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19";
    var editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 7);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // textHeight is six rows. Line 10's box middle is 9.5, so the desired
    // zero-based top is floor(9.5 - 3) = 6 (one-based top 7).
    try std.testing.expect(editor.revealLine(10, .Center));
    try std.testing.expectEqual(@as(usize, 7), editor.topViewLine());

    // Top places the line at the first view row.
    try std.testing.expect(editor.revealLine(10, .Top));
    try std.testing.expectEqual(@as(usize, 10), editor.topViewLine());

    // Bottom keeps one row below the revealed line, matching upstream's
    // Simple/Bottom padding.
    try std.testing.expect(editor.revealLine(10, .Bottom));
    try std.testing.expectEqual(@as(usize, 6), editor.topViewLine());

    // A visible line under Default does not move the viewport.
    try std.testing.expect(!editor.revealLine(10, .Simple));
    try std.testing.expectEqual(@as(usize, 6), editor.topViewLine());

    // An off-screen line scrolls minimally, again leaving the padded row.
    try std.testing.expect(editor.setTopViewLine(1));
    try std.testing.expect(editor.revealLine(10, .Simple));
    try std.testing.expectEqual(@as(usize, 6), editor.topViewLine());
}

test "Editor: cursorMove by wrapped line and viewport center" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten";
    var editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 7);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(2, 1));
    const down = CursorMoveCommands.parse("down", "wrappedLine", false, 1, false).?;
    try std.testing.expect(try editor.cursorMove(down));
    try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().lineNumber);

    const select_down = CursorMoveCommands.parse("down", "line", true, 1, false).?;
    try std.testing.expect(try editor.cursorMove(select_down));
    try std.testing.expect(editor.modelSelection().isEmpty() == false);

    try editor.setCursorPosition(Position.init(1, 1));
    try std.testing.expect(editor.setTopViewLine(5));
    const center = CursorMoveCommands.parse("viewPortCenter", "line", false, 1, false).?;
    try std.testing.expect(try editor.cursorMove(center));
    // Visible model lines are 5..10; the center is line 8.
    try std.testing.expectEqual(@as(usize, 8), editor.modelCursorPosition().lineNumber);
}

test "Editor: manual fold ranges are created and removed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.refreshFoldingIfDirty();
    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 4, 1)});
    try editor.createFoldingRangeFromSelection();
    try std.testing.expectEqual(folding.FoldState.collapsed, editor.foldStateAtModelLine(1));
    const folded_count = editor.viewLineCount();
    try std.testing.expect(folded_count < 5);

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 1)});
    try editor.removeManualFoldingRanges();
    try std.testing.expectEqual(folding.FoldState.expanded, editor.foldStateAtModelLine(1));
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
}

test "Editor: one undo group covers an insert session with newlines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "a", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 2));
    editor.beginUndoGroup();
    try editor.insertText("b");
    try editor.newline();
    try editor.insertText("c");
    editor.endUndoGroup();

    var value = try editor.model.getValue(.LF, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("ab\nc", value.items);

    try editor.undo();
    var undone = try editor.model.getValue(.LF, false);
    defer undone.deinit();
    try std.testing.expectEqualStrings("a", undone.items);
    try std.testing.expectEqual(Position.init(1, 2), editor.modelCursorPosition());

    try editor.redo();
    var redone = try editor.model.getValue(.LF, false);
    defer redone.deinit();
    try std.testing.expectEqualStrings("ab\nc", redone.items);
}

test "Editor: logical-line movement preserves the visible column" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdef\nab\nabcdef", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 6));
    try editor.moveLogicalLine(true, false, 1);
    try std.testing.expectEqual(Position.init(2, 3), editor.modelCursorPosition());

    try editor.moveLogicalLine(true, false, 1);
    try std.testing.expectEqual(Position.init(3, 6), editor.modelCursorPosition());

    try editor.moveLogicalLine(false, false, 1);
    try std.testing.expectEqual(Position.init(2, 3), editor.modelCursorPosition());
    try editor.moveLogicalLine(false, false, 1);
    try std.testing.expectEqual(Position.init(1, 6), editor.modelCursorPosition());
}

test "Editor: logical-line selection carries the desired column" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdef\nab\nabcdef", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setCursorPosition(Position.init(1, 6));
    try editor.moveLogicalLine(true, true, 1);
    const selection = editor.modelSelection();
    try std.testing.expectEqual(Position.init(1, 6), selection.getStartPosition());
    try std.testing.expectEqual(Position.init(2, 3), selection.getEndPosition());
}

test "JSON synchronizes once per shared document and follows its language" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try json_language.Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();
    const editor = try Editor.createFromText(allocator, time_compat.io, "{}", "events.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.setJsonLanguageClient(client);
    try std.testing.expect(editor.document.json.uri == null);
    try editor.insertText(" ");
    try std.testing.expectEqual(@as(u32, 0), editor.document.json_version);

    try editor.setLanguage("json");
    const uri = editor.document.json.uri.?;
    try std.testing.expectEqual(editor.model.getVersionId(), editor.document.json_version);
    {
        const split = try Editor.createViewFromEditor(editor, 40, 8);
        defer {
            split.deinit();
            allocator.destroy(split);
        }
        split.setJsonLanguageClient(client);
        try std.testing.expect(uri.ptr == split.document.json.uri.?.ptr);
        try split.insertText(" ");
        try std.testing.expectEqual(split.model.getVersionId(), editor.document.json_version);
    }
    try std.testing.expect(editor.document.json.uri.?.ptr == uri.ptr);
    try editor.setLanguage("jsonc");
    try std.testing.expect(editor.document.json.uri != null);
    try editor.setLanguage("zig");
    try std.testing.expect(editor.document.json.uri == null);
    const last_json_version = editor.document.json_version;
    try editor.insertText(" ");
    try std.testing.expectEqual(last_json_version, editor.document.json_version);
}

test "JSON incremental edits use pre-edit UTF-16 ranges and discard cancelled outline replies" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const a = std.testing.allocator;
    const client = try json_language.Client.start(a, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();
    const editor = try Editor.createFromText(a, time_compat.io, "{\"😀key\":1,\"é\":2}", "ranges.json", 80, 12);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    editor.setJsonLanguageClient(client);
    const Sink = struct {
        calls: usize = 0,
        correct: bool = false,
        fn ready(ctx: *anyopaque, symbols: []const languages.DocumentSymbol) void {
            const sink: *@This() = @ptrCast(@alignCast(ctx));
            sink.calls += 1;
            sink.correct = symbols.len == 2 and std.mem.eql(u8, symbols[0].name, "A") and std.mem.eql(u8, symbols[1].name, "猫");
        }
    };
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var sink = Sink{};
    const callback = languages.DocumentSymbolCallback{ .context = &sink, .complete = Sink.ready };
    const stale = (try Editor.requestJsonSymbols(editor.document, scratch.allocator(), editor.model, callback)).?;
    stale.dispose();
    const edits = [_]TextEdit{
        .{ .range = Range.init(1, 3, 1, 10), .text = "A" },
        .{ .range = Range.init(1, 15, 1, 17), .text = "猫" },
    };
    try editor.applyTextEdits(&edits, &.{});
    const handle = try Editor.requestJsonSymbols(editor.document, scratch.allocator(), editor.model, callback);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(0, sink.calls);
    while (sink.calls == 0) try std.testing.expect(client.dispatchResponses(true));
    try std.testing.expect(sink.correct);
    try std.testing.expectEqual(1, sink.calls);
}

test "wrapped view lines retain immutable text through edits and undo" {
    const a = std.testing.allocator;
    const editor = try Editor.createFromText(a, time_compat.io, "abcdef0123456789\nsecond", "cached.txt", 10, 10);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    const before = try editor.model.acquireLineContent(1);
    defer before.release();
    var tokens = try editor.model.tokenization().getLineTokens(1);
    defer tokens.deinit();
    var retained = try tokens.retainForView(a);
    defer retained.deinit();
    try std.testing.expect(retained.shared_text == before);
    try editor.insertText("X");
    const after = try editor.model.acquireLineContent(1);
    defer after.release();
    try std.testing.expect(after != before);
    try std.testing.expectEqualStrings("abcdef0123456789", retained.getLineContent());
    try std.testing.expectEqualStrings("Xabcdef0123456789", after.text.items);
    try editor.undo();
    const undone = try editor.model.acquireLineContent(1);
    defer undone.release();
    try std.testing.expectEqualStrings(before.text.items, undone.text.items);
    try std.testing.expectEqualStrings("Xabcdef0123456789", after.text.items);
}
