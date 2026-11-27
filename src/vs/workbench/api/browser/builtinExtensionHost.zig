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
const EditorService = @import("../../services/editor/browser/editorService.zig").EditorService;
const CommandRegistry = @import("../../browser/commands.zig").CommandRegistry;
const QuickInputService = @import("../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const ConfigurationService = @import("../../services/configuration/browser/configurationService.zig").ConfigurationService;
const LanguageFeaturesService = @import("../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const TerminalInstance = @import("../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const EditorInput = @import("../../common/editor/editorInput.zig").EditorInput;
const Tab = @import("../../browser/parts/editor/editorPane.zig").Tab;
const editor_input_dispatch = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig");
const time_compat = @import("../../../base/common/timeCompat.zig");
const Position = @import("../../../editor/common/core/position.zig").Position;
const Range = @import("../../../editor/common/core/range.zig").Range;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const view_events = @import("../../../editor/common/viewEvents.zig");
const commands = @import("../../../platform/commands/common/commands.zig");
const statusbar = @import("../../services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../../browser/parts/statusbar/statusbarPart.zig");
const key_input = @import("../common/keyInput.zig");
const tunnel = @import("../../../platform/tunnel/common/tunnel.zig");
const TunnelProvider = @import("../../../../extensions/tunnel-forwarding/portForwarding.zig").TunnelProvider;
const TunnelView = @import("../../contrib/remote/browser/tunnelView.zig").TunnelView;
const extension_api = @import("../common/extensionApi.zig");
const builtin_extension = @import("../common/builtinExtension.zig");

const ITextEditor = extension_api.ITextEditor;
const IStatusEntry = extension_api.IStatusEntry;
const IExtensionContext = extension_api.IExtensionContext;

/// The compiled extension host consumes the same editor, command and status
/// services as the extension-host actors. These callbacks adapt the remaining
/// terminal window actions until their portable services own them.
pub const Services = struct {
    context: *anyopaque,
    io: std.Io,
    window: ?*@import("../../../base/common/windowDispatch.zig").Queue = null,
    editors: EditorService,
    commands: *CommandRegistry,
    statusbar: *statusbar_part.StatusbarService,
    quick_input: *QuickInputService,
    language_features: *const fn (*anyopaque) ?*LanguageFeaturesService,
    configuration: *const fn (*anyopaque) ?*ConfigurationService,
    launch_terminal: *const fn (*anyopaque, []const u8, []const u8, []const []const u8, ?[]const u8) anyerror!*TerminalInstance,
    terminal_instance: *const fn (*anyopaque, usize) ?*TerminalInstance,
    update_configuration: *const fn (*anyopaque, []const u8, ?std.json.Value) anyerror!void,
    status_hint: *const fn (*anyopaque, []const u8) void,
    force_close_active: *const fn (*anyopaque) anyerror!void,
    open_path: *const fn (*anyopaque, []const u8) anyerror!void,
    switch_tab: *const fn (*anyopaque, isize) anyerror!void,
    history_back: *const fn (*anyopaque) anyerror!bool,
    history_forward: *const fn (*anyopaque) anyerror!bool,
    record_navigation: *const fn (*anyopaque) void,
};

pub const BuiltinExtensionHost = struct {
    allocator: Allocator,
    services: Services,
    key_registry: key_input.KeyInputRegistry,
    extensions: builtin_extension.BuiltinExtensionRegistry,
    context: IExtensionContext,
    tunnel_service: tunnel.TunnelService = .{},
    tunnel_provider: TunnelProvider = undefined,
    tunnel_view: ?TunnelView = null,

    pub fn init(allocator: Allocator, services: Services) !*BuiltinExtensionHost {
        const self = try allocator.create(BuiltinExtensionHost);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .services = services,
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
                .locations_fn = executeLocationProvider,
                .request_locations_fn = requestLocationProvider,
            },
            .key_input = .{ .context = self, .register_fn = registerKeyHandler },
            .editors = .{
                .context = self,
                .active_text_editor_fn = activeTextEditor,
                .on_did_change_active_editor_fn = onDidChangeActiveEditor,
            },
            .window = .{
                .terminals = .{ .context = self, .create = createExtensionTerminal, .running = extensionTerminalRunning, .send_text = sendTerminalText },
                .context = self,
                .create_status_entry_fn = createStatusEntry,
                .set_message_fn = setWindowMessage,
                .force_close_active_fn = forceCloseActive,
                .open_path_fn = openPath,
                .switch_tab_fn = switchTab,
            },
            .workspace = .{
                .update_user_configuration_fn = updateUserConfiguration,
                .register_tunnel_provider = registerTunnelProvider,
                .context = self,
                .text_document_fn = getTextDocument,
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
        try self.tunnel_provider.activate(&self.context);
        return self;
    }

    /// Modal extensions own independent key handlers and dispose them together.
    pub fn createChild(self: *BuiltinExtensionHost) !*BuiltinExtensionHost {
        return init(self.allocator, self.services);
    }

    pub fn deinit(self: *BuiltinExtensionHost) void {
        if (self.tunnel_view) |*view| view.deinit();
        self.tunnel_provider.deinit();
        self.extensions.deinit();
        self.key_registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn registerPortActions(self: *BuiltinExtensionHost) !void {
        self.tunnel_view = @as(TunnelView, undefined);
        errdefer self.tunnel_view = null;
        try self.tunnel_view.?.init(&self.context, self.services.quick_input, &self.tunnel_service);
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
        if (self.services.editors.activeEditorPane()) |tab| if (tab.codeEditorControl()) |editor| editor.setMessage(fmt, args);
    }

    fn activeEditorInterface(self: *BuiltinExtensionHost) ?ITextEditor {
        const tab = self.services.editors.activeEditorPane() orelse return null;
        var editor = editorInterface(tab.codeEditorControl() orelse return null);
        editor.keyboard_input = .{
            .context = tab,
            .dispatch = tabDispatchEditorKey,
            .cancel_suggestions = tabCancelEditorSuggestions,
        };
        return editor;
    }
};

pub fn editorInterface(editor: *Editor) ITextEditor {
    return .{
        .context = editor,
        .model = editor.model,
        .path = editor.path,
        .language_id = editor.languageId(),
        .keyboard_input = .{ .context = editor, .dispatch = editorDispatchKey },
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
        .commit_undo_group_fn = editorCommitUndoGroup,
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

fn editorDispatchKey(context: *anyopaque, event: *const key_input.KeyInputEvent, fallback: ?key_input.KeyInputEvent) void {
    var is_pasting = false;
    _ = editor_input_dispatch.dispatch(editorFrom(context), fallback orelse event.*, &is_pasting);
}

fn tabDispatchEditorKey(context: *anyopaque, event: *const key_input.KeyInputEvent, fallback: ?key_input.KeyInputEvent) void {
    const tab: *Tab = @ptrCast(@alignCast(context));
    var key = event.*;
    var is_pasting = false;
    _ = tab.handleEditorKey(&key, &is_pasting, time_compat.milliTimestamp(), fallback) catch |err| {
        tab.editor.setMessage("edit failed: {s}", .{@errorName(err)});
    };
}

fn tabCancelEditorSuggestions(context: *anyopaque) void {
    const tab: *Tab = @ptrCast(@alignCast(context));
    const controllers = tab.controllers orelse return;
    const suggest = controllers.suggest orelse return;
    suggest.cancelSnippetSession();
    suggest.cancel();
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

fn editorCommitUndoGroup(context: *anyopaque) void {
    editorFrom(context).commitUndoGroup();
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

const ActiveEditorRegistration = struct {
    host: *BuiltinExtensionHost,
    listener: extension_api.EditorChangeListener,
    last_editor: ?*anyopaque,
    active_id: usize = undefined,
    visible_id: usize = undefined,

    fn dispose(self: *ActiveEditorRegistration) void {
        const service = self.host.services.editors;
        service.onDidActiveEditorChange().unlisten(self.active_id);
        service.onDidVisibleEditorsChange().unlisten(self.visible_id);
        self.host.allocator.destroy(self);
    }

    fn onActive(_: ?*EditorInput, self: *ActiveEditorRegistration) !void {
        self.notify();
    }
    fn onVisible(_: void, self: *ActiveEditorRegistration) !void {
        self.notify();
    }
    fn notify(self: *ActiveEditorRegistration) void {
        const editor = self.host.activeEditorInterface();
        const context = if (editor) |value| value.context else null;
        if (self.last_editor == context) return;
        self.last_editor = context;
        self.listener.callback(self.listener.context, editor);
    }
};

fn onDidChangeActiveEditor(context: *anyopaque, listener: extension_api.EditorChangeListener) anyerror!extension_api.IDisposable {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const registration = try self.allocator.create(ActiveEditorRegistration);
    errdefer self.allocator.destroy(registration);
    registration.* = .{
        .host = self,
        .listener = listener,
        .last_editor = if (self.activeEditorInterface()) |editor| editor.context else null,
    };
    const service = self.services.editors;
    registration.active_id = try service.onDidActiveEditorChange().listen(registration, ActiveEditorRegistration.onActive);
    errdefer service.onDidActiveEditorChange().unlisten(registration.active_id);
    registration.visible_id = try service.onDidVisibleEditorsChange().listen(registration, ActiveEditorRegistration.onVisible);
    return extension_api.IDisposable.from(ActiveEditorRegistration, registration, ActiveEditorRegistration.dispose);
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
        self.host.services.commands.unregister(self.state.id);
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
    const registration = try self.allocator.create(CommandRegistration);
    errdefer self.allocator.destroy(registration);
    try self.services.commands.registerCommand(.{ .id = state.id, .context = state, .run = runRegisteredCommand }, .{ .id = state.id, .title = state.label, .category = handler.category }, .{});
    registration.* = .{ .host = self, .state = state };
    return .{ .context = registration, .disposeFn = CommandRegistration.dispose };
}

fn executeCommand(context: *anyopaque, id: []const u8) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.services.commands.platform.execute(id);
}

/// Built-in API command IDs map to the model-and-position commands in goToSymbol.ts.
fn executeLocationProvider(context: *anyopaque, arena: Allocator, id: []const u8, model: *TextModel, position: Position) ![]const extension_api.LocationLink {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const features = self.services.language_features(self.services.context) orelse return &.{};
    return collectLocationLinks(features, arena, id, model, position, .None);
}

fn collectLocationLinks(features: *LanguageFeaturesService, arena: Allocator, id: []const u8, model: *TextModel, position: Position, token: @import("../../../base/common/cancellation.zig").CancellationToken) ![]const extension_api.LocationLink {
    const symbols = @import("../../../editor/contrib/gotoSymbol/browser/goToSymbol.zig");
    const links = if (std.mem.eql(u8, id, "vscode.executeReferenceProvider"))
        try symbols.getReferencesAtPosition(arena, &features.reference_provider, model, position, false, false, token)
    else if (std.mem.eql(u8, id, "vscode.executeImplementationProvider"))
        try symbols.getImplementationsAtPosition(arena, &features.implementation_provider, model, position, false, token)
    else
        return error.UnknownCommand;
    var sorted = try @import("../../../editor/contrib/gotoSymbol/browser/referencesModel.zig").ReferencesModel.init(arena, links, "");
    defer sorted.deinit();
    const result = try arena.alloc(extension_api.LocationLink, sorted.references.len);
    for (result, sorted.references) |*link, reference| link.* = reference.link;
    return result;
}

const LocationRequest = struct {
    const Window = @import("../../../base/common/windowDispatch.zig");
    const Source = @import("../../../base/common/cancellation.zig").CancellationTokenSource;
    const Emitter = @import("../../../base/common/event.zig").Emitter(usize);
    allocator: Allocator,
    arena: Allocator,
    window: *Window.Queue,
    document: *@import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument,
    features: *LanguageFeaturesService,
    command: []const u8,
    position: Position,
    callback: extension_api.LocationProviderCallback,
    registry: *Emitter,
    registry_listener: Emitter.ListenerId,
    content_listener: ?usize = null,
    source: Source,
    future: std.Io.Future(anyerror![]const extension_api.LocationLink),
    completion: Window.Task,

    fn run(self: *LocationRequest) anyerror![]const extension_api.LocationLink {
        defer self.completion.post();
        const token = try self.source.token();
        try token.throwIfCancellationRequested();
        const links = try collectLocationLinks(self.features, self.arena, self.command, self.document.model, self.position, token);
        try token.throwIfCancellationRequested();
        return links;
    }

    fn changed(_: usize, self: *LocationRequest) !void {
        self.source.cancel();
    }

    fn contentChanged(_: @import("../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent, self: *LocationRequest) !void {
        self.source.cancel();
    }

    fn dispose(self: *LocationRequest) void {
        self.registry.unlisten(self.registry_listener);
        if (self.content_listener) |listener| self.document.model.removeDidChangeContentListener(listener);
        self.source.deinit();
        self.document.release();
        self.completion.schedule(null);
        self.allocator.destroy(self);
    }

    fn cancel(context: *anyopaque) void {
        const self: *LocationRequest = @ptrCast(@alignCast(context));
        self.source.cancel();
        _ = self.future.cancel(self.window.io) catch &.{};
        self.dispose();
    }

    fn complete(context: *anyopaque, _: i64, _: bool) bool {
        const self: *LocationRequest = @ptrCast(@alignCast(context));
        const value = self.future.await(self.window.io);
        const token = self.source.token() catch @import("../../../base/common/cancellation.zig").CancellationToken.Cancelled;
        const result: anyerror![]const extension_api.LocationLink = if (token.isCancellationRequested()) error.CancellationError else value;
        const callback = self.callback;
        self.dispose();
        callback.complete(callback.context, result);
        return true;
    }
};

fn requestLocationProvider(context: *anyopaque, arena: Allocator, id: []const u8, model: *TextModel, position: Position, callback: extension_api.LocationProviderCallback) !?extension_api.IDisposable {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const features = self.services.language_features(self.services.context) orelse {
        callback.complete(callback.context, &.{});
        return null;
    };
    const registry = if (std.mem.eql(u8, id, "vscode.executeReferenceProvider"))
        &features.reference_provider.on_did_change
    else if (std.mem.eql(u8, id, "vscode.executeImplementationProvider"))
        &features.implementation_provider.on_did_change
    else
        return error.UnknownCommand;
    const window = self.services.window orelse {
        callback.complete(callback.context, executeLocationProvider(context, arena, id, model, position));
        return null;
    };
    const editor_interface = self.activeEditorInterface() orelse return error.NoActiveEditor;
    if (editor_interface.model != model) return error.NoActiveEditor;
    const editor = editorFrom(editor_interface.context);
    if (window.scheduler == null) {
        callback.complete(callback.context, executeLocationProvider(context, arena, id, model, position));
        return null;
    }
    // Keep the immediate path for local, synchronous providers. Only host
    // providers require an asynchronous window-fiber boundary.
    const needs_fiber = if (std.mem.eql(u8, id, "vscode.executeReferenceProvider")) blk: {
        const providers = try features.reference_provider.ordered(arena, model, false);
        defer arena.free(providers);
        for (providers) |provider| if (provider.requires_window_fiber) break :blk true;
        break :blk false;
    } else blk: {
        const providers = try features.implementation_provider.ordered(arena, model, false);
        defer arena.free(providers);
        for (providers) |provider| if (provider.requires_window_fiber) break :blk true;
        break :blk false;
    };
    if (!needs_fiber) {
        callback.complete(callback.context, executeLocationProvider(context, arena, id, model, position));
        return null;
    }

    const request = try self.allocator.create(LocationRequest);
    errdefer self.allocator.destroy(request);
    var source = try LocationRequest.Source.init(self.allocator);
    errdefer source.deinit();
    editor.document.retain();
    errdefer editor.document.release();
    request.* = .{
        .allocator = self.allocator,
        .arena = arena,
        .window = window,
        .document = editor.document,
        .features = features,
        .command = if (std.mem.eql(u8, id, "vscode.executeReferenceProvider")) "vscode.executeReferenceProvider" else "vscode.executeImplementationProvider",
        .position = position,
        .callback = callback,
        .registry = registry,
        .registry_listener = undefined,
        .source = source,
        .future = undefined,
        .completion = .{ .queue = window, .context = request, .run = LocationRequest.complete, .progress = true },
    };
    request.registry_listener = try registry.listen(request, LocationRequest.changed);
    errdefer registry.unlisten(request.registry_listener);
    request.content_listener = try model.onDidChangeContentWithContextId(request, LocationRequest.contentChanged);
    errdefer model.removeDidChangeContentListener(request.content_listener.?);
    request.future = try window.io.concurrent(LocationRequest.run, .{request});
    return .{ .context = request, .disposeFn = LocationRequest.cancel };
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
    const accessor = try self.services.statusbar.addEntry(.{
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

fn registerTunnelProvider(context: *anyopaque, provider: tunnel.ITunnelProvider) !extension_api.IDisposable {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.tunnel_service.setTunnelProvider(provider);
}

fn createExtensionTerminal(context: *anyopaque, options: extension_api.TerminalOptions) !usize {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const executable = try @import("../../../platform/terminal/node/terminalProfiles.zig").findTerminalExecutable(self.allocator, self.services.io, options.shell_path) orelse return error.ExecutableNotFound;
    defer self.allocator.free(executable);
    const instance = try self.services.launch_terminal(self.services.context, options.name, executable, options.shell_args, null);
    return instance.id;
}

fn extensionTerminalRunning(context: *anyopaque, id: usize) bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const instance = self.services.terminal_instance(self.services.context, id) orelse return false;
    return instance.process_state == .running;
}

fn sendTerminalText(context: *anyopaque, id: usize, text: []const u8) void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    if (self.services.terminal_instance(self.services.context, id)) |instance| instance.writeInput(text);
}

fn updateUserConfiguration(context: *anyopaque, key: []const u8, value: ?std.json.Value) !void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.services.update_configuration(self.services.context, key, value);
}

fn setWindowMessage(context: *anyopaque, text: []const u8) void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    if (self.services.editors.activeEditorPane()) |tab| {
        if (tab.codeEditorControl()) |editor| {
            editor.setMessage("{s}", .{text});
            return;
        }
    }
    self.services.status_hint(self.services.context, text);
}

fn forceCloseActive(context: *anyopaque) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.services.force_close_active(self.services.context);
}

fn openPath(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.services.open_path(self.services.context, path);
}

fn switchTab(context: *anyopaque, delta: isize) anyerror!void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    try self.services.switch_tab(self.services.context, delta);
}

fn getTextDocument(context: *anyopaque, path: []const u8) ?*TextModel {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const input = self.services.editors.findOpenFileInput(self.services.io, path) orelse return null;
    return input.editor.model;
}

fn getBool(context: *anyopaque, key: []const u8, default: bool) bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const configuration = self.services.configuration(self.services.context) orelse return default;
    return configuration.getBool(key, default);
}

fn getString(context: *anyopaque, key: []const u8) ?[]const u8 {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    const configuration = self.services.configuration(self.services.context) orelse return null;
    const value = configuration.getValue(key, .{}) orelse return null;
    return switch (value.*) {
        .string => |text| text,
        else => null,
    };
}

fn historyGoBack(context: *anyopaque) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.services.history_back(self.services.context);
}

fn historyGoForward(context: *anyopaque) anyerror!bool {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    return self.services.history_forward(self.services.context);
}

fn historyRecord(context: *anyopaque) void {
    const self: *BuiltinExtensionHost = @ptrCast(@alignCast(context));
    self.services.record_navigation(self.services.context);
}
