// TUI adapter for the pinned VS Code extension host.
//
// The portable pieces (transport, RPC, generated protocol table, host boot)
// live under `src/vs/workbench/services/extensions/`. This file owns only the
// terminal-specific state: the editor-group model lifecycle and focused editor mirror, the command
// surface Node extensions call back into, and the typed-text path
// through the `type` command.

const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const extension_service = @import("../../services/extensions/common/extensionService.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const proxyIdentifier = @import("../../services/extensions/common/proxyIdentifier.zig");
const protocol = @import("../common/extHost.protocol.zig");
const time_compat = @import("../../../base/common/timeCompat.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const Editor = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorDocument = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const LastContentChange = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").LastContentChange;
const ChangeListener = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").ChangeListener;
const TextEdit = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
pub const Services = @import("extensionHostServices.zig").Services;
const GroupPane = @import("../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const Tab = @import("../../browser/parts/editor/editorPane.zig").Tab;
const EditorInput = @import("../../common/editor/editorInput.zig").EditorInput;
const EditorService = @import("../../services/editor/browser/editorService.zig").EditorService;
const GroupModelChangeEvent = @import("../../common/editor/editorGroupModel.zig").GroupModelChangeEvent;
const Task = @import("../../../base/common/windowDispatch.zig").Task;
const ModelLanguageChangedEvent = @import("../../../editor/common/textModelEvents.zig").ModelLanguageChangedEvent;
const ViewEventHandler = @import("../../../editor/common/viewEventHandler.zig").ViewEventHandler;
const GroupDirection = @import("../../services/editor/common/editorGroupsService.zig").GroupDirection;
const statusbar = @import("../../services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../../browser/parts/statusbar/statusbarPart.zig");
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const Range = @import("../../../editor/common/core/range.zig").Range;
const view_events = @import("../../../editor/common/viewEvents.zig");
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const Position = @import("../../../editor/common/core/position.zig").Position;
const CursorColumns = @import("../../../editor/common/core/cursorColumns.zig").CursorColumns;
const ui = @import("ui");
const MainThreadLanguageFeatures = @import("./mainThreadLanguageFeatures.zig").MainThreadLanguageFeatures;
const languageFeaturesHost = @import("./mainThreadLanguageFeatures.zig").HostProxy;
const MainThreadDiagnostics = @import("./mainThreadDiagnostics.zig").MainThreadDiagnostics;
const MainThreadStorage = @import("./mainThreadStorage.zig").MainThreadStorage;
const MainThreadStatusBar = @import("./mainThreadStatusBar.zig").MainThreadStatusBar;
const TerminalSuggestAddon = @import("../../contrib/terminalContrib/suggest/browser/terminalSuggestAddon.zig").TerminalSuggestAddon;
const TerminalInstance = @import("../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const MainThreadCommands = @import("./mainThreadCommands.zig").MainThreadCommands;
const MainThreadConfiguration = @import("./mainThreadConfiguration.zig").MainThreadConfiguration;
const documents_and_editors = @import("./mainThreadDocumentsAndEditors.zig");
const MainThreadDocuments = @import("./mainThreadDocuments.zig").MainThreadDocuments;
const MainThreadTextEditors = @import("./mainThreadTextEditors.zig").MainThreadTextEditors;
const EditSpec = @import("./mainThreadTextEditors.zig").EditSpec;
const editor_tabs = @import("./mainThreadEditorTabs.zig");
const MainThreadEditorTabs = editor_tabs.MainThreadEditorTabs;
const MainThreadWindow = @import("./mainThreadWindow.zig").MainThreadWindow;
const MainThreadExtensionService = @import("./mainThreadExtensionService.zig").MainThreadExtensionService;
const diagnosticsHost = @import("./mainThreadDiagnostics.zig").HostProxy;
const markers_mod = @import("../../../platform/markers/common/markers.zig");
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const position_converter = @import("../common/positionConverter.zig");
const go_to_commands = @import("../../../editor/contrib/gotoSymbol/browser/goToCommands.zig");
const cursor_move = @import("../../../editor/common/cursor/cursorMoveCommands.zig");
const folding = @import("../../../editor/contrib/folding/browser/folding.zig");
const RevealSpec = @import("./mainThreadTextEditors.zig").RevealSpec;
const TextEditorRevealType = @import("./mainThreadTextEditors.zig").TextEditorRevealType;

const EntryAccessor = statusbar_part.EntryAccessor;

const ActiveDocument = struct {
    tab: *Tab,
    dispose_listener: usize,
    editor_dispose_listener: usize,
    language_listener: usize,
    editor: *Editor,
    uri: []u8,
    id: []const u8 = "1",
    language_id: []u8,
};

/// Source of a cursor-selection change, using upstream's
/// `ICursorSelectionChangedEvent.source` strings. The extension host maps
/// `"mouse"`/`"keyboard"` to `TextEditorSelectionChangeKind` so an extension can
/// tell a user-initiated selection change from its own edit.
pub const SelectionSource = enum {
    keyboard,
    mouse,
    command,

    fn wireName(self: SelectionSource) []const u8 {
        return switch (self) {
            .keyboard => "keyboard",
            .mouse => "mouse",
            .command => "command",
        };
    }
};

const freeDocumentLines = documents_and_editors.freeLines;
const utf16ColumnInLines = documents_and_editors.utf16ColumnForLines;

fn applyChangeToDocumentLines(allocator: Allocator, lines: *std.array_list.Managed([]u8), change: LastContentChange) !void {
    try documents_and_editors.applyLineChange(allocator, lines, change.range, change.text);
}

pub const Extensions = struct {
    allocator: Allocator,
    io: Io,
    services: Services,
    host: *manager.HostManager,
    /// Loadable Node extensions. The host receives all of them in one
    /// init-data payload; activation events select which one runs.
    descriptions: []manager.ExtensionDescription,
    extension_ptrs: []const *const manager.ExtensionDescription,
    user_data_dir: []u8,
    active: ?ActiveDocument = null,
    decoration_count: usize = 0,
    activated: bool = false,
    activation_tracker: extension_service.ActivationTracker,
    needs_render: bool = false,
    editor_service: EditorService,
    active_editor_listener: ?usize = null,
    visible_editors_listener: ?usize = null,
    group_model_listener: ?usize = null,
    add_group_listener: ?usize = null,
    remove_group_listener: ?usize = null,
    move_group_listener: ?usize = null,
    tabs_task: Task = .{},
    models_task: Task = .{},
    models: documents_and_editors.ModelCollection,
    active_selection_handler: ViewEventHandler,
    selection_task: Task = .{},
    visible_ranges_task: Task = .{},
    pending_selection_source: SelectionSource = .keyboard,
    /// The active editor whose scroll events are mirrored to the host.
    scroll_listener_editor: ?*Editor = null,
    inline_completions: @import("inlineCompletionSession.zig").Session = undefined,
    language_features_actor: ?MainThreadLanguageFeatures = null,
    diagnostics_actor: ?*MainThreadDiagnostics = null,
    storage_actor: ?MainThreadStorage = null,
    statusbar_actor: ?MainThreadStatusBar = null,
    terminal_completion_provider: @import("terminalCompletionSession.zig").Session = undefined,
    terminal_completions: ?TerminalSuggestAddon = null,
    secret_state: @import("mainThreadSecretState.zig").SecretState = .{},
    accounts: @import("mainThreadAuthentication.zig").Accounts = undefined,
    task_service: @import("../../contrib/tasks/browser/abstractTaskService.zig").AbstractTaskService = undefined,
    task_actor: @import("mainThreadTask.zig").MainThreadTask = undefined,
    message_service: @import("mainThreadMessageService.zig").MainThreadMessageService = undefined,
    commands_actor: ?MainThreadCommands = null,
    configuration_actor: ?MainThreadConfiguration = null,
    documents_actor: ?MainThreadDocuments = null,
    text_editors_actor: ?MainThreadTextEditors = null,
    editor_tabs_actor: ?MainThreadEditorTabs = null,
    window_actor: ?MainThreadWindow = null,
    extension_service_actor: ?MainThreadExtensionService = null,
    /// The selections the extension host already knows about. Upstream's
    /// `MainThreadTextEditor` keeps the same mirror and sends a properties
    /// delta only when the selection differs; here it also swallows the echo
    /// of `$trySetSelections`, which the host applied itself.
    last_selections: std.array_list.Managed(Selection),
    /// Source reported with the next selection delta; the app sets it from the
    /// input event being dispatched.
    selection_source: SelectionSource = .keyboard,

    pub const ExtensionPath = extension_service.ExtensionPath;

    pub fn init(
        allocator: Allocator,
        io: Io,
        services: Services,
        extension_paths: []const ExtensionPath,
        user_data_dir: []const u8,
        runtime_dir: []const u8,
    ) !*Extensions {
        const self = try allocator.create(Extensions);
        errdefer allocator.destroy(self);

        const owned_descriptions = try extension_service.readExtensions(allocator, io, extension_paths);
        errdefer {
            for (owned_descriptions) |*description| description.deinit(allocator);
            allocator.free(owned_descriptions);
        }
        const extension_ptrs = try allocator.alloc(*const manager.ExtensionDescription, owned_descriptions.len);
        errdefer allocator.free(extension_ptrs);
        for (owned_descriptions, 0..) |*description, index| {
            extension_ptrs[index] = description;
            // Extension settings are part of the workbench configuration that
            // the host receives during `$initializeConfiguration`.
            services.register_extension_configuration(services.common.context, description.manifest, description.identifier);
        }

        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        const data = try std.fs.path.resolve(allocator, &.{ cwd, user_data_dir });
        errdefer allocator.free(data);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .services = services,
            .editor_service = services.common.editors,
            .host = undefined,
            .descriptions = owned_descriptions,
            .extension_ptrs = extension_ptrs,
            .user_data_dir = data,
            .activation_tracker = extension_service.ActivationTracker.init(allocator),
            .last_selections = std.array_list.Managed(Selection).init(allocator),
            .models = documents_and_editors.ModelCollection.init(allocator, .{ .context = self, .notify = notifyModelMirror }),
            .active_selection_handler = ViewEventHandler.init(self, .{ .onCursorStateChanged = onActiveSelection }),
        };

        self.models_task = .{ .queue = services.window, .context = self, .run = updateModels, .progress = true };
        self.tabs_task = .{ .queue = services.window, .context = self, .run = updateTabs, .progress = true };
        self.selection_task = .{ .queue = services.window, .context = self, .run = updateSelection, .progress = true };
        self.visible_ranges_task = .{ .queue = services.window, .context = self, .run = updateVisibleRanges, .progress = true };
        const host_script = try std.fs.path.join(allocator, &.{ runtime_dir, "extensionHost.mjs" });
        defer allocator.free(host_script);
        // Fail before spawning node: without the bundle the host can never
        // connect, and the manager would otherwise wait for its socket timeout.
        std.Io.Dir.cwd().access(io, host_script, .{}) catch return error.ExtensionHostBundleMissing;
        const workspace_path = try std.fs.path.resolve(allocator, &.{ cwd, services.workspace_folder_path(services.common.context) orelse "." });
        defer allocator.free(workspace_path);
        self.host = try manager.HostManager.start(allocator, .{
            .host_script = host_script,
            .extensions = self.extension_ptrs,
            .workspace_path = workspace_path,
            .workspace_name = "workspace",
            .user_data_dir = data,
            .app_root = runtime_dir,
            .parent_pid = @intCast(manager.currentProcessId()),
        });
        errdefer self.host.deinit();
        errdefer self.models.deinit();
        self.inline_completions = .{
            .editors = services.common.editors,
            .configuration = .{ .context = self, .get_value = configurationValue },
            .io = io,
            .window = services.window,
            .host_context = self,
            .has_editor_focus = hasEditorFocus,
            .request_frame = requestTerminalFrame,
            .host = self.host,
            .arena = .init(allocator),
        };
        errdefer self.inline_completions.deinit();

        self.message_service = .{ .allocator = allocator, .notification_service = services.notification, .dialog_service = services.dialog };
        errdefer self.message_service.deinit();
        self.storage_actor = try MainThreadStorage.init(allocator);
        self.statusbar_actor = try MainThreadStatusBar.init(allocator, services.common.statusbar, .{
            .context = self,
            .callback = requestTerminalFrame,
        });
        self.commands_actor = try MainThreadCommands.init(allocator, self.host, .{
            .context = self,
            .execute = executeHostCommand,
        }, services.common.commands, self.descriptions, try services.context_keys(services.common.context));
        self.configuration_actor = MainThreadConfiguration.init(
            allocator,
            .{ .context = self, .data = configurationDataHost },
            .{ .context = self, .notify = configurationNotifyHost },
        );
        self.documents_actor = .{ .host = .{
            .context = self,
            .open = documentsOpenHost,
            .create = documentsCreateHost,
            .save = documentsSaveHost,
        } };
        self.text_editors_actor = MainThreadTextEditors.init(allocator, .{
            .context = self,
            .set_selections = textEditorSetSelectionsHost,
            .apply_edits = textEditorApplyEditsHost,
            .show_document = textEditorShowDocumentHost,
            .reveal = textEditorRevealHost,
        });
        self.editor_tabs_actor = MainThreadEditorTabs.init(allocator, .{
            .context = self,
            .notify = editorTabsNotifyHost,
            .move_tab = editorTabsMoveHost,
            .close_tab = editorTabsCloseTabHost,
            .close_group = editorTabsCloseGroupHost,
        });
        self.window_actor = .{ .host = .{ .context = self, .open_uri = windowOpenUriHost } };
        self.extension_service_actor = .{ .host = .{
            .context = self,
            .on_did_activate = extensionServiceActivatedHost,
            .as_browser_uri = extensionServiceBrowserUriHost,
        } };
        try self.accounts.init(allocator, services.common.commands, services.common.quick_input, .{ .context = services.common.context, .show = services.common.status_hint }, self.host, self.descriptions);
        errdefer self.accounts.deinit();
        try self.task_service.init(allocator, services.common.commands, services.common.quick_input, self.descriptions, .{
            .context = self,
            .activate = activateTaskType,
            .run_terminal = runTaskInTerminal,
        });
        errdefer self.task_service.deinit();
        self.task_actor = .{ .allocator = allocator, .host = self.host, .service = self.task_service.interface() };
        errdefer self.task_actor.deinit();
        for (self.descriptions) |extension| {
            if (!std.ascii.eqlIgnoreCase(extension.identifier, "vscode.terminal-suggest")) continue;
            self.terminal_completion_provider = .{ .host = self.host, .allocator = allocator };
            // Take the address only after the optional payload is in its final slot.
            self.terminal_completions = @as(TerminalSuggestAddon, undefined);
            try self.terminal_completions.?.init(allocator, .{
                .context = self,
                .focused = focusedTerminal,
                .find = findTerminal,
                .request_render = requestTerminalFrame,
            }, self.terminal_completion_provider.interface(), services.common.commands, services.quick_access);
            break;
        }
        errdefer if (self.terminal_completions) |*session| session.deinit();
        self.registerActors();
        self.initLanguageActors() catch |err| {
            std.log.warn("language feature actors unavailable: {s}", .{@errorName(err)});
        };
        errdefer self.removeActiveDocument() catch {};
        try self.boot(runtime_dir);
        try self.registerEditorListeners();
        return self;
    }

    pub fn deinit(self: *Extensions) void {
        if (self.services.quick_access.isOpen()) self.services.quick_access.inputService().hide();
        self.message_service.deinit();
        if (self.terminal_completions) |*session| session.deinit();
        self.secret_state.deinit(self.allocator);
        self.accounts.deinit();
        self.task_actor.deinit();
        self.task_service.deinit();
        self.inline_completions.deinit();
        self.unregisterEditorListeners();
        self.removeActiveDocument() catch {};
        self.models.deinit();
        if (self.diagnostics_actor) |actor| {
            actor.deinit();
            self.diagnostics_actor = null;
        }
        if (self.language_features_actor) |*actor| actor.deinit();
        if (self.storage_actor) |*actor| actor.deinit();
        if (self.statusbar_actor) |*actor| actor.deinit();
        if (self.commands_actor) |*actor| actor.deinit();
        if (self.configuration_actor) |*actor| actor.deinit();
        if (self.editor_tabs_actor) |*actor| actor.deinit();
        self.activation_tracker.deinit();
        self.last_selections.deinit();
        self.host.deinit();
        for (self.descriptions) |*description| description.deinit(self.allocator);
        self.allocator.free(self.descriptions);
        self.allocator.free(self.extension_ptrs);
        self.allocator.free(self.user_data_dir);
        self.allocator.destroy(self);
    }

    fn registerActors(self: *Extensions) void {
        var nid: u8 = 1;
        while (nid <= protocol.max_nid) : (nid += 1) {
            const entry = protocol.identifier(nid).?;
            if (nid == @backingInt(protocol.MainContext.MainThreadSecretState)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeSecretState });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadAuthentication)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeAuthentication });
            } else if (nid == 26) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeLanguageFeatures });
            } else if (nid == 16) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeDiagnostics });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadStorage)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeStorage });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadStatusBar)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeStatusBar });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadCommands)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeCommands });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadConfiguration)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeConfiguration });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadDocuments)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeDocuments });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadTextEditors)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeTextEditors });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadEditorTabs)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeEditorTabs });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadTask)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeTask });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadWindow)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeWindow });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadExtensionService)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeExtensionService });
            } else {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invoke });
            }
        }
    }

    fn initLanguageActors(self: *Extensions) !void {
        const features = self.services.common.language_features(self.services.common.context) orelse return;
        const marker_service = self.services.marker_service orelse return;
        self.language_features_actor = MainThreadLanguageFeatures.init(self.allocator, features, .{
            .context = self,
            .request = languageFeaturesRequest,
            .notify = languageFeaturesNotify,
            .request_async = languageFeaturesRequestAsync,
        });
        try self.inline_completions.start(&self.language_features_actor.?);
        self.diagnostics_actor = try MainThreadDiagnostics.init(self.allocator, marker_service, .{
            .context = self,
            .notify = diagnosticsNotify,
        }, .{ .context = self, .model_for = diagnosticsModelFor });
    }

    fn languageFeaturesRequest(context: *anyopaque, allocator: Allocator, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, timeout_ms: u32) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.host.requestSync(allocator, proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures), method, args, token, timeout_ms);
    }

    const AsyncLanguageRequest = struct {
        owner: *Extensions,
        request_id: u32,
        callback: rpc.ReplyCallback,

        fn complete(context: *anyopaque, reply: rpc.Reply) void {
            const self: *AsyncLanguageRequest = @ptrCast(@alignCast(context));
            const allocator = self.owner.allocator;
            const callback = self.callback;
            allocator.destroy(self);
            callback.call(reply);
        }
        fn cancel(context: *anyopaque) void {
            const self: *AsyncLanguageRequest = @ptrCast(@alignCast(context));
            self.owner.host.rpc.cancel(self.request_id);
            self.owner.allocator.destroy(self);
        }
    };

    fn languageFeaturesRequestAsync(context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !@import("../../../base/common/lifecycle.zig").IDisposable {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const pending = try self.allocator.create(AsyncLanguageRequest);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .owner = self, .request_id = 0, .callback = callback };
        pending.request_id = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures), method, args, @import("../../../base/common/cancellation.zig").CancellationToken.None, .{ .context = pending, .callback = AsyncLanguageRequest.complete });
        return .{ .context = pending, .disposeFn = AsyncLanguageRequest.cancel };
    }

    fn languageFeaturesNotify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures), method, args);
    }

    fn diagnosticsNotify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDiagnostics), method, args);
    }

    fn focusedTerminal(context: *anyopaque) ?*TerminalInstance {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.services.focused_terminal(self.services.common.context);
    }

    fn findTerminal(context: *anyopaque, id: usize) ?*TerminalInstance {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.services.common.terminal_instance(self.services.common.context, id);
    }

    fn requestTerminalFrame(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.needs_render = true;
    }

    fn hasEditorFocus(context: *anyopaque) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.services.has_editor_focus(self.services.common.context);
    }

    fn configurationValue(context: *anyopaque, key: []const u8) ?*const @import("../../../platform/configuration/common/configuration.zig").Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const service = self.services.common.configuration(self.services.common.context) orelse return null;
        return service.getValue(key, .{});
    }

    fn diagnosticsModelFor(context: *anyopaque, resource: markers_mod.Resource) ?*TextModel {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const key = resource.key(self.allocator) catch return null;
        defer self.allocator.free(key);
        return self.models.modelForResource(key);
    }

    fn invokeLanguageFeatures(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.language_features_actor) |*actor| return actor.invoke(method, args, token, arena);
        return .empty;
    }

    fn invokeDiagnostics(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.diagnostics_actor) |actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeStorage(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.storage_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeStatusBar(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.statusbar_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeCommands(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, method, "$executeCommand") and args.len > 1 and args[0] == .json and args[0].json == .string and std.mem.eql(u8, args[0].json.string, "_executeCodeLensProvider")) {
            if (args[1] != .json or args[1].json != .array or args[1].json.array.items.len == 0) return error.InvalidArguments;
            const parameters = args[1].json.array.items;
            const components = try std_uri.componentsFromJson(parameters[0], arena);
            const key = try std_uri.resourceKeyFromComponents(arena, components);
            const document = self.models.documentForResource(key) orelse return error.InvalidArguments;
            const count: ?usize = if (parameters.len > 1) switch (parameters[1]) {
                .null => null,
                .integer => |number| @intCast(@max(0, number)),
                .float => |number| if (std.math.isFinite(number) and number <= @as(f64, @floatFromInt(std.math.maxInt(i32)))) @intFromFloat(@ceil(@max(0, number))) else return error.InvalidArguments,
                else => return error.InvalidArguments,
            } else null;
            const provider = if (self.language_features_actor) |*actor| actor else return error.LanguageFeaturesUnavailable;
            return provider.executeCodeLensCommand(document, count, self.services.common.commands, self.services.window);
        }
        if (self.commands_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeSecretState(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.secret_state.invoke(self.allocator, self.host, method, args, arena);
    }

    fn invokeAuthentication(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.accounts.invoke(method, args, arena);
    }

    fn invokeConfiguration(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.configuration_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeDocuments(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.documents_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeTextEditors(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.text_editors_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeEditorTabs(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.editor_tabs_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeTask(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, _: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.task_actor.invoke(method, args);
    }

    fn invokeWindow(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.window_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeExtensionService(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.extension_service_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn windowOpenUriHost(context: *anyopaque, uri: std.json.Value) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (uri != .object) return false;
        const scheme = uri.object.get("scheme") orelse return false;
        if (scheme != .string) return false;
        if (std.mem.eql(u8, scheme.string, "https") or std.mem.eql(u8, scheme.string, "http")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const components = try std_uri.componentsFromJson(uri, a);
            if (components.authority.len == 0) return false;
            const url = try std_uri.resourceKeyFromComponents(a, components);
            for (url) |byte| if (byte < 32 or byte == 127) return false;
            return @import("../../../platform/opener/common/opener.zig").openExternal(self.allocator, self.io, url) catch false;
        }
        if (!std.mem.eql(u8, scheme.string, "file")) return false;
        const path = uriPath(uri) orelse return false;
        self.services.common.open_path(self.services.common.context, path) catch return false;
        self.needs_render = true;
        return true;
    }

    fn extensionServiceActivatedHost(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.activated = true;
    }

    fn extensionServiceBrowserUriHost(_: *anyopaque, uri: std.json.Value) std.json.Value {
        return uri;
    }

    fn editorTabsNotifyHost(context: *anyopaque, model: std.json.Value) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var args = [_]rpc.Arg{.{ .json = model }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditorTabs), "$acceptEditorTabModel", &args, null, manager.noop_callback) catch {};
    }

    fn editorTabsMoveHost(_: *anyopaque, _: []const u8, _: usize) anyerror!void {}

    const LocatedTab = struct { pane: *GroupPane, tab: *Tab };

    fn findTabById(self: *Extensions, id: []const u8) !?LocatedTab {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        for (self.editor_service.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (std.mem.eql(u8, id, try tabId(arena.allocator(), pane, tab))) return .{ .pane = pane, .tab = tab };
            }
        }
        return null;
    }

    fn editorTabsCloseTabHost(context: *anyopaque, tab_id: []const u8) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const target = (try self.findTabById(tab_id)) orelse return false;
        const opening = self.editor_service.opening orelse return false;
        try opening.group_actions.closeEditor(target.pane, target.tab);
        self.needs_render = true;
        // A dirty editor's asynchronous confirmation may still be pending;
        // do not report success before the group actually closes the tab.
        return (try self.findTabById(tab_id)) == null;
    }

    fn editorTabsCloseGroupHost(context: *anyopaque, group_id: i64) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const id = std.math.cast(u32, group_id) orelse return false;
        const opening = self.editor_service.opening orelse return false;
        const part = self.editor_service.part;
        while (part.service.getGroup(id)) |group| {
            const pane = part.viewForGroup(group) orelse return false;
            const old_count = pane.tabs.items.len;
            if (old_count == 0) {
                _ = part.collapseView(pane);
                self.needs_render = true;
                return true;
            }
            try opening.group_actions.closeEditor(pane, pane.tabs.items[0]);
            self.needs_render = true;
            const current = part.service.getGroup(id) orelse return true;
            const remaining = part.viewForGroup(current) orelse return false;
            if (remaining.tabs.items.len >= old_count) return false;
        }
        return true;
    }

    fn documentsOpenHost(context: *anyopaque, uri: std.json.Value, options: std.json.Value, arena: Allocator) anyerror!std.json.Value {
        _ = options;
        const self: *Extensions = @ptrCast(@alignCast(context));
        const components = try std_uri.componentsFromJson(uri, arena);
        const key = try std_uri.resourceKeyFromComponents(arena, components);
        if (self.models.modelForResource(key)) |model| return try std_uri.jsonComponents(arena, model.uri());
        if (!std.mem.eql(u8, components.scheme, "file")) return .null;
        const path = uriPath(uri) orelse return .null;
        self.services.common.open_path(self.services.common.context, path) catch {};
        // Make the document known before `workspace.openTextDocument`
        // resolves; the extension host otherwise waits for the next pump.
        self.syncActiveDocument() catch {};
        self.needs_render = true;
        // Return the resource the document mirror registered, not the caller's
        // path spelling, so an extension-requested open joins the same
        // document (`$tryOpenDocument` resolves to this URI).
        const opened = self.editor_service.findOpenFileInput(self.io, path) orelse return .null;
        return try std_uri.jsonComponents(arena, opened.editor.model.uri());
    }

    fn documentsCreateHost(context: *anyopaque, options: std.json.Value, arena: Allocator) anyerror!std.json.Value {
        _ = options;
        _ = context;
        return manager.fileUri(arena, "/tmp/untitled");
    }

    fn documentsSaveHost(context: *anyopaque, uri: std.json.Value) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const components = try std_uri.componentsFromJson(uri, arena);
        const key = try std_uri.resourceKeyFromComponents(arena, components);
        const editor = self.models.writableEditorForResource(key) orelse return false;
        editor.save() catch return false;
        self.needs_render = true;
        return true;
    }

    fn textEditorSetSelectionsHost(context: *anyopaque, selections: []Selection) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const editor = if (self.active) |active| active.editor else return;
        for (selections) |*selection| {
            selection.startColumn = columnFromUtf16ForModel(editor.model, selection.startLineNumber, selection.startColumn);
            selection.endColumn = columnFromUtf16ForModel(editor.model, selection.endLineNumber, selection.endColumn);
        }
        if (selections.len > 0) {
            editor.setSelections(selections) catch {};
            self.needs_render = true;
        }
        self.captureSelections(editor);
    }

    fn textEditorApplyEditsHost(context: *anyopaque, version: u32, edits: []const EditSpec) anyerror!void {
        _ = version;
        const self: *Extensions = @ptrCast(@alignCast(context));
        const editor = if (self.active) |active| active.editor else return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        try self.applyEditSpecs(arena_instance.allocator(), editor, edits);
    }

    fn textEditorShowDocumentHost(context: *anyopaque, uri: std.json.Value, options: std.json.Value) anyerror!?[]const u8 {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const path = uriPath(uri) orelse return null;
        self.services.common.open_path(self.services.common.context, path) catch {};
        if (self.editor_service.activeEditorPane()) |tab| applyShowDocumentSelection(tab.editor, options);
        self.syncActiveDocument() catch {};
        self.syncSelection() catch {};
        self.needs_render = true;
        return "1";
    }

    fn textEditorRevealHost(
        context: *anyopaque,
        range: RevealSpec,
        reveal_type: TextEditorRevealType,
    ) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.active) |active| {
            const vertical_type: view_events.VerticalRevealType = switch (reveal_type) {
                .default => .Simple,
                .in_center => .Center,
                .in_center_if_outside_viewport => .CenterIfOutsideViewport,
                .at_top => .Top,
            };
            const start = std.math.clamp(range.start_line, 1, active.editor.model.getLineCount());
            const end = std.math.clamp(range.end_line, start, active.editor.model.getLineCount());
            _ = active.editor.revealRange(
                Range.init(start, 1, end, active.editor.model.getLineMaxColumn(end)),
                vertical_type,
            );
        }
        self.sendVisibleRanges() catch {};
        self.needs_render = true;
    }

    fn configurationDataHost(context: *anyopaque, arena: Allocator) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.services.configuration_data(self.services.common.context, arena);
    }

    fn configurationNotifyHost(context: *anyopaque, arena: Allocator, data: std.json.Value, changed_key: []const u8) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var change: std.json.ObjectMap = .empty;
        var keys = std.json.Array.init(arena);
        try keys.append(.{ .string = try arena.dupe(u8, changed_key) });
        try change.put(arena, "keys", .{ .array = keys });
        try change.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
        var args = [_]rpc.Arg{
            .{ .json = data },
            .{ .json = .{ .object = change } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostConfiguration), "$acceptConfigurationChanged", &args, null, manager.noop_callback) catch {};
    }

    fn boot(self: *Extensions, runtime_dir: []const u8) !void {
        try self.host.expectControl(2, 10_000);
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", arena);
        const workspace = try std.fs.path.resolve(arena, &.{ cwd, self.services.workspace_folder_path(self.services.common.context) orelse "." });
        const init_data = try manager.buildInitData(arena, .{
            .host_script = "",
            .extensions = self.extension_ptrs,
            .workspace_path = workspace,
            .workspace_name = "workspace",
            .user_data_dir = self.user_data_dir,
            .app_root = try std.fs.path.resolve(arena, &.{ cwd, runtime_dir }),
            .parent_pid = @intCast(manager.currentProcessId()),
        });
        try self.host.sendInitData(init_data);
        try self.host.expectControl(1, 10_000);

        var workspace_args = std.array_list.Managed(rpc.Arg).init(arena);
        var workspace_data: std.json.ObjectMap = .empty;
        try workspace_data.put(arena, "id", .{ .string = "workspace" });
        try workspace_data.put(arena, "name", .{ .string = "workspace" });
        try workspace_data.put(arena, "transient", .{ .bool = false });
        try workspace_data.put(arena, "configuration", .null);
        try workspace_data.put(arena, "isUntitled", .null);
        var folders = std.json.Array.init(arena);
        var folder: std.json.ObjectMap = .empty;
        try folder.put(arena, "uri", try manager.fileUri(arena, workspace));
        try folder.put(arena, "name", .{ .string = "workspace" });
        try folder.put(arena, "index", .{ .integer = 0 });
        try folders.append(.{ .object = folder });
        try workspace_data.put(arena, "folders", .{ .array = folders });
        try workspace_args.append(.{ .json = .{ .object = workspace_data } });
        try workspace_args.append(.{ .json = .{ .bool = true } });
        try self.callAndWait(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostWorkspace),
            "$initializeWorkspace",
            workspace_args.items,
            5_000,
            error.InitializeWorkspaceRejected,
        );

        const configuration_data = try self.services.configuration_data(self.services.common.context, arena);
        var config_args = [_]rpc.Arg{.{ .json = if (configuration_data == .null) try emptyConfig(arena) else configuration_data }};
        try self.callAndWait(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostConfiguration),
            "$initializeConfiguration",
            &config_args,
            5_000,
            error.InitializeConfigurationRejected,
        );

        var delta: std.json.ObjectMap = .empty;
        try delta.put(arena, "versionId", .{ .integer = 1 });
        try delta.put(arena, "toRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "toAdd", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "addActivationEvents", .{ .object = .empty });
        try delta.put(arena, "myToRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "myToAdd", .{ .array = std.json.Array.init(arena) });
        var start_args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
        try self.callAndWait(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService),
            "$startExtensionHost",
            &start_args,
            10_000,
            error.StartExtensionHostRejected,
        );

        try self.syncActiveDocument();
        try self.syncTabs();
        try self.host.activateByEvent("onStartupFinished", 0);
    }

    /// Calls a host method and waits for its reply. A rejected reply becomes
    /// `rejected` instead of being ignored: the handshake calls are barriers on
    /// the host side, so a rejected `$initializeConfiguration` used to leave the
    /// host waiting forever while the editor carried on without an extension.
    fn callAndWait(
        self: *Extensions,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const rpc.Arg,
        timeout_ms: u32,
        rejected: anyerror,
    ) !void {
        var wait = WaitFlag{};
        _ = try self.host.call(identifier, method, args, null, .{ .context = &wait, .callback = WaitFlag.callback });
        try self.host.waitUntil(&wait, done, timeout_ms);
        if (wait.failed) return rejected;
    }

    // Upstream MainThreadDocumentAndEditorStateComputer and MainThreadEditorTabs
    // subscribe to editor/model/group lifecycle events. A terminal group model
    // changes before its pane is mounted, so use the mounted EditorService pane
    // for the document mirror and coalesce group-tab changes on the window.
    fn registerEditorListeners(self: *Extensions) !void {
        errdefer self.unregisterEditorListeners();
        self.active_editor_listener = try self.editor_service.onDidActiveEditorChange().listen(self, onActiveEditorChanged);
        self.visible_editors_listener = try self.editor_service.onDidVisibleEditorsChange().listen(self, onVisibleEditorsChanged);
        const part = self.editor_service.part;
        self.group_model_listener = try part.service.on_did_change_group_model.listen(self, onGroupModelChanged);
        self.add_group_listener = try part.on_did_add_group.listen(self, onGroupChanged);
        self.remove_group_listener = try part.on_did_remove_group.listen(self, onGroupChanged);
        self.move_group_listener = try part.on_did_move_group.listen(self, onGroupChanged);
    }
    fn unregisterEditorListeners(self: *Extensions) void {
        if (self.active_editor_listener) |id| self.editor_service.onDidActiveEditorChange().unlisten(id);
        if (self.visible_editors_listener) |id| self.editor_service.onDidVisibleEditorsChange().unlisten(id);
        const part = self.editor_service.part;
        if (self.group_model_listener) |id| part.service.on_did_change_group_model.unlisten(id);
        if (self.add_group_listener) |id| part.on_did_add_group.unlisten(id);
        if (self.remove_group_listener) |id| part.on_did_remove_group.unlisten(id);
        if (self.move_group_listener) |id| part.on_did_move_group.unlisten(id);
        self.tabs_task.schedule(null);
        self.models_task.schedule(null);
        self.selection_task.schedule(null);
        self.visible_ranges_task.schedule(null);
    }
    fn onActiveEditorChanged(_: ?*EditorInput, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        self.tabs_task.post();
    }
    fn onVisibleEditorsChanged(_: void, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        self.models_task.post();
        self.tabs_task.post();
    }
    fn onGroupChanged(_: *GroupPane, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        self.models_task.post();
        self.tabs_task.post();
    }
    fn onGroupModelChanged(event: GroupModelChangeEvent, self: *Extensions) !void {
        switch (event) {
            .EDITOR_OPEN, .EDITOR_CLOSE => {
                self.models_task.post();
                self.tabs_task.post();
            },
            .EDITOR_MOVE, .EDITOR_ACTIVE, .EDITOR_DIRTY, .EDITOR_LABEL, .EDITOR_PIN, .EDITOR_STICKY, .EDITOR_TRANSIENT => self.tabs_task.post(),
            else => {},
        }
    }
    fn updateTabs(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.syncTabs() catch {};
        return true;
    }
    fn onActiveSelection(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.pending_selection_source = self.selection_source;
        self.selection_task.post();
        return false;
    }
    fn updateSelection(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.syncSelectionFrom(self.pending_selection_source) catch {};
        return true;
    }
    fn updateVisibleRanges(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.sendVisibleRanges() catch {};
        return true;
    }
    fn onActiveTabWillDispose(_: void, self: *Extensions) !void {
        // Do not wait for the next host pump: the editor and its listeners
        // are still alive at this point in the pane's disposal lifecycle.
        self.removeActiveDocument() catch {};
    }
    fn onActiveEditorWillDispose(_: void, self: *Extensions) !void {
        // A virtualized item can unmount while its input and text documents
        // remain open. Detach from the old code editor before it is released.
        self.removeActiveDocument() catch {};
    }
    fn onActiveLanguageChanged(event: ModelLanguageChangedEvent, self: *Extensions) !void {
        const active = if (self.active) |*value| value else return;
        const language = try self.allocator.dupe(u8, event.newLanguage);
        self.allocator.free(active.language_id);
        active.language_id = language;
        self.activation_tracker.activateLanguage(self.host, event.newLanguage);
    }

    /// Drains incoming extension messages. Returns true when the TUI should
    /// repaint (an edit, selection, or status entry changed).
    pub fn pump(self: *Extensions) bool {
        _ = self.host.pump();
        if (self.diagnostics_actor) |actor| actor.flush() catch {};
        if (self.accounts.changed) {
            self.accounts.changed = false;
            self.needs_render = true;
        }
        const result = self.needs_render;
        self.needs_render = false;
        return result;
    }

    fn notifyModelMirror(context: *anyopaque, actor: documents_and_editors.ModelCollection.Actor, method: []const u8, args: []const rpc.Arg) !void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const identifier = switch (actor) {
            .documents => protocol.ExtHostContext.ExtHostDocuments,
            .documents_and_editors => protocol.ExtHostContext.ExtHostDocumentsAndEditors,
        };
        try self.host.notify(proxyIdentifier.identifierFromEnum(identifier), method, args);
    }

    fn updateModels(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.syncActiveDocument() catch {};
        self.syncDocumentModels() catch {};
        return true;
    }

    fn activeCodeEditorForTab(tab: *Tab) ?*Editor {
        if (tab.isImage() or tab.terminalInstance() != null) return null;
        if (tab.diff) |diff| return diff.widget.focusedEditor();
        if (tab.multi_diff) |multi| {
            const control = multi.widget.activeControl() orelse return null;
            return control.focusedEditor();
        }
        return tab.editor;
    }

    fn syncDocumentModels(self: *Extensions) !void {
        var documents: std.ArrayList(*EditorDocument) = .empty;
        defer documents.deinit(self.allocator);
        if (self.editor_service.activeEditorPane()) |tab| {
            if (activeCodeEditorForTab(tab)) |editor| try documents.append(self.allocator, editor.document);
        }
        for (self.editor_service.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.isImage() or tab.terminalInstance() != null) continue;
                if (tab.multi_diff) |multi| {
                    for (multi.input.entries) |entry| {
                        for ([_]?@import("../../../editor/browser/widget/multiDiffEditor/model.zig").DiffItemSource{ entry.item.original, entry.item.modified }) |source| {
                            if (source) |side| if (side.textModel) |document| try documents.append(self.allocator, document);
                        }
                    }
                } else if (tab.diff) |diff| {
                    try documents.appendSlice(self.allocator, &.{ diff.widget.original_editor.document, diff.widget.modified_editor.document });
                } else try documents.append(self.allocator, tab.editor.document);
            }
        }
        try self.models.synchronizeDocuments(documents.items);
    }

    fn syncActiveDocument(self: *Extensions) !void {
        const tab = self.editor_service.activeEditorPane() orelse {
            if (self.active != null) try self.removeActiveDocument();
            try self.syncDocumentModels();
            return;
        };
        const editor = activeCodeEditorForTab(tab) orelse {
            if (self.active != null) try self.removeActiveDocument();
            try self.syncDocumentModels();
            return;
        };
        if (self.active) |active| {
            if (active.tab == tab and active.editor == editor) return;
            try self.removeActiveDocument();
        }
        try self.syncDocumentModels();

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const uri = try self.allocator.dupe(u8, try std_uri.fsPath(editor.model.uri(), arena));
        errdefer self.allocator.free(uri);
        const language = try self.allocator.dupe(u8, editor.languageId());
        errdefer self.allocator.free(language);

        const language_ids = try editor.language_service.getRegisteredLanguageIds(arena);
        var ids = std.json.Array.init(arena);
        for (language_ids) |id| try ids.append(.{ .string = id });
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguages), "$acceptLanguageIds", &.{.{ .json = .{ .array = ids } }});

        const selections = try editor.getSelections();
        defer editor.allocator.free(selections);
        const delta = try documents_and_editors.addedEditorDelta(arena, editor.model, .{
            .tab_size = editor.cursor_config.tabSize,
            .indent_size = editor.cursor_config.indentSize,
            .insert_spaces = editor.cursor_config.insertSpaces,
        }, selections);
        const dispose_listener = try tab.listenWillDispose(self, onActiveTabWillDispose);
        errdefer tab.unlistenWillDispose(dispose_listener);
        const editor_dispose_listener = try editor.on_will_dispose.listen(self, onActiveEditorWillDispose);
        errdefer editor.on_will_dispose.unlisten(editor_dispose_listener);
        const language_listener = try editor.model.listenDidChangeLanguage(self, onActiveLanguageChanged);
        errdefer editor.model.removeDidChangeLanguageListener(language_listener);
        try notifyModelMirror(self, .documents_and_editors, "$acceptDocumentsAndEditorsDelta", &.{.{ .json = delta }});
        editor.addViewEventHandler(&self.active_selection_handler);
        self.active = .{ .tab = tab, .dispose_listener = dispose_listener, .editor_dispose_listener = editor_dispose_listener, .language_listener = language_listener, .editor = editor, .uri = uri, .language_id = language };
        self.setScrollListener(editor);
        self.captureSelections(editor);
        self.activation_tracker.activateLanguage(self.host, editor.languageId());
        self.needs_render = true;
    }

    /// Mirrors upstream EditorResourceAccessor.getCanonicalUri with BOTH for
    /// composite diffs. The group's ID also distinguishes identical inputs in
    /// different groups, and virtual resource queries are never dropped.
    fn tabId(arena: Allocator, pane: *GroupPane, tab: *Tab) ![]const u8 {
        const resource = if (tab.diff) |diff| try std.fmt.allocPrint(arena, "{s}-{s}", .{
            try std_uri.encodedResource(arena, diff.modified_input.resolve().model.uri()),
            try std_uri.encodedResource(arena, diff.original_input.resolve().model.uri()),
        }) else if (tab.multi_diff) |multi| multi.input.source_uri else if (tab.markdown_panel != null or tab.terminal_input != null) tab.input.resource orelse "undefined-undefined" else try std_uri.encodedResource(arena, tab.editor.model.uri());
        return std.fmt.allocPrint(arena, "{d}~{s}-{s}-{s} ", .{ pane.group.id, tab.input.editor_id orelse "undefined", tab.input.type_id, resource });
    }

    fn tabInput(arena: Allocator, tab: *Tab) !editor_tabs.TabInputSpec {
        if (tab.diff) |diff| return .{ .text_diff = .{
            .original = diff.original_input.resolve().model.uri(),
            .modified = diff.modified_input.resolve().model.uri(),
        } };
        if (tab.multi_diff) |multi| {
            var pairs: std.ArrayList(editor_tabs.TextDiffSpec) = .empty;
            // Upstream describes the input's declared resources, not the
            // mounted/filtered/sorted view models. Added/deleted resources
            // have no TextDiffInputDto when either URI is absent.
            for (multi.input.resources() orelse &.{}) |resource| {
                const original = resource.originalUri orelse continue;
                const modified = resource.modifiedUri orelse continue;
                try pairs.append(arena, .{ .original = original, .modified = modified });
            }
            return .{ .multi_diff = pairs.items };
        }
        if (tab.terminal_input != null) return .terminal;
        if (tab.image_input != null) return .{ .custom = .{ .uri = tab.editor.model.uri(), .view_type = tab.input.editor_id orelse "" } };
        if (tab.markdown_panel != null) return .{ .webview = tab.input.editor_id orelse "" };
        if (tab.file_input != null or tab.text_resource_input != null) return .{ .text = tab.editor.model.uri() };
        return .unknown;
    }

    fn syncTabs(self: *Extensions) !void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const part = self.editor_service.part;
        const panes = try part.orderedViews(arena);
        var specs: std.ArrayList(editor_tabs.GroupSpec) = .empty;
        for (panes, 1..) |pane, column| {
            const inputs = try pane.group.model.getEditors(arena, .SEQUENTIAL, false);
            var tabs: std.ArrayList(editor_tabs.TabSpec) = .empty;
            for (inputs) |input| {
                const tab = pane.tabForInput(input) orelse continue;
                try tabs.append(arena, .{
                    .id = try tabId(arena, pane, tab),
                    .label = input.getName(),
                    .editor_id = input.editor_id,
                    .input = try tabInput(arena, tab),
                    .is_active = pane.group.model.activeEditor() == input,
                    .is_dirty = input.isDirty(),
                    .is_pinned = pane.group.model.isSticky(.{ .editor = input }),
                    .is_preview = !pane.group.model.isPinned(.{ .editor = input }),
                });
            }
            try specs.append(arena, .{ .id = pane.group.id, .view_column = column, .is_active = part.activeView() == pane, .tabs = tabs.items });
        }
        if (self.editor_tabs_actor) |*actor| try actor.sync(arena, specs.items);
    }

    fn removeActiveDocument(self: *Extensions) !void {
        const active = self.active orelse return;
        self.active = null;
        self.selection_task.schedule(null);
        self.visible_ranges_task.schedule(null);
        active.tab.unlistenWillDispose(active.dispose_listener);
        active.editor.on_will_dispose.unlisten(active.editor_dispose_listener);
        active.editor.removeViewEventHandler(&self.active_selection_handler);
        active.editor.model.removeDidChangeLanguageListener(active.language_listener);
        self.setScrollListener(null);

        defer self.allocator.free(active.uri);
        defer self.allocator.free(active.language_id);

        self.needs_render = true;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const delta = try documents_and_editors.removedEditorDelta(arena);
        var args = [_]rpc.Arg{.{ .json = delta }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback) catch {};
    }

    fn executeCommand(self: *Extensions, command: []const u8, command_args: []const std.json.Value) void {
        self.host.executeContributedCommand(command, command_args) catch {};
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        if (std.mem.eql(u8, method, "$writeText")) {
            const self: *Extensions = @ptrCast(@alignCast(context));
            if (args.len != 1 or args[0] != .json or args[0].json != .string) return error.InvalidClipboardText;
            const value = args[0].json.string;
            const output = std.Io.File.stdout();
            if (!try output.isTty(self.io)) return error.TerminalClipboardUnavailable;
            const encoder = std.base64.standard.Encoder;
            const prefix = "\x1b]52;c;";
            const size = encoder.calcSize(value.len);
            const sequence = try arena.alloc(u8, prefix.len + size + 1);
            @memcpy(sequence[0..prefix.len], prefix);
            _ = encoder.encode(sequence[prefix.len..][0..size], value);
            sequence[sequence.len - 1] = 7;
            try output.writeStreamingAll(self.io, sequence);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$showMessage")) {
            const self: *Extensions = @ptrCast(@alignCast(context));
            self.needs_render = true;
            return self.message_service.showMessage(args);
        }
        if (std.mem.eql(u8, method, "$startFileSearch")) {
            const self: *Extensions = @ptrCast(@alignCast(context));
            return .{ .json = try @import("mainThreadWorkspace.zig").findFiles(self.io, self.allocator, arena, self.services.workspace_folder_path(self.services.common.context), args) };
        }
        if (std.mem.eql(u8, method, "$getTools")) {
            return .{ .json = .{ .array = std.json.Array.init(arena) } };
        }
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            return .{ .json = .{ .bool = true } };
        }
        return .empty;
    }

    fn applyType(self: *Extensions, arena: Allocator, editor: *Editor, text: []const u8) !void {
        try editor.typeCharacter(text);
        // The content listener mirrors real edits; a cursor-only type (for
        // example overtyping an auto-closing pair) fires no model event.
        try self.sendSelection(arena, .command);
        self.needs_render = true;
    }

    /// Mirrors the selection/scroll result of a command. Content changes are
    /// handled once, by the model's document mirror.
    fn syncAfterEditorCommand(self: *Extensions, _: Allocator, _: *Editor) !void {
        try self.syncSelection();
        self.sendVisibleRanges() catch {};
        self.needs_render = true;
    }

    fn applyCommandEdit(self: *Extensions, arena: Allocator, _: *Editor) !void {
        try self.sendSelection(arena, .command);
        self.needs_render = true;
    }

    fn applyEditSpecs(self: *Extensions, arena: Allocator, editor: *Editor, edits: []const EditSpec) !void {
        var text_edits = std.array_list.Managed(TextEdit).init(self.allocator);
        defer {
            for (text_edits.items) |edit| self.allocator.free(edit.text);
            text_edits.deinit();
        }
        for (edits) |edit| {
            if (edit.text.len == 0 and edit.start_line == edit.end_line and edit.start_column == edit.end_column) continue;
            const range = Range.init(
                edit.start_line,
                columnFromUtf16ForModel(editor.model, edit.start_line, edit.start_column),
                edit.end_line,
                columnFromUtf16ForModel(editor.model, edit.end_line, edit.end_column),
            );
            const copied = try self.allocator.dupe(u8, edit.text);
            errdefer self.allocator.free(copied);
            try text_edits.append(.{ .range = range, .text = copied });
        }
        if (text_edits.items.len == 0) return;
        try editor.applyTextEdits(text_edits.items, &.{});
        try self.sendSelection(arena, .keyboard);
        self.needs_render = true;
    }

    fn sendSelection(self: *Extensions, arena: Allocator, source: SelectionSource) !void {
        const active = self.active orelse return;
        const selections = try active.editor.getSelections();
        defer active.editor.allocator.free(selections);
        const value = try documents_and_editors.editorPropertiesChanged(
            arena,
            "1",
            active.editor.model,
            selections,
            source.wireName(),
            currentVisibleRange(active.editor),
        );
        if (value != .array or value.array.items.len < 2) return;
        var args = [_]rpc.Arg{
            .{ .json = value.array.items[0] },
            .{ .json = value.array.items[1] },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditors), "$acceptEditorPropertiesChanged", &args, null, manager.noop_callback) catch {};
        self.visible_ranges_task.schedule(null);
        self.captureSelections(active.editor);
    }

    fn onEditorScroll(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.visible_ranges_task.post();
        self.needs_render = true;
    }

    fn setScrollListener(self: *Extensions, editor: ?*Editor) void {
        if (self.scroll_listener_editor == editor) return;
        if (self.scroll_listener_editor) |old| {
            old.removeScrollListener(.{ .context = self, .callback = onEditorScroll });
        }
        self.scroll_listener_editor = null;
        if (editor) |value| {
            value.addScrollListener(.{ .context = self, .callback = onEditorScroll });
            self.scroll_listener_editor = value;
        }
    }

    fn sendVisibleRanges(self: *Extensions) !void {
        const active = self.active orelse return;
        const range = currentVisibleRange(active.editor) orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const value = try documents_and_editors.editorVisibleRangesChanged(arena, "1", active.editor.model, range);
        if (value != .array or value.array.items.len < 2) return;
        var args = [_]rpc.Arg{
            .{ .json = value.array.items[0] },
            .{ .json = value.array.items[1] },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditors), "$acceptEditorPropertiesChanged", &args, null, manager.noop_callback) catch {};
        self.visible_ranges_task.schedule(null);
    }

    /// Records the selections the extension host now has, without a round
    /// trip. Called after the host applies a selection and after every delta
    /// this side sends, so only real user changes are reported.
    fn captureSelections(self: *Extensions, editor: *Editor) void {
        const selections = editor.getSelections() catch return;
        defer editor.allocator.free(selections);
        self.last_selections.clearRetainingCapacity();
        self.last_selections.appendSlice(selections) catch {};
    }

    fn sameSelections(a: []const Selection, b: []const Selection) bool {
        if (a.len != b.len) return false;
        for (a, b) |left, right| {
            if (!Selection.equalsSelection(&left, &right)) return false;
        }
        return true;
    }

    /// Reports a caret or selection change the TUI applied itself (mouse
    /// press/drag, arrow key, find, tab switch) to the extension host,
    /// mirroring `MainThreadTextEditor`'s properties-changed delta. Without it
    /// Keep the extension host's selection mirror in step with a caret move
    /// the TUI made itself.
    fn syncSelection(self: *Extensions) !void {
        try self.syncSelectionFrom(self.selection_source);
    }
    fn syncSelectionFrom(self: *Extensions, source: SelectionSource) !void {
        const active = self.active orelse return;
        const selections = try active.editor.getSelections();
        defer active.editor.allocator.free(selections);
        if (sameSelections(self.last_selections.items, selections)) return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        try self.sendSelection(arena_instance.allocator(), source);
    }
};

/// Maps command ids issued by Node extensions to the workbench LSP
/// actions. Returns true when the command was recognized, even when the
/// action produced no result.
pub fn runLspCommand(services: Services, command: []const u8) bool {
    if (std.mem.eql(u8, command, "editor.action.showHover")) {
        _ = services.show_hover(services.common.context) catch false;
        return true;
    }
    if (std.mem.eql(u8, command, "outline.focus")) {
        services.common.commands.execute(command) catch return false;
        return true;
    }
    if (std.mem.eql(u8, command, "workbench.action.gotoSymbol")) {
        _ = services.goto_symbol(services.common.context) catch false;
        return true;
    }

    const id = if (std.mem.eql(u8, command, "editor.action.goToDeclaration"))
        go_to_commands.definition.id
    else if (std.mem.eql(u8, command, "editor.action.findReferences"))
        go_to_commands.peek_references.id
    else
        command;
    if (go_to_commands.find(id) == null) return false;
    _ = services.run_lsp_action(services.common.context, id) catch false;
    return true;
}

fn currentVisibleRange(editor: *Editor) ?Range {
    if (editor.viewLineCount() == 0) return null;
    const top = editor.topViewLine();
    const bottom = @min(top + editor.textHeight() -| 1, editor.viewLineCount());
    const line_count = editor.model.getLineCount();
    // The view model can lag the model for one event: deleting the last line
    // leaves a view line that still maps to the deleted model line. Upstream
    // reads the visible range from the view model after that update has
    // settled; clamp to the model here so a selection push cannot query a
    // line that no longer exists.
    const start_line = @min(@max(editor.modelLineNumber(top), 1), line_count);
    const end_line = @min(@max(editor.modelLineNumber(bottom), start_line), line_count);
    return Range.init(start_line, 1, end_line, editor.model.getLineMaxColumn(end_line));
}

fn isFoldCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "editor.fold") or
        std.mem.eql(u8, command, "editor.unfold") or
        std.mem.eql(u8, command, "editor.toggleFold") or
        std.mem.eql(u8, command, "editor.foldRecursively") or
        std.mem.eql(u8, command, "editor.unfoldRecursively") or
        std.mem.eql(u8, command, "editor.foldAll") or
        std.mem.eql(u8, command, "editor.unfoldAll") or
        std.mem.eql(u8, command, "editor.createFoldingRangeFromSelection") or
        std.mem.eql(u8, command, "editor.removeManualFoldingRanges");
}

fn commandObject(args: []const std.json.Value) ?std.json.ObjectMap {
    if (args.len == 0 or args[0] != .object) return null;
    return args[0].object;
}

fn objectString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn objectBool(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn objectUsize(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0) @intFromFloat(@floor(number)) else null,
        else => null,
    };
}

fn objectI64(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(@floor(number)),
        else => null,
    };
}

fn selectionLines(editor: *Editor, object: ?std.json.ObjectMap) ![]usize {
    if (object) |map| {
        if (map.get("selectionLines")) |value| {
            if (value == .array) {
                var result = std.array_list.Managed(usize).init(editor.allocator);
                errdefer result.deinit();
                for (value.array.items) |item| {
                    if (item != .integer or item.integer < 0) continue;
                    try result.append(@min(@as(usize, @intCast(item.integer)) + 1, editor.model.getLineCount()));
                }
                if (result.items.len > 0) return try result.toOwnedSlice();
                result.deinit();
            }
        }
    }
    const selections = try editor.getSelections();
    defer editor.allocator.free(selections);
    var result = try editor.allocator.alloc(usize, selections.len);
    for (selections, 0..) |selection, index| {
        result[index] = selection.startLineNumber;
    }
    return result;
}

fn applyEditorScroll(editor: *Editor, args: []const std.json.Value) bool {
    const object = commandObject(args) orelse return false;
    const to = objectString(object, "to") orelse return false;
    const direction: Editor.ScrollDirection = if (std.mem.eql(u8, to, "up"))
        .up
    else if (std.mem.eql(u8, to, "down"))
        .down
    else
        return false;
    const by = objectString(object, "by") orelse "wrappedLine";
    const unit: Editor.ScrollUnit = if (std.mem.eql(u8, by, "line"))
        .line
    else if (std.mem.eql(u8, by, "page"))
        .page
    else if (std.mem.eql(u8, by, "halfPage"))
        .half_page
    else if (std.mem.eql(u8, by, "editor"))
        .editor
    else
        .wrapped_line;
    const value = objectUsize(object, "value") orelse 1;
    return editor.scrollEditor(
        direction,
        unit,
        value,
        objectBool(object, "revealCursor"),
        objectBool(object, "select"),
    );
}

fn applyRevealLine(editor: *Editor, args: []const std.json.Value) bool {
    const object = commandObject(args) orelse return false;
    const line_value = object.get("lineNumber") orelse return false;
    const zero_based: i64 = switch (line_value) {
        .integer => |value| value,
        .float => |value| @intFromFloat(@floor(value)),
        .string => |value| std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t"), 10) catch return false,
        else => return false,
    };
    const line = @min(@max(@as(usize, @intCast(@max(zero_based, 0))) + 1, 1), editor.model.getLineCount());
    const at = objectString(object, "at") orelse "";
    const reveal_type: view_events.VerticalRevealType = if (std.mem.eql(u8, at, "top"))
        .Top
    else if (std.mem.eql(u8, at, "center"))
        .Center
    else if (std.mem.eql(u8, at, "bottom"))
        .Bottom
    else
        .Simple;
    return editor.revealLine(line, reveal_type);
}

fn applyCursorMove(editor: *Editor, args: []const std.json.Value) !bool {
    const object = commandObject(args) orelse return false;
    const to = objectString(object, "to") orelse return false;
    const by = objectString(object, "by");
    const select = objectBool(object, "select");
    const raw_value = objectUsize(object, "value");
    const value = if (raw_value == null or raw_value.? == 0) @as(?usize, 1) else raw_value;
    const no_history = objectBool(object, "noHistory");
    const parsed = cursor_move.CursorMoveCommands.parse(to, by, select, value, no_history) orelse return false;
    return editor.cursorMove(parsed);
}

fn applyFoldCommand(editor: *Editor, command: []const u8, args: []const std.json.Value) !bool {
    if (args.len == 0) {
        if (std.mem.eql(u8, command, "editor.foldAll")) {
            try editor.foldAll();
            return true;
        }
        if (std.mem.eql(u8, command, "editor.unfoldAll")) {
            try editor.unfoldAll();
            return true;
        }
        if (std.mem.eql(u8, command, "editor.createFoldingRangeFromSelection")) {
            try editor.createFoldingRangeFromSelection();
            return true;
        }
        if (std.mem.eql(u8, command, "editor.removeManualFoldingRanges")) {
            try editor.removeManualFoldingRanges();
            return true;
        }
    }

    const object = commandObject(args);
    const levels = if (object) |map| objectUsize(map, "levels") else null;
    const direction_name = if (object) |map| objectString(map, "direction") else null;
    const direction: ?folding.Direction = if (direction_name) |name|
        if (std.mem.eql(u8, name, "up")) .up else .down
    else
        null;
    const lines = try selectionLines(editor, object);
    defer editor.allocator.free(lines);

    if (std.mem.eql(u8, command, "editor.fold")) {
        try editor.foldLines(lines, levels, direction);
    } else if (std.mem.eql(u8, command, "editor.unfold")) {
        try editor.unfoldLines(lines, levels, direction);
    } else if (std.mem.eql(u8, command, "editor.toggleFold")) {
        try editor.toggleFoldLines(lines, levels orelse 1);
    } else if (std.mem.eql(u8, command, "editor.foldRecursively")) {
        try editor.foldLines(lines, std.math.maxInt(usize), .down);
    } else if (std.mem.eql(u8, command, "editor.unfoldRecursively")) {
        try editor.unfoldLines(lines, std.math.maxInt(usize), .down);
    } else if (std.mem.eql(u8, command, "editor.foldAll")) {
        try editor.foldAll();
    } else if (std.mem.eql(u8, command, "editor.unfoldAll")) {
        try editor.unfoldAll();
    } else if (std.mem.eql(u8, command, "editor.createFoldingRangeFromSelection")) {
        try editor.createFoldingRangeFromSelection();
    } else if (std.mem.eql(u8, command, "editor.removeManualFoldingRanges")) {
        try editor.removeManualFoldingRanges();
    } else {
        return false;
    }
    return true;
}

fn activateTaskType(context: *anyopaque, arena: Allocator, event: []const u8) !void {
    const self: *Extensions = @ptrCast(@alignCast(context));
    _ = try self.host.requestSync(arena, proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = event } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
}

fn runTaskInTerminal(context: *anyopaque, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !void {
    const self: *Extensions = @ptrCast(@alignCast(context));
    _ = try self.services.common.launch_terminal(self.services.common.context, name, executable, args, cwd);
}

fn findInFiles(views: @import("../../services/views/common/viewsService.zig").IViewsService) !void {
    const search = @import("../../contrib/search/browser/searchActionsBase.zig");
    if (try search.openSearchView(views, true)) |view| try search.findInFiles(view);
}

fn executeHostCommand(context: *anyopaque, command: []const u8, command_args: std.json.Value, arena: Allocator) anyerror!?std.json.Value {
    const self: *Extensions = @ptrCast(@alignCast(context));
    const args: []const std.json.Value = if (command_args == .array) command_args.array.items else &.{};
    if (std.mem.eql(u8, command, "workbench.action.browser.open") or std.mem.eql(u8, command, "simpleBrowser.show")) {
        try self.services.simple_browser.show(if (args.len > 0 and args[0] == .string) args[0].string else null);
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "editorScroll")) {
        if (self.active) |active| {
            _ = applyEditorScroll(active.editor, args);
            try self.syncAfterEditorCommand(arena, active.editor);
        }
        return null;
    }
    if (std.mem.eql(u8, command, "revealLine")) {
        if (self.active) |active| {
            _ = applyRevealLine(active.editor, args);
            self.needs_render = true;
        }
        return null;
    }
    if (std.mem.eql(u8, command, "cursorMove")) {
        if (self.active) |active| {
            _ = try applyCursorMove(active.editor, args);
            try self.syncAfterEditorCommand(arena, active.editor);
        }
        return null;
    }
    if (isFoldCommand(command)) {
        if (self.active) |active| {
            _ = try applyFoldCommand(active.editor, command, args);
            try self.syncAfterEditorCommand(arena, active.editor);
        }
        return null;
    }
    if (std.mem.eql(u8, command, "default:type")) {
        const editor = if (self.active) |active| active.editor else return null;
        if (args.len > 0 and args[0] == .object) {
            if (args[0].object.get("text")) |value| {
                if (value == .string) try self.applyType(arena, editor, value.string);
            }
        }
        return null;
    }
    // Some extensions delegate Backspace/Delete to the editor's core
    // `deleteLeft`/`deleteRight` commands.
    if (std.mem.eql(u8, command, "deleteLeft") or std.mem.eql(u8, command, "deleteRight")) {
        const editor = if (self.active) |active| active.editor else return null;
        _ = try runEditorCommand(editor, command);
        try self.applyCommandEdit(arena, editor);
        return null;
    }
    if (std.mem.eql(u8, command, "editor.action.insertLineAfter") or std.mem.eql(u8, command, "editor.action.insertLineBefore")) {
        const editor = if (self.active) |active| active.editor else return null;
        if (std.mem.eql(u8, command, "editor.action.insertLineAfter")) {
            try editor.insertLineAfter();
        } else {
            try editor.insertLineBefore();
        }
        try self.applyCommandEdit(arena, editor);
        return null;
    }
    if (std.mem.eql(u8, command, "search.action.focusSearchList")) {
        findInFiles(self.services.views) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.splitEditor") or
        std.mem.eql(u8, command, "workbench.action.splitEditorOrthogonal") or
        std.mem.eql(u8, command, "workbench.action.splitEditorLeft") or
        std.mem.eql(u8, command, "workbench.action.splitEditorRight") or
        std.mem.eql(u8, command, "workbench.action.splitEditorUp") or
        std.mem.eql(u8, command, "workbench.action.splitEditorDown"))
    {
        const direction: GroupDirection = if (std.mem.eql(u8, command, "workbench.action.splitEditorLeft"))
            .LEFT
        else if (std.mem.eql(u8, command, "workbench.action.splitEditorUp"))
            .UP
        else if (std.mem.eql(u8, command, "workbench.action.splitEditorDown"))
            .DOWN
        else if (std.mem.eql(u8, command, "workbench.action.splitEditor"))
            self.services.preferredSideBySideDirection()
        else if (std.mem.eql(u8, command, "workbench.action.splitEditorOrthogonal"))
            if (self.services.preferredSideBySideDirection() == .RIGHT) .DOWN else .RIGHT
        else
            .RIGHT;
        self.services.split_active(self.services.common.context, direction) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.closeActiveEditor")) {
        _ = self.services.close_active(self.services.common.context) catch false;
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "moveActiveEditor")) {
        if (args.len > 0 and args[0] == .object) {
            const object = args[0].object;
            const to = objectString(object, "to") orelse "";
            const by = objectString(object, "by") orelse "tab";
            const value = objectUsize(object, "value") orelse 1;
            self.services.move_active_editor(self.services.common.context, to, by, value) catch {};
            self.needs_render = true;
        }
        return null;
    }
    if (std.mem.startsWith(u8, command, "workbench.action.openEditorAtIndex")) {
        if (args.len > 0 and args[0] == .integer and args[0].integer >= 0) {
            self.services.activate_index(self.services.common.context, @intCast(args[0].integer)) catch {};
            self.needs_render = true;
        } else if (std.mem.eql(u8, command, "workbench.action.openEditorAtIndex1")) {
            self.services.activate_index(self.services.common.context, 0) catch {};
            self.needs_render = true;
        }
        return null;
    }
    if (runLspCommand(self.services, command)) {
        // Publish the new document/selection before the command reply so an
        // extension that reads `activeTextEditor` immediately sees the target.
        self.syncActiveDocument() catch {};
        self.syncSelection() catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.files.save")) {
        if (self.active) |active| active.editor.save() catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.nextEditorInGroup")) {
        self.services.common.switch_tab(self.services.common.context, 1) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.previousEditorInGroup")) {
        self.services.common.switch_tab(self.services.common.context, -1) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "vscode.open")) {
        if (args.len > 0 and args[0] == .object) {
            if (args[0].object.get("path")) |path| {
                if (path == .string) {
                    self.services.common.open_path(self.services.common.context, path.string) catch {};
                    self.needs_render = true;
                }
            }
        }
        return null;
    }
    if (std.mem.eql(u8, command, "_setContext") or std.mem.eql(u8, command, "setContext")) {
        // Context keys are accepted for extension compatibility; the Node API
        // surface does not yet expose a terminal context-key registry.
        return null;
    }
    if (self.services.common.commands.get(command) != null) {
        self.services.common.commands.execute(command) catch |err| {
            if (self.active) |active| active.editor.setMessage("{s}: {s}", .{ command, @errorName(err) });
        };
        self.syncActiveDocument() catch {};
        if (self.active) |active| {
            try self.syncAfterEditorCommand(arena, active.editor);
        } else {
            try self.syncSelection();
        }
        self.needs_render = true;
        return null;
    }
    return null;
}

/// Applies a core editor command the extension host delegates back to the
/// TUI. Extensions may delegate Backspace/Delete to these core commands; the
/// caller mirrors the resulting edit.
fn runEditorCommand(editor: *Editor, command: []const u8) !bool {
    if (std.mem.eql(u8, command, "deleteLeft")) {
        try editor.deleteLeft();
        return true;
    }
    if (std.mem.eql(u8, command, "deleteRight")) {
        try editor.deleteRight();
        return true;
    }
    return false;
}

const WaitFlag = struct {
    done: bool = false,
    failed: bool = false,

    fn callback(context: *anyopaque, reply: rpc.Reply) void {
        const self: *WaitFlag = @ptrCast(@alignCast(context));
        self.failed = reply == .err;
        self.done = true;
    }
};

fn done(context: *anyopaque) bool {
    const flag: *WaitFlag = @ptrCast(@alignCast(context));
    return flag.done;
}

test "WaitFlag records an accepted handshake reply" {
    var wait = WaitFlag{};
    WaitFlag.callback(@ptrCast(&wait), .empty);
    try std.testing.expect(wait.done);
    try std.testing.expect(!wait.failed);
}

test "WaitFlag records a rejected handshake reply" {
    // A rejected reply is a real failure: the handshake calls are barriers on
    // the host side, so treating them as success leaves the host waiting.
    var wait = WaitFlag{};
    WaitFlag.callback(@ptrCast(&wait), .{ .err = .{ .name = "Error", .message = "unknown method" } });
    try std.testing.expect(wait.done);
    try std.testing.expect(wait.failed);
}

fn emptyConfig(arena: Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "defaults", "policy", "application", "userLocal", "userRemote", "workspace" }) |key| {
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "contents", .{ .object = .empty });
        try model.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
        try model.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
        try root.put(arena, key, .{ .object = model });
    }
    try root.put(arena, "folders", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "configurationScopes", .{ .array = std.json.Array.init(arena) });
    return .{ .object = root };
}

fn uriPath(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const path = value.object.get("path") orelse return null;
    if (path != .string) return null;
    return path.string;
}

fn utf16ColumnForModel(model: *TextModel, line_number: usize, column: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return column;
    var line = model.getLineContent(line_number) catch return column;
    defer line.deinit();
    return position_converter.utf16OffsetForColumn(line.items, column);
}

fn columnFromUtf16ForModel(model: *TextModel, line_number: usize, offset: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return offset;
    var line = model.getLineContent(line_number) catch return offset;
    defer line.deinit();
    return position_converter.columnForUtf16Offset(line.items, offset);
}

fn selectionFromJson(value: std.json.Value) ?Selection {
    if (value != .object) return null;
    const object = value.object;
    const start_line = integerField(object, "selectionStartLineNumber") orelse return null;
    const start_column = integerField(object, "selectionStartColumn") orelse return null;
    const end_line = integerField(object, "positionLineNumber") orelse return null;
    const end_column = integerField(object, "positionColumn") orelse return null;
    return Selection.init(start_line, start_column, end_line, end_column);
}

fn rangeFromJson(value: std.json.Value) ?Range {
    if (value != .object) return null;
    const object = value.object;
    const start_line = integerField(object, "startLineNumber") orelse return null;
    const start_column = integerField(object, "startColumn") orelse return null;
    const end_line = integerField(object, "endLineNumber") orelse return null;
    const end_column = integerField(object, "endColumn") orelse return null;
    return Range.init(start_line, start_column, end_line, end_column);
}

fn applyShowDocumentSelection(editor: *Editor, options: std.json.Value) void {
    if (options != .object) return;
    const selection = options.object.get("selection") orelse return;
    if (selection != .object) return;
    const start_line = integerField(selection.object, "startLineNumber") orelse return;
    const start_column = integerField(selection.object, "startColumn") orelse return;
    const end_line = integerField(selection.object, "endLineNumber") orelse return;
    const end_column = integerField(selection.object, "endColumn") orelse return;
    if (start_line < 1 or end_line < 1) return;
    var owned = Selection.init(
        start_line,
        columnFromUtf16ForModel(editor.model, start_line, start_column),
        end_line,
        columnFromUtf16ForModel(editor.model, end_line, end_column),
    );
    editor.setSelections(&.{owned}) catch {
        owned = Selection.init(start_line, 1, end_line, 1);
        editor.setSelections(&.{owned}) catch {};
    };
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn countListenerCall(context: *anyopaque) void {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += 1;
}

pub fn Tests(comptime terminal_window_type: type, comptime factory: anytype) type {
    return struct {
        const TestWindow = @import("../../test/browser/workbenchTestServices.zig").TestWindow(terminal_window_type, factory);
        test "Extensions: editor-pane disposal detaches listeners before the editor is destroyed" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "owned.txt", .data = "alpha" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPathFile(io, "owned.txt", &path_buffer);

            const workbench_window = try TestWindow.init(allocator, io, &.{path_buffer[0..path_len]}, 40, 9);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();

            var content_calls: usize = 0;
            var scroll_calls: usize = 0;
            const content_listener = ChangeListener{ .context = &content_calls, .callback = countListenerCall };
            const scroll_listener = ChangeListener{ .context = &scroll_calls, .callback = countListenerCall };

            // An editor that the workbench still owns is detached normally.
            const owned = workbench.activeTab().?.editor;
            owned.addWorkingCopyContentListener(content_listener);
            owned.addScrollListener(scroll_listener);
            owned.removeWorkingCopyContentListener(content_listener);
            owned.removeScrollListener(scroll_listener);
            try owned.typeCharacter("x");
            owned.emitCurrentViewState();
            try std.testing.expectEqual(@as(usize, 0), content_calls);
            try std.testing.expectEqual(@as(usize, 0), scroll_calls);
            // A clean editor closes without the dirty confirmation.
            try owned.save();

            // A live editor outside this pane must keep its own listeners.
            var stale = try Editor.createFromText(allocator, io, "beta", "stale.txt", 40, 9);
            defer {
                stale.deinit();
                allocator.destroy(stale);
            }
            stale.addWorkingCopyContentListener(content_listener);
            stale.addScrollListener(scroll_listener);
            try stale.typeCharacter("y");
            stale.emitCurrentViewState();
            try std.testing.expect(content_calls > 0);
            try std.testing.expect(scroll_calls > 0);

            // The former Ctrl-W crash now retires subscriptions before tab deinit
            // releases the editor. The callback must run exactly once.
            try workbench.activeTab().?.ensureControllers();
            const tab = workbench.activeTab().?;
            const closed = tab.editor;
            const Detach = struct {
                editor: ?*Editor,
                content: ChangeListener,
                scroll: ChangeListener,
                count: usize = 0,
                fn onDispose(_: void, self: *@This()) !void {
                    const editor = self.editor orelse return error.AlreadyDisposed;
                    editor.removeWorkingCopyContentListener(self.content);
                    editor.removeScrollListener(self.scroll);
                    self.editor = null;
                    self.count += 1;
                }
            };
            var detach: Detach = .{ .editor = closed, .content = content_listener, .scroll = scroll_listener };
            closed.addWorkingCopyContentListener(content_listener);
            closed.addScrollListener(scroll_listener);
            _ = try tab.listenWillDispose(&detach, Detach.onDispose);
            try workbench.commands.execute("workbench.action.closeActiveEditor");
            try std.testing.expect(detach.editor == null);
            try std.testing.expectEqual(@as(usize, 1), detach.count);
        }

        test "Extensions: insert-mode Backspace and Delete run the core editor commands" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            var editor = try Editor.createFromText(allocator, io, "abc", "test.zig", 40, 8);
            defer {
                editor.deinit();
                allocator.destroy(editor);
            }

            // Some editor actions delegate to `deleteLeft`; the key is not an edit by
            // itself, so the TUI must run the command.
            try editor.setSelections(&[_]Selection{Selection.init(1, 4, 1, 4)});
            try std.testing.expect(try runEditorCommand(editor, "deleteLeft"));
            const after_backspace = try editor.model.getValue(.TextDefined, false);
            defer after_backspace.deinit();
            try std.testing.expectEqualStrings("ab", after_backspace.items);
            try std.testing.expectEqual(Position.init(1, 3), editor.modelCursorPosition());

            // DeleteInInsertMode delegates to `deleteRight`.
            try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 1)});
            try std.testing.expect(try runEditorCommand(editor, "deleteRight"));
            const after_delete = try editor.model.getValue(.TextDefined, false);
            defer after_delete.deinit();
            try std.testing.expectEqualStrings("b", after_delete.items);
            try std.testing.expectEqual(Position.init(1, 1), editor.modelCursorPosition());

            try std.testing.expect(!try runEditorCommand(editor, "unhandled.command"));
        }

        test "Extensions: language feature registration reaches the workbench registries" {
            // The fixture registers definition/declaration/implementation/type
            // definition/reference providers so the bridge actions run without tsserver.
            if (!build_options.e2e) return error.SkipZigTest;
            std.Io.Dir.cwd().access(time_compat.io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(time_compat.io, "host/test-fixtures/language-features/package.json", .{}) catch return error.SkipZigTest;

            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "fixture.json", .data = "{\n  \"a\": 1\n}\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "fixture.json", &path_buffer);
            const relative = path_buffer[0..relative_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();

            var extension_host = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-language-fixture", "host/dist");
            defer extension_host.deinit();

            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                if (extension_host.active != null) break;
                time_compat.sleepMillis(10);
            }
            _ = extension_host.pump();

            const features = workbench.language_features.?;
            const model = workbench.activeTab().?.editor.model;
            const hover_providers = try features.hover_provider.ordered(allocator, model, false);
            defer allocator.free(hover_providers);
            try std.testing.expect(hover_providers.len > 0);
            const hover = try hover_providers[0].provide_hover(
                hover_providers[0].context,
                model,
                Position.init(1, 1),
                @import("../../../base/common/cancellation.zig").CancellationToken.None,
                null,
            );
            try std.testing.expect(hover != null);

            const completion_providers = try features.completion_provider.ordered(allocator, model, false);
            defer allocator.free(completion_providers);
            try std.testing.expect(completion_providers.len > 0);

            const symbol_providers = try features.document_symbol_provider.ordered(allocator, model, false);
            defer allocator.free(symbol_providers);
            try std.testing.expect(symbol_providers.len > 0);

            const declaration_providers = try features.declaration_provider.ordered(allocator, model, false);
            defer allocator.free(declaration_providers);
            try std.testing.expect(declaration_providers.len > 0);
            var check_arena = std.heap.ArenaAllocator.init(allocator);
            defer check_arena.deinit();
            const check_links = try declaration_providers[0].provide_declaration(
                declaration_providers[0].context,
                check_arena.allocator(),
                model,
                Position.init(1, 1),
                @import("../../../base/common/cancellation.zig").CancellationToken.None,
            );
            try std.testing.expect(check_links.len > 0);
            const implementation_providers = try features.implementation_provider.ordered(allocator, model, false);
            defer allocator.free(implementation_providers);
            try std.testing.expect(implementation_providers.len > 0);
            const type_providers = try features.type_definition_provider.ordered(allocator, model, false);
            defer allocator.free(type_providers);
            try std.testing.expect(type_providers.len > 0);
            const reference_providers = try features.reference_provider.ordered(allocator, model, false);
            defer allocator.free(reference_providers);
            try std.testing.expect(reference_providers.len > 0);

            // Extension command names reach the same workbench actions.
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToDeclaration"));
            try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.revealDeclaration"));
            try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToImplementation"));
            try std.testing.expectEqual(@as(usize, 3), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToTypeDefinition"));
            try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);

            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToReferences"));
            try std.testing.expect(workbench.quick_access.isOpen());
            workbench.quick_access.inputService().hide();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.findReferences"));
            try std.testing.expect(workbench.quick_access.isOpen());
            workbench.quick_access.inputService().hide();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "outline.focus"));
            try std.testing.expect(workbench.outline_view != null);
            try std.testing.expect(workbench.outline_view.?.focused);
            workbench.focusEditor();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.showHover"));
            try std.testing.expect(workbench.activeTab().?.controllers.?.hover.isVisible());
            const tab = workbench.activeTab().?;
            try tab.editor.setCursorPosition(Position.init(1, model.getLineMaxColumn(1)));
            try tab.editor.insertText("é");
            _ = extension_host.pump();
            const inline_deadline = time_compat.milliTimestamp() + 5_000;
            while (!tab.view.ghost_text.isVisible() and time_compat.milliTimestamp() < inline_deadline) {
                _ = extension_host.pump();
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(tab.view.ghost_text.isVisible());
            try std.testing.expectEqualStrings(" inline result", tab.view.ghost_text.text.?);
            var before_inline = try model.getLineContent(1);
            defer before_inline.deinit();
            try std.testing.expect(try extension_host.inline_completions.accept());
            var after_inline = try model.getLineContent(1);
            defer after_inline.deinit();
            try std.testing.expect(std.mem.endsWith(u8, after_inline.items, "é inline result"));
            try tab.editor.undo();
            var undone = try model.getLineContent(1);
            defer undone.deinit();
            try std.testing.expectEqualStrings(before_inline.items, undone.items);
        }

        test "Extensions: relative paths mirror the model URI language features use" {
            // Regression: a relative command-line path used to be mirrored with its
            // raw spelling while language-feature requests carried the model's
            // absolute URI. The host never found the document, so `gd`/F12 and the
            // other navigation actions returned no result for relative paths.
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(io, "host/test-fixtures/language-features/package.json", .{}) catch return error.SkipZigTest;

            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "relative.json", .data = "{\n  \"a\": 1\n}\n" });
            var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const absolute_length = try tmp.dir.realPathFile(io, "relative.json", &absolute_buffer);
            var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_length = try Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
            const relative = try std.fs.path.relativeAlloc(
                allocator,
                cwd_buffer[0..cwd_length],
                null,
                cwd_buffer[0..cwd_length],
                absolute_buffer[0..absolute_length],
            );
            defer allocator.free(relative);
            // The bug only manifests when the input spelling is relative.
            if (std.fs.path.isAbsolute(relative)) return error.SkipZigTest;

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();

            var extension_host = try Extensions.init(
                allocator,
                io,
                workbench.extensionHostServices(),
                &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }},
                ".cache-ext/data-relative-fixture",
                "host/dist",
            );
            defer extension_host.deinit();

            const tab = workbench.activeTab().?;
            const model_uri = try std_uri.resourceKey(allocator, tab.editor.model.uri());
            defer allocator.free(model_uri);

            const deadline = time_compat.milliTimestamp() + 10_000;
            var mirrored: ?[]u8 = null;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                if (extension_host.active) |active| {
                    mirrored = try std.fmt.allocPrint(allocator, "file://{s}", .{active.uri});
                    break;
                }
                time_compat.sleepMillis(10);
            }
            defer if (mirrored) |value| allocator.free(value);
            try std.testing.expect(mirrored != null);
            try std.testing.expectEqualStrings(model_uri, mirrored.?);

            // The fixture provider sees the mirrored document and the action jumps to
            // its target range on line 1.
            try tab.editor.setCursorPosition(Position.init(3, 1));
            const navigation_deadline = time_compat.milliTimestamp() + 10_000;
            var navigated = false;
            while (!navigated and time_compat.milliTimestamp() < navigation_deadline) {
                _ = extension_host.pump();
                navigated = workbench.revealDefinition() catch false;
                if (!navigated) time_compat.sleepMillis(20);
            }
            try std.testing.expect(navigated);
            try std.testing.expectEqual(@as(usize, 1), tab.editor.modelCursorPosition().lineNumber);

            // Opening, selecting and closing tabs now deliver the document delta on
            // editor events, even if the host's message pump has not been called.
            try tmp.dir.writeFile(io, .{ .sub_path = "second.json", .data = "{\n}\n" });
            var second_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const second_length = try tmp.dir.realPathFile(io, "second.json", &second_buffer);
            try workbench.openPath(second_buffer[0..second_length]);
            const second = workbench.activeTab().?;
            try std.testing.expect(extension_host.active.?.tab == second);
            try std.testing.expect(extension_host.tabs_task.at != null);
            try second.editor.setCursorPosition(Position.init(2, 1));
            try std.testing.expect(extension_host.selection_task.at != null);
            second.editor.emitCurrentViewState();
            try std.testing.expect(extension_host.visible_ranges_task.at != null);
            second.editor.model.setLanguage("plaintext");
            try std.testing.expectEqualStrings("plaintext", extension_host.active.?.language_id);
            for (0..256) |_| {
                if (extension_host.tabs_task.at == null and extension_host.selection_task.at == null and extension_host.visible_ranges_task.at == null) break;
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
            }
            try std.testing.expect(extension_host.tabs_task.at == null and extension_host.selection_task.at == null and extension_host.visible_ranges_task.at == null);
            try std.testing.expectEqual(@as(usize, 2), extension_host.last_selections.items[0].endLineNumber);
            _ = try workbench.closeActive();
            try std.testing.expect(extension_host.active.?.tab == tab);
        }

        test "Extensions: CodeLens providers receive both distinct diff side documents before focus" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const a = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "diff.json", .data = "{}" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPathFile(io, "diff.json", &path_buffer);
            const path = path_buffer[0..path_len];
            const window = try TestWindow.init(a, io, &.{path}, 120, 24);
            defer window.deinit();
            const wb = window.workbench;
            try wb.enableLanguageFeatures();
            const extensions = try Extensions.init(a, io, wb.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-diff-lens-fixture", "host/dist");
            defer extensions.deinit();
            try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "{\"old\":1}", "{\"new\":2}", "Original", "Modified");
            const tab = wb.activeTab().?;
            const diff = tab.diff.?.widget;
            try std.testing.expectEqual(diff.modified_editor, extensions.active.?.editor);
            const features = wb.language_features.?;
            const token = @import("../../../base/common/cancellation.zig").CancellationToken.None;
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                const providers = try features.code_lens_provider.ordered(a, diff.originalModel(), false);
                defer a.free(providers);
                if (providers.len != 0) break;
                time_compat.sleepMillis(10);
            }
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            for ([_]*TextModel{ diff.originalModel(), diff.modifiedModel() }, [_][]const u8{ "Original:{\"old\":1}", "Modified:{\"new\":2}" }) |model, title| {
                const providers = try features.code_lens_provider.ordered(arena.allocator(), model, false);
                try std.testing.expect(providers.len > 0);
                const list = (try providers[0].provide_code_lenses(providers[0].context, arena.allocator(), model, token)).?;
                defer if (list.disposable) |disposable| disposable.dispose();
                try std.testing.expectEqual(@as(usize, 2), list.lenses.len);
                try std.testing.expectEqualStrings(title, list.lenses[0].command.?.title);
                try std.testing.expect(list.lenses[1].command == null);
                const uri = try std_uri.resourceKey(arena.allocator(), model.uri());
                const id = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
                const value = try extensions.host.requestSync(arena.allocator(), id, "$executeContributedCommand", &.{
                    .{ .json = .{ .string = "fixture.executeCodeLens" } },
                    .{ .json = .{ .string = uri } },
                    .{ .json = .{ .integer = 1 } },
                }, null, 5000);
                try std.testing.expectEqual(@as(usize, 2), value.array.items.len);
                try std.testing.expectEqualStrings(title, value.array.items[0].object.get("title").?.string);
                try std.testing.expectEqualStrings("resolved lens", value.array.items[1].object.get("title").?.string);
                try std.testing.expectEqual(@as(i64, 1), value.array.items[1].object.get("start").?.integer);
                try std.testing.expect(extensions.language_features_actor.?.code_lens_commands.items.len != 0);
                for (0..64) |_| _ = wb.window_events.dispatch(std.math.maxInt(i64));
                try std.testing.expectEqual(@as(usize, 0), extensions.language_features_actor.?.code_lens_commands.items.len);
            }
            diff.setFocus(.original);
            try std.testing.expectEqual(diff.original_editor, extensions.active.?.editor);
            diff.setFocus(.modified);
            try std.testing.expectEqual(diff.modified_editor, extensions.active.?.editor);
        }

        test "Extensions: multi-diff tabs expose declared pairs and offscreen documents through virtualization" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const a = std.testing.allocator;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const arena = scratch.allocator();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "bootstrap.json", .data = "{}" });
            const bootstrap = try tmp.dir.realPathFileAlloc(io, "bootstrap.json", arena);
            const Resource = @import("../../common/editor.zig").IMultiDiffEditorResource;
            var resources: [3]Resource = undefined;
            for (&resources, 0..) |*resource, index| {
                var uris: [2]std.Uri = undefined;
                for ([_][]const u8{ "old", "new" }, 0..) |side, side_index| {
                    const name = try std.fmt.allocPrint(arena, "{d}-{s}.json", .{ index, side });
                    var contents: std.ArrayList(u8) = .empty;
                    try contents.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}-{d}\n", .{ side, index }));
                    for (1..45) |line| try contents.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} {d}\n", .{ side, line }));
                    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = contents.items });
                    const path = try tmp.dir.realPathFileAlloc(io, name, arena);
                    uris[side_index] = try std.Uri.parse(try std_uri.encodedResource(arena, .{ .scheme = "file", .path = .{ .raw = path } }));
                }
                resource.* = .{ .original = uris[0], .modified = uris[1] };
            }
            const window = try TestWindow.init(a, io, &.{bootstrap}, 120, 24);
            defer window.deinit();
            const wb = window.workbench;
            try wb.enableLanguageFeatures();
            const extensions = try Extensions.init(a, io, wb.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-multi-diff-fixture", "host/dist");
            defer extensions.deinit();
            const features = wb.language_features.?;
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                const providers = try features.code_lens_provider.ordered(arena, wb.activeTab().?.editor.model, false);
                if (providers.len != 0) break;
                time_compat.sleepMillis(10);
            }
            try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = try std.Uri.parse("multi-diff-editor:ext-host-test"), .label = "Extension host comparison", .resources = &resources });
            for (0..6000) |_| {
                if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
                    if (!multi.widget.getViewModel().?.isLoading) break;
                };
                _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                _ = extensions.pump();
                std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
            }
            const tab = wb.activeTab() orelse return error.TestExpectedMultiDiffTab;
            const multi = tab.multi_diff orelse return error.TestExpectedMultiDiffTab;
            const vm = multi.widget.getViewModel().?;
            try std.testing.expectEqual(@as(usize, 3), vm.items.len);
            const last = vm.items[2];
            try std.testing.expect(multi.widget.impl.bindingFor(last) == null);
            for (0..32) |_| _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            const command_id = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
            const command_args = &.{rpc.Arg{ .json = .{ .string = "fixture.tabState" } }};
            const state = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            const groups = state.object.get("groups").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), groups.len);
            const tabs = groups[0].object.get("tabs").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), tabs.len);
            const comparison = tabs[1].object;
            try std.testing.expect(comparison.get("active").?.bool);
            try std.testing.expect(!comparison.get("pinned").?.bool);
            const diffs = comparison.get("diffs").?.array.items;
            try std.testing.expectEqual(@as(usize, resources.len), diffs.len);
            for (diffs, resources) |wire, resource| {
                try std.testing.expectEqualStrings(try std_uri.encodedResource(arena, resource.original.?), wire.object.get("original").?.string);
                try std.testing.expectEqualStrings(try std_uri.encodedResource(arena, resource.modified.?), wire.object.get("modified").?.string);
            }
            const docs = state.object.get("documents").?.array.items;
            try std.testing.expectEqual(@as(usize, 7), docs.len);
            try std.testing.expect(for (docs) |doc| {
                if (std.mem.eql(u8, doc.object.get("firstLine").?.string, "old-2")) break true;
            } else false);
            // A language feature can use the last unmounted document before
            // it is scrolled into view, and the real active editor follows both sides.
            const model = last.original.model;
            const value = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", &.{
                .{ .json = .{ .string = "fixture.executeCodeLens" } },
                .{ .json = .{ .string = try std_uri.encodedResource(arena, model.uri()) } },
                .{ .json = .{ .integer = 0 } },
            }, null, 5000);
            try std.testing.expectEqualStrings(":old-2", value.array.items[0].object.get("title").?.string);
            try multi.widget.reveal(.{ .original = resources[2].original, .modified = resources[2].modified }, null);
            const control = multi.widget.activeControl() orelse return error.TestExpectedMultiDiffControl;
            control.setFocus(.original);
            try std.testing.expectEqual(control.original_editor, extensions.active.?.editor);
            control.setFocus(.modified);
            try std.testing.expectEqual(control.modified_editor, extensions.active.?.editor);
            const after = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            try std.testing.expectEqual(@as(usize, 7), after.object.get("documents").?.array.items.len);
            try std.testing.expectEqualStrings(try std_uri.encodedResource(arena, control.modified_editor.model.uri()), after.object.get("activeDocument").?.string);
            _ = try wb.closeActive();
            for (0..32) |_| _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            const closed = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            try std.testing.expectEqual(@as(usize, 1), closed.object.get("documents").?.array.items.len);
        }

        test "Extensions: real TypeScript extension drives the language features" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(io, "host/dist/extensions/typescript-language-features/package.json", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(io, "host/dist/extensions/node_modules/typescript/lib/tsserver.js", .{}) catch return error.SkipZigTest;

            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "sample.ts", .data =
                \\const  value:number = "text";
                \\const other=value.toFixed( );
                \\const é = 1; const x: number = "s";
                \\
            });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_length = try tmp.dir.realPathFile(io, "sample.ts", &path_buffer);

            const workbench_window = try TestWindow.init(allocator, io, &.{path_buffer[0..path_length]}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();
            var extension_host = try Extensions.init(
                allocator,
                io,
                workbench.extensionHostServices(),
                &.{.{ .path = "host/dist/extensions/typescript-language-features", .is_builtin = true }},
                ".cache-ext/data-ts-test",
                "host/dist",
            );
            defer extension_host.deinit();

            const marker_service = workbench.marker_service.?;
            const features = workbench.language_features.?;
            const tab = workbench.activeTab().?;
            const model = tab.editor.model;
            var resource = try markers_mod.Resource.fromUri(allocator, model.uri());
            defer resource.deinit(allocator);
            const token = @import("../../../base/common/cancellation.zig").CancellationToken.None;

            const deadline = time_compat.milliTimestamp() + 60_000;

            // Diagnostics: the extension's tsserver client publishes semantic errors
            // through its diagnostic collection.
            var found_diagnostic = false;
            var verified_utf16 = false;
            while ((!found_diagnostic or !verified_utf16) and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const list = marker_service.read(arena.allocator(), .{ .resource = resource }) catch &.{};
                for (list) |marker| {
                    if (std.mem.indexOf(u8, marker.message, "not assignable") == null) continue;
                    found_diagnostic = true;
                    if (marker.start_line_number == 3) {
                        var line = try model.getLineContent(3);
                        defer line.deinit();
                        if (marker.start_column == 21 and marker.end_column == 22 and line.items.len >= 21 and line.items[20] == 'x') {
                            verified_utf16 = true;
                        }
                    }
                }
                if (!found_diagnostic or !verified_utf16) time_compat.sleepMillis(20);
            }
            try std.testing.expect(found_diagnostic);
            try std.testing.expect(verified_utf16);

            // Completion: tsserver suggests `toFixed` after `value.`.
            var found_completion = false;
            while (!found_completion and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                const providers = try features.completion_provider.ordered(allocator, model, false);
                defer allocator.free(providers);
                for (providers) |provider| {
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const list = provider.provide_completion_items(
                        provider.context,
                        arena.allocator(),
                        model,
                        Position.init(2, 19),
                        .{},
                        token,
                    ) catch continue;
                    for (list.items) |item| {
                        if (std.mem.indexOf(u8, item.label, "toFixed") != null) {
                            found_completion = true;
                            break;
                        }
                    }
                    if (found_completion) break;
                }
                if (!found_completion) time_compat.sleepMillis(200);
            }
            try std.testing.expect(found_completion);

            // Hover: quick info for `value` carries tsserver's display string.
            var found_hover = false;
            while (!found_hover and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                const providers = try features.hover_provider.ordered(allocator, model, false);
                defer allocator.free(providers);
                for (providers) |provider| {
                    const hover = provider.provide_hover(provider.context, model, Position.init(2, 14), token, null) catch continue;
                    if (hover) |value| {
                        for (value.contents) |content| {
                            if (std.mem.indexOf(u8, content.value, "number") != null) {
                                found_hover = true;
                                break;
                            }
                        }
                    }
                    if (found_hover) break;
                }
                if (!found_hover) time_compat.sleepMillis(200);
            }
            try std.testing.expect(found_hover);

            // Definition: `value` on line 2 resolves to its declaration on line 1.
            const definition_tab = workbench.activeTab().?;
            try definition_tab.editor.setCursorPosition(Position.init(2, 13));
            var found_definition = false;
            while (!found_definition and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                if (try workbench.revealDefinition()) {
                    if (workbench.activeTab()) |opened| {
                        const target = opened.editor.modelCursorPosition();
                        if (target.lineNumber == 1 and std.mem.eql(u8, opened.editor.path, definition_tab.editor.path)) {
                            found_definition = true;
                            break;
                        }
                    }
                }
                time_compat.sleepMillis(200);
            }
            try std.testing.expect(found_definition);

            try tab.editor.setCursorPosition(Position.init(2, 13));
            try workbench.commands.execute("references-view.findReferences");
            try std.testing.expect(workbench.quick_access.isOpen());
            const reference_picker = workbench.quick_access.inputService().pickerRef();
            try std.testing.expect(reference_picker.items.items.len >= 3);
            reference_picker.accept();
            try workbench.commands.execute("references-view.pickFromHistory");
            try std.testing.expectEqualStrings("value", reference_picker.items.items[0].item.label);
            reference_picker.accept();
            try std.testing.expect(reference_picker.items.items.len >= 3);
            workbench.quick_access.inputService().hide();

            // Document symbols: the extension's provider feeds the breadcrumb/outline
            // registries with UTF-16-converted ranges.
            var found_symbol = false;
            while (!found_symbol and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                const providers = try features.document_symbol_provider.ordered(allocator, model, false);
                defer allocator.free(providers);
                for (providers) |provider| {
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const symbols = provider.provide_document_symbols(
                        provider.context,
                        arena.allocator(),
                        model,
                        token,
                    ) catch continue;
                    for (symbols) |symbol| {
                        if (std.mem.eql(u8, symbol.name, "value") or std.mem.eql(u8, symbol.name, "other")) {
                            found_symbol = true;
                            break;
                        }
                    }
                    if (found_symbol) break;
                }
                if (!found_symbol) time_compat.sleepMillis(200);
            }
            try std.testing.expect(found_symbol);

            // Formatting: the extension's document formatting provider replaces the
            // unformatted text through the regular editor command path.
            var formatted = false;
            while (!formatted and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                tab.editor.formatDocument() catch {};
                var text = try model.getValue(.LF, false);
                defer text.deinit();
                formatted = std.mem.indexOf(u8, text.items, "const value: number") != null;
                if (!formatted) time_compat.sleepMillis(200);
            }
            try std.testing.expect(formatted);
        }

        test "Extensions: real TypeScript extension reports JavaScript syntax errors" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(io, "host/dist/extensions/typescript-language-features/package.json", .{}) catch return error.SkipZigTest;
            std.Io.Dir.cwd().access(io, "host/dist/extensions/node_modules/typescript/lib/tsserver.js", .{}) catch return error.SkipZigTest;

            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "broken.cjs", .data =
                \\function f() {
                \\    return 1;
                \\}
                \\
            });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_length = try tmp.dir.realPathFile(io, "broken.cjs", &path_buffer);

            const workbench_window = try TestWindow.init(allocator, io, &.{path_buffer[0..path_length]}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();
            var extension_host = try Extensions.init(
                allocator,
                io,
                workbench.extensionHostServices(),
                &.{.{ .path = "host/dist/extensions/typescript-language-features", .is_builtin = true }},
                ".cache-ext/data-js-test",
                "host/dist",
            );
            defer extension_host.deinit();

            const marker_service = workbench.marker_service.?;
            const tab = workbench.activeTab().?;
            const model = tab.editor.model;
            // Let the extension activate and open the mirror before simulating the
            // user edit; the workbench starts the host asynchronously after the first
            // document delta.
            const ready_deadline = time_compat.milliTimestamp() + 5_000;
            while (time_compat.milliTimestamp() < ready_deadline) {
                _ = extension_host.pump();
                time_compat.sleepMillis(20);
            }
            // Make the file invalid after the extension host has opened it, matching
            // the user path: delete the closing brace and wait for the diagnostics.
            try tab.editor.setCursorPosition(Position.init(3, 2));
            try tab.editor.deleteLeft();
            try std.testing.expect(tab.editor.last_content_changes.items.len > 0);
            var edited_line = try model.getLineContent(3);
            defer edited_line.deinit();
            try std.testing.expectEqualStrings("", edited_line.items);

            var resource = try markers_mod.Resource.fromUri(allocator, model.uri());
            defer resource.deinit(allocator);

            const deadline = time_compat.milliTimestamp() + 60_000;
            var found_error = false;
            var marker_line: u32 = 0;
            var marker_column: u32 = 0;
            while (!found_error and time_compat.milliTimestamp() < deadline) {
                _ = extension_host.pump();
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const list = marker_service.read(arena.allocator(), .{ .resource = resource }) catch &.{};
                for (list) |marker| {
                    if (marker.severity == markers_mod.MarkerSeverity.Error) {
                        found_error = true;
                        marker_line = marker.start_line_number;
                        marker_column = marker.start_column;
                        break;
                    }
                }
                if (!found_error) time_compat.sleepMillis(20);
            }
            try std.testing.expect(found_error);

            // The same marker feeds the workbench hover: moving the caret into the
            // diagnostic range and opening the hover (the `gh` path) must show the
            // severity/message rows.
            try tab.ensureControllers();
            try tab.editor.setCursorPosition(Position.init(marker_line, marker_column));
            try std.testing.expect(try workbench.showHover());
            const controllers = tab.controllers orelse return error.TestUnexpectedResult;
            try std.testing.expect(controllers.hover.isVisible());
            const content = controllers.hover.widget().getWidgetContent() orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(u8, content, "Error:") != null);
        }

        test "Extensions: showDocument applies a line selection" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            var editor = try Editor.createFromText(allocator, io, "alpha\nbeta\n", "selection.txt", 40, 8);
            defer {
                editor.deinit();
                allocator.destroy(editor);
            }
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const options = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"selection\":{\"startLineNumber\":2,\"startColumn\":1,\"endLineNumber\":2,\"endColumn\":2}}", .{});
            applyShowDocumentSelection(editor, options);
            try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
            try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);
        }

        test "Extensions: editorScroll, revealLine and cursorMove command arguments" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            var editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight", "test.txt", 40, 6);
            defer {
                editor.deinit();
                allocator.destroy(editor);
            }

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const scroll_args = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena.allocator(),
                "[{\"to\":\"down\",\"by\":\"line\",\"value\":2}]",
                .{},
            );
            try std.testing.expect(applyEditorScroll(editor, scroll_args.array.items));
            try std.testing.expectEqual(@as(usize, 3), editor.topViewLine());

            const reveal_args = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena.allocator(),
                "[{\"lineNumber\":0,\"at\":\"top\"}]",
                .{},
            );
            try std.testing.expect(applyRevealLine(editor, reveal_args.array.items));
            try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());

            try editor.setCursorPosition(Position.init(1, 1));
            const move_args = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena.allocator(),
                "[{\"to\":\"down\",\"by\":\"line\",\"select\":false,\"value\":1}]",
                .{},
            );
            try std.testing.expect(try applyCursorMove(editor, move_args.array.items));
            try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
        }

        test "extension host document mirror keeps UTF-16 deletion ranges valid" {
            const allocator = std.testing.allocator;
            var lines = std.array_list.Managed([]u8).init(allocator);
            try lines.append(try allocator.dupe(u8, "é}"));
            defer freeDocumentLines(allocator, &lines);

            // `é` is two UTF-8 bytes but one UTF-16 code unit: deleting `}` is byte
            // columns 3..4 and UTF-16 columns 2..3 in the mirrored document.
            try std.testing.expectEqual(@as(usize, 2), utf16ColumnInLines(lines.items, 1, 3));
            try std.testing.expectEqual(@as(usize, 3), utf16ColumnInLines(lines.items, 1, 4));

            var empty: [0]u8 = .{};
            try applyChangeToDocumentLines(allocator, &lines, .{
                .range = Range.init(1, 3, 1, 4),
                .text = empty[0..],
            });
            try std.testing.expectEqual(@as(usize, 1), lines.items.len);
            try std.testing.expectEqualStrings("é", lines.items[0]);
        }

        /// Use one extension per host so an identically labelled native or Emmet
        /// suggestion cannot mask a client/server or activation failure.
        fn checkBuiltinCompletion(comptime name: []const u8, filename: []const u8, source: []const u8, expected: []const u8) !void {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const allocator = std.testing.allocator;
            var catalog = try @import("../../services/extensions/common/extensionsRegistry.zig").scan(allocator, &.{ "vscode/extensions/configuration-editing", "vscode/extensions/lua" });
            defer catalog.deinit();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = source });
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = try tmp.dir.realPathFile(io, filename, &buf);
            const workbench_window = try TestWindow.init(allocator, io, &.{buf[0..len]}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            workbench.setDeclarativeExtensions(&catalog);
            try workbench.enableLanguageFeatures();
            var extensions = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{
                .path = "host/dist/extensions/" ++ name,
                .is_builtin = true,
            }}, ".cache-ext/test-" ++ name, "host/dist");
            defer extensions.deinit();
            const model = workbench.activeTab().?.editor.model;
            const deadline = time_compat.milliTimestamp() + 15_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const providers = try workbench.language_features.?.completion_provider.ordered(a, model, false);
                for (providers) |provider| {
                    const items = provider.provide_completion_items(provider.context, a, model, Position.init(1, source.len + 1), .{}, .None) catch continue;
                    for (items.items) |item| {
                        if (std.mem.indexOf(u8, item.insert_text, expected) != null) return;
                    }
                }
                time_compat.sleepMillis(100);
            }
            return error.MissingBuiltinCompletion;
        }

        test "Extensions: CSS server suggests background-color" {
            try checkBuiltinCompletion("css-language-features", "style.css", "a { background-col", "background-color");
        }

        test "Extensions: HTML server suggests textarea" {
            try checkBuiltinCompletion("html-language-features", "index.html", "<textar", "textarea");
        }

        test "Extensions: Emmet expands a nested abbreviation" {
            try checkBuiltinCompletion("emmet", "index.html", "ul>li", "<li>");
        }

        test "Extensions: settings authoring suggests languages from declarative extensions" {
            try checkBuiltinCompletion("configuration-editing", "settings.json", "{\"files.defaultLanguage\": ", "lua");
        }

        test "Extensions: manifest authoring suggests a language override snippet" {
            try checkBuiltinCompletion("extension-editing", "package.json", "{\"contributes\": {\"configurationDefaults\": ", "language");
        }

        test "Extensions: accept incoming merge conflict in the workbench" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "conflict.txt", .data = "<<<<<<< HEAD\ncurrent\n=======\nincoming\n>>>>>>> branch\n" });
            const path = try tmp.dir.realPathFileAlloc(io, "conflict.txt", allocator);
            defer allocator.free(path);
            const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 25);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            var host = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/dist/extensions/merge-conflict", .is_builtin = true }}, ".cache-ext/test-merge", "host/dist");
            defer host.deinit();
            const command = "merge-conflict.accept.all-incoming";
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (workbench.commands.get(command) == null and time_compat.milliTimestamp() < deadline) {
                _ = host.pump();
                time_compat.sleepMillis(10);
            }
            const action = workbench.commands.getRegistration(command) orelse return error.MissingMergeCommand;
            try std.testing.expect(action.isInPalette() and (try workbench.ensureContextKeys()).contextMatchesRules(action.descriptor.precondition.?));
            try workbench.commands.execute(command);
            while (time_compat.milliTimestamp() < deadline) {
                _ = host.pump();
                var value = try workbench.activeTab().?.editor.model.getValue(null, false);
                defer value.deinit();
                if (std.mem.eql(u8, value.items, "incoming\n")) return;
                time_compat.sleepMillis(10);
            }
            return error.MissingMergeEdit;
        }

        test "Extensions: account sessions need a grant for the requesting extension and scopes" {
            if (!build_options.e2e) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const workbench_window = try TestWindow.init(allocator, io, &.{}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            const ext = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/authentication", .is_under_development = true }}, ".cache-ext/auth-fixture", "host/dist");
            defer ext.deinit();
            var tmp = std.heap.ArenaAllocator.init(allocator);
            defer tmp.deinit();
            const a = tmp.allocator();
            try ext.accounts.activate(a, "fixture");
            const Result = struct {
                success: ?bool = null,
                fn receive(ctx: *anyopaque, reply: rpc.Reply) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.success = reply == .json and reply.json == .bool and reply.json.bool;
                }
                fn request(self: *@This(), host: *Extensions, interactive: bool, scope: []const u8) !void {
                    self.success = null;
                    _ = try host.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &.{
                        .{ .json = .{ .string = "fixture.account" } }, .{ .json = .{ .bool = interactive } }, .{ .json = .{ .string = scope } },
                    }, null, .{ .context = self, .callback = receive });
                }
                fn wait(self: *@This(), host: *Extensions, picker: bool) !void {
                    const deadline = time_compat.milliTimestamp() + 5000;
                    while (time_compat.milliTimestamp() < deadline) {
                        _ = host.pump();
                        if (if (picker) host.services.quick_access.isOpen() else self.success != null) return;
                        time_compat.sleepMillis(10);
                    }
                    return error.Timeout;
                }
            };
            var result: Result = .{};
            try result.request(ext, false, "read");
            try result.wait(ext, false);
            try std.testing.expect(!result.success.?);
            try result.request(ext, true, "read");
            try result.wait(ext, true);
            const picker = workbench.quick_access.inputService().pickerRef();
            try std.testing.expectEqualStrings("Cancel", picker.activeItem().?.label);
            picker.accept();
            try result.wait(ext, false);
            try std.testing.expect(!result.success.?);
            try result.request(ext, true, "read");
            try result.wait(ext, true);
            picker.setActiveIndex(1);
            picker.accept();
            try result.wait(ext, false);
            try std.testing.expect(result.success.?);
            try result.request(ext, false, "read");
            try result.wait(ext, false);
            try std.testing.expect(result.success.?);
            try result.request(ext, false, "write");
            try result.wait(ext, false);
            try std.testing.expect(!result.success.?);
            const accounts = try ext.accounts.accounts(a, "fixture");
            try std.testing.expectEqual(@as(usize, 1), accounts.array.items.len);
            try std.testing.expect(accounts.array.items[0].object.get("accessToken") == null);
            try workbench.commands.execute("workbench.action.accounts.manage");
            picker.accept();
            try std.testing.expectEqualStrings("Fixture user", picker.activeItem().?.label);
            picker.accept();
            picker.setActiveIndex(1);
            picker.accept();
            try std.testing.expectEqual(@as(usize, 0), (try ext.accounts.accounts(a, "fixture")).array.items.len);
            try result.request(ext, false, "read");
            try result.wait(ext, false);
            try std.testing.expect(!result.success.?);
        }
    };
}
