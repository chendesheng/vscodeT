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
const SingleCursorState = cursorCommon.SingleCursorState;
const EditOperationType = cursorCommon.EditOperationType;
const CursorCollection = @import("../vs/editor/common/cursor/cursorCollection.zig").CursorCollection;
const TextModelCursorSimpleModel = @import("../vs/editor/common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const MoveOperations = @import("../vs/editor/common/cursor/cursorMoveOperations.zig").MoveOperations;
const WordOperations = @import("../vs/editor/common/cursor/cursorWordOperations.zig").WordOperations;
const WordNavigationType = @import("../vs/editor/common/cursor/cursorWordOperations.zig").WordNavigationType;
const DeleteOperations = @import("../vs/editor/common/cursor/cursorDeleteOperations.zig").DeleteOperations;
const TypeWithoutInterceptorsOperation = @import("../vs/editor/common/cursor/cursorTypeEditOperations.zig").TypeWithoutInterceptorsOperation;
const EditOperationResult = cursorCommon.EditOperationResult;
const CursorMoveCommands = @import("../vs/editor/common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const WordCharacterClassifier = @import("../vs/editor/common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const DefaultWordSeparators = @import("../vs/editor/common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const InternalModelContentChangeEvent = @import("../vs/editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const String = @import("../vs/base/common/strings.zig").String;
const strings = @import("../vs/base/common/strings.zig");
const eolToString = @import("../vs/editor/common/core/misc/eolCounter.zig").eolToString;
const language = @import("./language.zig");

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

    fn setViewState(self: *Editor, state: SingleCursorState) !void {
        try self.cursorsRef().setStates(&[_]PartialCursorState{CursorState.fromViewState(state)});
        self.ensureCursorVisible();
    }

    pub fn moveLeft(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveLeft(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, 1));
    }

    pub fn moveRight(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveRight(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, 1));
    }

    pub fn moveUp(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveUp(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, 1));
    }

    pub fn moveDown(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveDown(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, 1));
    }

    pub fn movePageUp(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveUp(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, self.cursor_config.pageSize));
    }

    pub fn movePageDown(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveDown(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, self.cursor_config.pageSize));
    }

    pub fn moveWordLeft(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        const position = WordOperations.moveWordLeft(&self.word_separators, self.view_lines.interface(), cursor.viewState.position, .WordStart, false);
        try self.setViewState(cursor.viewState.move(select, position.lineNumber, position.column, 0));
    }

    pub fn moveWordRight(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        const position = WordOperations.moveWordRight(&self.word_separators, self.view_lines.interface(), cursor.viewState.position, .WordStart);
        try self.setViewState(cursor.viewState.move(select, position.lineNumber, position.column, 0));
    }

    pub fn moveLineStart(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveToBeginningOfLine(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select));
    }

    pub fn moveLineEnd(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveToEndOfLine(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select, false));
    }

    pub fn moveDocStart(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveToBeginningOfBuffer(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select));
    }

    pub fn moveDocEnd(self: *Editor, select: bool) !void {
        self.closeTypingGroup();
        const cursor = self.cursorsRef().getPrimaryCursor();
        try self.setViewState(MoveOperations.moveToEndOfBuffer(&self.cursor_config, self.view_lines.interface(), cursor.viewState, select));
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

    pub fn deleteLeft(self: *Editor) !void {
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
