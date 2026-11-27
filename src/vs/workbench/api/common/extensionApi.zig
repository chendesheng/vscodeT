// Built-in extension API contracts.
//
// This is a focused, transport-neutral subset of the `vscode` API for
// extensions compiled into this binary. A built-in extension receives these
// interfaces, registers commands/key handlers/status entries, and never sees
// `Workbench` or `Editor`. The Node extension host keeps using the RPC actors
// under `api/browser/` and `api/common/extHost.protocol.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const contextkey = @import("../../../platform/contextkey/common/contextkey.zig");
const Position = @import("../../../editor/common/core/position.zig").Position;
const Range = @import("../../../editor/common/core/range.zig").Range;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const key_input = @import("./keyInput.zig");

pub const IDisposable = lifecycle.IDisposable;
pub const DisposableStore = lifecycle.DisposableStore;
pub const KeyInputHandler = key_input.Handler;
pub const KeyInputEvent = key_input.KeyInputEvent;

pub const ITextEdit = struct {
    range: Range,
    text: []const u8,
};

/// Editor operations exposed to a built-in extension. Reads go through the
/// portable `TextModel`; mutations go through these methods so the editor
/// keeps ownership of undo grouping, cursor state and view invalidation.
pub const ITextEditor = struct {
    context: *anyopaque,
    model: *TextModel,
    path: []const u8,
    language_id: []const u8,

    /// Forward a key to the editor after extension key handling. The host
    /// dispatches editor contributions and editing commands directly.
    keyboard_input: struct {
        context: *anyopaque,
        dispatch: *const fn (context: *anyopaque, event: *const KeyInputEvent, fallback: ?KeyInputEvent) void,
        cancel_suggestions: ?*const fn (context: *anyopaque) void = null,
    },

    get_selections_fn: *const fn (context: *anyopaque, allocator: Allocator) anyerror![]Selection,
    set_selections_fn: *const fn (context: *anyopaque, selections: []const Selection) anyerror!void,
    cursor_position_fn: *const fn (context: *anyopaque) Position,
    cursor_view_line_fn: *const fn (context: *anyopaque) usize,
    set_cursor_fn: *const fn (context: *anyopaque, position: Position) anyerror!void,
    move_logical_line_fn: *const fn (context: *anyopaque, down: bool, select: bool, count: usize) anyerror!void,
    move_wrapped_line_fn: *const fn (context: *anyopaque, down: bool, select: bool, count: usize) anyerror!void,
    clamp_normal_fn: *const fn (context: *anyopaque) anyerror!void,
    apply_edits_fn: *const fn (context: *anyopaque, edits: []const ITextEdit, cursors: []const Position) anyerror!void,
    insert_text_fn: *const fn (context: *anyopaque, text: []const u8) anyerror!void,
    newline_fn: *const fn (context: *anyopaque) anyerror!void,
    insert_tab_fn: *const fn (context: *anyopaque) anyerror!void,
    outdent_fn: *const fn (context: *anyopaque) anyerror!void,
    indent_lines_fn: *const fn (context: *anyopaque) anyerror!void,
    outdent_lines_fn: *const fn (context: *anyopaque) anyerror!void,
    delete_left_fn: *const fn (context: *anyopaque) anyerror!void,
    delete_right_fn: *const fn (context: *anyopaque) anyerror!void,
    begin_undo_group_fn: *const fn (context: *anyopaque) void,
    end_undo_group_fn: *const fn (context: *anyopaque) void,
    commit_undo_group_fn: ?*const fn (context: *anyopaque) void = null,
    undo_fn: *const fn (context: *anyopaque) anyerror!void,
    redo_fn: *const fn (context: *anyopaque) anyerror!void,
    reveal_range_fn: *const fn (context: *anyopaque, range: Range) void,
    ensure_cursor_visible_fn: *const fn (context: *anyopaque) void,
    top_view_line_fn: *const fn (context: *anyopaque) usize,
    set_top_view_line_fn: *const fn (context: *anyopaque, line: usize) bool,
    scroll_view_lines_fn: *const fn (context: *anyopaque, delta: isize) bool,
    text_height_fn: *const fn (context: *anyopaque) usize,
    view_line_count_fn: *const fn (context: *anyopaque) usize,
    model_line_number_fn: *const fn (context: *anyopaque, view_line: usize) usize,
    set_message_fn: *const fn (context: *anyopaque, text: []const u8) void,
    /// Optional. Built-in vim/helix hosts install it to paint incremental
    /// search matches with the editor's find-match colors.
    set_search_highlights_fn: ?*const fn (context: *anyopaque, matches: []const Range, current: ?Range) void = null,

    pub fn getSelections(self: ITextEditor, allocator: Allocator) ![]Selection {
        return self.get_selections_fn(self.context, allocator);
    }
    pub fn setSelections(self: ITextEditor, selections: []const Selection) !void {
        return self.set_selections_fn(self.context, selections);
    }
    pub fn cursorPosition(self: ITextEditor) Position {
        return self.cursor_position_fn(self.context);
    }
    pub fn cursorViewLine(self: ITextEditor) usize {
        return self.cursor_view_line_fn(self.context);
    }
    pub fn setCursor(self: ITextEditor, position: Position) !void {
        return self.set_cursor_fn(self.context, position);
    }
    pub fn moveLogicalLine(self: ITextEditor, down: bool, select: bool, count: usize) !void {
        return self.move_logical_line_fn(self.context, down, select, count);
    }
    pub fn moveWrappedLine(self: ITextEditor, down: bool, select: bool, count: usize) !void {
        return self.move_wrapped_line_fn(self.context, down, select, count);
    }
    pub fn clampNormal(self: ITextEditor) !void {
        return self.clamp_normal_fn(self.context);
    }
    pub fn applyEdits(self: ITextEditor, edits: []const ITextEdit, cursors: []const Position) !void {
        return self.apply_edits_fn(self.context, edits, cursors);
    }
    pub fn insertText(self: ITextEditor, text: []const u8) !void {
        return self.insert_text_fn(self.context, text);
    }
    pub fn dispatchEditorKey(self: ITextEditor, event: *const KeyInputEvent) void {
        self.keyboard_input.dispatch(self.keyboard_input.context, event, null);
    }
    /// Editor contributions see the original key before the fallback runs.
    pub fn dispatchEditorKeyWithFallback(self: ITextEditor, event: *const KeyInputEvent, fallback: KeyInputEvent) void {
        self.keyboard_input.dispatch(self.keyboard_input.context, event, fallback);
    }
    pub fn cancelEditorSuggestions(self: ITextEditor) void {
        if (self.keyboard_input.cancel_suggestions) |cancel| cancel(self.keyboard_input.context);
    }
    pub fn newline(self: ITextEditor) !void {
        return self.newline_fn(self.context);
    }
    pub fn insertTab(self: ITextEditor) !void {
        return self.insert_tab_fn(self.context);
    }
    pub fn outdent(self: ITextEditor) !void {
        return self.outdent_fn(self.context);
    }
    pub fn indentLines(self: ITextEditor) !void {
        return self.indent_lines_fn(self.context);
    }
    pub fn outdentLines(self: ITextEditor) !void {
        return self.outdent_lines_fn(self.context);
    }
    pub fn deleteLeft(self: ITextEditor) !void {
        return self.delete_left_fn(self.context);
    }
    pub fn deleteRight(self: ITextEditor) !void {
        return self.delete_right_fn(self.context);
    }
    pub fn beginUndoGroup(self: ITextEditor) void {
        self.begin_undo_group_fn(self.context);
    }
    pub fn endUndoGroup(self: ITextEditor) void {
        self.end_undo_group_fn(self.context);
    }
    /// Closes any open undo group (Helix's per-command history boundary).
    pub fn commitUndoGroup(self: ITextEditor) void {
        if (self.commit_undo_group_fn) |commit| commit(self.context);
    }
    pub fn undo(self: ITextEditor) !void {
        return self.undo_fn(self.context);
    }
    pub fn redo(self: ITextEditor) !void {
        return self.redo_fn(self.context);
    }
    pub fn revealRange(self: ITextEditor, range: Range) void {
        self.reveal_range_fn(self.context, range);
    }
    pub fn ensureCursorVisible(self: ITextEditor) void {
        self.ensure_cursor_visible_fn(self.context);
    }
    pub fn topViewLine(self: ITextEditor) usize {
        return self.top_view_line_fn(self.context);
    }
    pub fn setTopViewLine(self: ITextEditor, line: usize) bool {
        return self.set_top_view_line_fn(self.context, line);
    }
    pub fn scrollViewLines(self: ITextEditor, delta: isize) bool {
        return self.scroll_view_lines_fn(self.context, delta);
    }
    pub fn textHeight(self: ITextEditor) usize {
        return self.text_height_fn(self.context);
    }
    pub fn viewLineCount(self: ITextEditor) usize {
        return self.view_line_count_fn(self.context);
    }
    pub fn modelLineNumber(self: ITextEditor, view_line: usize) usize {
        return self.model_line_number_fn(self.context, view_line);
    }
    pub fn setMessage(self: ITextEditor, text: []const u8) void {
        self.set_message_fn(self.context, text);
    }
    /// Replaces the incremental-search highlights: every range in `matches`
    /// plus the emphasized `current` match (which may be repeated in
    /// `matches`). An empty slice clears them.
    pub fn setSearchHighlights(self: ITextEditor, matches: []const Range, current: ?Range) void {
        if (self.set_search_highlights_fn) |set| set(self.context, matches, current);
    }
};

pub const EditorChangeListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, editor: ?ITextEditor) void,
};

pub const IEditorService = struct {
    context: *anyopaque,
    active_text_editor_fn: *const fn (context: *anyopaque) ?ITextEditor,
    on_did_change_active_editor_fn: *const fn (context: *anyopaque, listener: EditorChangeListener) anyerror!IDisposable,

    pub fn activeTextEditor(self: IEditorService) ?ITextEditor {
        return self.active_text_editor_fn(self.context);
    }
    pub fn onDidChangeActiveEditor(self: IEditorService, listener: EditorChangeListener) !IDisposable {
        return self.on_did_change_active_editor_fn(self.context, listener);
    }
};

pub const IStatusEntry = struct {
    context: *anyopaque,
    set_text_fn: *const fn (context: *anyopaque, text: []const u8) void,
    dispose_fn: *const fn (context: *anyopaque) void,

    pub fn setText(self: IStatusEntry, text: []const u8) void {
        self.set_text_fn(self.context, text);
    }
    pub fn disposable(self: IStatusEntry) IDisposable {
        return .{ .context = self.context, .disposeFn = self.dispose_fn };
    }
};

pub const TerminalOptions = struct { name: []const u8, shell_path: []const u8, shell_args: []const []const u8 };

/// The native terminal collection uses instance IDs so a disposed terminal
/// can be queried safely by compiled-in extensions.
pub const TerminalCollection = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, TerminalOptions) anyerror!usize,
    running: *const fn (*anyopaque, usize) bool,
    send_text: *const fn (*anyopaque, usize, []const u8) void,
};

pub const IWindowService = struct {
    terminals: ?TerminalCollection = null,
    context: *anyopaque,
    create_status_entry_fn: *const fn (context: *anyopaque, id: []const u8, name: []const u8) anyerror!IStatusEntry,
    set_message_fn: *const fn (context: *anyopaque, text: []const u8) void,
    force_close_active_fn: *const fn (context: *anyopaque) anyerror!void,
    open_path_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    switch_tab_fn: *const fn (context: *anyopaque, delta: isize) anyerror!void,

    pub fn createStatusEntry(self: IWindowService, id: []const u8, name: []const u8) !IStatusEntry {
        return self.create_status_entry_fn(self.context, id, name);
    }
    pub fn setMessage(self: IWindowService, text: []const u8) void {
        self.set_message_fn(self.context, text);
    }
    pub fn forceCloseActive(self: IWindowService) !void {
        return self.force_close_active_fn(self.context);
    }
    pub fn openPath(self: IWindowService, path: []const u8) !void {
        return self.open_path_fn(self.context, path);
    }
    pub fn switchTab(self: IWindowService, delta: isize) !void {
        return self.switch_tab_fn(self.context, delta);
    }
};

/// Port of the workbench `IHistoryService` subset exposed to built-ins.
/// `recordNavigation` is the TUI adapter for upstream `notifyNavigation`.
pub const IHistoryService = struct {
    context: *anyopaque,
    go_back_fn: *const fn (context: *anyopaque) anyerror!bool,
    go_forward_fn: *const fn (context: *anyopaque) anyerror!bool,
    record_navigation_fn: *const fn (context: *anyopaque) void,

    pub fn goBack(self: IHistoryService) !bool {
        return self.go_back_fn(self.context);
    }
    pub fn goForward(self: IHistoryService) !bool {
        return self.go_forward_fn(self.context);
    }
    pub fn recordNavigation(self: IHistoryService) void {
        self.record_navigation_fn(self.context);
    }
};

pub const IWorkspaceService = struct {
    register_tunnel_provider: ?*const fn (*anyopaque, @import("../../../platform/tunnel/common/tunnel.zig").ITunnelProvider) anyerror!IDisposable = null,

    /// workspace.getConfiguration().update(key, value, ConfigurationTarget.Global)
    update_user_configuration_fn: ?*const fn (*anyopaque, []const u8, ?std.json.Value) anyerror!void = null,

    /// Looks up a document already open in the editor, as in workspace.textDocuments.
    text_document_fn: ?*const fn (*anyopaque, []const u8) ?*TextModel = null,

    context: *anyopaque,
    get_bool_fn: *const fn (context: *anyopaque, key: []const u8, default: bool) bool,
    get_string_fn: *const fn (context: *anyopaque, key: []const u8) ?[]const u8,

    pub fn updateUserConfiguration(self: IWorkspaceService, key: []const u8, value: ?std.json.Value) !void {
        const update = self.update_user_configuration_fn orelse return error.ConfigurationUnavailable;
        try update(self.context, key, value);
    }

    pub fn registerTunnelProvider(self: IWorkspaceService, provider: @import("../../../platform/tunnel/common/tunnel.zig").ITunnelProvider) !IDisposable {
        const register = self.register_tunnel_provider orelse return error.Unsupported;
        return register(self.context, provider);
    }

    pub fn getBool(self: IWorkspaceService, key: []const u8, default: bool) bool {
        return self.get_bool_fn(self.context, key, default);
    }
    pub fn getString(self: IWorkspaceService, key: []const u8) ?[]const u8 {
        return self.get_string_fn(self.context, key);
    }
};

pub const CommandHandler = struct {
    category: []const u8 = "",
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

pub const LocationLink = @import("../../../editor/common/languages.zig").LocationLink;

pub const LocationProviderCallback = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror![]const LocationLink) void,
};

pub const ICommandService = struct {
    /// Typed executeCommand overload for the language provider API. The supplied
    /// arena owns the result and its resource strings.
    locations_fn: ?*const fn (*anyopaque, Allocator, []const u8, *TextModel, Position) anyerror![]const LocationLink = null,
    request_locations_fn: ?*const fn (*anyopaque, Allocator, []const u8, *TextModel, Position, LocationProviderCallback) anyerror!?IDisposable = null,

    context: *anyopaque,
    register_fn: *const fn (context: *anyopaque, id: []const u8, label: []const u8, handler: CommandHandler) anyerror!IDisposable,
    execute_fn: *const fn (context: *anyopaque, id: []const u8) anyerror!bool,

    pub fn requestLocationProvider(self: ICommandService, arena: Allocator, id: []const u8, model: *TextModel, position: Position, callback: LocationProviderCallback) !?IDisposable {
        if (self.request_locations_fn) |request| return request(self.context, arena, id, model, position, callback);
        callback.complete(callback.context, self.executeLocationProvider(arena, id, model, position));
        return null;
    }

    pub fn executeLocationProvider(self: ICommandService, arena: Allocator, id: []const u8, model: *TextModel, position: Position) ![]const LocationLink {
        const run = self.locations_fn orelse return error.UnknownCommand;
        return run(self.context, arena, id, model, position);
    }

    pub fn register(self: ICommandService, id: []const u8, label: []const u8, handler: CommandHandler) !IDisposable {
        return self.register_fn(self.context, id, label, handler);
    }
    pub fn execute(self: ICommandService, id: []const u8) !bool {
        return self.execute_fn(self.context, id);
    }
};

pub const IKeyInputService = struct {
    context: *anyopaque,
    register_fn: *const fn (context: *anyopaque, handler: KeyInputHandler) anyerror!IDisposable,

    pub fn register(self: IKeyInputService, handler: KeyInputHandler) !IDisposable {
        return self.register_fn(self.context, handler);
    }
};

pub const IContextKeyService = contextkey.IContextKeyService;

/// Everything a built-in extension can see. Fields are interface values, not
/// concrete services; the host implementation owns the adapters.
pub const IExtensionContext = struct {
    allocator: Allocator,
    disposables: *DisposableStore,
    commands: ICommandService,
    key_input: IKeyInputService,
    editors: IEditorService,
    window: IWindowService,
    workspace: IWorkspaceService,
    history: IHistoryService,
};

pub const IBuiltinExtension = struct {
    context: *anyopaque,
    id: []const u8,
    display_name: []const u8,
    version: []const u8,
    activate_fn: *const fn (context: *anyopaque, api: *const IExtensionContext) anyerror!void,
    deactivate_fn: *const fn (context: *anyopaque) void,

    pub fn activate(self: *const IBuiltinExtension, api: *const IExtensionContext) !void {
        return self.activate_fn(self.context, api);
    }
    pub fn deactivate(self: *const IBuiltinExtension) void {
        self.deactivate_fn(self.context);
    }
};
