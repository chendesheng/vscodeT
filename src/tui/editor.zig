const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../vs/editor/common/model.zig").TextModelCreationOptions;
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
const editor_common = @import("../vs/editor/common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;
const command_runner = @import("../vs/editor/common/commands/commandRunner.zig");
const lines_ops = @import("../vs/editor/contrib/linesOperations/browser/linesOperations.zig");
const line_selection = @import("../vs/editor/contrib/lineSelection/browser/lineSelection.zig");
const LineCommentCommand = @import("../vs/editor/contrib/comment/browser/lineCommentCommand.zig").LineCommentCommand;
const CommentType = @import("../vs/editor/contrib/comment/browser/lineCommentCommand.zig").Type;
const BlockCommentCommand = @import("../vs/editor/contrib/comment/browser/blockCommentCommand.zig").BlockCommentCommand;
const InsertFinalNewLineCommand = @import("../vs/editor/contrib/insertFinalNewLine/browser/insertFinalNewLineCommand.zig").InsertFinalNewLineCommand;
const BracketMatchingController = @import("../vs/editor/contrib/bracketMatching/browser/bracketMatching.zig").BracketMatchingController;
const language_configuration_service = @import("./languageConfiguration.zig");
const ShiftCommand = @import("../vs/editor/common/commands/shiftCommand.zig").ShiftCommand;
const IShiftCommandOpts = @import("../vs/editor/common/commands/shiftCommand.zig").IShiftCommandOpts;
const indentation_commands = @import("../vs/editor/contrib/indentation/browser/indentation.zig");
const IndentationToSpacesCommand = indentation_commands.IndentationToSpacesCommand;
const IndentationToTabsCommand = indentation_commands.IndentationToTabsCommand;
const ISingleEditOperation = @import("../vs/editor/common/core/editOperation.zig").ISingleEditOperation;
const multicursor = @import("../vs/editor/contrib/multicursor/browser/multicursor.zig");
const auto_closing = @import("../vs/editor/common/cursor/autoClosing.zig");
const CharacterPairSupport = @import("../vs/editor/common/languages/supports/characterPair.zig");

const MAX_STATUS: usize = 512;

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

pub const Editor = struct {
    allocator: Allocator,
    io: Io,
    path: []u8,
    model: *TextModel,
    undo_redo: *UndoRedoService,
    codec: *LanguageIdCodec,
    language_service: *LanguageService,
    view_lines: ProjectedViewModelLines,
    converter: CoordinatesConverter,
    cursor_config: CursorConfiguration,
    cursor_context: ?*CursorContext,
    cursors: ?CursorCollection,
    model_adapter: TextModelCursorSimpleModel,
    word_separators: WordCharacterClassifier,
    bracket_matching: BracketMatchingController,
    language_config_service: *language_configuration_service.Service,
    character_pair: ?CharacterPairSupport,
    multicursor_session: ?multicursor.SearchSession,
    after_edit: AfterEditComputer,
    saved_version: u32,
    screen_width: usize,
    screen_height: usize,
    gutter_width: usize,
    top_view_line: usize,
    status: [MAX_STATUS]u8,
    status_len: usize,
    quit_armed: bool,
    prev_edit_operation_type: EditOperationType,
    pending_selection: [8]Selection,
    pending_selection_count: usize,
    tokens_need_refresh: bool,

    pub fn create(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, null);
    }

    pub fn createFromText(allocator: Allocator, io: Io, text: []const u8, path: []const u8, width: usize, height: usize) !*Editor {
        return createInternal(allocator, io, path, width, height, text);
    }

    fn createInternal(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize, text: ?[]const u8) !*Editor {
        const editor = try allocator.create(Editor);
        errdefer allocator.destroy(editor);

        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        const language_id = language.languageIdForPath(path);

        const codec = try allocator.create(LanguageIdCodec);
        errdefer allocator.destroy(codec);
        codec.* = try LanguageIdCodec.init(allocator);
        errdefer codec.deinit();
        try codec.register(language_id);

        const language_service = try allocator.create(LanguageService);
        errdefer allocator.destroy(language_service);
        language_service.* = LanguageService.init(allocator, codec);
        errdefer language_service.deinit();

        var language_config = language_configuration.empty();
        var has_language_config = false;
        if (language.commentRuleFor(language_id)) |comments| {
            language_config.comments = comments;
            has_language_config = true;
        }
        if (language.bracketsFor(language_id)) |brackets| {
            language_config.brackets = brackets;
            has_language_config = true;
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

        const model = try createModel(allocator, io, path, language_id, undo_redo, language_service, text);
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
            .undo_redo = undo_redo,
            .codec = codec,
            .language_service = language_service,
            .view_lines = view_lines,
            .converter = undefined,
            .cursor_config = cursor_config,
            .cursor_context = null,
            .cursors = null,
            .model_adapter = TextModelCursorSimpleModel.init(allocator, model),
            .word_separators = word_separators,
            .bracket_matching = BracketMatchingController.init(allocator, model),
            .language_config_service = language_config_service,
            .character_pair = character_pair,
            .multicursor_session = null,
            .after_edit = .{ .model = model },
            .saved_version = model.getAlternativeVersionId(),
            .screen_width = @max(width, 1),
            .screen_height = @max(height, 1),
            .gutter_width = gutter,
            .top_view_line = 1,
            .status = undefined,
            .status_len = 0,
            .quit_armed = false,
            .prev_edit_operation_type = .Other,
            .pending_selection = undefined,
            .pending_selection_count = 0,
            .tokens_need_refresh = false,
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
            editor.converter.toInterface(),
            &editor.cursor_config,
        );
        editor.cursor_context = context;

        editor.cursors = try CursorCollection.init(allocator, context);
        errdefer if (editor.cursors) |*cursors| cursors.deinit();

        try model.onDidChangeContentWithContext(editor, contentChangedCallback);

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        if (self.cursors) |*cursors| cursors.deinit();
        if (self.cursor_context) |context| self.allocator.destroy(context);
        self.model_adapter.deinit();
        self.bracket_matching.deinit();
        self.language_config_service.deinit();
        self.allocator.destroy(self.language_config_service);
        if (self.multicursor_session) |*session| session.deinit();
        self.word_separators.deinit();
        self.view_lines.deinit();
        self.model.deinit();
        self.allocator.destroy(self.model);
        self.undo_redo.deinit();
        self.allocator.destroy(self.undo_redo);
        self.language_service.deinit();
        self.allocator.destroy(self.language_service);
        self.codec.deinit();
        self.allocator.destroy(self.codec);
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
    }

    fn cursorsRef(self: *Editor) *CursorCollection {
        return &self.cursors.?;
    }

    pub fn textHeight(self: *const Editor) usize {
        return @max(@as(usize, 1), self.screen_height - 1);
    }

    pub fn viewLineCount(self: *Editor) usize {
        return self.view_lines.getViewLineCount();
    }

    pub fn tabSize(self: *const Editor) usize {
        return self.cursor_config.tabSize;
    }

    pub fn topViewLine(self: *const Editor) usize {
        return self.top_view_line;
    }

    pub fn gutterWidth(self: *const Editor) usize {
        return self.gutter_width;
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

    pub fn languageId(self: *Editor) []const u8 {
        return self.model.getLanguageId();
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

    fn refreshLayout(self: *Editor) !void {
        const new_gutter = gutterWidthFor(self.model.getLineCount());
        const text_width = @max(@as(usize, 1), self.screen_width - new_gutter);
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
        const total = self.view_lines.getViewLineCount();
        const max_top = if (total <= height) 1 else total - height + 1;
        if (self.top_view_line < 1) self.top_view_line = 1;
        if (self.top_view_line > max_top) self.top_view_line = max_top;
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
                interfaces[i] = commandOf(auto_closing.TypeWithAutoClosingCommand).of(&commands[i]);
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
            interfaces[i] = commandOf(ShiftCommand).of(&commands[i]);
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
        try self.executeCommands(&[_]?ICommand{commandOf(IndentationToSpacesCommand).of(&command)});
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
        try self.executeCommands(&[_]?ICommand{commandOf(IndentationToTabsCommand).of(&command)});
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

    fn getSelectionsCopy(self: *Editor) ![]Selection {
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

    pub fn expandLineSelection(self: *Editor) !void {
        const cursors = try self.cursorsRef().getAll(self.allocator);
        defer self.allocator.free(cursors);

        const states = try line_selection.expandLineSelection(self.allocator, self.view_lines.interface(), cursors);
        defer self.allocator.free(states);

        try self.cursorsRef().setStates(states);
        self.ensureCursorVisible();
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
            interfaces[i] = commandOf(LineCommentCommand).of(&commands[i]);
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
            interfaces[i] = commandOf(BlockCommentCommand).of(&commands[i]);
        }

        try self.executeCommands(interfaces);
    }

    pub fn insertFinalNewLine(self: *Editor) !void {
        const selection = self.modelSelection();
        self.closeTypingGroup();

        var command = InsertFinalNewLineCommand.init(selection);
        try self.executeCommands(&[_]?ICommand{commandOf(InsertFinalNewLineCommand).of(&command)});
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
        try atomic.file.writeStreamingAll(self.io, value.items);
        if (exists) {
            try atomic.replace(self.io);
        } else {
            try atomic.link(self.io);
        }

        self.saved_version = self.model.getAlternativeVersionId();
        self.setMessage("Saved {s}", .{self.path});
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

    if (text) |content| {
        var fixed = Io.Reader.fixed(content);
        return try TextModel.init(allocator, &fixed, language_id, options, null, undo_redo, language_service);
    }

    const cwd = Io.Dir.cwd();
    const maybe_file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (maybe_file) |file| {
        defer file.close(io);
        var buffer: [65535]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        return try TextModel.init(allocator, &reader.interface, language_id, options, null, undo_redo, language_service);
    }

    var fixed = Io.Reader.fixed("");
    return try TextModel.init(allocator, &fixed, language_id, options, null, undo_redo, language_service);
}

test "Editor: create, edit, undo, and render" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const Screen = @import("./screen.zig").Screen;
    const renderer = @import("./render.zig");

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

    var screen = try Screen.init(allocator, 24, 6);
    defer screen.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try renderer.render(editor, &screen, &out.writer);
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
    const Screen = @import("./screen.zig").Screen;
    const renderer = @import("./render.zig");

    var editor = try Editor.createFromText(allocator, io, "// hi\nconst x = 1;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.ensureTokensVisible();
    const line = try editor.viewLineData(1);
    try std.testing.expect(line.tokens.getCount() > 0);
    try std.testing.expectEqual(@as(u9, 5), line.tokens.getForeground(0));

    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try renderer.render(editor, &screen, &out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "Editor: syntax stays visible after inserting blank lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const Screen = @import("./screen.zig").Screen;
    const renderer = @import("./render.zig");

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

    var screen = try Screen.init(allocator, 80, 10);
    defer screen.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try renderer.render(editor, &screen, &out.writer);
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
    const Screen = @import("./screen.zig").Screen;
    const renderer = @import("./render.zig");

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

    var screen = try Screen.init(allocator, 80, 12);
    defer screen.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try renderer.render(editor, &screen, &out.writer);
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
