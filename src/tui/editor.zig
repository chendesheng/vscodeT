const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Emitter = @import("../vs/base/common/event.zig").Emitter;

const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../vs/editor/common/model.zig").TextModelCreationOptions;
const PositionAffinity = @import("../vs/editor/common/model.zig").PositionAffinity;
const IdentifiedSingleEditOperation = @import("../vs/editor/common/model.zig").IdentifiedSingleEditOperation;
const ValidEditOperation = @import("../vs/editor/common/model.zig").ValidEditOperation;
const CursorStateComputer = @import("../vs/editor/common/model/editStack.zig").CursorStateComputer;
const UndoRedoService = @import("../vs/platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const LanguageService = @import("../vs/editor/common/services/languageService.zig").LanguageService;
const LanguageIdCodec = @import("../vs/editor/common/languages.zig").LanguageIdCodec;
const ProjectedViewModelLines = @import("../vs/editor/common/viewModel/viewModelLines.zig").ProjectedViewModelLines;
const CoordinatesConverter = @import("../vs/editor/common/viewModel/viewModelLines.zig").CoordinatesConverter;
const ViewLineData = @import("../vs/editor/common/viewModel.zig").ViewLineData;
const WordBreak = @import("../vs/editor/common/modelLineProjectionData.zig").WordBreak;
const WrappingIndent = @import("../vs/editor/common/config/editorOptions.zig").WrappingIndent;
const cursorCommon = @import("../vs/editor/common/cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const CursorContext = @import("../vs/editor/common/cursor/cursorContext.zig").CursorContext;
const CursorState = cursorCommon.CursorState;
const PartialCursorState = cursorCommon.PartialCursorState;
const EditOperationType = cursorCommon.EditOperationType;
const CursorCollection = @import("../vs/editor/common/cursor/cursorCollection.zig").CursorCollection;
const TextModelCursorSimpleModel = @import("../vs/editor/common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const CursorMoveCommands = @import("../vs/editor/common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const CursorMoveDirection = @import("../vs/editor/common/cursor/cursorMoveCommands.zig").Direction;
const CursorMoveUnit = @import("../vs/editor/common/cursor/cursorMoveCommands.zig").Unit;
const CursorWordDirection = @import("../vs/editor/common/cursor/cursorMoveCommands.zig").WordDirection;
const DeleteOperations = @import("../vs/editor/common/cursor/cursorDeleteOperations.zig").DeleteOperations;
const TypeWithoutInterceptorsOperation = @import("../vs/editor/common/cursor/cursorTypeEditOperations.zig").TypeWithoutInterceptorsOperation;
const EditOperationResult = cursorCommon.EditOperationResult;

const WordCharacterClassifier = @import("../vs/editor/common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const DefaultWordSeparators = @import("../vs/editor/common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const InternalModelContentChangeEvent = @import("../vs/editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const String = @import("../vs/base/common/strings.zig").String;
const strings = @import("../vs/base/common/strings.zig");
const eolToString = @import("../vs/editor/common/core/misc/eolCounter.zig").eolToString;
const language = @import("./language.zig");
const language_configuration = @import("../vs/editor/common/languages/languageConfiguration.zig");
const encoding_mod = @import("../vs/workbench/services/textfile/common/encoding.zig");
const EOL = @import("../vs/editor/common/core/misc/eolCounter.zig").EOL;
const editor_status = @import("../vs/workbench/browser/parts/editor/editorStatus.zig");
const editor_common = @import("../vs/editor/common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const command_runner = @import("../vs/editor/common/commands/commandRunner.zig");
const ReplaceCommandCommand = @import("../vs/editor/common/commands/replaceCommand.zig").ReplaceCommand;
const lines_ops = @import("../vs/editor/contrib/linesOperations/browser/linesOperations.zig");
const line_selection = @import("../vs/editor/contrib/lineSelection/browser/lineSelection.zig");
const LineCommentCommand = @import("../vs/editor/contrib/comment/browser/lineCommentCommand.zig").LineCommentCommand;
const CommentType = @import("../vs/editor/contrib/comment/browser/lineCommentCommand.zig").Type;
const BlockCommentCommand = @import("../vs/editor/contrib/comment/browser/blockCommentCommand.zig").BlockCommentCommand;
const InsertFinalNewLineCommand = @import("../vs/editor/contrib/insertFinalNewLine/browser/insertFinalNewLineCommand.zig").InsertFinalNewLineCommand;
const bracket_matching = @import("../vs/editor/contrib/bracketMatching/browser/bracketMatching.zig");
const BracketMatchingController = bracket_matching.BracketMatchingController;
const folding = @import("../vs/editor/contrib/folding/browser/folding.zig");
const FoldingRules = @import("../vs/editor/common/languages/languageConfiguration.zig").FoldingRules;
const language_configuration_service = @import("./languageConfiguration.zig");
const completion = @import("../vs/editor/common/languages/completion.zig");
const CancellationToken = @import("../vs/base/common/cancellation.zig").CancellationToken;
const extensions_registry = @import("../vs/workbench/services/extensions/common/extensionsRegistry.zig");
const language_config_point = @import("../vs/workbench/services/language/common/languageConfigurationExtensionPoint.zig");
const text_mate_tokenizer = @import("../vs/editor/common/model/tokens/textMateTokenizer.zig");
const json_language = @import("../vs/workbench/services/language/common/jsonLanguageClient.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const languagesAssociations = @import("../vs/editor/common/services/languagesAssociations.zig");
const input = @import("ui").input;
const keybinding_service = @import("./keybindingService.zig");
const key_codes = @import("../vs/base/common/keyCodes.zig");
const keybinding_registry = @import("../vs/platform/keybinding/common/keybindingsRegistry.zig");
const CommandRegistry = @import("../vs/platform/commands/common/commands.zig").CommandRegistry;
const ShiftCommand = @import("../vs/editor/common/commands/shiftCommand.zig").ShiftCommand;
const IShiftCommandOpts = @import("../vs/editor/common/commands/shiftCommand.zig").IShiftCommandOpts;
const indentation_commands = @import("../vs/editor/contrib/indentation/browser/indentation.zig");
const IndentationToSpacesCommand = indentation_commands.IndentationToSpacesCommand;
const IndentationToTabsCommand = indentation_commands.IndentationToTabsCommand;
const ISingleEditOperation = @import("../vs/editor/common/core/editOperation.zig").ISingleEditOperation;
const multicursor = @import("../vs/editor/contrib/multicursor/browser/multicursor.zig");
const auto_closing = @import("../vs/editor/common/cursor/autoClosing.zig");
const CharacterPairSupport = @import("../vs/editor/common/languages/supports/characterPair.zig");
const smart_select = @import("../vs/editor/contrib/smartSelect/browser/smartSelect.zig");
const in_place_replace = @import("../vs/editor/contrib/inPlaceReplace/browser/inPlaceReplace.zig");
const InPlaceReplaceCommand = @import("../vs/editor/contrib/inPlaceReplace/browser/inPlaceReplaceCommand.zig").InPlaceReplaceCommand;
const model_module = @import("../vs/editor/common/model.zig");
const ModelDecorationOptions = model_module.ModelDecorationOptions;
const ModelDeltaDecoration = model_module.ModelDeltaDecoration;

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

pub const TextEdit = struct {
    range: Range,
    text: []const u8,
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

pub const Editor = struct {
    allocator: Allocator,
    io: Io,
    path: []u8,
    model: *TextModel,
    encoding: encoding_mod.Encoding = .utf8,
    undo_redo: *UndoRedoService,
    codec: *LanguageIdCodec,
    language_service: *LanguageService,
    /// Owns the strings of the configured `files.associations` patterns; the
    /// language service stores slices into this arena.
    associations_arena: std.heap.ArenaAllocator,
    view_lines: ProjectedViewModelLines,
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
    smart_select: smart_select.SmartSelectController,
    in_place_replace_deadline: ?i64,
    language_config_service: *language_configuration_service.Service,
    character_pair: ?CharacterPairSupport,
    multicursor_session: ?multicursor.SearchSession,
    after_edit: AfterEditComputer,
    saved_version: u32,
    /// Last observed dirty state. Content changes and saves fire
    /// `on_did_change_dirty` only when this flips, so tab labels can follow
    /// the editor without polling.
    dirty_state: bool,
    /// True when the file changed on disk while this editor had unsaved edits.
    conflict: bool = false,
    working_copy_dirty_listeners: std.array_list.Managed(ChangeListener),
    working_copy_content_listeners: std.array_list.Managed(ChangeListener),
    working_copy_save_listeners: std.array_list.Managed(ChangeListener),
    on_did_change_dirty: Emitter(void),
    screen_width: usize,
    screen_height: usize,
    /// The screen height includes a one-row status line when true. The
    /// multi-group workbench uses a workbench-level status bar and disables
    /// this fallback row for its editor panes.
    status_row: bool,
    gutter_width: usize,
    /// Rightmost columns reserved by the view for the overview ruler and
    /// scrollbar. Zero for the read-only preview and for editors used without
    /// the TUI view.
    scrollbar_width: usize,
    top_view_line: usize,
    status: [MAX_STATUS]u8,
    status_len: usize,
    quit_armed: bool,
    close_tab_armed: bool,
    prev_edit_operation_type: EditOperationType,
    pending_selection: [8]Selection,
    pending_selection_count: usize,
    tokens_need_refresh: bool,
    /// Whether multi-cursor paste spreads clipboard lines over cursors. The
    /// terminal has no settings service yet; upstream's default is `spread`.
    multi_cursor_paste_spread: bool = true,
    /// Ctrl/Alt character shortcuts are resolved through the ported keybinding
    /// registry; text editing itself stays on the editor methods below.
    keybindings: ?*keybinding_service.KeybindingService = null,
    shortcut_commands: CommandRegistry,
    /// Find controller hooks, installed by the per-tab controllers.
    find_context: ?*anyopaque = null,
    find_start_fn: ?*const fn (context: *anyopaque, replace: bool) anyerror!void = null,
    declarative: ?*const extensions_registry.Registry = null,
    declarative_arena: std.heap.ArenaAllocator,
    json_client: ?*json_language.Client = null,
    json_uri: ?[]u8 = null,
    json_version: u32 = 0,
    json_attached: bool = false,
    json_error_count: usize = 0,
    json_warning_count: usize = 0,
    json_message: ?[]u8 = null,

    pub fn create(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, null, null);
    }

    pub fn createWithDeclarative(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const extensions_registry.Registry,
    ) !*Editor {
        return createInternal(allocator, io, path, width, height, null, declarative);
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
        const editor = try createInternal(allocator, io, path, width, height, null, declarative);
        editor.json_client = json_client;
        editor.attachJsonLanguage() catch {};
        return editor;
    }

    pub fn createFromText(allocator: Allocator, io: Io, text: []const u8, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, text, null);
    }

    fn createInternal(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize, text: ?[]const u8, declarative: ?*const extensions_registry.Registry) !*Editor {
        const editor = try allocator.create(Editor);
        errdefer allocator.destroy(editor);

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
                });
            }
        }

        // Path matching goes through the ported language associations, which the
        // service derives from the registered language contributions.
        const language_id = language_service.guessLanguageIdByFilepathOrFirstLine(path, null) orelse "plaintext";
        try codec.register(language_id);

        var declarative_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer declarative_arena.deinit();

        var language_config = language_configuration.empty();
        var has_language_config = false;
        if (declarative) |registry| {
            if (registry.language(language_id)) |contribution| {
                if (contribution.configuration) |relative| {
                    if (language_config_point.load(declarative_arena.allocator(), contribution.root, relative)) |config| {
                        language_config = config;
                        has_language_config = true;
                    } else |_| {}
                }
                if (registry.grammarForLanguage(language_id)) |grammar| {
                    registerDeclarativeGrammar(io, allocator, contribution.root, grammar);
                }
            }
        }
        if (!has_language_config) {
            if (language.commentRuleFor(language_id)) |comments| {
                language_config.comments = comments;
                has_language_config = true;
            }
            if (language.bracketsFor(language_id)) |brackets| {
                language_config.brackets = brackets;
                has_language_config = true;
            }
            if (language.foldingRulesFor(language_id)) |rules| {
                language_config.folding = rules;
                has_language_config = true;
            }
        }
        if (has_language_config) {
            try language_service.registerLanguageConfiguration(language_id, language_config);
        }

        const language_config_service = try allocator.create(language_configuration_service.Service);
        errdefer allocator.destroy(language_config_service);
        language_config_service.* = try language_configuration_service.Service.init(allocator, language_service);
        errdefer language_config_service.deinit();

        const undo_redo = try allocator.create(UndoRedoService);
        errdefer allocator.destroy(undo_redo);
        undo_redo.* = UndoRedoService.init(allocator);
        errdefer undo_redo.deinit();

        var encoding: encoding_mod.Encoding = .utf8;
        const model = try createModel(allocator, io, path, language_id, undo_redo, language_service, text, &encoding);
        errdefer {
            model.deinit();
            allocator.destroy(model);
        }

        const resolved = model.getOptions();
        const gutter = gutterWidthFor(model.getLineCount());
        const text_width = @max(1, width - gutter);

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

        const cursor_config = CursorConfiguration{
            .tabSize = resolved.tabSize,
            .indentSize = resolved.indentSize,
            .insertSpaces = resolved.insertSpaces,
            .pageSize = @max(1, height - 1),
        };

        editor.* = Editor{
            .allocator = allocator,
            .io = io,
            .path = path_copy,
            .model = model,
            .encoding = encoding,
            .undo_redo = undo_redo,
            .codec = codec,
            .language_service = language_service,
            .associations_arena = std.heap.ArenaAllocator.init(allocator),
            .view_lines = view_lines,
            .converter = undefined,
            .cursor_config = cursor_config,
            .cursor_context = null,
            .cursors = null,
            .model_adapter = TextModelCursorSimpleModel.init(allocator, model),
            .word_separators = word_separators,
            .bracket_matching = BracketMatchingController.init(allocator, model),
            .folding = undefined,
            .folding_dirty = false,
            .smart_select = smart_select.SmartSelectController.init(allocator, &.{}, .{}),
            .in_place_replace_deadline = null,
            .language_config_service = language_config_service,
            .character_pair = character_pair,
            .multicursor_session = null,
            .after_edit = .{ .model = model },
            .saved_version = model.getAlternativeVersionId(),
            .dirty_state = false,
            .conflict = false,
            .working_copy_dirty_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .working_copy_content_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .working_copy_save_listeners = std.array_list.Managed(ChangeListener).init(allocator),
            .on_did_change_dirty = Emitter(void).init(allocator),
            .screen_width = @max(width, 1),
            .screen_height = @max(height, 1),
            .status_row = true,
            .gutter_width = gutter,
            .scrollbar_width = 0,
            .top_view_line = 1,
            .status = undefined,
            .status_len = 0,
            .quit_armed = false,
            .close_tab_armed = false,
            .prev_edit_operation_type = .Other,
            .pending_selection = undefined,
            .pending_selection_count = 0,
            .tokens_need_refresh = false,
            .keybindings = null,
            .shortcut_commands = CommandRegistry.init(allocator),
            .find_context = null,
            .find_start_fn = null,
            .declarative = declarative,
            .declarative_arena = declarative_arena,
            .json_client = null,
        };
        editor.converter = CoordinatesConverter.init(&editor.view_lines);
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

        const folding_controller = try folding.Controller.init(allocator, model, &editor.view_lines);
        errdefer folding_controller.deinit();
        editor.folding = folding_controller;
        try editor.refreshFoldingRules();
        try editor.refreshFolding();

        try model.onDidChangeContentWithContext(editor, contentChangedCallback);

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

    fn ensureShortcutKeybindings(self: *Editor) !void {
        if (self.keybindings != null) return;

        for (shortcut_specs) |spec| {
            try self.shortcut_commands.register(.{
                .id = spec.id,
                .context = self,
                .run = spec.run,
            });
        }

        const service = try keybinding_service.KeybindingService.init(self.allocator, &shortcut_keybinding_rules, .{
            .context = self,
            .execute = executeShortcutCommand,
        });
        self.keybindings = service;
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
        self.json_client = client;
        self.attachJsonLanguage() catch |err| self.setMessage("JSON attach failed: {s}", .{@errorName(err)});
    }

    pub fn pollJsonLanguage(self: *Editor) bool {
        if (self.json_client == null) return false;
        if (!self.json_attached) {
            self.attachJsonLanguage() catch |err| {
                self.setMessage("JSON attach failed: {s}", .{@errorName(err)});
                return true;
            };
            return true;
        }
        const version = self.model.getVersionId();
        if (version == self.json_version) return false;
        self.syncJsonDocument() catch return false;
        return true;
    }

    fn attachJsonLanguage(self: *Editor) !void {
        const client = self.json_client orelse return;
        const language_id = self.languageId();
        if (!std.mem.eql(u8, language_id, "json") and !std.mem.eql(u8, language_id, "jsonc")) return;
        if (self.json_uri != null) return;
        const absolute = if (std.fs.path.isAbsolute(self.path))
            try self.allocator.dupe(u8, self.path)
        else
            try std.fs.path.resolve(self.allocator, &.{self.path});
        defer self.allocator.free(absolute);
        const uri = try fileUri(self.allocator, absolute);
        errdefer self.allocator.free(uri);
        const text = try self.model.getValue(.LF, false);
        defer text.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        try client.didOpen(arena.allocator(), uri, language_id, text.items);
        self.json_uri = uri;
        self.json_attached = true;
        self.json_version = self.model.getVersionId();
        try self.pullJsonDiagnostics();
    }

    fn syncJsonDocument(self: *Editor) !void {
        const client = self.json_client orelse return;
        const uri = self.json_uri orelse return;
        const text = try self.model.getValue(.LF, false);
        defer text.deinit();
        const version = self.model.getVersionId();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        try client.didChange(arena.allocator(), uri, version, text.items);
        self.json_version = version;
        try self.pullJsonDiagnostics();
    }

    fn pullJsonDiagnostics(self: *Editor) !void {
        const client = self.json_client orelse return;
        const uri = self.json_uri orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const diagnostics = try client.pullDiagnostics(arena.allocator(), uri);
        self.json_error_count = 0;
        self.json_warning_count = 0;
        var first_message: ?[]const u8 = null;
        for (diagnostics) |diagnostic| {
            if (diagnostic.severity <= 2) {
                self.json_error_count += 1;
                if (first_message == null) first_message = diagnostic.message;
            } else {
                self.json_warning_count += 1;
                if (first_message == null) first_message = diagnostic.message;
            }
        }
        if (self.json_message) |old_message| {
            self.allocator.free(old_message);
            self.json_message = null;
        }
        if (first_message) |diagnostic_message| {
            self.json_message = try self.allocator.dupe(u8, diagnostic_message);
            self.setMessage("JSON {d} error(s), {d} warning(s): {s}", .{
                self.json_error_count,
                self.json_warning_count,
                self.json_message.?,
            });
        } else if (std.mem.startsWith(u8, self.message(), "JSON ")) {
            self.clearMessage();
        }
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
        const client = self.json_client orelse return .{};
        const uri = self.json_uri orelse return .{};
        if (self.model.getVersionId() != self.json_version) {
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

    /// Applies declarative language contributions to an editor created before
    /// the extension scan completed.
    pub fn applyDeclarativeExtensions(self: *Editor, registry: *const extensions_registry.Registry) !void {
        self.declarative = registry;
        for (registry.languages) |contribution| {
            try self.language_service.registerLanguage(.{
                .id = contribution.id,
                .aliases = contribution.aliases,
                .extensions = contribution.extensions,
                .filenames = contribution.filenames,
                .filenamePatterns = contribution.filename_patterns,
            });
        }
        if (registry.language(self.languageId())) |contribution| {
            if (contribution.configuration) |relative| {
                if (language_config_point.load(self.declarative_arena.allocator(), contribution.root, relative)) |config| {
                    try self.language_service.registerLanguageConfiguration(self.languageId(), config);
                } else |_| {}
            }
            if (registry.grammarForLanguage(self.languageId())) |grammar| {
                registerDeclarativeGrammar(self.io, self.allocator, contribution.root, grammar);
            }
        }
        if (self.language_service.guessLanguageIdByFilepathOrFirstLine(self.path, null)) |guessed| {
            if (!std.mem.eql(u8, guessed, self.languageId())) try self.setLanguage(guessed);
        }
    }

    pub fn deinit(self: *Editor) void {
        self.folding.deinit();
        if (self.cursors) |*cursors| cursors.deinit();
        if (self.cursor_context) |context| self.allocator.destroy(context);
        self.model_adapter.deinit();
        self.bracket_matching.deinit();
        self.smart_select.deinit();
        self.language_config_service.deinit();
        self.allocator.destroy(self.language_config_service);
        self.declarative_arena.deinit();
        if (self.json_uri) |uri| self.allocator.free(uri);
        if (self.json_message) |json_message| self.allocator.free(json_message);
        if (self.multicursor_session) |*session| session.deinit();
        self.word_separators.deinit();
        self.view_lines.deinit();
        self.model.deinit();
        self.allocator.destroy(self.model);
        self.undo_redo.deinit();
        self.allocator.destroy(self.undo_redo);
        self.working_copy_dirty_listeners.deinit();
        self.working_copy_content_listeners.deinit();
        self.working_copy_save_listeners.deinit();
        self.associations_arena.deinit();
        self.language_service.deinit();
        self.allocator.destroy(self.language_service);
        self.codec.deinit();
        self.allocator.destroy(self.codec);
        if (self.keybindings) |service| service.deinit();
        self.shortcut_commands.deinit();
        self.on_did_change_dirty.deinit();
        self.allocator.free(self.path);
    }

    fn contentChangedCallback(event: InternalModelContentChangeEvent, editor: *Editor) anyerror!void {
        editor.onModelContentChanged(event);
    }

    fn onModelContentChanged(self: *Editor, event: InternalModelContentChangeEvent) void {
        if (event.rawContentChangedEvent.isUndoing or event.rawContentChangedEvent.isRedoing) {
            if (event.rawContentChangedEvent.resultingSelection) |selections| {
                const count = @min(selections.len, self.pending_selection.len);
                for (selections[0..count], 0..) |selection, i| self.pending_selection[i] = selection;
                self.pending_selection_count = count;
            }
        }
        self.refreshDirtyState();
        self.folding_dirty = true;
        for (self.working_copy_content_listeners.items) |listener| listener.callback(listener.context);
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

    pub fn textHeight(self: *const Editor) usize {
        const reserved: usize = if (self.status_row) 1 else 0;
        return @max(@as(usize, 1), self.screen_height -| reserved);
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
        return self.top_view_line;
    }

    pub fn gutterWidth(self: *const Editor) usize {
        return self.gutter_width;
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
        return self.model.getAlternativeVersionId() != self.saved_version;
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
        // A line-count change may leave the wrapping model one change behind;
        // rebuild it before a hidden range can point past its projections.
        self.ensureTokensVisible();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        try self.folding.refresh(selections);
        self.folding_dirty = false;
        try self.applyFoldingVisibility();
    }

    /// Applies the fold controller's hidden ranges to the view model and keeps
    /// selections out of them, mirroring `onHiddenRangesChanges`.
    fn applyFoldingVisibility(self: *Editor) !void {
        // Keep the model line at the top of the viewport stable across the
        // mapping change. Revealing the cursor here would jump a scrolled
        // viewport back to the cursor whenever a fold is toggled.
        const top_model_line = self.modelLineNumber(self.top_view_line);
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const adjusted = self.folding.adjustSelections(selections);
        const changed = try self.view_lines.setHiddenAreas(self.folding.hiddenRanges());
        if (changed or adjusted) {
            try self.cursorsRef().setSelections(self.allocator, selections);
        }
        if (changed) {
            const top_position = self.viewPositionOfModelPosition(Position.init(top_model_line, 1));
            _ = self.setTopViewLine(top_position.lineNumber);
        }
        if (adjusted) self.ensureCursorVisible();
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
        try self.folding.foldLine(self.modelCursorPosition().lineNumber);
        try self.applyFoldingVisibility();
    }

    pub fn unfoldAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        self.folding.unfoldLine(self.modelCursorPosition().lineNumber);
        try self.applyFoldingVisibility();
    }

    pub fn toggleFoldAtCursor(self: *Editor) !void {
        self.refreshFoldingIfDirty();
        try self.folding.toggleLine(self.modelCursorPosition().lineNumber, 1);
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
        _ = self.associations_arena.reset(.retain_capacity);
        const arena = self.associations_arena.allocator();
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

        const language_id = self.language_service.guessLanguageIdByFilepathOrFirstLine(self.path, null) orelse "plaintext";
        try self.setLanguage(language_id);
    }

    /// Switches the active language and refreshes the language-dependent
    /// services. Mirrors the model-language branch of the browser status item.
    pub fn setLanguage(self: *Editor, language_id: []const u8) !void {
        if (std.mem.eql(u8, language_id, self.model.getLanguageId())) return;

        self.model.setLanguage(language_id);
        try self.codec.register(language_id);

        var config = language_configuration.empty();
        var has_config = false;
        if (language.commentRuleFor(language_id)) |comments| {
            config.comments = comments;
            has_config = true;
        }
        if (language.bracketsFor(language_id)) |brackets| {
            config.brackets = brackets;
            has_config = true;
        }
        if (language.foldingRulesFor(language_id)) |rules| {
            config.folding = rules;
            has_config = true;
        }
        if (has_config) try self.language_service.registerLanguageConfiguration(language_id, config);
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
        self.folding_dirty = true;
    }

    pub fn getEncoding(self: *const Editor) encoding_mod.Encoding {
        return self.encoding;
    }

    pub fn setEncoding(self: *Editor, encoding: encoding_mod.Encoding) void {
        self.encoding = encoding;
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
        };
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
        return .{
            .line = position.lineNumber,
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
        return self.encoding;
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
        self.changeIndentation(tab_size, insert_spaces, display_only);
    }

    fn statusDetectIndentation(context: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(context));
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
        if (self.model.getEOL() == eol) return;
        self.model.pushStackElement();
        try self.model.pushEOL(eol);
        self.model.pushStackElement();
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
        const last = @min(self.top_view_line + self.textHeight() - 1, count);
        const model_line = @min(self.view_lines.getModelLineNumber(last), line_count);
        if (self.tokens_need_refresh) {
            const first_model_line = self.view_lines.getModelLineNumber(self.top_view_line);
            self.model.tokenization().forceRefreshRange(first_model_line, model_line);
            self.tokens_need_refresh = false;
        }
        self.model.forceTokenization(model_line);
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

    fn refreshLayout(self: *Editor) !void {
        const new_gutter = gutterWidthFor(self.model.getLineCount());
        const available = self.screen_width -| new_gutter;
        const text_width = @max(@as(usize, 1), available -| self.scrollbar_width);
        self.gutter_width = new_gutter;
        self.cursor_config.pageSize = self.textHeight();

        if (try self.view_lines.setWrappingColumn(text_width)) {
            try self.resetCursorViewState();
        }
    }

    fn resetCursorViewState(self: *Editor) !void {
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        try self.cursorsRef().setSelections(self.allocator, selections);
    }

    pub fn ensureCursorVisible(self: *Editor) void {
        const position = self.viewCursorPosition();
        const height = self.textHeight();
        if (position.lineNumber < self.top_view_line) {
            self.top_view_line = position.lineNumber;
        } else if (position.lineNumber >= self.top_view_line + height) {
            self.top_view_line = position.lineNumber - height + 1;
        }
        const max_top = self.maxTopViewLine();
        if (self.top_view_line < 1) self.top_view_line = 1;
        if (self.top_view_line > max_top) self.top_view_line = max_top;
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
        const current: isize = @intCast(@min(self.top_view_line, max_top));
        const max: isize = @intCast(max_top);
        const next = std.math.clamp(current + delta, 1, max);
        if (next == self.top_view_line) return false;
        self.top_view_line = @intCast(next);
        return true;
    }

    /// Sets the first visible view line without moving the cursor. Used by the
    /// terminal scrollbar, whose scroll position is expressed in lines.
    pub fn setTopViewLine(self: *Editor, line: usize) bool {
        const next = std.math.clamp(line, 1, self.maxTopViewLine());
        if (next == self.top_view_line) return false;
        self.top_view_line = next;
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

    fn closeTypingGroup(self: *Editor) void {
        self.model.pushStackElement();
        self.prev_edit_operation_type = .Other;
    }

    pub fn viewCursorStates(self: *Editor) ![]CursorState {
        return self.cursorsRef().getAll(self.allocator);
    }

    pub fn cursorCount(self: *Editor) usize {
        return self.cursorsRef().cursors.items.len;
    }

    pub fn removeSecondaryCursors(self: *Editor) !void {
        try self.cursorsRef().killSecondaryCursors();
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
        self.ensureCursorVisible();
    }

    pub fn addCursorBelow(self: *Editor) !void {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);
        const states = try multicursor.addCursorDown(self.allocator, &self.cursor_config, self.model_adapter.interface(), cursors);
        defer self.allocator.free(states);
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
        self.ensureCursorVisible();
    }

    pub fn selectNextOccurrence(self: *Editor) !void {
        var session = (try self.ensureMultiCursorSession()) orelse return;
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const result = try session.addSelectionToNext(self.model, selections) orelse return;
        defer self.allocator.free(result);
        try self.cursorsRef().setSelections(self.allocator, result);
        self.ensureCursorVisible();
    }

    pub fn selectAllOccurrences(self: *Editor) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        var session = (try multicursor.SearchSession.create(self.allocator, self.model, selections)) orelse return;
        defer session.deinit();

        const result = try session.selectAll(self.model) orelse return;
        defer self.allocator.free(result);
        try self.cursorsRef().setSelections(self.allocator, result);
        self.ensureCursorVisible();
    }

    fn cursorStatesCopy(self: *Editor) ![]CursorState {
        return self.cursorsRef().getAll(self.allocator);
    }

    fn applyCursorStates(self: *Editor, states: []PartialCursorState) !void {
        defer self.allocator.free(states);
        try self.cursorsRef().setStates(states);
        try self.cursorsRef().normalize();
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
        try self.cursorsRef().setSelections(self.allocator, &[_]Selection{selection});
        self.ensureCursorVisible();
    }

    pub fn cancelSelection(self: *Editor) !void {
        const cursor = self.cursorsRef().getPrimaryCursor();
        const partial = CursorMoveCommands.cancelSelection(cursor);
        try self.cursorsRef().setStates(&[_]PartialCursorState{partial});
        self.ensureCursorVisible();
    }

    fn executeReplaceCommands(self: *Editor, commands: []const ?cursorCommon.ReplaceCommand) !void {
        if (commands.len == 0) return;

        const before_selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(before_selections);

        var operations = ArrayList(IdentifiedSingleEditOperation).init(self.allocator);
        defer operations.deinit();
        for (commands) |command| {
            const cmd = command orelse continue;
            const text = if (cmd.text.len == 0) null else String.initBorrowed(cmd.text);
            try operations.append(IdentifiedSingleEditOperation.init(cmd.range, text));
        }
        if (operations.items.len == 0) return;

        const after_selections = try self.model.pushEditOperations(
            before_selections,
            operations.items,
            self.after_edit.state(),
            null,
        );

        try self.afterEdit();

        if (after_selections) |selections| {
            try self.cursorsRef().setSelections(self.allocator, selections);
        } else {
            try self.cursorsRef().setSelections(self.allocator, before_selections);
        }
        self.ensureCursorVisible();
    }

    fn afterEdit(self: *Editor) !void {
        self.tokens_need_refresh = true;
        try self.view_lines.rebuildAll();
        self.resetCursorViewState() catch {};
        try self.refreshLayout();
    }

    fn executeTypeResult(self: *Editor, result: EditOperationResult) !void {
        if (result.shouldPushStackElementBefore) self.model.pushStackElement();
        try self.executeReplaceCommands(result.commands);
        if (result.shouldPushStackElementAfter) self.model.pushStackElement();
        self.prev_edit_operation_type = result.type;
    }

    pub fn insertText(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        var result = try TypeWithoutInterceptorsOperation.getEdits(self.allocator, self.prev_edit_operation_type, selections, text);
        defer result.deinit(self.allocator);
        try self.executeTypeResult(result);
    }

    pub fn typeCharacter(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

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
        const eol = eolToString(self.model.getEOL());
        const position = self.modelCursorPosition();
        const line = try self.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const first_non_ws = strings.firstNonWhitespaceIndex(line.items) orelse line.items.len;
        const indent_end = @min(first_non_ws, position.column - 1);
        var buffer = ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.appendSlice(eol);
        try buffer.appendSlice(line.items[0..indent_end]);
        self.closeTypingGroup();
        try self.insertText(buffer.items);
        self.model.pushStackElement();
    }

    pub fn insertTab(self: *Editor) !void {
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
        try self.cursorsRef().setSelections(self.allocator, before);
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

        self.language_config_service.activate();
        for (selections, 0..) |selection, i| {
            commands[i] = ShiftCommand.init(self.allocator, selection, opts, self.language_config_service.interface());
            interfaces[i] = commands[i].interface();
        }

        try self.executeCommands(interfaces);
    }

    pub fn indentLines(self: *Editor) !void {
        try self.indentLinesImpl(false);
    }

    pub fn outdentLines(self: *Editor) !void {
        try self.indentLinesImpl(true);
    }

    pub fn reindentLines(self: *Editor) !void {
        self.closeTypingGroup();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        self.language_config_service.activate();
        var edits = try indentation_commands.reindentLines(
            arena_state.allocator(),
            self.model,
            self.language_config_service.interface(),
        );
        defer edits.deinit();
        if (edits.items.len == 0) return;

        try self.applyEditOperations(edits.items);
        self.model.pushStackElement();
    }

    pub fn reindentSelectedLines(self: *Editor) !void {
        self.closeTypingGroup();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        self.language_config_service.activate();
        var edits = try indentation_commands.reindentSelectedLines(
            arena_state.allocator(),
            self.model,
            self.language_config_service.interface(),
            selections,
        );
        defer edits.deinit();
        if (edits.items.len == 0) return;

        try self.applyEditOperations(edits.items);
        self.model.pushStackElement();
    }

    pub fn indentationToSpaces(self: *Editor) !void {
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
        indentation_commands.detectIndentation(self.model);
        self.refreshCursorOptions();
        self.ensureCursorVisible();
    }

    pub fn changeIndentation(self: *Editor, tab_size: usize, insert_spaces: bool, display_size_only: bool) void {
        indentation_commands.changeIndentation(self.model, tab_size, insert_spaces, display_size_only);
        self.refreshCursorOptions();
        self.ensureCursorVisible();
    }

    pub fn deleteLeft(self: *Editor) !void {
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
        if (result.shouldPushStackElementBefore) self.model.pushStackElement();
        try self.executeReplaceCommands(result.commands);
        self.prev_edit_operation_type = .DeletingLeft;
    }

    pub fn deleteRight(self: *Editor) !void {
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
        if (result.shouldPushStackElementBefore) self.model.pushStackElement();
        try self.executeReplaceCommands(result.commands);
        self.prev_edit_operation_type = .DeletingRight;
    }

    pub fn undo(self: *Editor) !void {
        self.model.pushStackElement();
        self.pending_selection_count = 0;
        self.model.undo() catch |err| {
            self.recoverWrapping();
            return err;
        };
        try self.afterUndoRedo();
    }

    pub fn redo(self: *Editor) !void {
        self.model.pushStackElement();
        self.pending_selection_count = 0;
        self.model.redo() catch |err| {
            self.recoverWrapping();
            return err;
        };
        try self.afterUndoRedo();
    }

    fn afterUndoRedo(self: *Editor) !void {
        self.tokens_need_refresh = true;
        try self.view_lines.rebuildAll();
        if (self.pending_selection_count > 0) {
            try self.cursorsRef().setSelections(self.allocator, self.pending_selection[0..self.pending_selection_count]);
            self.pending_selection_count = 0;
        } else {
            try self.resetCursorViewState();
        }
        try self.refreshLayout();
        self.ensureCursorVisible();
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

    fn applyCommandResult(self: *Editor, after: ?[]Selection) !void {
        const selections = after orelse return;
        defer self.allocator.free(selections);

        try self.afterEdit();
        try self.cursorsRef().setSelections(self.allocator, selections);
        self.ensureCursorVisible();
        self.model.pushStackElement();
    }

    fn executeCommands(self: *Editor, commands: []const ?ICommand) !void {
        const before = try self.getSelectionsCopy();
        defer self.allocator.free(before);

        const after = try command_runner.executeCommands(self.allocator, self.model, commands, before);
        try self.applyCommandResult(after);
    }

    pub fn moveLines(self: *Editor, down: bool) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.moveLines(self.allocator, self.model, selections, down);
        try self.applyCommandResult(after);
    }

    pub fn copyLines(self: *Editor, down: bool) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.copyLines(self.allocator, self.model, selections, down);
        try self.applyCommandResult(after);
    }

    pub fn sortLines(self: *Editor, descending: bool) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.sortLines(self.allocator, self.model, selections, descending);
        try self.applyCommandResult(after);
    }

    pub fn duplicateSelection(self: *Editor) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.duplicateSelection(self.allocator, self.model, selections);
        try self.applyCommandResult(after);
    }

    pub fn trimTrailingWhitespace(self: *Editor) !void {
        self.closeTypingGroup();
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);
        const after = try lines_ops.trimTrailingWhitespace(self.allocator, self.model, selections);
        try self.applyCommandResult(after);
    }

    pub fn setCursorPosition(self: *Editor, position: Position) !void {
        self.closeTypingGroup();
        try self.cursorsRef().setSelections(self.allocator, &[_]Selection{Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)});
        self.ensureCursorVisible();
    }

    /// Replaces the editor selection with one range. Used by find to put the
    /// selection on a match.
    pub fn setSelection(self: *Editor, range: Range) !void {
        self.closeTypingGroup();
        try self.cursorsRef().setSelections(self.allocator, &[_]Selection{
            Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn),
        });
        self.ensureCursorVisible();
    }

    pub fn setSelections(self: *Editor, selections: []const Selection) !void {
        self.closeTypingGroup();
        try self.cursorsRef().setSelections(self.allocator, selections);
        self.ensureCursorVisible();
    }

    /// Updates the selection during a mouse drag. The press already closed the
    /// typing group, so motion must not start a new undo stop per report.
    pub fn updateDragSelection(self: *Editor, anchor: Position, position: Position) !void {
        try self.cursorsRef().setSelections(self.allocator, &[_]Selection{
            Selection.init(anchor.lineNumber, anchor.column, position.lineNumber, position.column),
        });
        self.ensureCursorVisible();
    }

    /// Replaces one range through the command runner (no auto-closing or
    /// typing interceptors). The cursor lands at the end of the replaced text.
    pub fn replaceRange(self: *Editor, range: Range, text: []const u8) !void {
        self.closeTypingGroup();
        var command = ReplaceCommandCommand.init(range, text, false);
        try self.executeCommands(&[_]?ICommand{command.interface()});
    }

    /// Applies several edits atomically and places one cursor at each supplied
    /// position. Used by completion acceptance for additional text edits and
    /// multi-cursor inserts.
    pub fn applyTextEdits(self: *Editor, edits: []const TextEdit, cursors: []const Position) !void {
        if (edits.len == 0) {
            if (cursors.len > 0) {
                const selections = try self.allocator.alloc(Selection, cursors.len);
                defer self.allocator.free(selections);
                for (cursors, 0..) |position, index| {
                    selections[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
                }
                try self.cursorsRef().setSelections(self.allocator, selections);
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
            try self.cursorsRef().setSelections(self.allocator, selections);
        }
        self.ensureCursorVisible();
    }

    /// Applies a batch of edits and returns where each edit landed. The
    /// returned positions are computed against the fully applied document,
    /// mirroring the `textChange.newPosition` values the upstream snippet
    /// session receives from `executeEdits`.
    pub fn applyTextEditsWithPositions(self: *Editor, edits: []const TextEdit) ![]AppliedTextEdit {
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
        self.ensureCursorVisible();
    }

    /// Expands or shrinks every selection through the ported smart-select
    /// controller. Upstream drives this from `editor.action.smartSelect.*`.
    pub fn growSelection(self: *Editor, forward: bool) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const updated = (try self.smart_select.run(self.model, selections, forward)) orelse return;
        defer self.allocator.free(updated);
        try self.cursorsRef().setSelections(self.allocator, updated);
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
        self.in_place_replace_deadline = time_compat.milliTimestamp() + 350;
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

    /// Called from the app loop. Returns true when the decoration expired.
    pub fn inPlaceReplaceTick(self: *Editor, now_ms: i64) bool {
        const deadline = self.in_place_replace_deadline orelse return false;
        if (now_ms < deadline) return false;
        self.in_place_replace_deadline = null;
        self.clearInPlaceReplaceDecoration();
        return true;
    }

    /// Milliseconds until the replacement decoration expires, or null when no
    /// timer is pending.
    pub fn inPlaceReplacePollTimeout(self: *Editor, now_ms: i64) ?i64 {
        const deadline = self.in_place_replace_deadline orelse return null;
        return @max(0, deadline - now_ms);
    }

    /// Recomputes the bracket highlights for the current cursors. `has_focus`
    /// mirrors upstream's `hasWidgetFocus`: a focused widget hides the hints.
    pub fn updateBracketMatches(self: *Editor, has_focus: bool) ![]const bracket_matching.BracketsData {
        self.bracket_matching.has_focus = has_focus;
        const selections = try self.cursorsRef().getSelections(self.allocator);
        defer self.allocator.free(selections);
        return self.bracket_matching.updateBrackets(selections);
    }

    pub fn jumpToBracket(self: *Editor) !void {
        const selection = self.modelSelection();
        const target = self.bracket_matching.jumpToBracket(selection) orelse return;
        try self.cursorsRef().setSelections(self.allocator, &[_]Selection{target});
        self.ensureCursorVisible();
    }

    pub fn selectToBracket(self: *Editor, select_brackets: bool) !void {
        const selections = try self.getSelectionsCopy();
        defer self.allocator.free(selections);

        const selected = try self.bracket_matching.selectToBracket(selections, select_brackets) orelse return;
        defer self.allocator.free(selected);

        try self.cursorsRef().setSelections(self.allocator, selected);
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
        self.model.pushStackElement();
    }

    pub fn toggleLineComment(self: *Editor) !void {
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
        const selection = self.modelSelection();
        self.closeTypingGroup();

        var command = InsertFinalNewLineCommand.init(selection);
        try self.executeCommands(&[_]?ICommand{command.interface()});
    }

    /// Reloads the editor content from disk (used for external file changes).
    /// The cursor moves to the start; the reload itself is not undoable in the
    /// terminal editor because no working-copy model tracks the old state.
    pub fn reloadFromDisk(self: *Editor) !void {
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, self.path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);
        const encoding = if (encoding_mod.detectBOM(bytes)) |bom| bom.encoding else .utf8;
        const decoded = try encoding_mod.decode(self.allocator, bytes, encoding);
        defer self.allocator.free(decoded);
        self.encoding = encoding;

        var current = try self.model.getValue(.TextDefined, true);
        defer current.deinit();
        if (std.mem.eql(u8, current.items, decoded)) return;

        const last_line = self.model.getLineCount();
        const last_column = self.model.getLineMaxColumn(last_line);
        var operations = [_]IdentifiedSingleEditOperation{.init(
            Range.init(1, 1, last_line, last_column),
            if (decoded.len == 0) null else String.initBorrowed(decoded),
        )};
        _ = try self.model.applyEdits(&operations, false);
        self.saved_version = self.model.getAlternativeVersionId();
        self.clearConflict();
        self.refreshDirtyState();
        try self.setCursorPosition(Position.init(1, 1));
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
        self.conflict = true;
        self.setMessage("Conflict: file changed on disk", .{});
    }

    pub fn hasConflict(self: *const Editor) bool {
        return self.conflict;
    }

    pub fn clearConflict(self: *Editor) void {
        self.conflict = false;
        self.clearMessage();
    }

    pub fn save(self: *Editor) !void {
        const value = try self.model.getValue(.TextDefined, true);
        defer value.deinit();

        const cwd = Io.Dir.cwd();
        var exists = true;
        const maybe_file = cwd.openFile(self.io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                exists = false;
                break :blk null;
            },
            else => return err,
        };
        if (maybe_file) |file| file.close(self.io);

        var atomic = try cwd.createFileAtomic(self.io, self.path, .{ .replace = exists });
        defer atomic.deinit(self.io);
        const encoded = try encoding_mod.encode(self.allocator, value.items, self.encoding);
        defer self.allocator.free(encoded);
        try atomic.file.writeStreamingAll(self.io, encoded);
        if (exists) {
            try atomic.replace(self.io);
        } else {
            try atomic.link(self.io);
        }

        self.saved_version = self.model.getAlternativeVersionId();
        self.clearConflict();
        self.refreshDirtyState();
        for (self.working_copy_save_listeners.items) |listener| listener.callback(listener.context);
        self.setMessage("Saved {s}", .{self.path});
    }

    /// Escape behavior: drop secondary cursors first, otherwise cancel the
    /// current selection.
    pub fn cancelSelectionOrCursors(self: *Editor) !void {
        if (self.cursorCount() > 1) {
            return self.removeSecondaryCursors();
        }
        return self.cancelSelection();
    }

    pub fn requestQuit(self: *Editor) bool {
        if (!self.isDirty()) return true;
        if (self.quit_armed) return true;
        self.quit_armed = true;
        self.setMessage("Unsaved changes: Ctrl-Q again to quit, Ctrl-S to save", .{});
        return false;
    }

    pub fn clearQuitArmed(self: *Editor) void {
        self.quit_armed = false;
    }

    /// Asks before closing this editor's tab, mirroring the dirty check of the
    /// workbench's editor-part close. The first request arms; the second
    /// returns true.
    pub fn requestCloseTab(self: *Editor) bool {
        if (!self.isDirty()) return true;
        if (self.close_tab_armed) return true;
        self.close_tab_armed = true;
        self.setMessage("Unsaved changes: Ctrl-W again to close, Ctrl-S to save", .{});
        return false;
    }

    pub fn clearCloseTabArmed(self: *Editor) void {
        self.close_tab_armed = false;
    }
};

fn gutterWidthFor(line_count: usize) usize {
    var digits: usize = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(@as(usize, 3), digits + 1);
}

fn createModel(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    language_id: []const u8,
    undo_redo: *UndoRedoService,
    language_service: *LanguageService,
    text: ?[]const u8,
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
        .bracketPairColorizationOptions = .{ .enabled = false, .independentColorPoolPerBracketType = false },
    };

    const raw: []u8 = if (text) |content|
        try allocator.dupe(u8, content)
    else
        Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try allocator.alloc(u8, 0),
            else => return err,
        };
    defer allocator.free(raw);

    const encoding = if (encoding_mod.detectBOM(raw)) |bom| bom.encoding else .utf8;
    encoding_out.* = encoding;
    const decoded = try encoding_mod.decode(allocator, raw, encoding);
    defer allocator.free(decoded);
    var fixed = Io.Reader.fixed(decoded);
    return try TextModel.init(allocator, &fixed, language_id, options, null, undo_redo, language_service);
}

fn fileUri(allocator: Allocator, absolute_path: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("file://");
    for (absolute_path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(byte);
        } else {
            var escaped: [3]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&escaped, "%{X:0>2}", .{byte});
            try output.appendSlice(encoded);
        }
    }
    return output.toOwnedSlice();
}

fn registerDeclarativeGrammar(io: Io, allocator: Allocator, root: []const u8, grammar: extensions_registry.Grammar) void {
    const path = std.fs.path.join(allocator, &.{ root, grammar.path }) catch return;
    defer allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return;
    defer allocator.free(data);
    text_mate_tokenizer.registerGrammar(grammar.language, grammar.scope, data);
}

test "Editor: create, edit, undo, and render" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const View = @import("./view.zig").View;

    var editor = try Editor.createFromText(allocator, io, "hello world\nsecond line", "test.txt", 24, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqual(@as(usize, 2), editor.model.getLineCount());
    try std.testing.expect(editor.viewLineCount() >= 2);

    try editor.insertText("X");
    const edited = try editor.model.getLineContent(1);
    defer edited.deinit();
    try std.testing.expectEqualStrings("Xhello world", edited.items);

    try editor.undo();
    const undone = try editor.model.getLineContent(1);
    defer undone.deinit();
    try std.testing.expectEqualStrings("hello world", undone.items);
    try std.testing.expectEqual(Position.init(1, 1), editor.modelCursorPosition());

    try editor.redo();
    const redone = try editor.model.getLineContent(1);
    defer redone.deinit();
    try std.testing.expectEqualStrings("Xhello world", redone.items);
    try std.testing.expectEqual(Position.init(1, 2), editor.modelCursorPosition());

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "Editor: viewport reflows wrapping" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 8, 5);
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
    var editor = try Editor.createFromText(allocator, io, "abcdefghijk", "test.txt", 14, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 11), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 14), editor.textAreaRight());

    editor.setScrollbarWidth(2);
    try std.testing.expectEqual(@as(usize, 2), editor.scrollbar_width);
    try std.testing.expectEqual(@as(usize, 9), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 12), editor.textAreaRight());
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
    var editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 8, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // Gutter is 3 columns, so the text wraps at 5 columns: abcde / fghij.
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

test "Editor: tokenized Zig lines render through the wrapped view" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const View = @import("./view.zig").View;

    var editor = try Editor.createFromText(allocator, io, "// hi\nconst x = 1;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.ensureTokensVisible();
    const line = try editor.viewLineData(1);
    try std.testing.expect(line.tokens.getCount() > 0);
    try std.testing.expectEqual(@as(u9, 5), line.tokens.getForeground(0));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "Editor: syntax stays visible after inserting blank lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const View = @import("./view.zig").View;

    var editor = try Editor.createFromText(
        allocator,
        io,
        "const a = 1;\n\n/// comment\npub fn f() void {}\n",
        "test.zig",
        80,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(false);
    try editor.newline();
    try editor.newline();

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;197;134;192m") != null);
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
    const source = @embedFile("../../src/vs/base/common/arrays.zig");

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

test "Editor: typing a function keeps following comments highlighted" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const View = @import("./view.zig").View;

    var editor = try Editor.createFromText(
        allocator,
        io,
        "const a = 1;\n\n/// comment\npub fn f() void {}\n",
        "test.zig",
        80,
        12,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(false);
    try editor.insertText("pub fn hell() void {");
    try editor.newline();
    try editor.insertText("}");

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;197;134;192m") != null);
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
    const RegExp = @import("../support/regexp.zig").RegExp;

    const increase = try RegExp.init("\\{$", .{});
    defer increase.deinit();
    const decrease = try RegExp.init("^\\s*\\}", .{});
    defer decrease.deinit();

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
    var registry = extensions_registry.scan(allocator, &.{"../vscode/extensions/markdown-basics"}) catch return error.SkipZigTest;
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

    const editor = try Editor.createWithExtensions(allocator, time_compat.io, buffer[0..length], 40, 8, null, client);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqualStrings("json", editor.languageId());
    try std.testing.expect(editor.json_error_count > 0);
    try std.testing.expect(std.mem.startsWith(u8, editor.message(), "JSON "));
}
