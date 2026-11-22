// Host implementation for compiled-in extensions.
//
// The host owns the generic key-input registry and the built-in extension
// registry. It adapts workbench/editor services to the interfaces in
// `api/common/extensionApi.zig`; extensions see only those interfaces.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Editor = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorTextEdit = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const Workbench = @import("../../browser/workbench.zig").Workbench;
const Position = @import("../../../editor/common/core/position.zig").Position;
const Range = @import("../../../editor/common/core/range.zig").Range;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const view_events = @import("../../../editor/common/viewEvents.zig");
const commands = @import("../../../platform/commands/common/commands.zig");
const statusbar = @import("../../services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../../browser/parts/statusbar/statusbarPart.zig");
const key_input = @import("../common/keyInput.zig");
const extension_api = @import("../common/extensionApi.zig");
const builtin_extension = @import("../common/builtinExtension.zig");

const ITextEditor = extension_api.ITextEditor;
const IStatusEntry = extension_api.IStatusEntry;
const IExtensionContext = extension_api.IExtensionContext;

pub const BuiltinExtensionHost = struct {
    allocator: Allocator,
    workbench: *Workbench,
    key_registry: key_input.KeyInputRegistry,
    extensions: builtin_extension.BuiltinExtensionRegistry,
    context: IExtensionContext,

    pub fn init(allocator: Allocator, workbench: *Workbench) !*BuiltinExtensionHost {
        const self = try allocator.create(BuiltinExtensionHost);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .workbench = workbench,
            .key_registry = key_input.KeyInputRegistry.init(allocator),
            .extensions = builtin_extension.BuiltinExtensionRegistry.init(allocator),
            .context = undefined,
        };
        self.key_registry.setErrorCallback(.{ .context = self, .report = reportKeyError });
        self.extensions.setErrorCallback(.{ .context = self, .report = reportActivationError });
        self.context = .{
            .allocator = allocator,
            .disposables = undefined,
            .commands = .{
                .context = self,
                .register_fn = registerCommand,
                .execute_fn = executeCommand,
            },
            .key_input = .{ .context = self, .register_fn = registerKeyHandler },
            .editors = .{
                .context = self,
                .active_text_editor_fn = activeTextEditor,
                .on_did_change_active_editor_fn = onDidChangeActiveEditor,
            },
            .window = .{
                .context = self,
                .create_status_entry_fn = createStatusEntry,
                .set_message_fn = setWindowMessage,
                .force_close_active_fn = forceCloseActive,
                .open_path_fn = openPath,
                .switch_tab_fn = switchTab,
            },
            .workspace = .{
                .context = self,
                .get_bool_fn = getBool,
                .get_string_fn = getString,
            },
            .history = .{
                .context = self,
                .go_back_fn = historyGoBack,
                .go_forward_fn = historyGoForward,
                .record_navigation_fn = historyRecord,
            },
        };
        return self;
    }

    pub fn deinit(self: *BuiltinExtensionHost) void {
        self.extensions.deinit();
        self.key_registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn registerBuiltin(self: *BuiltinExtensionHost, extension: builtin_extension.IBuiltinExtension) !void {
        try self.extensions.register(extension);
    }

    pub fn activate(self: *BuiltinExtensionHost) void {
        self.extensions.activateAll(self.context);
    }

    pub fn dispatchKey(self: *BuiltinExtensionHost, event: *const key_input.KeyInputEvent) bool {
        return self.key_registry.dispatch(event);
    }

    pub fn resetKeyInput(self: *BuiltinExtensionHost) void {
        self.key_registry.reset();
    }

    fn reportKeyError(context: *anyopaque, err: anyerror) void {
        const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
        self.setActiveMessage("key handler failed: {s}", .{@errorName(err)});
    }

    fn reportActivationError(context: *anyopaque, id: []const u8, err: anyerror) void {
        const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
        std.log.warn("built-in extension {s} failed to activate: {s}", .{ id, @errorName(err) });
        self.setActiveMessage("extension {s} failed: {s}", .{ id, @errorName(err) });
    }

    fn setActiveMessage(self: *BuiltinExtensionHost, comptime fmt: []const u8, args: anytype) void {
        if (self.workbench.activeTab()) |tab| tab.editor.setMessage(fmt, args);
    }

    fn activeEditorInterface(self: *BuiltinExtensionHost) ?ITextEditor {
        const tab = self.workbench.activeTab() orelse return null;
        return editorInterface(tab.editor);
    }
};

pub fn editorInterface(editor: *Editor) ITextEditor {
    return .{
        .context = editor,
        .model = editor.model,
        .path = editor.path,
        .language_id = editor.languageId(),
        .get_selections_fn = editorGetSelections,
        .set_selections_fn = editorSetSelections,
        .cursor_position_fn = editorCursorPosition,
        .cursor_view_line_fn = editorCursorViewLine,
        .set_cursor_fn = editorSetCursor,
        .move_logical_line_fn = editorMoveLogicalLine,
        .move_wrapped_line_fn = editorMoveWrappedLine,
        .clamp_normal_fn = editorClampNormal,
        .apply_edits_fn = editorApplyEdits,
        .insert_text_fn = editorInsertText,
        .newline_fn = editorNewline,
        .insert_tab_fn = editorInsertTab,
        .outdent_fn = editorOutdent,
        .indent_lines_fn = editorIndentLines,
        .outdent_lines_fn = editorOutdentLines,
        .delete_left_fn = editorDeleteLeft,
        .delete_right_fn = editorDeleteRight,
        .begin_undo_group_fn = editorBeginUndoGroup,
        .end_undo_group_fn = editorEndUndoGroup,
        .undo_fn = editorUndo,
        .redo_fn = editorRedo,
        .reveal_range_fn = editorRevealRange,
        .ensure_cursor_visible_fn = editorEnsureCursorVisible,
        .top_view_line_fn = editorTopViewLine,
        .set_top_view_line_fn = editorSetTopViewLine,
        .scroll_view_lines_fn = editorScrollViewLines,
        .text_height_fn = editorTextHeight,
        .view_line_count_fn = editorViewLineCount,
        .model_line_number_fn = editorModelLineNumber,
        .set_message_fn = editorSetMessage,
        .set_search_highlights_fn = editorSetSearchHighlights,
    };
}

fn editorFrom(context: *anyopaque) *Editor {
    return @ptrCast(@alignCast(context));
}

fn editorGetSelections(context: *anyopaque, allocator: Allocator) anyerror![]Selection {
    const editor = editorFrom(context);
    const selections = try editor.getSelections();
    defer editor.allocator.free(selections);
    return allocator.dupe(Selection, selections);
}

fn editorSetSelections(context: *anyopaque, selections: []const Selection) anyerror!void {
    return editorFrom(context).setSelections(selections);
}

fn editorCursorPosition(context: *anyopaque) Position {
    return editorFrom(context).modelCursorPosition();
}

fn editorCursorViewLine(context: *anyopaque) usize {
    const editor = editorFrom(context);
    return editor.viewPositionOfModelPosition(editor.modelCursorPosition()).lineNumber;
}

fn editorSetCursor(context: *anyopaque, position: Position) anyerror!void {
    return editorFrom(context).setCursorPosition(position);
}

fn editorMoveLogicalLine(context: *anyopaque, down: bool, select: bool, count: usize) anyerror!void {
    return editorFrom(context).moveLogicalLine(down, select, count);
}

fn editorMoveWrappedLine(context: *anyopaque, down: bool, select: bool, count: usize) anyerror!void {
    const editor = editorFrom(context);
    var remaining = @max(count, 1);
    while (remaining > 0) : (remaining -= 1) {
        if (down) try editor.moveDown(select) else try editor.moveUp(select);
    }
}

fn editorClampNormal(context: *anyopaque) anyerror!void {
    return editorFrom(context).clampCursorToLastChar();
}

fn editorApplyEdits(context: *anyopaque, edits: []const extension_api.ITextEdit, cursors: []const Position) anyerror!void {
    const editor = editorFrom(context);
    var translated = ArrayList(EditorTextEdit).init(editor.allocator);
    defer translated.deinit();
    for (edits) |edit| {
        try translated.append(.{ .range = edit.range, .text = edit.text });
    }
    try editor.applyTextEdits(translated.items, cursors);
}

fn editorInsertText(context: *anyopaque, text: []const u8) anyerror!void {
    return editorFrom(context).insertText(text);
}

fn editorNewline(context: *anyopaque) anyerror!void {
    return editorFrom(context).newline();
}

fn editorInsertTab(context: *anyopaque) anyerror!void {
    return editorFrom(context).insertTab();
}

fn editorOutdent(context: *anyopaque) anyerror!void {
    return editorFrom(context).outdent();
}

fn editorIndentLines(context: *anyopaque) anyerror!void {
    return editorFrom(context).indentLines();
}

fn editorOutdentLines(context: *anyopaque) anyerror!void {
    return editorFrom(context).outdentLines();
}

fn editorDeleteLeft(context: *anyopaque) anyerror!void {
    return editorFrom(context).deleteLeft();
}

fn editorDeleteRight(context: *anyopaque) anyerror!void {
    return editorFrom(context).deleteRight();
}

fn editorBeginUndoGroup(context: *anyopaque) void {
    editorFrom(context).beginUndoGroup();
}

fn editorEndUndoGroup(context: *anyopaque) void {
    editorFrom(context).endUndoGroup();
}

fn editorUndo(context: *anyopaque) anyerror!void {
    return editorFrom(context).undo();
}

fn editorRedo(context: *anyopaque) anyerror!void {
    return editorFrom(context).redo();
}

fn editorRevealRange(context: *anyopaque, range: Range) void {
    _ = editorFrom(context).revealRange(range, .Center);
}

fn editorEnsureCursorVisible(context: *anyopaque) void {
    editorFrom(context).ensureCursorVisible();
}

fn editorTopViewLine(context: *anyopaque) usize {
    return editorFrom(context).topViewLine();
}

fn editorSetTopViewLine(context: *anyopaque, line: usize) bool {
    return editorFrom(context).setTopViewLine(line);
}

fn editorScrollViewLines(context: *anyopaque, delta: isize) bool {
    return editorFrom(context).scrollViewLines(delta);
}

fn editorTextHeight(context: *anyopaque) usize {
    return editorFrom(context).textHeight();
}

fn editorViewLineCount(context: *anyopaque) usize {
    return editorFrom(context).viewLineCount();
}

fn editorModelLineNumber(context: *anyopaque, view_line: usize) usize {
    return editorFrom(context).modelLineNumber(view_line);
}

fn editorSetMessage(context: *anyopaque, text: []const u8) void {
    editorFrom(context).setMessage("{s}", .{text});
}

fn editorSetSearchHighlights(context: *anyopaque, matches: []const Range, current: ?Range) void {
    editorFrom(context).setSearchHighlights(matches, current);
}

fn activeTextEditor(context: *anyopaque) ?ITextEditor {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.activeEditorInterface();
}

fn onDidChangeActiveEditor(_: *anyopaque, _: extension_api.EditorChangeListener) anyerror!extension_api.IDisposable {
    // The terminal currently has no generic active-editor event bus. Key
    // handlers observe the active editor on every event; tab-switch-driven
    // status refresh is a follow-up. Returning `none` keeps the contract
    // explicit instead of inventing a second notification path.
    return extension_api.IDisposable.none;
}

fn registerKeyHandler(context: *anyopaque, handler: extension_api.KeyInputHandler) anyerror!extension_api.IDisposable {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.key_registry.register(handler);
}

const CommandState = struct {
    host: *BuiltinExtensionHost,
    id: []u8,
    label: []u8,
    handler: extension_api.CommandHandler,
};

fn runRegisteredCommand(context: *anyopaque) anyerror!void {
    const state: *CommandState = @ptrCast(@alignCast(context));
    return state.handler.run(state.handler.context);
}

const CommandRegistration = struct {
    host: *BuiltinExtensionHost,
    state: *CommandState,

    fn dispose(context: *anyopaque) void {
        const self: *CommandRegistration = @ptrCast(@alignCast(context));
        self.host.workbench.commands.unregister(self.state.id);
        self.host.allocator.free(self.state.id);
        self.host.allocator.free(self.state.label);
        self.host.allocator.destroy(self.state);
        self.host.allocator.destroy(self);
    }
};

fn registerCommand(
    context: *anyopaque,
    id: []const u8,
    label: []const u8,
    handler: extension_api.CommandHandler,
) anyerror!extension_api.IDisposable {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const state = try self.allocator.create(CommandState);
    errdefer self.allocator.destroy(state);
    const id_copy = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(id_copy);
    const label_copy = try self.allocator.dupe(u8, label);
    errdefer self.allocator.free(label_copy);
    state.* = .{ .host = self, .id = id_copy, .label = label_copy, .handler = handler };
    try self.workbench.commands.register(.{
        .id = state.id,
        .label = state.label,
        .context = state,
        .run = runRegisteredCommand,
    });
    const registration = try self.allocator.create(CommandRegistration);
    registration.* = .{ .host = self, .state = state };
    return .{ .context = registration, .disposeFn = CommandRegistration.dispose };
}

fn executeCommand(context: *anyopaque, id: []const u8) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.workbench.commands.platform.execute(id);
}

const StatusEntryState = struct {
    host: *BuiltinExtensionHost,
    id: []u8,
    name: []u8,
    accessor: statusbar_part.EntryAccessor,
    text: [256]u8 = undefined,
    text_len: usize = 0,

    fn setText(context: *anyopaque, text: []const u8) void {
        const self: *StatusEntryState = @ptrCast(@alignCast(context));
        const len = @min(text.len, self.text.len);
        @memcpy(self.text[0..len], text[0..len]);
        self.text_len = len;
        self.accessor.update(.{
            .name = self.name,
            .text = self.text[0..self.text_len],
        });
    }

    fn dispose(context: *anyopaque) void {
        const self: *StatusEntryState = @ptrCast(@alignCast(context));
        self.accessor.dispose();
        self.host.allocator.free(self.id);
        self.host.allocator.free(self.name);
        self.host.allocator.destroy(self);
    }
};

fn createStatusEntry(context: *anyopaque, id: []const u8, name: []const u8) anyerror!IStatusEntry {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const state = try self.allocator.create(StatusEntryState);
    errdefer self.allocator.destroy(state);
    const id_copy = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(id_copy);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);
    const accessor = try self.workbench.statusbar.addEntry(.{
        .name = name_copy,
        .text = "",
    }, id_copy, .left, .{ .number = 50 });
    state.* = .{
        .host = self,
        .id = id_copy,
        .name = name_copy,
        .accessor = accessor,
    };
    return .{
        .context = state,
        .set_text_fn = StatusEntryState.setText,
        .dispose_fn = StatusEntryState.dispose,
    };
}

fn setWindowMessage(context: *anyopaque, text: []const u8) void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    if (self.workbench.activeTab()) |tab| tab.editor.setMessage("{s}", .{text});
}

fn forceCloseActive(context: *anyopaque) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.workbench.forceCloseActive();
}

fn openPath(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.workbench.openPath(path);
}

fn switchTab(context: *anyopaque, delta: isize) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.workbench.switchTab(delta);
}

fn getBool(context: *anyopaque, key: []const u8, default: bool) bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const configuration = self.workbench.configuration orelse return default;
    return configuration.getBool(key, default);
}

fn getString(context: *anyopaque, key: []const u8) ?[]const u8 {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const configuration = self.workbench.configuration orelse return null;
    const value = configuration.getValue(key, .{}) orelse return null;
    return switch (value.*) {
        .string => |text| text,
        else => null,
    };
}

fn historyGoBack(context: *anyopaque) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.workbench.goBackInHistory();
}

fn historyGoForward(context: *anyopaque) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.workbench.goForwardInHistory();
}

fn historyRecord(context: *anyopaque) void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    self.workbench.recordNavigationWithReason(.NAVIGATION);
}
