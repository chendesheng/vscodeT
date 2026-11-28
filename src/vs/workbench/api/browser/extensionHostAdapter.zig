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
const extension_service = @import("../../services/extensions/common/abstractExtensionService.zig");
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
const groups_service = @import("../../services/editor/common/editorGroupsService.zig");
const EditorGroup = groups_service.EditorGroup;
const EditorsChangeEvent = groups_service.EditorsChangeEvent;
const FileEditorInput = @import("../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const TextResourceEditorInput = @import("../../common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
const diff_input_mod = @import("../../common/editor/diffEditorInput.zig");
const MultiDiffEditorInput = @import("../../contrib/multiDiffEditor/browser/multiDiffEditorInput.zig").MultiDiffEditorInput;
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
const MainThreadQuickDiff = @import("./mainThreadQuickDiff.zig").MainThreadQuickDiff;
const MainThreadDocumentContentProviders = @import("./mainThreadDocumentContentProviders.zig").MainThreadDocumentContentProviders;
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
    editor_model_listener: usize,
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
    eager_start_request: ?u32 = null,
    activation_tracker: extension_service.ActivationTracker,
    needs_render: bool = false,
    editor_service: EditorService,
    active_editor_listener: ?usize = null,
    workspace_listener: ?usize = null,
    model_added_listener: ?usize = null,
    model_removed_listener: ?usize = null,
    visible_editors_listener: ?usize = null,
    group_model_listener: ?usize = null,
    input_resources_listener: ?usize = null,
    add_group_listener: ?usize = null,
    remove_group_listener: ?usize = null,
    move_group_listener: ?usize = null,
    tabs_task: Task = .{},
    models_task: Task = .{},
    rpc_task: Task = .{},
    models: documents_and_editors.ModelCollection,
    active_selection_handler: ViewEventHandler,
    selection_task: Task = .{},
    visible_ranges_task: Task = .{},
    pending_selection_source: SelectionSource = .keyboard,
    /// The active editor whose scroll events are mirrored to the host.
    scroll_listener_editor: ?*Editor = null,
    inline_completions: @import("inlineCompletionSession.zig").Session = undefined,
    language_features_actor: ?MainThreadLanguageFeatures = null,
    progress_actor: ?@import("mainThreadProgress.zig").MainThreadProgress = null,
    file_events_actor: ?@import("mainThreadFileSystemEventService.zig").MainThreadFileSystemEventService = null,
    output_actor: ?@import("mainThreadOutputService.zig").MainThreadOutputService = null,
    languages_actor: ?@import("mainThreadLanguages.zig").MainThreadLanguages = null,
    quick_diff_actor: ?MainThreadQuickDiff = null,
    document_content_actor: ?MainThreadDocumentContentProviders = null,
    bulk_edit_actor: ?@import("mainThreadBulkEdits.zig").MainThreadBulkEdits = null,
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
    save_participant: @import("mainThreadSaveParticipant.zig").MainThreadSaveParticipant = undefined,
    save_participant_registered: bool = false,
    pending_document_saves: std.ArrayList(*DocumentSaveRequest) = .empty,
    text_editors_actor: ?MainThreadTextEditors = null,
    editor_tabs_actor: ?MainThreadEditorTabs = null,
    pending_tab_closes: std.ArrayList(*TabCloseRequest) = .empty,
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
        // Once all actors exist, a failed handshake must follow the very
        // same teardown as a normal host shutdown: bootstrap can already
        // receive provider registrations and schedule editor callbacks.
        const self = try create(allocator, io, services, extension_paths, user_data_dir, runtime_dir);
        errdefer self.deinit();
        try self.boot(runtime_dir);
        try self.registerEditorListeners();
        self.workspace_listener = try services.workspace.on_did_change_workspace_folders.listen(self, onWorkspaceChanged);
        self.save_participant = .{
            .allocator = allocator,
            .host = self.host,
            .window = services.window,
            .models = .{ .context = self, .synchronize = synchronizeSaveModel },
        };
        try services.text_files.addDocumentSaveParticipant(self.save_participant.interface());
        self.save_participant_registered = true;
        self.host.attachReadyTask(&self.rpc_task);
        return self;
    }

    fn create(
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
        for (owned_descriptions, 0..) |*description, index| extension_ptrs[index] = description;
        // Upstream configurationExtensionPoint applies one registry delta for
        // all added extensions. Rebuild the effective configuration once,
        // before `$initializeConfiguration`, not after each manifest.
        services.register_extension_configurations(services.common.context, owned_descriptions);

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

        self.rpc_task = .{ .queue = services.window, .context = self, .run = dispatchRpc, .progress = true };
        errdefer self.rpc_task.schedule(null);
        self.models_task = .{ .queue = services.window, .context = self, .run = updateModels, .progress = true };
        self.tabs_task = .{ .queue = services.window, .context = self, .run = updateTabs, .progress = true };
        self.selection_task = .{ .queue = services.window, .context = self, .run = updateSelection, .progress = true };
        self.visible_ranges_task = .{ .queue = services.window, .context = self, .run = updateVisibleRanges, .progress = true };
        const host_script = try std.fs.path.join(allocator, &.{ runtime_dir, "extensionHost.mjs" });
        defer allocator.free(host_script);
        // Fail before spawning node: without the bundle the host can never
        // connect, and the manager would otherwise wait for its socket timeout.
        std.Io.Dir.cwd().access(io, host_script, .{}) catch return error.ExtensionHostBundleMissing;
        self.host = try manager.HostManager.start(allocator, .{
            .host_script = host_script,
            .extensions = self.extension_ptrs,
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
        errdefer self.storage_actor.?.deinit();
        self.statusbar_actor = try MainThreadStatusBar.init(allocator, services.common.statusbar, .{
            .context = self,
            .callback = requestTerminalFrame,
        });
        errdefer self.statusbar_actor.?.deinit();
        self.commands_actor = try MainThreadCommands.init(allocator, self.host, .{
            .context = self,
            .execute = executeHostCommand,
        }, services.common.commands, self.descriptions, try services.context_keys(services.common.context));
        errdefer self.commands_actor.?.deinit();
        self.configuration_actor = MainThreadConfiguration.init(
            allocator,
            .{ .context = self, .data = configurationDataHost },
            .{ .context = self, .notify = configurationNotifyHost },
        );
        errdefer self.configuration_actor.?.deinit();
        self.documents_actor = .init(allocator, services.text_model_service, services.window, .{
            .context = self,
            .synchronize = documentsSynchronizeHost,
            .create = documentsCreateHost,
            .save = documentsSaveHost,
        });
        errdefer self.documents_actor.?.deinit();
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
            .close = editorTabsCloseHost,
        });
        self.window_actor = .{ .host = .{ .context = self, .open_uri = windowOpenUriHost } };
        self.extension_service_actor = .{ .host = .{
            .context = self,
            .on_did_activate = extensionServiceActivatedHost,
            .as_browser_uri = extensionServiceBrowserUriHost,
        } };
        try self.accounts.init(allocator, services.common.commands, services.common.quick_input, .{ .context = services.common.context, .show = services.common.status_hint }, self.host, services.window, self.descriptions);
        errdefer self.accounts.deinit();
        try self.task_service.init(allocator, services.common.commands, services.common.quick_input, self.descriptions, .{
            .context = self,
            .window = services.window,
            .activate = activateTaskType,
            .run_terminal = runTaskInTerminal,
        });
        errdefer self.task_service.deinit();
        self.task_actor = .{ .allocator = allocator, .host = self.host, .window = services.window, .service = self.task_service.interface() };
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
        self.quick_diff_actor = MainThreadQuickDiff.init(allocator, services.quick_diff, services.quick_diff_models, .{
            .context = self,
            .request = quickDiffRequestAsync,
            .notify = quickDiffNotify,
        });
        errdefer self.quick_diff_actor.?.deinit();
        self.document_content_actor = MainThreadDocumentContentProviders.init(allocator, services.text_model_service, .{
            .context = self,
            .request = documentContentRequestAsync,
        });
        errdefer self.document_content_actor.?.deinit();
        self.bulk_edit_actor = .{ .allocator = allocator, .service = services.bulk_edit };
        errdefer self.bulk_edit_actor.?.deinit();
        self.languages_actor = .init(allocator, services.language_status);
        errdefer self.languages_actor.?.deinit();
        self.output_actor = .init(allocator, services.output_service, services.views, .{ .context = self, .set_visible_channel = setVisibleOutputChannel });
        errdefer self.output_actor.?.deinit();
        try self.output_actor.?.attach();
        self.file_events_actor = .init(allocator, try services.file_watcher(services.common.context), services.file_service, .{ .context = self, .notify = notifyFileEvents });
        errdefer self.file_events_actor.?.deinit();
        try self.file_events_actor.?.attach();
        self.progress_actor = .init(allocator, services.progress_service, .{ .context = self, .cancel = cancelProgress });
        errdefer self.progress_actor.?.deinit();
        self.registerActors();
        self.initLanguageActors() catch |err| {
            std.log.warn("language feature actors unavailable: {s}", .{@errorName(err)});
        };
        return self;
    }

    pub fn deinit(self: *Extensions) void {
        if (self.workspace_listener) |listener| self.services.workspace.on_did_change_workspace_folders.unlisten(listener);
        if (self.save_participant_registered) self.services.text_files.removeDocumentSaveParticipant(&self.save_participant);
        self.save_participant_registered = false;
        if (self.eager_start_request) |request| self.host.rpc.cancel(request);
        self.eager_start_request = null;
        while (self.pending_document_saves.items.len != 0) {
            const request = self.pending_document_saves.items[self.pending_document_saves.items.len - 1];
            request.channel = null;
            request.document.cancelPendingSave();
        }
        self.pending_document_saves.deinit(self.allocator);
        self.host.attachReadyTask(null);
        self.rpc_task.schedule(null);
        if (self.services.quick_access.isOpen()) self.services.quick_access.inputService().hide();
        self.message_service.deinit();
        if (self.terminal_completions) |*session| session.deinit();
        self.secret_state.deinit(self.allocator);
        self.accounts.deinit();
        self.task_service.cancelPending();
        self.task_actor.deinit();
        self.task_service.deinit();
        self.inline_completions.deinit();
        if (self.quick_diff_actor) |*actor| actor.deinit();
        if (self.document_content_actor) |*actor| actor.deinit();
        if (self.bulk_edit_actor) |*actor| actor.deinit();
        if (self.documents_actor) |*actor| actor.deinit();
        self.unregisterEditorListeners();
        self.removeActiveDocument() catch {};
        self.models.deinit();
        if (self.diagnostics_actor) |actor| {
            actor.deinit();
            self.diagnostics_actor = null;
        }
        if (self.language_features_actor) |*actor| actor.deinit();
        if (self.languages_actor) |*actor| actor.deinit();
        if (self.output_actor) |*actor| actor.deinit();
        if (self.file_events_actor) |*actor| actor.deinit();
        if (self.progress_actor) |*actor| actor.deinit();
        self.services.logger_service.clear();
        if (self.storage_actor) |*actor| actor.deinit();
        if (self.statusbar_actor) |*actor| actor.deinit();
        if (self.commands_actor) |*actor| actor.deinit();
        if (self.configuration_actor) |*actor| actor.deinit();
        if (self.editor_tabs_actor) |*actor| actor.deinit();
        for (self.pending_tab_closes.items) |request| {
            request.extensions = null;
            request.channel = null;
        }
        self.pending_tab_closes.deinit(self.allocator);
        self.activation_tracker.deinit();
        self.last_selections.deinit();
        self.host.deinit();
        self.rpc_task.schedule(null);
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
            if (nid == @backingInt(protocol.MainContext.MainThreadBulkEdits)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeBulkEdits });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadSecretState)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeSecretState });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadAuthentication)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeAuthentication });
            } else if (nid == 26) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeLanguageFeatures });
            } else if (nid == 16) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeDiagnostics });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadDocumentContentProviders)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeDocumentContentProviders });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadQuickDiff)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeQuickDiff });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadOutputService)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeOutput });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadLogger)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeLogger });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadLanguages)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeLanguages });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadProgress)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeProgress });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadFileSystemEventService)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeFileEvents });
            } else if (nid == @backingInt(protocol.MainContext.MainThreadFileSystem)) {
                self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invokeFileSystem });
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
        self.language_features_actor.?.workspace_symbol_registry = &self.services.quick_access.workspace_symbols.registry;
        try self.inline_completions.start(&self.language_features_actor.?);
        self.diagnostics_actor = try MainThreadDiagnostics.init(self.allocator, marker_service, .{
            .context = self,
            .notify = diagnosticsNotify,
        }, .{ .context = self, .model_for = diagnosticsModelFor });
    }

    fn languageFeaturesRequest(context: *anyopaque, allocator: Allocator, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, timeout_ms: u32) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const actor = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures);
        if (@import("ui").WindowIo.inFiber(self.services.window.io))
            return self.host.requestAwait(self.services.window, allocator, actor, method, args, token, timeout_ms);
        return self.host.requestSync(allocator, actor, method, args, token, timeout_ms);
    }

    const AsyncActorRequest = struct {
        owner: *Extensions,
        request_id: u32,
        callback: rpc.ReplyCallback,

        fn complete(context: *anyopaque, reply: rpc.Reply) void {
            const self: *AsyncActorRequest = @ptrCast(@alignCast(context));
            const allocator = self.owner.allocator;
            const callback = self.callback;
            allocator.destroy(self);
            callback.call(reply);
        }
        fn cancel(context: *anyopaque) void {
            const self: *AsyncActorRequest = @ptrCast(@alignCast(context));
            self.owner.host.rpc.cancel(self.request_id);
            self.owner.allocator.destroy(self);
        }
    };

    fn languageFeaturesRequestAsync(context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !@import("../../../base/common/lifecycle.zig").IDisposable {
        return requestActorAsync(context, protocol.ExtHostContext.ExtHostLanguageFeatures, method, args, callback);
    }

    fn quickDiffRequestAsync(context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !@import("../../../base/common/lifecycle.zig").IDisposable {
        return requestActorAsync(context, protocol.ExtHostContext.ExtHostQuickDiff, method, args, callback);
    }

    fn documentContentRequestAsync(context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !@import("../../../base/common/lifecycle.zig").IDisposable {
        return requestActorAsync(context, protocol.ExtHostContext.ExtHostDocumentContentProviders, method, args, callback);
    }

    fn requestActorAsync(context: *anyopaque, actor: protocol.ExtHostContext, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !@import("../../../base/common/lifecycle.zig").IDisposable {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const pending = try self.allocator.create(AsyncActorRequest);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .owner = self, .request_id = 0, .callback = callback };
        pending.request_id = try self.host.call(proxyIdentifier.identifierFromEnum(actor), method, args, @import("../../../base/common/cancellation.zig").CancellationToken.None, .{ .context = pending, .callback = AsyncActorRequest.complete });
        return .{ .context = pending, .disposeFn = AsyncActorRequest.cancel };
    }

    fn quickDiffNotify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostQuickDiff), method, args);
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
        self.requestRender();
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

    fn invokeBulkEdits(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, _: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.bulk_edit_actor) |*actor| return actor.invoke(method, args);
        return .empty;
    }

    fn invokeDocumentContentProviders(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        _ = arena;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.document_content_actor) |*actor| return actor.invoke(method, args);
        return .empty;
    }

    fn invokeQuickDiff(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        _ = arena;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.quick_diff_actor) |*actor| return actor.invoke(method, args);
        return .empty;
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

    fn setVisibleOutputChannel(context: *anyopaque, id: ?[]const u8) !void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostOutputService), "$setVisibleChannel", &.{.{ .json = if (id) |value| .{ .string = value } else .null }});
    }

    fn invokeOutput(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.output_actor) |*actor| return actor.invoke(method, args, arena);
        return .{ .err = .{ .name = "Unavailable", .message = method } };
    }

    fn invokeLogger(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var actor = @import("mainThreadLogService.zig").MainThreadLoggerService{ .service = self.services.logger_service };
        return actor.invoke(method, args, arena);
    }

    fn invokeLanguages(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, _: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.languages_actor) |*actor| {
            const reply = try actor.invoke(method, args);
            self.requestRender();
            return reply;
        }
        return .{ .err = .{ .name = "Unavailable", .message = method } };
    }

    fn cancelProgress(context: *anyopaque, handle: i64) !void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostProgress), "$acceptProgressCanceled", &.{.{ .json = .{ .integer = handle } }});
    }

    fn invokeProgress(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, _: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.progress_actor) |*actor| return actor.invoke(method, args);
        return .{ .err = .{ .name = "Unavailable", .message = method } };
    }

    fn notifyFileEvents(context: *anyopaque, event: std.json.Value) !void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostFileSystemEventService), "$onFileEvent", &.{.{ .json = event }});
    }

    fn invokeFileEvents(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.file_events_actor) |*actor| return actor.invoke(method, args, arena);
        return .{ .err = .{ .name = "Unavailable", .message = method } };
    }

    fn invokeFileSystem(context: *anyopaque, method: []const u8, args: []const rpc.Arg, _: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const actor = @import("mainThreadFileSystem.zig").MainThreadFileSystem{ .service = self.services.file_service };
        return actor.invoke(method, args, arena);
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
        if (std.mem.eql(u8, method, "$executeCommand") and args.len > 1 and args[0] == .json and args[0].json == .string and std.mem.eql(u8, args[0].json.string, "_executeCodeActionProvider")) {
            if (args[1] != .json or args[1].json != .array or args[1].json.array.items.len < 2) return error.InvalidArguments;
            const parameters = args[1].json.array.items;
            const components = try std_uri.componentsFromJson(parameters[0], arena);
            const key = try std_uri.resourceKeyFromComponents(arena, components);
            const resource: std.Uri = .{ .scheme = components.scheme, .host = if (components.authority.len != 0) .{ .raw = components.authority } else null, .path = .{ .raw = components.path }, .query = if (components.query.len != 0) .{ .raw = components.query } else null, .fragment = if (components.fragment.len != 0) .{ .raw = components.fragment } else null };
            const kind = if (parameters.len > 2 and parameters[2] == .string) parameters[2].string else null;
            const count: usize = if (parameters.len > 3 and parameters[3] == .integer and parameters[3].integer > 0) @intCast(parameters[3].integer) else 0;
            const provider = if (self.language_features_actor) |*actor| actor else return error.LanguageFeaturesUnavailable;
            return provider.executeCodeActionCommand(resource, parameters[1], kind, count, self.models.documentForResource(key), self.services.text_model_service, self.services.common.commands, self.services.window);
        }
        if (std.mem.eql(u8, method, "$executeCommand") and args.len > 1 and args[0] == .json and args[0].json == .string) if (@import("mainThreadLanguageFeatures.zig").ModelPositionCommand.fromId(args[0].json.string)) |command| {
            if (args[1] != .json or args[1].json != .array or args[1].json.array.items.len < 2) return error.InvalidArguments;
            const parameters = args[1].json.array.items;
            const components = try std_uri.componentsFromJson(parameters[0], arena);
            const key = try std_uri.resourceKeyFromComponents(arena, components);
            const resource: std.Uri = .{
                .scheme = components.scheme,
                .host = if (components.authority.len != 0) .{ .raw = components.authority } else null,
                .path = .{ .raw = components.path },
                .query = if (components.query.len != 0) .{ .raw = components.query } else null,
                .fragment = if (components.fragment.len != 0) .{ .raw = components.fragment } else null,
            };
            if (parameters[1] != .object) return error.InvalidArguments;
            const line = parameters[1].object.get("lineNumber") orelse return error.InvalidArguments;
            const column = parameters[1].object.get("column") orelse return error.InvalidArguments;
            if (line != .integer or column != .integer or line.integer < 1 or column.integer < 1) return error.InvalidArguments;
            const provider = if (self.language_features_actor) |*actor| actor else return error.LanguageFeaturesUnavailable;
            return provider.executeModelPositionCommand(command, resource, Position.init(@intCast(line.integer), @intCast(column.integer)), self.models.documentForResource(key), self.services.text_model_service, self.services.common.commands);
        };
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
        self.requestRender();
        return true;
    }

    fn extensionServiceActivatedHost(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.activated = true;
    }

    fn extensionServiceBrowserUriHost(_: *anyopaque, uri: std.json.Value) std.json.Value {
        return uri;
    }

    fn editorTabsNotifyHost(context: *anyopaque, method: []const u8, model: std.json.Value) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var args = [_]rpc.Arg{.{ .json = model }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditorTabs), method, &args, null, manager.noop_callback) catch {};
    }

    fn editorTabsMoveHost(context: *anyopaque, tab_id: []const u8, requested_index: i64, column: i64, preserve_focus: bool) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const target = (try self.findTabById(tab_id)) orelse return error.UnknownTab;
        const opening = self.editor_service.opening orelse return error.EditorOpeningUnavailable;
        const group_actions = opening.group_actions;
        const part = self.editor_service.part;
        const previous_group = part.service.activeGroup().id;
        const columns = @import("../../services/editor/common/editorGroupColumn.zig");
        const preference = group_actions.preferredSideBySideDirection();
        const target_id = try columns.columnToEditorGroup(part.interface(), self.allocator, preference, column);
        const dest = if (std.math.cast(u32, target_id)) |id| part.viewForGroup(part.service.getGroup(id) orelse return error.UnknownTabGroup) orelse return error.UnknownTabGroup else blk: {
            const ordered = try part.orderedViews(self.allocator);
            defer self.allocator.free(ordered);
            if (ordered.len == 0) return error.UnknownTabGroup;
            break :blk try part.addGroup(ordered[ordered.len - 1], if (column == columns.SIDE_GROUP) preference else .RIGHT);
        };
        if (preserve_focus) if (part.service.getGroup(previous_group)) |group| part.service.activateGroup(group);
        const length = dest.group.model.count();
        const index = if (requested_index < 0 or requested_index > @as(i64, @intCast(length))) length else @as(usize, @intCast(requested_index));
        if (target.pane != dest and target.tab.input.canMove(target.pane.group.id, dest.group.id) != .yes) return error.EditorMoveVetoed;
        _ = try target.pane.moveEditor(dest, target.tab, .{ .pinned = true, .sticky = target.pane.group.model.isSticky(.{ .editor = target.tab.input }), .active = true, .preserve_focus = preserve_focus, .index = @intCast(index) }, group_actions.transfer.move);
        if (target.pane != dest and target.pane.group.model.count() == 0) part.collapseGroup(target.pane, group_actions.transfer);
        group_actions.transfer.layout(group_actions.transfer.copy.context);
        self.requestRender();
    }

    const LocatedTab = struct { pane: *GroupPane, tab: *Tab };

    fn findTabById(self: *Extensions, id: []const u8) !?LocatedTab {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        for (self.editor_service.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (std.mem.eql(u8, id, try tabId(arena.allocator(), pane.group.id, tab.input))) return .{ .pane = pane, .tab = tab };
            }
        }
        return null;
    }

    fn editorTabsCloseHost(context: *anyopaque, kind: editor_tabs.CloseKind, ids: []const std.json.Value, preserve_focus: bool) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return TabCloseRequest.create(self, kind, ids, preserve_focus);
    }

    /// Upstream groups all close targets by editor group and awaits each
    /// group's confirmation. The native dialog callback is the continuation
    /// of that promise; the RPC request stays pending until it settles.
    const TabCloseRequest = struct {
        allocator: Allocator,
        extensions: ?*Extensions,
        arena: std.heap.ArenaAllocator,
        kind: editor_tabs.CloseKind,
        batches: std.ArrayList(Batch) = .empty,
        next: usize = 0,
        all_closed: bool = true,
        preserve_focus: bool,
        original_group: u32,
        channel: ?*rpc.RpcProtocol = null,
        request_id: u32 = 0,

        const Batch = struct { group_id: u32, tabs: std.ArrayList([]const u8) = .empty };

        fn create(extensions: *Extensions, kind: editor_tabs.CloseKind, ids: []const std.json.Value, preserve_focus: bool) !rpc.HandlerReply {
            const allocator = extensions.allocator;
            const self = try allocator.create(TabCloseRequest);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .extensions = extensions, .arena = .init(allocator), .kind = kind, .preserve_focus = preserve_focus, .original_group = extensions.editor_service.part.service.activeGroup().id };
            errdefer self.arena.deinit();
            const a = self.arena.allocator();
            for (ids) |id| {
                const group_id = switch (kind) {
                    .tabs => blk: {
                        if (id != .string) continue;
                        const located = (try extensions.findTabById(id.string)) orelse continue;
                        break :blk located.pane.group.id;
                    },
                    .groups => if (id == .integer) std.math.cast(u32, id.integer) orelse continue else continue,
                };
                const batch = blk: {
                    for (self.batches.items) |*batch| if (batch.group_id == group_id) break :blk batch;
                    try self.batches.append(a, .{ .group_id = group_id });
                    break :blk &self.batches.items[self.batches.items.len - 1];
                };
                if (kind == .tabs) {
                    for (batch.tabs.items) |existing| {
                        if (std.mem.eql(u8, existing, id.string)) break;
                    } else try batch.tabs.append(a, try a.dupe(u8, id.string));
                }
            }
            try extensions.pending_tab_closes.append(allocator, self);
            return .{ .deferred = .{ .context = self, .start = start } };
        }

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, request_id: u32) void {
            const self: *TabCloseRequest = @ptrCast(@alignCast(context));
            self.channel = channel;
            self.request_id = request_id;
            self.advance();
        }

        fn restoreFocus(self: *TabCloseRequest, extensions: *Extensions) void {
            if (!self.preserve_focus) return;
            const part = extensions.editor_service.part;
            if (part.service.getGroup(self.original_group)) |group| part.service.activateGroup(group);
        }

        fn advance(self: *TabCloseRequest) void {
            const extensions = self.extensions orelse return self.finish();
            const opening = extensions.editor_service.opening orelse {
                self.all_closed = false;
                return self.finish();
            };
            const part = extensions.editor_service.part;
            const group_actions = opening.group_actions;
            while (self.next < self.batches.items.len) {
                const batch = self.batches.items[self.next];
                self.next += 1;
                const group = part.service.getGroup(batch.group_id) orelse continue;
                const pane = part.viewForGroup(group) orelse continue;
                var tabs: std.ArrayList(*Tab) = .empty;
                const a = self.arena.allocator();
                switch (self.kind) {
                    .groups => tabs.appendSlice(a, pane.tabs.items) catch {
                        self.all_closed = false;
                        continue;
                    },
                    .tabs => for (batch.tabs.items) |id| {
                        const located = extensions.findTabById(id) catch {
                            self.all_closed = false;
                            continue;
                        } orelse continue;
                        if (located.pane == pane) tabs.append(a, located.tab) catch {
                            self.all_closed = false;
                            continue;
                        };
                    },
                }
                pane.closeEditorsWithOptions(tabs.items, group_actions.dialog_service.*, group_actions.close_host, .{
                    .preserve_focus = self.preserve_focus,
                    .completion = .{ .context = self, .complete = groupClosed },
                }) catch {
                    self.all_closed = false;
                    continue;
                };
                // Synchronous clean closes may already have finished and
                // destroyed this request. Dirty closes resume in groupClosed.
                return;
            }
            self.finish();
        }

        fn groupClosed(context: *anyopaque, success: bool) void {
            const self: *TabCloseRequest = @ptrCast(@alignCast(context));
            self.all_closed = self.all_closed and success;
            const extensions = self.extensions orelse return self.finish();
            if (self.kind == .groups and success) {
                const group_id = self.batches.items[self.next - 1].group_id;
                const part = extensions.editor_service.part;
                if (part.service.getGroup(group_id)) |group| {
                    if (part.viewForGroup(group)) |pane| {
                        if (group.model.count() == 0) {
                            if (extensions.editor_service.opening) |opening| part.collapseGroup(pane, opening.group_actions.transfer);
                        }
                    }
                }
            }
            self.restoreFocus(extensions);
            extensions.requestRender();
            self.advance();
        }

        fn finish(self: *TabCloseRequest) void {
            if (self.extensions) |extensions| {
                self.restoreFocus(extensions);
                if (std.mem.indexOfScalar(*TabCloseRequest, extensions.pending_tab_closes.items, self)) |index| _ = extensions.pending_tab_closes.swapRemove(index);
            }
            if (self.channel) |channel| channel.sendReply(self.request_id, .{ .json = .{ .bool = self.all_closed } });
            self.arena.deinit();
            self.allocator.destroy(self);
        }
    };

    fn documentsSynchronizeHost(context: *anyopaque, resolved: @import("../../../editor/common/services/resolverService.zig").IResolvedTextEditorModel) !void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const document: *EditorDocument = @ptrCast(@alignCast(resolved.context));
        try self.models.addTrackedDocument(document);
    }

    fn documentsCreateHost(context: *anyopaque, options: std.json.Value, arena: Allocator) anyerror!std.json.Value {
        _ = options;
        _ = context;
        return manager.fileUri(arena, "/tmp/untitled");
    }

    fn synchronizeSaveModel(context: *anyopaque, model: *TextModel) !bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.syncDocumentModels();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const key = try std_uri.resourceKey(arena.allocator(), model.uri());
        return self.models.modelForResource(key) == model;
    }

    const DocumentSaveRequest = struct {
        owner: *Extensions,
        document: *EditorDocument,
        channel: ?*rpc.RpcProtocol = null,
        id: u32 = 0,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *DocumentSaveRequest = @ptrCast(@alignCast(context));
            self.channel = channel;
            self.id = id;
            self.document.requestSave(self.owner.services.window, .{ .context = self, .complete = complete }) catch |err| complete(self, err);
        }

        fn complete(context: *anyopaque, result: anyerror!bool) void {
            const self: *DocumentSaveRequest = @ptrCast(@alignCast(context));
            const owner = self.owner;
            if (self.channel) |channel| channel.sendReply(self.id, .{ .json = .{ .bool = result catch false } });
            if (std.mem.indexOfScalar(*DocumentSaveRequest, owner.pending_document_saves.items, self)) |index| _ = owner.pending_document_saves.swapRemove(index);
            const document = self.document;
            owner.allocator.destroy(self);
            document.release();
            owner.requestRender();
        }
    };

    fn documentsSaveHost(context: *anyopaque, uri: std.json.Value) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const components = try std_uri.componentsFromJson(uri, arena);
        const key = try std_uri.resourceKeyFromComponents(arena, components);
        const editor = self.models.writableEditorForResource(key) orelse return .{ .json = .{ .bool = false } };
        const request = try self.allocator.create(DocumentSaveRequest);
        errdefer self.allocator.destroy(request);
        editor.document.retain();
        errdefer editor.document.release();
        request.* = .{ .owner = self, .document = editor.document };
        try self.pending_document_saves.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = DocumentSaveRequest.start } };
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
            self.requestRender();
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
        self.requestRender();
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
        self.requestRender();
    }

    fn configurationDataHost(context: *anyopaque, arena: Allocator) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.services.configuration_data(self.services.common.context, arena);
    }

    fn configurationNotifyHost(context: *anyopaque, arena: Allocator, data: std.json.Value, event: configuration.Change) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        var change: std.json.ObjectMap = .empty;
        var keys = std.json.Array.init(arena);
        for (event.keys) |key| try keys.append(.{ .string = key });
        try change.put(arena, "keys", .{ .array = keys });
        var overrides = std.json.Array.init(arena);
        for (event.overrides) |entry| {
            var pair = std.json.Array.init(arena);
            var changed_keys = std.json.Array.init(arena);
            for (entry.keys) |key| try changed_keys.append(.{ .string = key });
            try pair.append(.{ .string = entry.identifier });
            try pair.append(.{ .array = changed_keys });
            try overrides.append(.{ .array = pair });
        }
        try change.put(arena, "overrides", .{ .array = overrides });
        var args = [_]rpc.Arg{
            .{ .json = data },
            .{ .json = .{ .object = change } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostConfiguration), "$acceptConfigurationChanged", &args, null, manager.noop_callback) catch {};
    }

    fn boot(self: *Extensions, runtime_dir: []const u8) !void {
        try self.host.expectControl(2, manager.startup_timeout_ms);
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", arena);
        const workspace = try @import("mainThreadWorkspace.zig").workspaceData(arena, self.io, self.services.workspace);
        const init_data = try manager.buildInitData(arena, .{
            .host_script = "",
            .extensions = self.extension_ptrs,
            .workspace_data = workspace,
            .workspace_name = "workspace",
            .user_data_dir = self.user_data_dir,
            .app_root = try std.fs.path.resolve(arena, &.{ cwd, runtime_dir }),
            .parent_pid = @intCast(manager.currentProcessId()),
        });
        try self.host.sendInitData(init_data);
        try self.host.expectControl(1, manager.startup_timeout_ms);

        const file_resource: std.Uri = .{ .scheme = "file", .path = .{ .raw = "/dummy" } };
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostFileSystemInfo), "$acceptProviderInfos", &.{
            .{ .json = try std_uri.jsonComponents(arena, file_resource) },
            .{ .json = .{ .integer = self.services.file_service.getCapabilities(file_resource) } },
        });

        const workspace_args = [_]rpc.Arg{ .{ .json = workspace }, .{ .json = .{ .bool = true } } };
        try self.callAndWait(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostWorkspace),
            "$initializeWorkspace",
            &workspace_args,
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

        if (self.configuration_actor) |*actor| try actor.bindConfiguration(self.services.configuration, self.services.workspace);

        // MainThreadDocumentsAndEditors publishes existing model state before
        // extension activation. Otherwise provider registration during startup
        // can reenter outline/code-action consumers before the host knows the
        // document URI. The active-editor delta and language activation follow
        // the host-start barrier below.
        try self.syncDocumentModels();

        var delta: std.json.ObjectMap = .empty;
        try delta.put(arena, "versionId", .{ .integer = 1 });
        try delta.put(arena, "toRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "toAdd", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "addActivationEvents", .{ .object = .empty });
        try delta.put(arena, "myToRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "myToAdd", .{ .array = std.json.Array.init(arena) });
        var start_args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
        // The upstream start promise resolves only when *all* eager
        // activation completes. It is not a workbench startup barrier;
        // the host itself schedules onStartupFinished after eager activation
        // or its 10-second grace period. Providers can register while other
        // extensions are still activating, so keep the window responsive.
        self.eager_start_request = try self.host.call(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService),
            "$startExtensionHost",
            &start_args,
            null,
            .{ .context = self, .callback = onEagerStartComplete },
        );

        try self.syncActiveDocument();
        try self.syncTabs();
    }

    fn onEagerStartComplete(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.eager_start_request = null;
        if (reply == .err) std.log.warn("extension host eager activation rejected", .{});
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
        const request = try self.host.call(identifier, method, args, null, .{ .context = &wait, .callback = WaitFlag.callback });
        errdefer if (!wait.done) self.host.rpc.cancel(request);
        const deadline = time_compat.milliTimestamp() + timeout_ms;
        // During bootstrap the native event loop has not started yet. Pump a
        // host frame batch, then dispatch one window completion. An activation
        // may asynchronously resolve a document before acknowledging start;
        // waiting on only the transport would deadlock that nested RPC.
        // Never recursively pump inside a frame callback.
        while (!wait.done) {
            _ = self.host.pump();
            const now = time_compat.milliTimestamp();
            _ = self.services.window.dispatch(now);
            if (self.host.hasEof()) return error.HostExited;
            if (now > deadline) return error.HostTimeout;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (wait.failed) return rejected;
    }

    // Upstream MainThreadDocumentAndEditorStateComputer and MainThreadEditorTabs
    // subscribe to editor/model/group lifecycle events. A terminal group model
    // changes before its pane is mounted, so use the mounted EditorService pane
    // for the document mirror and coalesce group-tab changes on the window.
    fn registerEditorListeners(self: *Extensions) !void {
        errdefer self.unregisterEditorListeners();
        const model_service = self.services.model_service;
        self.model_added_listener = try model_service.on_model_added.listen(self, onModelAdded);
        self.model_removed_listener = try model_service.on_model_removed.listen(self, onModelRemoved);
        const existing = try model_service.getModels(self.allocator);
        defer self.allocator.free(existing);
        for (existing) |model| try onModelAdded(model, self);
        self.active_editor_listener = try self.editor_service.onDidActiveEditorChange().listen(self, onActiveEditorChanged);
        self.visible_editors_listener = try self.editor_service.onDidVisibleEditorsChange().listen(self, onVisibleEditorsChanged);
        const part = self.editor_service.part;
        self.group_model_listener = try part.service.on_did_change_group_model.listen(self, onGroupModelChanged);
        self.input_resources_listener = try part.service.on_did_change_input_resources.listen(self, onInputResourcesChanged);
        self.add_group_listener = try part.on_did_add_group.listen(self, onGroupChanged);
        self.remove_group_listener = try part.on_did_remove_group.listen(self, onGroupChanged);
        self.move_group_listener = try part.on_did_move_group.listen(self, onGroupChanged);
    }
    fn onModelAdded(model: @import("../../../editor/common/services/resolverService.zig").IResolvedTextEditorModel, self: *Extensions) !void {
        const document: *EditorDocument = @ptrCast(@alignCast(model.context));
        try self.models.addTrackedDocument(document);
    }

    fn onModelRemoved(model: @import("../../../editor/common/services/resolverService.zig").IResolvedTextEditorModel, self: *Extensions) !void {
        self.models.removeTrackedModel(model.textEditorModel);
    }

    fn unregisterEditorListeners(self: *Extensions) void {
        if (self.model_added_listener) |id| self.services.model_service.on_model_added.unlisten(id);
        if (self.model_removed_listener) |id| self.services.model_service.on_model_removed.unlisten(id);
        self.model_added_listener = null;
        self.model_removed_listener = null;
        if (self.active_editor_listener) |id| self.editor_service.onDidActiveEditorChange().unlisten(id);
        if (self.visible_editors_listener) |id| self.editor_service.onDidVisibleEditorsChange().unlisten(id);
        const part = self.editor_service.part;
        if (self.group_model_listener) |id| part.service.on_did_change_group_model.unlisten(id);
        if (self.input_resources_listener) |id| part.service.on_did_change_input_resources.unlisten(id);
        if (self.add_group_listener) |id| part.on_did_add_group.unlisten(id);
        if (self.remove_group_listener) |id| part.on_did_remove_group.unlisten(id);
        if (self.move_group_listener) |id| part.on_did_move_group.unlisten(id);
        self.active_editor_listener = null;
        self.visible_editors_listener = null;
        self.group_model_listener = null;
        self.input_resources_listener = null;
        self.add_group_listener = null;
        self.remove_group_listener = null;
        self.move_group_listener = null;
        self.tabs_task.schedule(null);
        self.models_task.schedule(null);
        self.selection_task.schedule(null);
        self.visible_ranges_task.schedule(null);
    }
    fn onActiveEditorChanged(_: ?*EditorInput, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        if (self.editor_tabs_actor) |*actor| actor.activateGroup(self.editor_service.part.service.activeGroup().id) catch self.tabs_task.post();
    }
    fn onVisibleEditorsChanged(_: void, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        self.models_task.post();
    }
    fn onGroupChanged(_: *GroupPane, self: *Extensions) !void {
        self.syncActiveDocument() catch {};
        self.models_task.post();
        self.tabs_task.post();
    }
    fn onGroupModelChanged(change: EditorsChangeEvent, self: *Extensions) !void {
        switch (change.event) {
            .EDITOR_OPEN, .EDITOR_CLOSE => self.models_task.post(),
            else => {},
        }
        // The event carries an owned-model input even before its native pane
        // mounts; send the actual tab operation now instead of rescanning the
        // mounted tab list at the next frame.
        if (self.tabs_task.at != null) return;
        self.patchTabModel(change) catch self.tabs_task.post();
    }

    fn patchTabModel(self: *Extensions, change: EditorsChangeEvent) !void {
        const actor = if (self.editor_tabs_actor) |*actor| actor else return;
        const group = self.editor_service.part.service.getGroup(change.group_id) orelse return error.UnknownTabGroup;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        switch (change.event) {
            .EDITOR_OPEN => |event| try actor.open(group.id, event.editor_index, try tabSpec(a, group, event.editor)),
            .EDITOR_CLOSE => |event| try actor.close(group.id, event.editor_index),
            .EDITOR_MOVE => |event| try actor.move(group.id, event.old_editor_index, event.editor_index, try tabId(a, group.id, event.editor)),
            .EDITOR_ACTIVE, .EDITOR_DIRTY, .EDITOR_LABEL, .EDITOR_PIN, .EDITOR_STICKY => |event| try actor.update(group.id, try tabSpec(a, group, event.editor)),
            .GROUP_ACTIVE => if (group == self.editor_service.part.service.activeGroup()) try actor.activateGroup(group.id),
            else => {},
        }
    }

    fn onInputResourcesChanged(input: *EditorInput, self: *Extensions) !void {
        if (self.tabs_task.at != null) return;
        const actor = if (self.editor_tabs_actor) |*actor| actor else return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        for (self.editor_service.part.group_views.items) |pane| {
            const index = pane.group.model.indexOf(.{ .input = input }) orelse continue;
            if (pane.group.model.getEditorByIndex(index) != input) continue;
            actor.update(pane.group.id, try tabSpec(scratch.allocator(), pane.group, input)) catch self.tabs_task.post();
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
    fn onActiveEditorWillChangeModel(_: @import("../../../editor/common/editorCommon.zig").IModelChangedEvent, self: *Extensions) !void {
        // Dispose subscriptions to the outgoing model before the reusable
        // code editor's ViewModel and model reference are detached.
        self.removeActiveDocument() catch {};
        self.models_task.post();
    }
    fn onActiveLanguageChanged(event: ModelLanguageChangedEvent, self: *Extensions) !void {
        const active = if (self.active) |*value| value else return;
        const language = try self.allocator.dupe(u8, event.newLanguage);
        self.allocator.free(active.language_id);
        active.language_id = language;
        self.activation_tracker.activateLanguage(self.host, event.newLanguage);
    }

    fn requestRender(self: *Extensions) void {
        self.needs_render = true;
        self.rpc_task.post();
    }

    fn dispatchRpc(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.pump();
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
        self.syncActiveDocument() catch {};
        self.syncDocumentModels() catch {};
        return true;
    }

    fn activeCodeEditorForTab(tab: *Tab) ?*Editor {
        if (tab.isImage() or tab.terminalInstance() != null) return null;
        const editor = if (tab.diff) |diff| diff.widget.focusedEditor() else if (tab.multi_diff) |multi| blk: {
            const control = multi.widget.activeControl() orelse return null;
            break :blk control.focusedEditor();
        } else tab.editor;
        return if (editor.hasModel() and editor.model.shouldSynchronizeModel()) editor else null;
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
        const editor_model_listener = try editor.on_will_change_model.listen(self, onActiveEditorWillChangeModel);
        errdefer editor.on_will_change_model.unlisten(editor_model_listener);
        const language_listener = try editor.model.listenDidChangeLanguage(self, onActiveLanguageChanged);
        errdefer editor.model.removeDidChangeLanguageListener(language_listener);
        try notifyModelMirror(self, .documents_and_editors, "$acceptDocumentsAndEditorsDelta", &.{.{ .json = delta }});
        editor.addViewEventHandler(&self.active_selection_handler);
        self.active = .{ .tab = tab, .dispose_listener = dispose_listener, .editor_dispose_listener = editor_dispose_listener, .editor_model_listener = editor_model_listener, .language_listener = language_listener, .editor = editor, .uri = uri, .language_id = language };
        self.setScrollListener(editor);
        self.captureSelections(editor);
        self.activation_tracker.activateLanguage(self.host, editor.languageId());
        self.requestRender();
    }

    fn textInputUri(input: *EditorInput) ?std.Uri {
        if (std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) {
            const file: *FileEditorInput = @ptrCast(@alignCast(input.impl orelse return null));
            return file.editor.model.uri();
        }
        if (std.mem.eql(u8, input.type_id, TextResourceEditorInput.ID)) {
            const resource: *TextResourceEditorInput = @ptrCast(@alignCast(input.impl orelse return null));
            return resource.resolve().model.uri();
        }
        return null;
    }

    /// Mirrors upstream EditorResourceAccessor.getCanonicalUri with BOTH for
    /// composite diffs. The group ID distinguishes identical inputs in
    /// different groups, and virtual resource queries are never dropped.
    fn tabId(arena: Allocator, group_id: u32, input: *EditorInput) ![]const u8 {
        const resource = if (diff_input_mod.is(input)) |diff| try std.fmt.allocPrint(arena, "{s}-{s}", .{
            if (textInputUri(diff.modified)) |uri| try std_uri.encodedResource(arena, uri) else "undefined",
            if (textInputUri(diff.original)) |uri| try std_uri.encodedResource(arena, uri) else "undefined",
        }) else if (textInputUri(input)) |uri| try std_uri.encodedResource(arena, uri) else input.resource orelse "undefined-undefined";
        return std.fmt.allocPrint(arena, "{d}~{s}-{s}-{s} ", .{ group_id, input.editor_id orelse "undefined", input.type_id, resource });
    }

    fn tabInput(arena: Allocator, input: *EditorInput) !editor_tabs.TabInputSpec {
        if (diff_input_mod.is(input)) |diff| return .{ .text_diff = .{
            .original = textInputUri(diff.original) orelse return .unknown,
            .modified = textInputUri(diff.modified) orelse return .unknown,
        } };
        if (MultiDiffEditorInput.is(input)) |multi| {
            var pairs: std.ArrayList(editor_tabs.TextDiffSpec) = .empty;
            // Input declarations, not resolved/visible/sorted view models.
            for (multi.resources() orelse &.{}) |resource| {
                const original = resource.originalUri orelse continue;
                const modified = resource.modifiedUri orelse continue;
                try pairs.append(arena, .{ .original = original, .modified = modified });
            }
            return .{ .multi_diff = pairs.items };
        }
        if (textInputUri(input)) |uri| return .{ .text = uri };
        if (std.mem.eql(u8, input.type_id, @import("../../contrib/terminal/browser/terminalEditorInput.zig").TerminalEditorInput.ID)) return .terminal;
        if (std.mem.eql(u8, input.type_id, @import("../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput.ID)) return .{ .custom = .{ .uri = .{ .scheme = "file", .path = .{ .raw = input.resource orelse return .unknown } }, .view_type = input.editor_id orelse "" } };
        if (std.mem.eql(u8, input.type_id, "workbench.editors.webviewInput")) return .{ .webview = input.editor_id orelse "" };
        return .unknown;
    }

    fn tabSpec(arena: Allocator, group: *EditorGroup, input: *EditorInput) !editor_tabs.TabSpec {
        return .{
            .id = try tabId(arena, group.id, input),
            .label = input.getName(),
            .editor_id = input.editor_id,
            .input = try tabInput(arena, input),
            .is_active = group.model.activeEditor() == input,
            .is_dirty = input.isDirty(),
            .is_pinned = group.model.isSticky(.{ .editor = input }),
            .is_preview = !group.model.isPinned(.{ .editor = input }),
        };
    }

    fn syncTabs(self: *Extensions) !void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const part = self.editor_service.part;
        const panes = try part.orderedViews(arena);
        var specs: std.ArrayList(editor_tabs.GroupSpec) = .empty;
        for (panes, 0..) |pane, column| {
            const inputs = try pane.group.model.getEditors(arena, .SEQUENTIAL, false);
            var tabs: std.ArrayList(editor_tabs.TabSpec) = .empty;
            for (inputs) |input| try tabs.append(arena, try tabSpec(arena, pane.group, input));
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
        active.editor.on_will_change_model.unlisten(active.editor_model_listener);
        active.editor.removeViewEventHandler(&self.active_selection_handler);
        active.editor.model.removeDidChangeLanguageListener(active.language_listener);
        self.setScrollListener(null);

        defer self.allocator.free(active.uri);
        defer self.allocator.free(active.language_id);

        self.requestRender();
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

    fn onWorkspaceChanged(_: @import("../../services/workspaces/common/workspaceContextService.zig").WorkspaceFoldersChangeEvent, self: *Extensions) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const data = try @import("mainThreadWorkspace.zig").workspaceData(arena.allocator(), self.io, self.services.workspace);
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostWorkspace), "$acceptWorkspaceData", &.{.{ .json = data }});
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
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
            self.requestRender();
            return self.message_service.showMessage(args);
        }
        if (std.mem.eql(u8, method, "$checkExists")) {
            const self: *Extensions = @ptrCast(@alignCast(context));
            const exists = try @import("mainThreadWorkspace.zig").checkExists(self.io, self.allocator, arena, args, token);
            return .{ .json = .{ .bool = exists } };
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
        self.requestRender();
    }

    /// Mirrors the selection/scroll result of a command. Content changes are
    /// handled once, by the model's document mirror.
    fn syncAfterEditorCommand(self: *Extensions, _: Allocator, _: *Editor) !void {
        try self.syncSelection();
        self.sendVisibleRanges() catch {};
        self.requestRender();
    }

    fn applyCommandEdit(self: *Extensions, arena: Allocator, _: *Editor) !void {
        try self.sendSelection(arena, .command);
        self.requestRender();
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
        self.requestRender();
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
        self.requestRender();
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
    _ = try self.host.requestAwait(self.services.window, arena, proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = event } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
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
        self.requestRender();
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
            self.requestRender();
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
        self.requestRender();
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
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.closeActiveEditor")) {
        _ = self.services.close_active(self.services.common.context) catch false;
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "moveActiveEditor")) {
        if (args.len > 0 and args[0] == .object) {
            const object = args[0].object;
            const to = objectString(object, "to") orelse "";
            const by = objectString(object, "by") orelse "tab";
            const value = objectUsize(object, "value") orelse 1;
            self.services.move_active_editor(self.services.common.context, to, by, value) catch {};
            self.requestRender();
        }
        return null;
    }
    if (std.mem.startsWith(u8, command, "workbench.action.openEditorAtIndex")) {
        if (args.len > 0 and args[0] == .integer and args[0].integer >= 0) {
            self.services.activate_index(self.services.common.context, @intCast(args[0].integer)) catch {};
            self.requestRender();
        } else if (std.mem.eql(u8, command, "workbench.action.openEditorAtIndex1")) {
            self.services.activate_index(self.services.common.context, 0) catch {};
            self.requestRender();
        }
        return null;
    }
    if (runLspCommand(self.services, command)) {
        // Publish the new document/selection before the command reply so an
        // extension that reads `activeTextEditor` immediately sees the target.
        self.syncActiveDocument() catch {};
        self.syncSelection() catch {};
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.files.save")) {
        if (self.active) |active| active.editor.requestSave(null) catch {};
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.nextEditorInGroup")) {
        self.services.common.switch_tab(self.services.common.context, 1) catch {};
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.previousEditorInGroup")) {
        self.services.common.switch_tab(self.services.common.context, -1) catch {};
        self.requestRender();
        return null;
    }
    if (std.mem.eql(u8, command, "vscode.open")) {
        if (args.len > 0 and args[0] == .object) {
            if (args[0].object.get("path")) |path| {
                if (path == .string) {
                    self.services.common.open_path(self.services.common.context, path.string) catch {};
                    self.requestRender();
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
        self.requestRender();
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

        // The Node host serializes VS Code URIs (including lower-cased,
        // percent-encoded drive letters). Compare the decoded file identity.
        fn expectFileResource(arena: Allocator, expected: std.Uri, serialized: []const u8) !void {
            const actual = try std.Uri.parse(serialized);
            const expected_key = try std_uri.resourceKey(arena, expected);
            const actual_key = try std_uri.resourceKey(arena, actual);
            const prefix = "file:///";
            if (@import("builtin").os.tag == .windows and
                std.mem.startsWith(u8, expected_key, prefix) and std.mem.startsWith(u8, actual_key, prefix) and
                expected_key.len > prefix.len + 1 and actual_key.len > prefix.len + 1 and
                expected_key[prefix.len + 1] == ':' and actual_key[prefix.len + 1] == ':')
            {
                try std.testing.expectEqual(std.ascii.toLower(expected_key[prefix.len]), std.ascii.toLower(actual_key[prefix.len]));
                try std.testing.expectEqualStrings(expected_key[prefix.len + 1 ..], actual_key[prefix.len + 1 ..]);
            } else {
                try std.testing.expectEqualStrings(expected_key, actual_key);
            }
        }

        fn waitNavigation(workbench: *terminal_window_type) !void {
            const deadline = time_compat.milliTimestamp() + 5_000;
            while (workbench.symbol_navigation.pending_navigation != null and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(workbench.symbol_navigation.pending_navigation == null);
        }

        fn waitReferences(workbench: *terminal_window_type) !void {
            const deadline = time_compat.milliTimestamp() + 5_000;
            while (workbench.references_view.pending_search != null and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(workbench.references_view.pending_search == null);
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
            const features = workbench.language_features.?;
            const model = workbench.activeTab().?.editor.model;
            // A mirrored active editor is not an activation barrier. These
            // fixture assertions require *all* eager provider registrations.
            while (extension_host.eager_start_request != null and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(extension_host.eager_start_request == null);
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
            try std.testing.expect(hover.?.id != null and hover.?.can_increase_verbosity.?);
            const verbosity_context: @import("../../../editor/common/languages.zig").HoverContext = .{ .verbosity_request = .{ .verbosity_delta = 2, .previous_hover = hover.? } };
            const verbose = (try hover_providers[0].provide_hover(hover_providers[0].context, model, Position.init(1, 1), .None, &verbosity_context)).?;
            try std.testing.expectEqualStrings("fixture hover verbosity 2: fixture hover", verbose.contents[0].value);
            try std.testing.expect(verbose.can_decrease_verbosity.?);

            // Workspace symbols use a debounced # provider and resolve the
            // selected URI-only symbol before opening its UTF-16 location.
            try workbench.commands.execute("workbench.action.showAllSymbols");
            const workspace_picker = workbench.quick_access.controller.pickerRef();
            try workspace_picker.setValue("#unused");
            try workspace_picker.setValue("#WorkspaceFixture");
            const symbols_deadline = time_compat.milliTimestamp() + 5000;
            while (time_compat.milliTimestamp() < symbols_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                if (workspace_picker.items.items.len == 1 and std.mem.eql(u8, workspace_picker.items.items[0].item.label, "WorkspaceFixture")) break;
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqual(1, workspace_picker.items.items.len);
            try std.testing.expectEqualStrings("WorkspaceFixture", workspace_picker.items.items[0].item.label);
            workspace_picker.accept();
            const workspace_resolve_deadline = time_compat.milliTimestamp() + 5000;
            while (workbench.quick_access.isOpen() and time_compat.milliTimestamp() < workspace_resolve_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(!workbench.quick_access.isOpen());
            try std.testing.expectEqual(Position.init(2, 3), workbench.activeTab().?.editor.modelCursorPosition());

            // The async selection provider must be cancelled when the caret
            // moves, then its nested ranges participate in expand/shrink.
            const selection_editor = workbench.activeTab().?.editor;
            try selection_editor.setCursorPosition(Position.init(2, 4));
            try selection_editor.growSelection(true);
            try std.testing.expect(selection_editor.smart_select.pending != null);
            try selection_editor.setCursorPosition(Position.init(1, 1));
            try std.testing.expect(selection_editor.smart_select.pending == null);
            try selection_editor.setCursorPosition(Position.init(2, 4));
            var expanded_line = false;
            for (0..4) |_| {
                try selection_editor.growSelection(true);
                const selection_deadline = time_compat.milliTimestamp() + 5000;
                while (selection_editor.smart_select.pending != null and time_compat.milliTimestamp() < selection_deadline) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    time_compat.sleepMillis(5);
                }
                try std.testing.expect(selection_editor.smart_select.pending == null);
                const selections = try selection_editor.getModelSelections();
                defer allocator.free(selections);
                if (selections[0].startLineNumber == 2 and selections[0].startColumn == 1 and selections[0].endColumn == model.getLineMaxColumn(2)) {
                    expanded_line = true;
                    break;
                }
            }
            try std.testing.expect(expanded_line);
            try selection_editor.growSelection(false);
            const shrunk = try selection_editor.getModelSelections();
            defer allocator.free(shrunk);
            try std.testing.expect(shrunk[0].startColumn > 1 or shrunk[0].endColumn < model.getLineMaxColumn(2));

            // Syntax ranges replace the indent fallback, drive the gutter and
            // refresh when the provider's change event arrives.
            const folding_deadline = time_compat.milliTimestamp() + 5000;
            while (selection_editor.folding.regionStartingAt(2) == null and time_compat.milliTimestamp() < folding_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(selection_editor.folding.regionStartingAt(2) != null);
            try selection_editor.setCursorPosition(Position.init(2, 1));
            try selection_editor.foldAtCursor();
            try std.testing.expect(!selection_editor.isModelLineVisible(3));
            try selection_editor.unfoldAtCursor();
            try std.testing.expect(selection_editor.isModelLineVisible(3));
            try extension_host.host.executeContributedCommand("fixture.changeFoldingRanges", &.{});
            const refresh_deadline = time_compat.milliTimestamp() + 5000;
            while (selection_editor.folding.regionStartingAt(2) != null and time_compat.milliTimestamp() < refresh_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(selection_editor.folding.regionStartingAt(2) == null);
            try std.testing.expect(selection_editor.folding.regionStartingAt(1) != null);

            const ParameterHintsController = @import("../../../editor/contrib/parameterHints/browser/parameterHints.zig").ParameterHintsController;
            try std.testing.expect(selection_editor.parameter_hints_available);
            try workbench.commands.execute("editor.action.triggerParameterHints");
            const hints = selection_editor.getInstantiatedContribution(ParameterHintsController).?;
            const hints_deadline = time_compat.milliTimestamp() + 5000;
            while (hints.model.hints() == null and time_compat.milliTimestamp() < hints_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const help = hints.model.hints() orelse return error.SignatureHelpUnavailable;
            try std.testing.expectEqual(@as(usize, 2), help.signatures.len);
            try std.testing.expectEqualStrings("f(é, b)", help.signatures[0].label);
            try std.testing.expectEqualSlices(usize, &.{ 2, 4 }, &help.signatures[0].parameters[0].label.offsets);
            try std.testing.expect(selection_editor.parameter_hints_visible and hints.widget_mounted);
            try workbench.commands.execute("showNextParameterHint");
            try std.testing.expectEqual(@as(usize, 1), hints.model.hints().?.active_signature);
            try workbench.commands.execute("closeParameterHints");
            try std.testing.expect(!selection_editor.parameter_hints_visible and !hints.widget_mounted);

            const RenameSkeleton = @import("../../../editor/contrib/rename/browser/rename.zig").RenameSkeleton;
            const rename_languages = @import("../../../editor/common/languages.zig");
            const RenameProbe = struct {
                location: ?rename_languages.RenameLocation = null,
                edit: ?rename_languages.RenameEdit = null,
                failure: ?anyerror = null,
                fn prepared(context: *anyopaque, result: anyerror!?rename_languages.RenameLocation) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.location = value else |err| self.failure = err;
                }
                fn edited(context: *anyopaque, result: anyerror!?rename_languages.RenameEdit) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.edit = value else |err| self.failure = err;
                }
            };
            var rename_probe: RenameProbe = .{};
            var rename = try RenameSkeleton.init(allocator, model, Position.init(2, 1), &features.rename_provider);
            defer rename.deinit();
            try std.testing.expect(rename.hasProvider());
            rename.resolveRenameLocation(.{ .context = &rename_probe, .complete = RenameProbe.prepared });
            const rename_deadline = time_compat.milliTimestamp() + 5000;
            while (rename_probe.location == null and rename_probe.failure == null and time_compat.milliTimestamp() < rename_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("fixture", (rename_probe.location orelse return error.RenamePrepareUnavailable).text);
            rename.provideRenameEdits("newName", .{ .context = &rename_probe, .complete = RenameProbe.edited });
            const edits_deadline = time_compat.milliTimestamp() + 5000;
            while (rename_probe.edit == null and rename_probe.failure == null and time_compat.milliTimestamp() < edits_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const rename_edit = (rename_probe.edit orelse return error.RenameEditsUnavailable).edit;
            try std.testing.expectEqual(@as(usize, 1), rename_edit.edits.len);
            try std.testing.expectEqualStrings("newName", rename_edit.edits[0].text.text);
            try std.testing.expectEqual(@as(@FieldType(rename_languages.WorkspaceTextEdit, "column_encoding"), .utf16), rename_edit.edits[0].text.column_encoding);

            const RenameController = @import("../../../editor/contrib/rename/browser/rename.zig").RenameController;
            try selection_editor.setCursorPosition(Position.init(2, 1));
            try std.testing.expect(selection_editor.rename_available);
            try workbench.commands.execute("editor.action.rename");
            const rename_controller = selection_editor.getInstantiatedContribution(RenameController).?;
            const input_deadline = time_compat.milliTimestamp() + 5000;
            while (!rename_controller.widget.visible and time_compat.milliTimestamp() < input_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(rename_controller.widget.visible and selection_editor.rename_input_visible);
            try std.testing.expectEqualStrings("fixture", rename_controller.widget.input.getValue());
            try rename_controller.widget.input.setValue("previewed");
            try workbench.commands.execute("acceptRenameInputWithPreview");
            const preview_deadline = time_compat.milliTimestamp() + 5000;
            while (!workbench.bulk_edit_preview.?.hasInput() and time_compat.milliTimestamp() < preview_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(workbench.bulk_edit_preview.?.hasInput());
            try workbench.commands.execute("refactorPreview.discard");
            try std.testing.expect(!workbench.bulk_edit_preview.?.hasInput());
            try std.testing.expect(!selection_editor.rename_input_visible);

            const SemanticResult = @import("../../../editor/common/languages.zig").SemanticTokensResult;
            const SemanticProbe = struct {
                result: ?SemanticResult = null,
                failure: ?anyerror = null,
                changed: bool = false,
                fn ready(context: *anyopaque, value: anyerror!?SemanticResult) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (value) |response| self.result = response else |err| self.failure = err;
                }
                fn change(_: void, self: *@This()) !void {
                    self.changed = true;
                }
            };
            var semantic_probe: SemanticProbe = .{};
            var semantic_arena = std.heap.ArenaAllocator.init(allocator);
            defer semantic_arena.deinit();
            const semantic_a = semantic_arena.allocator();
            const semantic_providers = try features.document_semantic_tokens_provider.ordered(semantic_a, model, false);
            try std.testing.expectEqual(@as(usize, 1), semantic_providers.len);
            const semantic_provider = semantic_providers[0];
            try std.testing.expectEqualStrings("variable", semantic_provider.legend.token_types[0]);
            const semantic_listener = try semantic_provider.on_did_change.?.listen(&semantic_probe, SemanticProbe.change);
            defer semantic_provider.on_did_change.?.unlisten(semantic_listener);
            _ = try semantic_provider.request_document_semantic_tokens(semantic_provider.context, semantic_a, model, null, .{ .context = &semantic_probe, .complete = SemanticProbe.ready });
            const semantic_deadline = time_compat.milliTimestamp() + 5000;
            while (semantic_probe.result == null and semantic_probe.failure == null and time_compat.milliTimestamp() < semantic_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const full = semantic_probe.result orelse return error.SemanticTokensUnavailable;
            try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1, 0, 1 }, full.payload.full);
            semantic_probe.result = null;
            _ = try semantic_provider.request_document_semantic_tokens(semantic_provider.context, semantic_a, model, full.id, .{ .context = &semantic_probe, .complete = SemanticProbe.ready });
            const delta_deadline = time_compat.milliTimestamp() + 5000;
            while (semantic_probe.result == null and semantic_probe.failure == null and time_compat.milliTimestamp() < delta_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const delta = semantic_probe.result orelse return error.SemanticDeltaUnavailable;
            try std.testing.expectEqual(@as(u32, 2), delta.payload.delta[0].start);
            try std.testing.expectEqualSlices(u32, &.{2}, delta.payload.delta[0].data);
            semantic_provider.release_document_semantic_tokens(semantic_provider.context, delta.id);
            const range_providers = try features.document_range_semantic_tokens_provider.ordered(semantic_a, model, false);
            try std.testing.expectEqual(@as(usize, 1), range_providers.len);
            const range_provider = range_providers[0];
            semantic_probe.result = null;
            _ = try range_provider.request_document_range_semantic_tokens(range_provider.context, semantic_a, model, Range.init(1, 1, 3, 1), .{ .context = &semantic_probe, .complete = SemanticProbe.ready });
            const range_deadline = time_compat.milliTimestamp() + 5000;
            while (semantic_probe.result == null and semantic_probe.failure == null and time_compat.milliTimestamp() < range_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1, 0, 0 }, (semantic_probe.result orelse return error.SemanticRangeUnavailable).payload.full);
            try extension_host.host.executeContributedCommand("fixture.changeSemanticTokens", &.{});
            const event_deadline = time_compat.milliTimestamp() + 5000;
            while (!semantic_probe.changed and time_compat.milliTimestamp() < event_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(semantic_probe.changed);

            const inlay_languages = @import("../../../editor/common/languages.zig");
            const InlayProbe = struct {
                list: ?inlay_languages.InlayHintList = null,
                resolved: ?inlay_languages.InlayHint = null,
                failure: ?anyerror = null,
                changed: bool = false,
                fn ready(context: *anyopaque, value: anyerror!?inlay_languages.InlayHintList) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (value) |list| self.list = list else |err| self.failure = err;
                }
                fn resolve(context: *anyopaque, value: anyerror!?inlay_languages.InlayHint) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (value) |hint| self.resolved = hint else |err| self.failure = err;
                }
                fn change(_: void, self: *@This()) !void {
                    self.changed = true;
                }
            };
            var inlay_probe: InlayProbe = .{};
            var inlay_arena = std.heap.ArenaAllocator.init(allocator);
            defer inlay_arena.deinit();
            const inlay_a = inlay_arena.allocator();
            const inlay_providers = try features.inlay_hints_provider.ordered(inlay_a, model, false);
            try std.testing.expectEqual(@as(usize, 1), inlay_providers.len);
            const inlay_provider = inlay_providers[0];
            const inlay_listener = try inlay_provider.on_did_change.?.listen(&inlay_probe, InlayProbe.change);
            defer inlay_provider.on_did_change.?.unlisten(inlay_listener);
            _ = try inlay_provider.request_inlay_hints(inlay_provider.context, inlay_a, model, model.getFullModelRange(), .{ .context = &inlay_probe, .complete = InlayProbe.ready });
            const inlay_deadline = time_compat.milliTimestamp() + 5000;
            while (inlay_probe.list == null and inlay_probe.failure == null and time_compat.milliTimestamp() < inlay_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            var inlay_list = inlay_probe.list orelse return error.InlayHintsUnavailable;
            defer inlay_list.dispose();
            try std.testing.expectEqual(@as(usize, 1), inlay_list.hints.len);
            const inlay_hint = inlay_list.hints[0];
            try std.testing.expectEqualStrings("fixtureHint", inlay_hint.label[0].label);
            try std.testing.expect(inlay_hint.padding_left and inlay_hint.padding_right and inlay_hint.label[0].location != null and inlay_hint.label[0].command != null);
            _ = try inlay_provider.resolve_inlay_hint.?(inlay_provider.context, inlay_a, model, inlay_hint, .{ .context = &inlay_probe, .complete = InlayProbe.resolve });
            const inlay_resolve_deadline = time_compat.milliTimestamp() + 5000;
            while (inlay_probe.resolved == null and inlay_probe.failure == null and time_compat.milliTimestamp() < inlay_resolve_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const resolved_hint = inlay_probe.resolved orelse return error.InlayResolveUnavailable;
            try std.testing.expectEqualStrings("Resolved inlay tooltip", resolved_hint.tooltip.?);
            try std.testing.expectEqualStrings("resolved", resolved_hint.text_edits[0].text);
            try extension_host.host.executeContributedCommand("fixture.changeInlayHints", &.{});
            const inlay_event_deadline = time_compat.milliTimestamp() + 5000;
            while (!inlay_probe.changed and time_compat.milliTimestamp() < inlay_event_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(inlay_probe.changed);
            const InlayHintsController = @import("../../../editor/contrib/inlayHints/browser/inlayHintsController.zig").InlayHintsController;
            const inlay_controller = selection_editor.getInstantiatedContribution(InlayHintsController).?;
            const injected_deadline = time_compat.milliTimestamp() + 5000;
            while (inlay_controller.parts.len == 0 and time_compat.milliTimestamp() < injected_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(inlay_controller.parts.len > 0);
            const inlay_view_position = selection_editor.viewPositionOfModelPosition(Position.init(2, 1));
            const injected_line = try selection_editor.viewLineData(inlay_view_position.lineNumber);
            try std.testing.expect(std.mem.indexOf(u8, injected_line.content, "fixtureHint") != null);
            try std.testing.expect(std.mem.indexOf(u8, try model.borrowLineContent(2), "fixtureHint") == null);
            var hit_found = false;
            const hint_column = std.mem.indexOf(u8, injected_line.content, "fixtureHint").? + 2;
            if (try selection_editor.injectedTextAtViewPoint(inlay_view_position.lineNumber, hint_column)) |injection| {
                hit_found = injection.options.attachedData != null;
            }
            try std.testing.expect(hit_found);
            const hint_view = workbench.activeTab().?.view;
            const HoverController = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
            const hint_hover = selection_editor.getContribution(HoverController) orelse return error.HoverControllerMissing;
            const settled_deadline = time_compat.milliTimestamp() + 5000;
            while ((inlay_controller.pending != null or inlay_controller.timer.at != null) and time_compat.milliTimestamp() < settled_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            var mouse: @import("ui").MouseEvent = .{ .kind = .move };
            var hint_cell: ?struct { x: usize, y: usize } = null;
            outer: for (0..selection_editor.screen_height) |y| {
                for (selection_editor.gutterWidth()..selection_editor.screen_width) |x| {
                    mouse.x = x;
                    mouse.y = y;
                    const target = try hint_view.mouseTargetAt(x, y);
                    if (inlay_controller.partAt(.{ .target = target, .event = &mouse }) != null) {
                        hint_cell = .{ .x = x, .y = y };
                        break :outer;
                    }
                }
            }
            const cell = hint_cell orelse return error.InlayMouseTargetUnavailable;
            mouse.x = cell.x;
            mouse.y = cell.y;
            const input_dispatch = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig");
            _ = try input_dispatch.handleMouseEvent(hint_view, hint_hover, null, selection_editor, &mouse);
            const hint_hover_deadline = time_compat.milliTimestamp() + 5000;
            var tooltip_found = false;
            while (!tooltip_found and time_compat.milliTimestamp() < hint_hover_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (0..12) |index| {
                    if (hint_hover.wrapper.getAccessibleWidgetContentAtIndex(@intCast(index))) |content| {
                        if (std.mem.indexOf(u8, content, "Resolved inlay tooltip") != null) tooltip_found = true;
                    }
                }
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(tooltip_found);
            hint_hover.hideContentHover();
            try selection_editor.setCursorPosition(Position.init(1, 1));
            var click: @import("ui").MouseEvent = .{ .kind = .down, .button = .left, .x = cell.x, .y = cell.y, .mods = .{ .ctrl = true } };
            _ = try input_dispatch.handleMouseEvent(hint_view, hint_hover, null, selection_editor, &click);
            click = .{ .kind = .up, .button = .left, .x = cell.x, .y = cell.y, .mods = .{ .ctrl = true } };
            _ = try input_dispatch.handleMouseEvent(hint_view, hint_hover, null, selection_editor, &click);
            const link_deadline = time_compat.milliTimestamp() + 5000;
            while (selection_editor.modelCursorPosition().lineNumber != 2 and time_compat.milliTimestamp() < link_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqual(@as(usize, 2), selection_editor.modelCursorPosition().lineNumber);

            const action_model = @import("../../../editor/contrib/codeAction/browser/codeAction.zig");
            const action_types = @import("../../../editor/contrib/codeAction/common/types.zig");
            const ActionReceiver = struct {
                result: ?*action_model.ManagedCodeActionSet = null,
                failure: ?anyerror = null,
                resolved: ?@import("../../../editor/common/languages.zig").CodeAction = null,
                workspace_applied: ?bool = null,
                fn ready(context: *anyopaque, value: anyerror!*action_model.ManagedCodeActionSet) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (value) |result| self.result = result else |err| self.failure = err;
                }
                fn resolvedAction(context: *anyopaque, value: anyerror!?@import("../../../editor/common/languages.zig").CodeAction) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (value) |action| self.resolved = action else |err| self.failure = err;
                }
                fn workspaceReply(context: *anyopaque, reply: rpc.Reply) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.workspace_applied = reply == .json and reply.json == .bool and reply.json.bool;
                }
            };
            var action_receiver: ActionReceiver = .{};
            const action_request = (try action_model.getCodeActions(allocator, &features.code_action_provider, model, Range.init(1, 1, 1, 2), .{ .type = .Invoke, .trigger_action = .QuickFix, .filter = .{ .include = action_types.CodeActionKind.QuickFix } }, .None, .{ .context = &action_receiver, .complete = ActionReceiver.ready })).?;
            const action_deadline = time_compat.milliTimestamp() + 5_000;
            while (action_receiver.result == null and action_receiver.failure == null and time_compat.milliTimestamp() < action_deadline) {
                _ = extension_host.pump();
                time_compat.sleepMillis(5);
            }
            if (action_receiver.result == null and action_receiver.failure == null) action_request.dispose();
            const action_set = action_receiver.result orelse return error.ExpectedCodeAction;
            defer action_set.dispose();
            try std.testing.expectEqual(1, action_set.valid_actions.len);
            try std.testing.expect(action_set.hasAutoFix());
            const action_item = action_set.valid_actions[0];
            try std.testing.expect(action_item.action.cache_id != null);
            const provider = action_item.provider.?;
            const resolve_request = (try provider.request_resolve_code_action.?(provider.context, action_set.arena.allocator(), action_item.action, .None, .{ .context = &action_receiver, .complete = ActionReceiver.resolvedAction })).?;
            const resolve_deadline = time_compat.milliTimestamp() + 5_000;
            while (action_receiver.resolved == null and action_receiver.failure == null and time_compat.milliTimestamp() < resolve_deadline) {
                _ = extension_host.pump();
                time_compat.sleepMillis(5);
            }
            if (action_receiver.resolved == null and action_receiver.failure == null) resolve_request.dispose();
            try std.testing.expectEqualStrings("Fixture code action command", action_receiver.resolved.?.command.?.title);
            var edit_scratch = std.heap.ArenaAllocator.init(allocator);
            defer edit_scratch.deinit();
            const resource = try std_uri.encodedResource(edit_scratch.allocator(), model.uri());
            const workspace_request = try Extensions.requestActorAsync(extension_host, protocol.ExtHostContext.ExtHostCommands, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.applyWorkspaceEdit" } }, .{ .json = .{ .string = resource } } }, .{ .context = &action_receiver, .callback = ActionReceiver.workspaceReply });
            const edit_deadline = time_compat.milliTimestamp() + 5_000;
            while (action_receiver.workspace_applied == null and time_compat.milliTimestamp() < edit_deadline) {
                _ = extension_host.pump();
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(5);
            }
            if (action_receiver.workspace_applied == null) workspace_request.dispose();
            try std.testing.expect(action_receiver.workspace_applied orelse false);
            try std.testing.expectEqualStrings(" {", try model.borrowLineContent(1));
            try workbench.activeTab().?.editor.undo();
            try std.testing.expectEqualStrings("{", try model.borrowLineContent(1));

            const completion_providers = try features.completion_provider.ordered(allocator, model, false);
            defer allocator.free(completion_providers);
            try std.testing.expect(completion_providers.len > 0);

            const symbol_providers = try features.document_symbol_provider.ordered(allocator, model, false);
            defer allocator.free(symbol_providers);
            try std.testing.expect(symbol_providers.len > 0);

            // These providers now complete through the window queue, without
            // explicitly pumping the extension host from the consumer.
            const DeferredResults = struct {
                completion_items: ?usize = null,
                symbols: ?usize = null,
                fn completions(context: *anyopaque, _: *anyopaque, result: anyerror!@import("../../../editor/common/languages/completion.zig").CompletionList) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.completion_items = if (result) |list| list.items.len else |_| 0;
                }
                fn documentSymbols(context: *anyopaque, symbols: []const @import("../../../editor/common/languages.zig").DocumentSymbol) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.symbols = symbols.len;
                }
            };
            var deferred_results: DeferredResults = .{};
            var provider_arena = std.heap.ArenaAllocator.init(allocator);
            defer provider_arena.deinit();
            const completions = completion_providers[0];
            const completion_request = (try completions.provide_completion_items_deferred.?(completions.context, provider_arena.allocator(), model, Position.init(1, 1), .{}, .None)).?;
            defer completion_request.cancel(completion_request.context);
            completion_request.on_complete(completion_request.context, &deferred_results, DeferredResults.completions);
            const symbols = symbol_providers[0];
            const symbol_request = (try symbols.request_document_symbols.?(symbols.context, provider_arena.allocator(), model, .{ .context = &deferred_results, .complete = DeferredResults.documentSymbols })).?;
            defer if (deferred_results.symbols == null) symbol_request.dispose();
            try std.testing.expect(deferred_results.completion_items == null and deferred_results.symbols == null);
            const deferred_deadline = time_compat.milliTimestamp() + 5_000;
            while ((deferred_results.completion_items == null or deferred_results.symbols == null) and time_compat.milliTimestamp() < deferred_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expectEqual(@as(?usize, 1), deferred_results.completion_items);
            try std.testing.expectEqual(@as(?usize, 1), deferred_results.symbols);

            // A fiber awaiting an extension command can receive a nested
            // workspace edit request before the command itself replies.
            const Nested = struct {
                fn run(ext: *Extensions, a: Allocator, uri: []const u8, completed: *bool) !bool {
                    defer completed.* = true;
                    const reply = try ext.host.requestAwait(ext.services.window, a, proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &.{
                        .{ .json = .{ .string = "fixture.applyWorkspaceEdit" } },
                        .{ .json = .{ .string = uri } },
                    }, null, 5_000);
                    return reply == .bool and reply.bool;
                }
            };
            var nested_done = false;
            const serial = workbench.window_events.io;
            var nested = try serial.concurrent(Nested.run, .{ extension_host, provider_arena.allocator(), resource, &nested_done });
            defer {
                if (!nested_done) _ = nested.cancel(serial) catch false;
            }
            const nested_deadline = time_compat.milliTimestamp() + 7_000;
            while (!nested_done and time_compat.milliTimestamp() < nested_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(nested_done);
            try std.testing.expect(try nested.await(serial));
            try std.testing.expectEqualStrings(" {", try model.borrowLineContent(1));
            try workbench.activeTab().?.editor.undo();

            // The real onWillSave listener sends a nested workspace edit.
            // It must be applied before the disk write and will-save reply.
            const command_actor = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
            const enabled = try extension_host.host.requestSync(provider_arena.allocator(), command_actor, "$executeContributedCommand", &.{.{ .json = .{ .string = "fixture.enableSaveParticipant" } }}, null, 5_000);
            try std.testing.expect(enabled == .bool and enabled.bool);
            const save_editor = workbench.activeTab().?.editor;
            try workbench.commands.execute("workbench.action.files.save");
            try std.testing.expect(save_editor.document.pending_save != null);
            const save_deadline = time_compat.milliTimestamp() + 5_000;
            while (save_editor.document.pending_save != null and time_compat.milliTimestamp() < save_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(save_editor.document.pending_save == null);
            try std.testing.expectEqualStrings(" {", try model.borrowLineContent(1));
            try std.testing.expect(!save_editor.isDirty());
            const saved_bytes = try tmp.dir.readFileAlloc(io, "fixture.json", allocator, .limited(1024));
            defer allocator.free(saved_bytes);
            try std.testing.expect(std.mem.startsWith(u8, saved_bytes, " {"));
            try save_editor.undo();

            // Extension-initiated TextDocument.save must also reply only
            // after its participant and disk snapshot have completed.
            var saved_by_extension: ?bool = null;
            const save_request = try Extensions.requestActorAsync(extension_host, protocol.ExtHostContext.ExtHostCommands, "$executeContributedCommand", &.{
                .{ .json = .{ .string = "fixture.saveDocument" } },
                .{ .json = .{ .string = resource } },
            }, .{ .context = &saved_by_extension, .callback = struct {
                fn complete(context: *anyopaque, reply: rpc.Reply) void {
                    const result: *?bool = @ptrCast(@alignCast(context));
                    result.* = reply == .json and reply.json == .bool and reply.json.bool;
                }
            }.complete });
            const extension_save_deadline = time_compat.milliTimestamp() + 5_000;
            while (saved_by_extension == null and time_compat.milliTimestamp() < extension_save_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            if (saved_by_extension == null) save_request.dispose();
            try std.testing.expect(saved_by_extension orelse false);
            try std.testing.expectEqualStrings(" {", try model.borrowLineContent(1));
            try std.testing.expect(!save_editor.isDirty());
            try save_editor.undo();

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
            try waitNavigation(workbench);
            try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.revealDeclaration"));
            try waitNavigation(workbench);
            try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToImplementation"));
            try waitNavigation(workbench);
            try std.testing.expectEqual(@as(usize, 3), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToTypeDefinition"));
            try waitNavigation(workbench);
            try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);

            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToReferences"));
            try waitNavigation(workbench);
            try std.testing.expect(workbench.quick_access.isOpen());
            workbench.quick_access.inputService().hide();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.findReferences"));
            try waitNavigation(workbench);
            try std.testing.expect(workbench.quick_access.isOpen());
            workbench.quick_access.inputService().hide();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "outline.focus"));
            try std.testing.expect(workbench.outline_view != null);
            try std.testing.expect(workbench.outline_view.?.focused);
            workbench.focusEditor();
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.showHover"));
            const hover_controller = workbench.activeTab().?.controllers.?.hover.?;
            const hover_deadline = time_compat.milliTimestamp() + 5_000;
            while (!hover_controller.wrapper.operation.isIdle() and time_compat.milliTimestamp() < hover_deadline) {
                _ = extension_host.pump();
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(hover_controller.wrapper.operation.isIdle());
            try std.testing.expect(hover_controller.isVisible());
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

            // Range-only providers paint visible lines without marking the
            // document as completely colored. Exercise this independently of
            // the full/delta provider and through actual theme metadata.
            try tmp.dir.writeFile(io, .{ .sub_path = "semantic-test-theme.json", .data = "{\"semanticHighlighting\":true,\"semanticTokenColors\":{\"*\":{\"foreground\":\"#12ab34\",\"bold\":true}}}" });
            try tmp.dir.writeFile(io, .{ .sub_path = "semantic-test-settings.json", .data = "{\"workbench.colorTheme\":\"Range Semantic Fixture\",\"editor.semanticHighlighting.enabled\":true}" });
            const theme_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(theme_root);
            const semantic_settings = try std.fs.path.join(allocator, &.{ theme_root, "semantic-test-settings.json" });
            defer allocator.free(semantic_settings);
            try workbench.registerThemeSources(&.{.{ .root = theme_root, .id = "Range Semantic Fixture", .settings_id = "Range Semantic Fixture", .label = "Range Semantic Fixture", .ui_theme = "vs-dark", .path = "semantic-test-theme.json" }});
            try workbench.setUserSettingsPaths(&.{semantic_settings});
            workbench.applyThemeSettings();
            model.setLanguage("plaintext");
            const viewport_deadline = time_compat.milliTimestamp() + 5000;
            while (!model.hasSomeSemanticTokens() and time_compat.milliTimestamp() < viewport_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(model.hasSomeSemanticTokens());
            try std.testing.expect(!model.hasCompleteSemanticTokens());
        }

        test "Extensions: eager activation does not block workbench startup" {
            if (!build_options.e2e) return error.SkipZigTest;
            try verifySlowStartup(false);
        }

        test "Extensions: disposing a partially started host unregisters providers and cancels editor work" {
            if (!build_options.e2e) return error.SkipZigTest;
            try verifySlowStartup(true);
        }

        fn verifySlowStartup(abort_start: bool) !void {
            const a = std.testing.allocator;
            const io = time_compat.io;
            try std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{});
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "slow.txt", .data = "hello\n" });
            const root = try tmp.dir.realPathFileAlloc(io, ".", a);
            defer a.free(root);
            const path = try tmp.dir.realPathFileAlloc(io, "slow.txt", a);
            defer a.free(path);
            const window = try TestWindow.init(a, io, &.{path}, 100, 30);
            defer window.deinit();
            const workbench = window.workbench;
            try workbench.enableLanguageFeatures();
            const editor = workbench.activeTab().?.editor;
            const registry = &workbench.language_features.?.code_lens_provider;
            try std.testing.expect(!registry.has(editor.model));
            const extension_paths = &[_]Extensions.ExtensionPath{.{ .path = "host/test-fixtures/slow-startup", .is_under_development = true }};
            // The aborted case exercises the same owner teardown used by
            // init's error path, before the save participant is registered.
            var host: ?*Extensions = if (abort_start)
                try Extensions.create(a, io, workbench.extensionHostServices(), extension_paths, root, "host/dist")
            else
                try Extensions.init(a, io, workbench.extensionHostServices(), extension_paths, root, "host/dist");
            defer if (host) |extension_host| extension_host.deinit();
            const extension_host = host.?;
            if (abort_start) {
                try extension_host.boot("host/dist");
                extension_host.host.attachReadyTask(&extension_host.rpc_task);
            }
            // Startup returned even though the fixture can only finish when
            // it receives the explicit release command below.
            try std.testing.expect(extension_host.eager_start_request != null);
            const Lens = @import("../../../editor/contrib/codelens/browser/codelensController.zig").CodeLensContribution;
            const lens = editor.getInstantiatedContribution(Lens) orelse return error.CodeLensContributionMissing;
            const deadline = time_compat.milliTimestamp() + 5000;
            while ((!registry.has(editor.model) or lens.pending_fetch == null) and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(registry.has(editor.model));
            try std.testing.expect(lens.pending_fetch != null);
            try std.testing.expect(extension_host.eager_start_request != null);
            if (!abort_start) {
                try extension_host.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &.{.{ .json = .{ .string = "fixture.slowStartup.release" } }});
                const finish_deadline = time_compat.milliTimestamp() + 5000;
                while ((extension_host.eager_start_request != null or lens.pending_fetch != null) and time_compat.milliTimestamp() < finish_deadline) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    time_compat.sleepMillis(10);
                }
                try std.testing.expect(extension_host.eager_start_request == null);
                try std.testing.expect(lens.pending_fetch == null);
            }
            extension_host.deinit();
            host = null;
            try std.testing.expect(!registry.has(editor.model));
            try std.testing.expect(lens.pending_fetch == null);
            try std.testing.expectEqual(@as(usize, 0), lens.providers.len);
            // The real crash occurred after the workbench continued to
            // dispatch a stale CodeLens deadline against the freed host.
            _ = workbench.window_events.dispatch(time_compat.milliTimestamp() + 1000);
            try std.testing.expect(lens.pending_fetch == null);
        }

        test "Extensions: real vscode-languageclient negotiates mock LSP and applies nested save and workspace edits" {
            if (!build_options.e2e) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            try std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{});
            try std.Io.Dir.cwd().access(io, "host/test-fixtures/lsp-language-features/package.json", .{});
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(root);
            const path = try std.fs.path.join(allocator, &.{ root, "mock.txt" });
            defer allocator.free(path);
            const settings_path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
            defer allocator.free(settings_path);
            try tmp.dir.writeFile(io, .{ .sub_path = "mock.txt", .data = "alpha(1)\n  beta\n}\n" });
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"lspFixture.value\":\"fixture setting\",\"workbench.colorTheme\":\"Mock LSP Semantic Theme\",\"editor.semanticHighlighting.enabled\":true}" });
            try tmp.dir.writeFile(io, .{ .sub_path = "theme.json", .data = "{\"semanticHighlighting\":true,\"semanticTokenColors\":{\"*\":{\"foreground\":\"#12ab34\",\"bold\":true}}}" });
            const window = try TestWindow.initWithOptions(allocator, io, &.{}, 100, 30, .{ .initial_user_settings_paths = &.{settings_path} }, null);
            defer window.deinit();
            const workbench = window.workbench;
            try workbench.setWorkspaceFolders(&.{root});
            try workbench.openPath(path);
            try workbench.enableLanguageFeatures();
            try workbench.registerThemeSources(&.{.{ .root = root, .id = "Mock LSP Semantic Theme", .settings_id = "Mock LSP Semantic Theme", .label = "Mock LSP Semantic Theme", .ui_theme = "vs-dark", .path = "theme.json" }});
            workbench.applyThemeSettings();
            const extension_host = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/lsp-language-features", .is_under_development = true }}, ".cache-ext/mock-languageclient", "host/dist");
            defer extension_host.deinit();
            const model = workbench.activeTab().?.editor.model;
            const editor = workbench.activeTab().?.editor;
            const features = workbench.language_features.?;
            const startup = time_compat.milliTimestamp() + 20000;
            while (time_compat.milliTimestamp() < startup) {
                _ = extension_host.pump();
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                if (extension_host.activated and features.signature_help_provider.has(model) and features.rename_provider.has(model) and features.inlay_hints_provider.has(model) and features.document_semantic_tokens_provider.has(model)) break;
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(extension_host.activated);
            try std.testing.expect(features.hover_provider.has(model));
            try std.testing.expect(features.completion_provider.has(model));
            try std.testing.expect(features.signature_help_provider.has(model));
            try std.testing.expect(features.definition_provider.has(model) and features.declaration_provider.has(model) and features.type_definition_provider.has(model));
            try std.testing.expect(features.reference_provider.has(model) and features.document_highlight_provider.has(model) and features.document_symbol_provider.has(model));
            try std.testing.expect(features.code_action_provider.has(model) and features.document_formatting_edit_provider.has(model));
            try std.testing.expect(features.rename_provider.has(model) and features.folding_range_provider.has(model) and features.selection_range_provider.has(model));
            try std.testing.expect(features.document_semantic_tokens_provider.has(model) and features.document_range_semantic_tokens_provider.has(model) and features.inlay_hints_provider.has(model));

            const MockCommand = struct {
                arena: Allocator,
                reply: ?std.json.Value = null,
                failed: bool = false,
                fn ready(context: *anyopaque, result: rpc.Reply) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result == .json) self.reply = rpc.cloneJsonValue(self.arena, result.json) catch {
                        self.failed = true;
                        return;
                    } else self.failed = true;
                }
                fn call(a: Allocator, wb: *terminal_window_type, host: *Extensions, command: []const u8) !std.json.Value {
                    var receiver: @This() = .{ .arena = a };
                    const request = try Extensions.requestActorAsync(host, protocol.ExtHostContext.ExtHostCommands, "$executeContributedCommand", &.{.{ .json = .{ .string = command } }}, .{ .context = &receiver, .callback = ready });
                    const deadline = time_compat.milliTimestamp() + 10000;
                    while (receiver.reply == null and !receiver.failed and time_compat.milliTimestamp() < deadline) {
                        _ = host.pump();
                        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                        time_compat.sleepMillis(5);
                    }
                    if (receiver.reply == null and !receiver.failed) request.dispose();
                    return receiver.reply orelse error.MockLspCommandFailed;
                }
            };
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const status = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.status");
            try std.testing.expect(status == .object);
            try std.testing.expect(status.object.get("initial").? == .object);
            try std.testing.expect(status.object.get("folders").?.array.items.len == 1);
            const mock_configuration = status.object.get("configuration") orelse return error.MockConfigurationMissing;
            try std.testing.expectEqualStrings("fixture setting", mock_configuration.object.get("value").?.string);
            // An omitted string default must reach the languageclient as the
            // empty string, not JSON null (the real Zig extension calls
            // startsWith on its implicit zig.path default at activation).
            const implicit_string = mock_configuration.object.get("implicitString") orelse return error.MockConfigurationMissing;
            try std.testing.expect(implicit_string == .string);
            try std.testing.expectEqualStrings("", implicit_string.string);
            var resource = try @import("../../../platform/markers/common/markers.zig").Resource.fromUri(allocator, model.uri());
            defer resource.deinit(allocator);
            const diagnostic_deadline = time_compat.milliTimestamp() + 5000;
            var diagnostic_found = false;
            while (!diagnostic_found and time_compat.milliTimestamp() < diagnostic_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                const markers = try workbench.marker_service.?.read(a, .{ .resource = resource });
                for (markers) |marker| if (std.mem.eql(u8, marker.message, "Mock diagnostic")) {
                    diagnostic_found = true;
                    break;
                };
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(diagnostic_found);

            const Deferred = struct {
                highlight_count: ?usize = null,
                completion_item: ?@import("../../../editor/common/languages/completion.zig").CompletionItem = null,
                symbol_name: ?[]const u8 = null,
                fn completions(context: *anyopaque, _: *anyopaque, result: anyerror!@import("../../../editor/common/languages/completion.zig").CompletionList) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |list| {
                        for (list.items) |item| if (std.mem.eql(u8, item.label, "mockCompletion")) {
                            self.completion_item = item;
                            break;
                        };
                    } else |_| {}
                }
                fn highlights(context: *anyopaque, result: anyerror!?[]const @import("../../../editor/common/languages.zig").DocumentHighlight) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.highlight_count = if (result) |value| if (value) |items| items.len else 0 else |_| 0;
                }
                fn symbols(context: *anyopaque, result: []const @import("../../../editor/common/languages.zig").DocumentSymbol) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result.len > 0) self.symbol_name = result[0].name;
                }
            };
            var deferred_result: Deferred = .{};
            const completion_providers = try features.completion_provider.ordered(a, model, false);
            var request_completion: ?@import("../../../editor/common/languages/completion.zig").CompletionRequest = null;
            for (completion_providers) |provider| if (provider.provide_completion_items_deferred) |request| {
                request_completion = try request(provider.context, a, model, Position.init(1, 1), .{}, .None);
                if (request_completion != null) break;
            };
            const completion_request = request_completion orelse return error.MockCompletionMissing;
            defer completion_request.cancel(completion_request.context);
            completion_request.on_complete(completion_request.context, &deferred_result, Deferred.completions);
            const symbol_providers = try features.document_symbol_provider.ordered(a, model, false);
            const symbols = symbol_providers[0];
            const symbol_request = (try symbols.request_document_symbols.?(symbols.context, a, model, .{ .context = &deferred_result, .complete = Deferred.symbols })).?;
            defer if (deferred_result.symbol_name == null) symbol_request.dispose();
            const highlight_providers = try features.document_highlight_provider.ordered(a, model, false);
            var highlight_request: ?@import("../../../base/common/lifecycle.zig").IDisposable = null;
            for (highlight_providers) |provider| if (provider.request_document_highlights) |request| {
                highlight_request = try request(provider.context, a, model, Position.init(1, 2), .None, .{ .context = &deferred_result, .complete = Deferred.highlights });
                if (highlight_request != null) break;
            };
            defer if (deferred_result.highlight_count == null) {
                if (highlight_request) |request| request.dispose();
            };
            const completion_deadline = time_compat.milliTimestamp() + 5000;
            while ((deferred_result.completion_item == null or deferred_result.symbol_name == null or deferred_result.highlight_count == null) and time_compat.milliTimestamp() < completion_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const completion_item = deferred_result.completion_item orelse return error.MockCompletionMissing;
            try std.testing.expectEqualStrings("(value)", completion_item.label_detail.?);
            try std.testing.expectEqualStrings("mock", completion_item.label_description.?);
            try std.testing.expectEqualStrings("Mock LSP completion", completion_item.detail.?);
            try std.testing.expectEqualStrings("mockCompletion(${1:value})", completion_item.insert_text);
            try std.testing.expectEqualStrings("alpha", deferred_result.symbol_name orelse return error.MockDocumentSymbolMissing);
            try std.testing.expectEqual(@as(?usize, 2), deferred_result.highlight_count);

            for ([_][]const u8{ "editor.action.revealDefinition", "editor.action.revealDeclaration", "editor.action.goToTypeDefinition" }) |command| {
                try editor.setCursorPosition(Position.init(1, 2));
                try std.testing.expect(runLspCommand(workbench.extensionHostServices(), command));
                try waitNavigation(workbench);
                try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
            }
            try editor.setCursorPosition(Position.init(1, 2));
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToReferences"));
            try waitNavigation(workbench);
            try std.testing.expect(workbench.quick_access.isOpen());
            workbench.quick_access.inputService().hide();
            try workbench.commands.execute("workbench.action.showAllSymbols");
            const picker = workbench.quick_access.controller.pickerRef();
            try picker.setValue("#MockWorkspaceSymbol");
            const workspace_deadline = time_compat.milliTimestamp() + 5000;
            var workspace_found = false;
            while (!workspace_found and time_compat.milliTimestamp() < workspace_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (picker.items.items, 0..) |item, index| if (item == .item and std.mem.eql(u8, item.item.label, "MockWorkspaceSymbol")) {
                    workspace_found = true;
                    picker.setActiveIndex(index);
                    break;
                };
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(workspace_found);
            picker.accept();
            try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);

            try editor.setCursorPosition(Position.init(1, 2));
            try workbench.commands.execute("editor.action.showHover");
            const HoverController = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
            const hover = editor.getInstantiatedContribution(HoverController).?;
            const hover_deadline = time_compat.milliTimestamp() + 5000;
            var mock_hover_found = false;
            while (!mock_hover_found and time_compat.milliTimestamp() < hover_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (0..12) |i| if (hover.wrapper.getAccessibleWidgetContentAtIndex(@intCast(i))) |content| {
                    if (std.mem.indexOf(u8, content, "Mock hover: alpha(1)") != null) mock_hover_found = true;
                };
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(hover.isVisible() and mock_hover_found);
            hover.hideContentHover();
            try editor.setCursorPosition(Position.init(1, 7));
            try workbench.commands.execute("editor.action.triggerParameterHints");
            const ParameterHintsController = @import("../../../editor/contrib/parameterHints/browser/parameterHints.zig").ParameterHintsController;
            const hints = editor.getInstantiatedContribution(ParameterHintsController).?;
            const hints_deadline = time_compat.milliTimestamp() + 5000;
            while (hints.model.hints() == null and time_compat.milliTimestamp() < hints_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("alpha(value: number)", (hints.model.hints() orelse return error.MockSignatureMissing).signatures[0].label);
            try workbench.commands.execute("closeParameterHints");
            const InlayController = @import("../../../editor/contrib/inlayHints/browser/inlayHintsController.zig").InlayHintsController;
            const inlay = editor.getInstantiatedContribution(InlayController).?;
            const features_deadline = time_compat.milliTimestamp() + 5000;
            while ((!model.hasCompleteSemanticTokens() or inlay.parts.len == 0 or editor.folding.regionStartingAt(1) == null) and time_compat.milliTimestamp() < features_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(model.hasCompleteSemanticTokens() and model.hasSomeSemanticTokens());
            try std.testing.expect(inlay.parts.len > 0 and editor.folding.regionStartingAt(1) != null);
            try std.testing.expect(std.mem.indexOf(u8, (try editor.viewLineData(1)).content, "value:") != null);
            const MockLanguageResults = struct {
                semantic: ?@import("../../../editor/common/languages.zig").SemanticTokensResult = null,
                resolved: ?@import("../../../editor/common/languages.zig").InlayHint = null,
                failed: bool = false,
                fn semanticReady(context: *anyopaque, result: anyerror!?@import("../../../editor/common/languages.zig").SemanticTokensResult) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.semantic = value else |_| self.failed = true;
                }
                fn inlayReady(context: *anyopaque, result: anyerror!?@import("../../../editor/common/languages.zig").InlayHint) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.resolved = value else |_| self.failed = true;
                }
                fn wait(self: *@This(), wb: *terminal_window_type, req: @import("../../../base/common/lifecycle.zig").IDisposable, is_semantic: bool) !void {
                    const deadline = time_compat.milliTimestamp() + 5000;
                    while (!self.failed and (if (is_semantic) self.semantic == null else self.resolved == null) and time_compat.milliTimestamp() < deadline) {
                        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                        time_compat.sleepMillis(10);
                    }
                    if (self.failed or (if (is_semantic) self.semantic == null else self.resolved == null)) {
                        if (!self.failed) req.dispose();
                        return error.MockProviderUnavailable;
                    }
                }
            };
            var language_results: MockLanguageResults = .{};
            const full_providers = try features.document_semantic_tokens_provider.ordered(a, model, false);
            const full_provider = full_providers[0];
            const raw_full = try full_provider.request_document_semantic_tokens(full_provider.context, a, model, null, .{ .context = &language_results, .complete = MockLanguageResults.semanticReady });
            try language_results.wait(workbench, raw_full, true);
            const full_tokens = language_results.semantic.?;
            try std.testing.expectEqualSlices(u32, &.{ 0, 0, 5, 1, 1 }, full_tokens.payload.full);
            language_results.semantic = null;
            const raw_delta = try full_provider.request_document_semantic_tokens(full_provider.context, a, model, full_tokens.id, .{ .context = &language_results, .complete = MockLanguageResults.semanticReady });
            try language_results.wait(workbench, raw_delta, true);
            const delta = language_results.semantic.?;
            try std.testing.expect(delta.payload == .delta);
            try std.testing.expectEqualSlices(u32, &.{4}, delta.payload.delta[0].data);
            full_provider.release_document_semantic_tokens(full_provider.context, delta.id);
            const range_providers = try features.document_range_semantic_tokens_provider.ordered(a, model, false);
            const range_provider = range_providers[0];
            language_results.semantic = null;
            const raw_range = try range_provider.request_document_range_semantic_tokens(range_provider.context, a, model, model.getFullModelRange(), .{ .context = &language_results, .complete = MockLanguageResults.semanticReady });
            try language_results.wait(workbench, raw_range, true);
            try std.testing.expectEqualSlices(u32, &.{ 0, 0, 5, 1, 1 }, language_results.semantic.?.payload.full);
            const item = inlay.parts[0].item;
            const raw_resolve = try item.provider.resolve_inlay_hint.?(item.provider.context, a, model, item.hint, .{ .context = &language_results, .complete = MockLanguageResults.inlayReady });
            try language_results.wait(workbench, raw_resolve, false);
            try std.testing.expectEqualStrings("Mock resolved hint", language_results.resolved.?.tooltip.?);

            try editor.setCursorPosition(Position.init(1, 2));
            try editor.growSelection(true);
            const selection_deadline = time_compat.milliTimestamp() + 5000;
            while (editor.smart_select.pending != null and time_compat.milliTimestamp() < selection_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const selected = try editor.getModelSelections();
            defer allocator.free(selected);
            try std.testing.expect(!selected[0].isEmpty());
            const actions_mod = @import("../../../editor/contrib/codeAction/browser/codeAction.zig");
            const action_kinds = @import("../../../editor/contrib/codeAction/common/types.zig");
            const bulk = @import("../../../editor/browser/services/bulkEditService.zig");
            const ActionProbe = struct {
                result: ?*actions_mod.ManagedCodeActionSet = null,
                applied: ?bool = null,
                failure: ?anyerror = null,
                fn ready(context: *anyopaque, result: anyerror!*actions_mod.ManagedCodeActionSet) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.result = value else |err| self.failure = err;
                }
                fn appliedEdit(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    if (result) |value| self.applied = value.is_applied else |err| self.failure = err;
                }
            };
            var action_probe: ActionProbe = .{};
            const action_request = (try actions_mod.getCodeActions(allocator, &features.code_action_provider, model, Range.init(1, 1, 1, 6), .{ .type = .Invoke, .trigger_action = .QuickFix, .filter = .{ .include = action_kinds.CodeActionKind.QuickFix } }, .None, .{ .context = &action_probe, .complete = ActionProbe.ready })).?;
            const action_deadline = time_compat.milliTimestamp() + 5000;
            while (action_probe.result == null and action_probe.failure == null and time_compat.milliTimestamp() < action_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            if (action_probe.result == null and action_probe.failure == null) action_request.dispose();
            const action_set = action_probe.result orelse return error.MockCodeActionMissing;
            defer action_set.dispose();
            try std.testing.expectEqual(@as(usize, 1), action_set.valid_actions.len);
            const action = action_set.valid_actions[0].action;
            try std.testing.expectEqualStrings("Mock quick fix", action.title);
            const apply_request = try workbench.bulk_edit_api.apply(action.edit orelse return error.MockActionEditMissing, .{ .editor = editor }, .{ .context = &action_probe, .complete = ActionProbe.appliedEdit });
            const apply_deadline = time_compat.milliTimestamp() + 5000;
            while (action_probe.applied == null and action_probe.failure == null and time_compat.milliTimestamp() < apply_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            if (action_probe.applied == null and action_probe.failure == null) if (apply_request) |request| request.dispose();
            try std.testing.expect(action_probe.applied orelse false);
            try std.testing.expectEqualStrings("fixed(1)", try model.borrowLineContent(1));
            try editor.undo();
            try std.testing.expectEqualStrings("alpha(1)", try model.borrowLineContent(1));

            try editor.setCursorPosition(Position.init(1, 2));
            try editor.formatDocument();
            const format_deadline = time_compat.milliTimestamp() + 5000;
            while (!std.mem.startsWith(u8, try model.borrowLineContent(2), "    beta") and time_compat.milliTimestamp() < format_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("    beta", try model.borrowLineContent(2));
            try editor.undo();
            try std.testing.expectEqualStrings("  beta", try model.borrowLineContent(2));
            try editor.setCursorPosition(Position.init(1, 2));
            try workbench.commands.execute("editor.action.rename");
            const RenameController = @import("../../../editor/contrib/rename/browser/rename.zig").RenameController;
            const rename = editor.getInstantiatedContribution(RenameController).?;
            const rename_deadline = time_compat.milliTimestamp() + 5000;
            while (!rename.widget.visible and time_compat.milliTimestamp() < rename_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("alpha", rename.widget.input.getValue());
            try rename.widget.input.setValue("renamed");
            try workbench.commands.execute("acceptRenameInput");
            const rename_edits_deadline = time_compat.milliTimestamp() + 5000;
            while (rename.state != .idle and time_compat.milliTimestamp() < rename_edits_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("renamed(1)", try model.borrowLineContent(1));
            try editor.undo();
            try std.testing.expectEqualStrings("alpha(1)", try model.borrowLineContent(1));

            // Saving calls the languageclient's onWillSave waitUntil listener;
            // its returned workspace edit must be applied before writing.
            try editor.setCursorPosition(Position.init(1, model.getLineMaxColumn(1)));
            try editor.insertText("é");
            try workbench.commands.execute("workbench.action.files.save");
            const save_deadline = time_compat.milliTimestamp() + 10000;
            var saved = false;
            while (!saved and time_compat.milliTimestamp() < save_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                const contents = try tmp.dir.readFileAlloc(io, "mock.txt", allocator, .limited(64 * 1024));
                defer allocator.free(contents);
                saved = std.mem.startsWith(u8, contents, "// mock save\n") and std.mem.indexOf(u8, contents, "é") != null;
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(saved);
            const applied = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.applyEdit");
            try std.testing.expect(applied == .bool and applied.bool);
            try std.testing.expectEqualStrings("// nested edit", try model.borrowLineContent(1));
            const progress = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.progress");
            try std.testing.expect(progress == .bool and progress.bool);
            const config_updated = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.updateConfiguration");
            try std.testing.expect(config_updated == .bool and config_updated.bool);
            const persisted = try tmp.dir.readFileAlloc(io, "settings.json", allocator, .limited(64 * 1024));
            defer allocator.free(persisted);
            try std.testing.expect(std.mem.indexOf(u8, persisted, "updated by extension") != null);
            const config_deadline = time_compat.milliTimestamp() + 5000;
            var config_seen = false;
            while (!config_seen and time_compat.milliTimestamp() < config_deadline) {
                const current = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.status");
                if (current.object.get("configuration")) |cfg| if (cfg == .object) if (cfg.object.get("value")) |value| {
                    config_seen = value == .string and std.mem.eql(u8, value.string, "updated by extension");
                };
                if (!config_seen) time_compat.sleepMillis(20);
            }
            try std.testing.expect(config_seen);
            try tmp.dir.writeFile(io, .{ .sub_path = "watched.lspfixture", .data = "change" });
            const watch_deadline = time_compat.milliTimestamp() + 5000;
            var watched_file = false;
            while (!watched_file and time_compat.milliTimestamp() < watch_deadline) {
                const current = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.status");
                for (current.object.get("watched").?.array.items) |change| {
                    if (change == .object and std.mem.endsWith(u8, change.object.get("uri").?.string, "watched.lspfixture")) watched_file = true;
                }
                if (!watched_file) time_compat.sleepMillis(20);
            }
            try std.testing.expect(watched_file);
            try tmp.dir.createDir(io, "another", .default_dir);
            const other_root = try std.fs.path.join(allocator, &.{ root, "another" });
            defer allocator.free(other_root);
            try workbench.setWorkspaceFolders(&.{ root, other_root });
            const folders_deadline = time_compat.milliTimestamp() + 5000;
            var folders_seen = false;
            while (!folders_seen and time_compat.milliTimestamp() < folders_deadline) {
                const current = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.status");
                folders_seen = current.object.get("folders").?.array.items.len == 2;
                if (!folders_seen) time_compat.sleepMillis(20);
            }
            try std.testing.expect(folders_seen);
            const final_status = try MockCommand.call(a, workbench, extension_host, "fixture.lsp.status");
            const saved_text = final_status.object.get("lastSaveText").?.string;
            try std.testing.expect(std.mem.startsWith(u8, saved_text, "// mock save\n") and std.mem.indexOf(u8, saved_text, "é") != null);
            const counts = final_status.object.get("counts").?.object;
            try std.testing.expect(counts.get("willSaveWaitUntil") != null and counts.get("save") != null and counts.get("applyEdit") != null);
            try std.testing.expect(counts.get("hover") != null and counts.get("signatureHelp") != null and counts.get("semanticFull") != null and counts.get("inlayHints") != null);
            for ([_][]const u8{ "completion", "documentSymbol", "definition", "declaration", "typeDefinition", "references", "highlight", "workspaceSymbol", "codeAction", "format", "prepareRename", "rename", "folding", "selectionRange", "semanticRange", "semanticDelta", "resolveInlayHint", "watchedFiles", "workspaceFolders", "configurationChanged" }) |method| {
                if (counts.get(method) == null) std.debug.print("Mock LSP method not reached: {s}\n", .{method});
                try std.testing.expect(counts.get(method) != null);
            }
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
                    mirrored = try std_uri.resourceKeyFromComponents(allocator, .{ .scheme = "file", .path = active.uri });
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
                if (navigated) try waitNavigation(workbench);
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
            try std.testing.expect(extension_host.tabs_task.at == null);
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

        test "Extensions: semantic document and multi-document highlights render both registered diff editors" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const a = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "diff.json", .data = "{}" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = path_buffer[0..try tmp.dir.realPathFile(io, "diff.json", &path_buffer)];
            const window = try TestWindow.init(a, io, &.{path}, 120, 24);
            defer window.deinit();
            const wb = window.workbench;
            try wb.enableLanguageFeatures();
            const extensions = try Extensions.init(a, io, wb.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-diff-highlight-fixture", "host/dist");
            defer extensions.deinit();
            try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "{\"word\":1}", "{\"word\":2}", "Original", "Modified");
            const diff = wb.activeTab().?.diff.?.widget;
            const WordHighlighterContribution = @import("../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
            const original = diff.original_editor.getContribution(WordHighlighterContribution).?;
            const modified = diff.modified_editor.getContribution(WordHighlighterContribution).?;
            const features = wb.language_features.?;
            try std.testing.expectEqual(features, diff.original_editor.language_features.?);
            try std.testing.expectEqual(features, diff.modified_editor.language_features.?);
            const registered_editors = wb.code_editor_api.listCodeEditors();
            try std.testing.expect(std.mem.indexOfScalar(*Editor, registered_editors, diff.original_editor) != null);
            try std.testing.expect(std.mem.indexOfScalar(*Editor, registered_editors, diff.modified_editor) != null);
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                const providers = try features.document_highlight_provider.ordered(a, diff.originalModel(), false);
                defer a.free(providers);
                const multi = try features.multi_document_highlight_provider.ordered(a, diff.originalModel(), false);
                defer a.free(multi);
                if (providers.len > 1 and multi.len > 1) break;
                time_compat.sleepMillis(10);
            }
            diff.setFocus(.original);
            try diff.original_editor.setCursorPosition(Position.init(1, 4));
            original.trigger();
            const Pump = struct {
                fn settle(host: *Extensions, contribution: *WordHighlighterContribution) !void {
                    const limit = time_compat.milliTimestamp() + 10_000;
                    while (time_compat.milliTimestamp() < limit) {
                        _ = host.pump();
                        const highlighter = contribution.word_highlighter.?;
                        if (highlighter.pending_request == null and highlighter.pending_deadline_ms == null) return;
                        time_compat.sleepMillis(10);
                    }
                    return error.OccurrenceRequestDidNotSettle;
                }
            };
            try Pump.settle(extensions, original);
            try std.testing.expectEqual(1, original.word_highlighter.?.decorations.items.len);
            try std.testing.expectEqual(@as(@import("../../../editor/browser/editorBrowser.zig").DecorationKind, .word_highlight), original.word_highlighter.?.decorations.items[0].kind);
            try std.testing.expect(!modified.saveViewState());
            original.applyConfiguration(.{ .occurrences_highlight = .multi_file });
            original.trigger();
            try Pump.settle(extensions, original);
            try std.testing.expectEqual(1, modified.word_highlighter.?.decorations.items.len);
            try std.testing.expectEqual(@as(@import("../../../editor/browser/editorBrowser.zig").DecorationKind, .word_highlight_strong), modified.word_highlighter.?.decorations.items[0].kind);
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const command = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
            const queries = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{.{ .json = .{ .string = "fixture.highlightQueries" } }}, null, 5000);
            var single_found = false;
            var multi_found = false;
            for (queries.array.items) |query| {
                const object = query.object;
                if (!std.mem.eql(u8, object.get("text").?.string, "{\"word\":1}")) continue;
                if (std.mem.eql(u8, object.get("type").?.string, "single")) single_found = true else {
                    for (object.get("others").?.array.items) |other| {
                        if (std.mem.eql(u8, other.object.get("text").?.string, "{\"word\":2}") and !std.mem.eql(u8, other.object.get("uri").?.string, object.get("uri").?.string)) multi_found = true;
                    }
                }
            }
            try std.testing.expect(single_found and multi_found);
            const original_uri = try std_uri.encodedResource(scratch.allocator(), diff.originalModel().uri());
            const value = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.executeDocumentHighlights" } }, .{ .json = .{ .string = original_uri } } }, null, 5000);
            try std.testing.expectEqual(1, value.array.items.len);
            try std.testing.expectEqual(2, value.array.items[0].object.get("start").?.integer);
            try std.testing.expectEqual(6, value.array.items[0].object.get("end").?.integer);
            try std.testing.expectEqual(1, value.array.items[0].object.get("kind").?.integer);
            try std.testing.expectEqual(0, extensions.language_features_actor.?.model_position_commands.items.len);
            const modified_uri = try std_uri.encodedResource(scratch.allocator(), diff.modifiedModel().uri());
            for ([_][]const u8{ original_uri, modified_uri }) |uri| {
                for ([_]bool{ false, true }) |recursive| {
                    const hovers = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.executeHovers" } }, .{ .json = .{ .string = uri } }, .{ .json = .{ .bool = recursive } } }, null, 5000);
                    var found = false;
                    for (hovers.array.items) |item| {
                        for (item.object.get("contents").?.array.items) |value_item| {
                            if (std.mem.eql(u8, value_item.string, "fixture hover")) {
                                found = true;
                                try std.testing.expectEqual(@as(i64, 2), item.object.get("start").?.integer);
                                try std.testing.expectEqual(@as(i64, 6), item.object.get("end").?.integer);
                            }
                        }
                    }
                    try std.testing.expect(found);
                    try std.testing.expectEqual(0, extensions.language_features_actor.?.model_position_commands.items.len);
                }
            }
            // The public code-action command uses the same registered provider
            // set on each genuine diff resource and preserves reversed selection.
            for ([_][]const u8{ original_uri, modified_uri }) |uri| {
                for ([_]i64{ 0, 1 }) |count| {
                    const actions = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.executeCodeActions" } }, .{ .json = .{ .string = uri } }, .{ .json = .{ .string = "quickfix" } }, .{ .json = .{ .integer = count } } }, null, 5000);
                    const items = actions.object.get("items").?.array.items;
                    try std.testing.expectEqual(@as(usize, 1), items.len);
                    try std.testing.expectEqualStrings("Fixture quick fix", items[0].object.get("title").?.string);
                    try std.testing.expect(items[0].object.get("preferred").?.bool);
                    if (count == 0) {
                        try std.testing.expect(items[0].object.get("edits") == null);
                    } else {
                        const edits = items[0].object.get("edits").?.array.items;
                        try std.testing.expectEqual(@as(usize, 1), edits.len);
                        try std.testing.expectEqualStrings(" ", edits[0].object.get("text").?.string);
                    }
                    const query = actions.object.get("query").?.object;
                    try std.testing.expect(query.get("selection").?.bool);
                    try std.testing.expectEqual(@as(i64, 6), query.get("anchor").?.integer);
                    try std.testing.expectEqual(@as(i64, 2), query.get("active").?.integer);
                }
                const disabled = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.executeCodeActions" } }, .{ .json = .{ .string = uri } }, .{ .json = .{ .string = "refactor" } }, .{ .json = .{ .integer = 1 } } }, null, 5000);
                try std.testing.expectEqual(@as(usize, 0), disabled.object.get("items").?.array.items.len);
                const source_actions = try extensions.host.requestSync(scratch.allocator(), command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.executeCodeActions" } }, .{ .json = .{ .string = uri } }, .{ .json = .{ .string = "source" } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
                try std.testing.expectEqualStrings("Fixture source action", source_actions.object.get("items").?.array.items[0].object.get("title").?.string);
            }
            for (0..1000) |_| {
                if (extensions.language_features_actor.?.code_action_commands.items.len == 0) break;
                _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expectEqual(@as(usize, 0), extensions.language_features_actor.?.code_action_commands.items.len);
            original.applyConfiguration(.{ .occurrences_highlight = .off });
            try std.testing.expect(!original.saveViewState() and !modified.saveViewState());
        }

        test "Extensions: async content hovers stream through real diff panes and cancel on pointer leave" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const a = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "hover.json", .data = "{}" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = path_buffer[0..try tmp.dir.realPathFile(io, "hover.json", &path_buffer)];
            const window = try TestWindow.init(a, io, &.{path}, 120, 24);
            defer window.deinit();
            const wb = window.workbench;
            try wb.enableLanguageFeatures();
            const extensions = try Extensions.init(a, io, wb.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-diff-hover-fixture", "host/dist");
            defer extensions.deinit();
            try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "{\"word\":1}", "{\"word\":2}", "HoverOriginal", "HoverModified");
            const tab = wb.activeTab().?;
            const diff = tab.diff.?.widget;
            const HoverController = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
            const DeadlineTimer = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").DeadlineTimer;
            const original = diff.original_editor.getContribution(HoverController).?;
            const modified = diff.modified_editor.getContribution(HoverController).?;
            original.updateSettings(.{ .delay = 60, .sticky = false });
            modified.updateSettings(.{ .delay = 60, .sticky = false });
            const features = wb.language_features.?;
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                const providers = try features.hover_provider.ordered(a, diff.originalModel(), false);
                defer a.free(providers);
                if (providers.len > 2) break;
                time_compat.sleepMillis(10);
            }
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const arena = scratch.allocator();
            const command = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
            const Pump = struct {
                fn fire(timer: *DeadlineTimer) !void {
                    const due = (timer.pending orelse return error.ExpectedHoverDeadline).deadline_ms;
                    try std.testing.expect(timer.tick(due));
                }
                fn call(host: *Extensions, allocator: Allocator, id: @TypeOf(command), name: []const u8, argument: ?[]const u8) !std.json.Value {
                    var args = std.array_list.Managed(rpc.Arg).init(allocator);
                    defer args.deinit();
                    try args.append(.{ .json = .{ .string = name } });
                    if (argument) |value| try args.append(.{ .json = .{ .string = value } });
                    return host.host.requestSync(allocator, id, "$executeContributedCommand", args.items, null, 5000);
                }
                fn waitFor(host: *Extensions, allocator: Allocator, id: @TypeOf(command), name: []const u8, kind: []const u8, count: usize) !void {
                    const limit = time_compat.milliTimestamp() + 10_000;
                    while (time_compat.milliTimestamp() < limit) {
                        _ = host.pump();
                        const events = try call(host, allocator, id, "fixture.hoverState", null);
                        var matching: usize = 0;
                        for (events.array.items) |event| {
                            if (std.mem.eql(u8, event.object.get("name").?.string, name) and std.mem.eql(u8, event.object.get("kind").?.string, kind)) matching += 1;
                        }
                        if (matching >= count) return;
                        time_compat.sleepMillis(5);
                    }
                    return error.HoverFixtureDidNotSettle;
                }
                fn findAction(root: *@import("ui").Node, action: []const u8) ?*@import("ui").Node {
                    if (root.getAttribute("data-hover-verbosity")) |value| if (std.mem.eql(u8, value, action)) return root;
                    var child = root.firstChild();
                    while (child) |node| : (child = node.nextSibling()) if (findAction(node, action)) |found| return found;
                    return null;
                }
                fn waitForContent(host: *Extensions, controller: *HoverController, content: []const u8) !void {
                    const limit = time_compat.milliTimestamp() + 10_000;
                    while (time_compat.milliTimestamp() < limit) {
                        _ = host.pump();
                        if (controller.widget().getWidgetContent()) |value| if (std.mem.indexOf(u8, value, content) != null) return;
                        time_compat.sleepMillis(5);
                    }
                    return error.HoverVerbosityDidNotComplete;
                }
                fn settle(host: *Extensions, controller: *HoverController) !void {
                    const limit = time_compat.milliTimestamp() + 10_000;
                    while (time_compat.milliTimestamp() < limit) {
                        _ = host.pump();
                        if (controller.wrapper.operation.isIdle()) return;
                        time_compat.sleepMillis(5);
                    }
                    return error.HoverDidNotComplete;
                }
            };
            var mouse: @import("ui").MouseEvent = .{ .kind = .move, .x = diff.original_editor.gutterWidth() + 3, .y = 0 };
            _ = try tab.handleDiffMouse(&mouse);
            try Pump.fire(&original.operation_timer);
            try std.testing.expect(!original.isVisible());
            try Pump.waitFor(extensions, arena, command, "HoverOriginal", "start", 1);
            try Pump.fire(&original.operation_timer);
            try std.testing.expect(!original.wrapper.operation.isIdle());
            try std.testing.expect(original.isVisible()); // built-in textual fallback arrives first
            try Pump.fire(&original.loading_timer);
            try std.testing.expect(std.mem.indexOf(u8, original.widget().getWidgetContent().?, "Loading...") != null);
            try std.testing.expect((try Pump.call(extensions, arena, command, "fixture.releaseHover", "HoverOriginal")).bool);
            try Pump.settle(extensions, original);
            try std.testing.expect(std.mem.indexOf(u8, original.widget().getWidgetContent().?, "semantic HoverOriginal") != null);
            try std.testing.expect(std.mem.indexOf(u8, original.widget().getWidgetContent().?, "Loading...") == null);
            original.hideContentHover();
            _ = try tab.handleDiffMouse(&mouse);
            try Pump.fire(&original.operation_timer);
            try Pump.waitFor(extensions, arena, command, "HoverOriginal", "start", 2);
            mouse.x = diff.paneWidths().modifiedLeft() + diff.modified_editor.gutterWidth() + 3;
            _ = try tab.handleDiffMouse(&mouse);
            try std.testing.expect(original.wrapper.operation.isIdle() and !original.isVisible());
            try Pump.waitFor(extensions, arena, command, "HoverOriginal", "cancel", 1);
            try Pump.fire(&modified.operation_timer);
            try Pump.waitFor(extensions, arena, command, "HoverModified", "start", 1);
            try Pump.fire(&modified.operation_timer);
            try std.testing.expect((try Pump.call(extensions, arena, command, "fixture.releaseHover", "HoverModified")).bool);
            try Pump.settle(extensions, modified);
            try std.testing.expect(std.mem.indexOf(u8, modified.widget().getWidgetContent().?, "semantic HoverModified") != null);
            try std.testing.expect(!original.isVisible());

            // Use the actual rendered hover part's button, then repeat before
            // the extension resolves. Upstream cancels and accumulates delta.
            try diff.modified_view.paint();
            const widget = modified.widget().widget;
            const plus = Pump.findAction(widget.root.?, "increase") orelse return error.ExpectedVerbosityButton;
            var click: @import("ui").MouseEvent = .{ .kind = .click, .button = .left };
            plus.document.dispatchMouse(plus, &click);
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-start", 1);
            plus.document.dispatchMouse(plus, &click);
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-cancel", 1);
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-start", 2);
            try std.testing.expect((try Pump.call(extensions, arena, command, "fixture.releaseHover", "HoverModified")).bool);
            try Pump.waitForContent(extensions, modified, "semantic HoverModified verbosity 2");
            try std.testing.expect(modified.isFocused());
            try diff.modified_view.paint();
            const minus = Pump.findAction(widget.root.?, "decrease") orelse return error.ExpectedVerbosityButton;
            try std.testing.expect(minus.document.focus(minus));
            _ = minus.document.dispatchKey(.enter, .{});
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-start", 3);
            try std.testing.expect((try Pump.call(extensions, arena, command, "fixture.releaseHover", "HoverModified")).bool);
            try Pump.waitForContent(extensions, modified, "semantic HoverModified verbosity 2 verbosity -1");
            try std.testing.expect(!original.isVisible());
            modified.widget().updateHoverVerbosityLevel(.Increase, -1, false);
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-start", 4);
            modified.hideContentHover();
            try Pump.waitFor(extensions, arena, command, "HoverModified", "verbosity-cancel", 2);
            try std.testing.expect(!modified.isVisible());
        }

        test "Extensions: Quick Diff providers resolve virtual originals and publish source-control information asynchronously" {
            if (!build_options.e2e) return error.SkipZigTest;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const a = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "quickdiff-fixture.txt", .data = "after\nsecond\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = path_buffer[0..try tmp.dir.realPathFile(io, "quickdiff-fixture.txt", &path_buffer)];
            const window = try TestWindow.init(a, io, &.{path}, 100, 30);
            defer window.deinit();
            const wb = window.workbench;
            try wb.enableLanguageFeatures();
            const quick_diff = @import("../../contrib/scm/common/quickDiff.zig");
            const native = struct {
                fn original(_: *anyopaque, allocator: Allocator, _: std.Uri) !?quick_diff.Original {
                    const resource: std.Uri = .{ .scheme = "quickdiff-fixture", .path = .{ .raw = "/baseline #?.txt" }, .query = .{ .raw = "source=fixture#query" } };
                    const encoded = try std_uri.encodedResource(allocator, resource);
                    errdefer allocator.free(encoded);
                    return .{ .resource_uri = encoded, .ref_label = try allocator.dupe(u8, "Native baseline") };
                }
            };
            var primary: quick_diff.QuickDiffProvider = .{ .context = @constCast(&{}), .id = "fixture.primary", .label = "Native baseline", .kind = .primary, .get_original_fn = native.original };
            const registration = try wb.scm.quick_diff_api.?.addQuickDiffProvider(&primary);
            defer registration.dispose();
            const extensions = try Extensions.init(a, io, wb.extensionHostServices(), &.{.{ .path = "host/test-fixtures/quick-diff", .is_under_development = true }}, ".cache-ext/data-quickdiff-fixture", "host/dist");
            defer extensions.deinit();
            const editor = wb.activeTab().?.editor;
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < deadline) {
                _ = extensions.pump();
                _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                if (extensions.quick_diff_actor.?.providers.count() == 1 and extensions.document_content_actor.?.providers.count() == 1) break;
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqual(@as(usize, 1), extensions.quick_diff_actor.?.providers.count());
            try std.testing.expectEqual(@as(usize, 1), extensions.document_content_actor.?.providers.count());
            var reference = (try wb.scm.quick_diff_model_api.?.createQuickDiffModelReference(editor.model.uri(), .{})) orelse return error.TestExpectedQuickDiffModel;
            defer reference.dispose();
            const model = reference.object;
            const Pump = struct {
                fn settle(host: *Extensions, workbench: @TypeOf(wb), quick: *@import("../../contrib/scm/browser/quickDiffModel.zig").QuickDiffModel, expected: usize) !void {
                    const limit = time_compat.milliTimestamp() + 10_000;
                    while (time_compat.milliTimestamp() < limit) {
                        _ = host.pump();
                        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                        if (quick.quickDiffs().len == expected and quick.due_at == null and quick.provider_query == null and quick.resolving == null and quick.pending == null) return;
                        time_compat.sleepMillis(10);
                    }
                    return error.QuickDiffDidNotSettle;
                }
            };
            try Pump.settle(extensions, wb, model, 2);
            try std.testing.expectEqual(@as(usize, 2), model.all_changes.items.len);
            var baseline: ?*EditorDocument = null;
            for (model.quickDiffs()) |quick| {
                const original = model.getDiffEditorModel(quick.id) orelse return error.TestExpectedOriginalModel;
                if (baseline) |document| try std.testing.expectEqual(document, original.original_document) else baseline = original.original_document;
            }
            const original = baseline.?;
            try std.testing.expectEqualStrings("before", try original.model.borrowLineContent(1));
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const arena = scratch.allocator();
            try std.testing.expectEqualStrings("/baseline #?.txt", try std_uri.path(original.model.uri(), arena));
            try std.testing.expectEqualStrings("source=fixture#query", try std_uri.query(original.model.uri(), arena));
            const editor_uri = try std_uri.encodedResource(arena, editor.model.uri());
            const command_id = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
            const commands = struct {
                fn call(host: *Extensions, allocator: Allocator, id: @TypeOf(command_id), name: []const u8, value: ?[]const u8) !std.json.Value {
                    var args = std.array_list.Managed(rpc.Arg).init(allocator);
                    defer args.deinit();
                    try args.append(.{ .json = .{ .string = name } });
                    if (value) |argument| try args.append(.{ .json = .{ .string = argument } });
                    return host.host.requestSync(allocator, id, "$executeContributedCommand", args.items, null, 5000);
                }
            };
            const documents = try commands.call(extensions, arena, command_id, "fixture.quickDiff.documents", null);
            try std.testing.expectEqual(@as(usize, 1), documents.array.items.len);
            try std.testing.expectEqualStrings("before\nsecond\n", documents.array.items[0].object.get("text").?.string);
            _ = try commands.call(extensions, arena, command_id, "fixture.quickDiff.createInformation", editor_uri);
            const information = try commands.call(extensions, arena, command_id, "fixture.quickDiff.information", null);
            try std.testing.expectEqual(@as(i64, editor.model.getVersionId()), information.object.get("documentVersion").?.integer);
            try std.testing.expect(!information.object.get("isStale").?.bool);
            try std.testing.expectEqual(@as(usize, 1), information.object.get("changes").?.array.items.len);
            _ = try commands.call(extensions, arena, command_id, "fixture.quickDiff.update", "after\nsecond\n");
            const update_deadline = time_compat.milliTimestamp() + 10_000;
            while (time_compat.milliTimestamp() < update_deadline) {
                _ = extensions.pump();
                _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                if (std.mem.eql(u8, "after", try original.model.borrowLineContent(1))) break;
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqualStrings("after", try original.model.borrowLineContent(1));
            try Pump.settle(extensions, wb, model, 2);
            try std.testing.expectEqual(@as(usize, 0), model.all_changes.items.len);
            const updated = try commands.call(extensions, arena, command_id, "fixture.quickDiff.information", null);
            try std.testing.expectEqual(@as(usize, 0), updated.object.get("changes").?.array.items.len);
            _ = try commands.call(extensions, arena, command_id, "fixture.quickDiff.dispose", null);
            try Pump.settle(extensions, wb, model, 1);
            try std.testing.expectEqual(@as(usize, 0), extensions.quick_diff_actor.?.informations.count());
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
            try std.testing.expectEqual(@as(i64, 1), groups[0].object.get("column").?.integer);
            const tabs = groups[0].object.get("tabs").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), tabs.len);
            const comparison = tabs[1].object;
            const open_events = state.object.get("tabEvents").?.array.items;
            try std.testing.expect(for (open_events) |event| {
                if (event.object.get("opened").?.array.items.len > 0) break true;
            } else false);
            try std.testing.expect(comparison.get("active").?.bool);
            try std.testing.expect(!comparison.get("pinned").?.bool);
            const diffs = comparison.get("diffs").?.array.items;
            try std.testing.expectEqual(@as(usize, resources.len), diffs.len);
            for (diffs, resources) |wire, resource| {
                try expectFileResource(arena, resource.original.?, wire.object.get("original").?.string);
                try expectFileResource(arena, resource.modified.?, wire.object.get("modified").?.string);
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
            // Virtualized templates retain their editor contributions, not just
            // the native editor pointers. In-flight old model requests detach
            // before the same contribution is mounted on the last item.
            const first_control = multi.widget.impl.bindingFor(vm.items[0]).?.editor.?;
            const Lens = @import("../../../editor/contrib/codelens/browser/codelensController.zig").CodeLensContribution;
            const Find = @import("../../../editor/contrib/find/browser/findController.zig").FindController;
            const Word = @import("../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
            const Sticky = @import("../../../editor/contrib/stickyScroll/browser/stickyScrollController.zig").StickyScrollController;
            const Hover = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
            const first_hover = first_control.modified_editor.getContribution(Hover).?;
            const first_hover_widget = first_hover.widget();
            const Suggest = @import("../../../editor/contrib/suggest/browser/suggestController.zig").SuggestController;
            const first_suggest = first_control.modified_editor.getContribution(Suggest).?;
            const first_suggest_widget = first_suggest.widget;
            const first_lens = first_control.modified_editor.getContribution(Lens).?;
            const first_find = first_control.modified_editor.getContribution(Find).?;
            const first_word = first_control.modified_editor.getContribution(Word).?;
            const first_sticky = first_control.modified_editor.getContribution(Sticky).?;
            // A focused item intentionally remains alive outside the viewport.
            // Blur the composite before forcing viewport eviction.
            try multi.widget.setFocused(false);
            try multi.widget.impl.setScrollState(@intCast(multi.widget.impl.scroll_view.layout.scrollHeight), null);
            try std.testing.expect(multi.widget.impl.bindingFor(vm.items[0]) == null);
            const recycled = multi.widget.impl.bindingFor(last).?.editor.?;
            try std.testing.expectEqual(first_control, recycled);
            try std.testing.expectEqual(first_lens, recycled.modified_editor.getContribution(Lens).?);
            try std.testing.expectEqual(first_find, recycled.modified_editor.getContribution(Find).?);
            try std.testing.expectEqual(first_word, recycled.modified_editor.getContribution(Word).?);
            try std.testing.expectEqual(first_sticky, recycled.modified_editor.getContribution(Sticky).?);
            try std.testing.expectEqual(first_hover, recycled.modified_editor.getContribution(Hover).?);
            try std.testing.expectEqual(first_hover_widget, first_hover.widget());
            try std.testing.expectEqual(first_suggest, recycled.modified_editor.getContribution(Suggest).?);
            try std.testing.expectEqual(first_suggest_widget, first_suggest.widget);
            try std.testing.expectEqual(last.modified.model, first_suggest.editor.model);
            try std.testing.expectEqual(last.modified.model, first_hover.model);
            try std.testing.expectEqual(last.modified.model, first_lens.editor.model);
            try std.testing.expectEqual(recycled.modified_view.terminal_view_host, first_lens.view_host);
            try multi.widget.reveal(.{ .original = resources[2].original, .modified = resources[2].modified }, null);
            try multi.widget.setFocused(true);
            const control = multi.widget.activeControl() orelse return error.TestExpectedMultiDiffControl;
            control.setFocus(.original);
            try std.testing.expectEqual(control.original_editor, extensions.active.?.editor);
            control.setFocus(.modified);
            try std.testing.expectEqual(control.modified_editor, extensions.active.?.editor);
            const after = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            try std.testing.expectEqual(@as(usize, 7), after.object.get("documents").?.array.items.len);
            try expectFileResource(arena, control.modified_editor.model.uri(), after.object.get("activeDocument").?.string);
            // Exercise the main-thread move RPC, including zero-based wire
            // columns, signed append index, target-group creation, and focus
            // preservation. The real extension host must see both groups.
            const source_pane = wb.activePane().?;
            const source_id = source_pane.group.id;
            const comparison_id = try Extensions.tabId(arena, source_id, tab.input);
            const actor = &extensions.editor_tabs_actor.?;
            _ = try actor.invoke("$moveTab", &.{
                .{ .json = .{ .string = comparison_id } },
                .{ .json = .{ .integer = -1 } },
                .{ .json = .{ .integer = 1 } },
                .{ .json = .{ .bool = true } },
            }, arena);
            try std.testing.expectEqual(source_id, wb.activePane().?.group.id);
            try std.testing.expect(wb.activeTab().?.multi_diff == null);
            const ordered = try wb.part.orderedViews(arena);
            try std.testing.expectEqual(@as(usize, 2), ordered.len);
            try std.testing.expectEqual(tab, ordered[1].activeTab().?);
            for (0..32) |_| _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            const moved_state = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            const moved_groups = moved_state.object.get("groups").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), moved_groups.len);
            try std.testing.expectEqual(@as(i64, 2), moved_groups[1].object.get("column").?.integer);
            try std.testing.expect(!moved_groups[1].object.get("active").?.bool);
            const moved_id = try Extensions.tabId(arena, ordered[1].group.id, tab.input);
            _ = try actor.invoke("$moveTab", &.{
                .{ .json = .{ .string = moved_id } },
                .{ .json = .{ .integer = 0 } },
                .{ .json = .{ .integer = 0 } },
                .{ .json = .{ .bool = false } },
            }, arena);
            try std.testing.expectEqual(tab, wb.activeTab().?);
            try std.testing.expectEqual(@as(usize, 0), wb.activePane().?.group.model.indexOf(.{ .input = tab.input }).?);
            for (0..32) |_| _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            const close_result = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", &.{.{ .json = .{ .string = "fixture.closeComparison" } }}, null, 5000);
            try std.testing.expect(close_result.bool);
            for (0..32) |_| _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            const closed = try extensions.host.requestSync(arena, command_id, "$executeContributedCommand", command_args, null, 5000);
            try std.testing.expectEqual(@as(usize, 1), closed.object.get("documents").?.array.items.len);
            try std.testing.expect(for (closed.object.get("tabEvents").?.array.items) |event| {
                if (event.object.get("closed").?.array.items.len > 0) break true;
            } else false);
            // The extension's close promise must remain pending during the
            // normal dirty confirmation and report cancellation truthfully.
            const bootstrap_tab = wb.activeTab().?;
            try bootstrap_tab.editor.insertText("dirty");
            const CloseResult = struct {
                resolved: bool = false,
                closed: bool = false,
                fn complete(context: *anyopaque, reply: rpc.Reply) void {
                    const result: *@This() = @ptrCast(@alignCast(context));
                    result.resolved = true;
                    result.closed = reply == .json and reply.json == .bool and reply.json.bool;
                }
            };
            for ([_]usize{ 2, 1 }) |choice| {
                var result: CloseResult = .{};
                _ = try extensions.host.call(command_id, "$executeContributedCommand", &.{
                    .{ .json = .{ .string = "fixture.closeNamedTab" } },
                    .{ .json = .{ .string = "bootstrap.json" } },
                }, null, .{ .context = &result, .callback = CloseResult.complete });
                const confirm_deadline = time_compat.milliTimestamp() + 5000;
                while (!wb.dialog_service.hasDialog() and !result.resolved and time_compat.milliTimestamp() < confirm_deadline) {
                    _ = extensions.pump();
                    time_compat.sleepMillis(5);
                }
                try std.testing.expect(wb.dialog_service.hasDialog());
                try std.testing.expect(!result.resolved);
                try std.testing.expectEqual(bootstrap_tab, wb.activeTab().?);
                wb.dialog_service.model.close(choice);
                const reply_deadline = time_compat.milliTimestamp() + 5000;
                while (!result.resolved and time_compat.milliTimestamp() < reply_deadline) {
                    _ = extensions.pump();
                    time_compat.sleepMillis(5);
                }
                try std.testing.expect(result.resolved);
                try std.testing.expectEqual(choice == 1, result.closed);
                if (choice == 2) try std.testing.expectEqual(bootstrap_tab, wb.activeTab().?);
            }
            try std.testing.expect(wb.activeTab() == null);
        }

        test "Extensions: real Zig extension starts ZLS and provides hover" {
            if (!build_options.e2e) return error.SkipZigTest;
            // Explicit opt-in keeps ordinary CI independent of a developer's
            // installed Zig/ZLS binaries and avoids installer network access.
            const extension_path = std.mem.span(std.c.getenv("VSCODE_T_ZIG_EXTENSION") orelse return error.SkipZigTest);
            const zig_path = std.mem.span(std.c.getenv("VSCODE_T_ZIG_PATH") orelse return error.SkipZigTest);
            const zls_path = std.mem.span(std.c.getenv("VSCODE_T_ZLS_PATH") orelse return error.SkipZigTest);
            try verifyRealZig(extension_path, zig_path, zls_path, false);
            try verifyRealZig(extension_path, zig_path, zls_path, true);
        }

        // This is deliberately separate from the synthetic LSP matrix: it
        // opens the actual checkout, build.zig and real editor implementation.
        test "Extensions: real Zig extension works on this repository" {
            if (!build_options.e2e) return error.SkipZigTest;
            const extension_path = std.mem.span(std.c.getenv("VSCODE_T_ZIG_EXTENSION") orelse return error.SkipZigTest);
            const zig_path = std.mem.span(std.c.getenv("VSCODE_T_ZIG_PATH") orelse return error.SkipZigTest);
            const zls_path = std.mem.span(std.c.getenv("VSCODE_T_ZLS_PATH") orelse return error.SkipZigTest);
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const repo = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
            try std.Io.Dir.cwd().access(io, "build.zig", .{});
            try std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{});
            const source_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "src/vs/editor/common/core/range.zig", a);
            const definition_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "src/vs/editor/common/core/position.zig", a);
            const theme_root = try std.Io.Dir.cwd().realPathFileAlloc(io, "vscode/extensions/theme-defaults", a);
            const original_source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, a, .limited(1024 * 1024));
            const original_definition = try std.Io.Dir.cwd().readFileAlloc(io, definition_path, a, .limited(1024 * 1024));

            // Store settings and extension data outside the checked-in files.
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const data_path = try tmp.dir.realPathFileAlloc(io, ".", a);
            const settings_path = try std.fs.path.join(a, &.{ data_path, "settings.json" });
            const settings = try std.json.Stringify.valueAlloc(a, .{
                .@"zig.path" = zig_path,
                .@"zig.zls.path" = zls_path,
                .@"zig.zls.enabled" = "on",
                .@"zig.zls.trace.server" = "verbose",
                .@"workbench.colorTheme" = "Dark 2026",
            }, .{});
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = settings });
            var catalog = try @import("../../services/extensions/common/extensionsRegistry.zig").scan(allocator, &.{extension_path});
            defer catalog.deinit();
            const window = try TestWindow.initWithOptions(allocator, io, &.{}, 100, 30, .{ .initial_user_settings_paths = &.{settings_path} }, null);
            defer window.deinit();
            const workbench = window.workbench;
            workbench.setDeclarativeExtensions(&catalog);
            try workbench.registerThemeSources(&.{.{ .root = theme_root, .id = "Dark 2026", .settings_id = "Dark 2026", .label = "Dark 2026", .ui_theme = "vs-dark", .path = "themes/2026-dark.json" }});
            workbench.applyThemeSettings();
            try workbench.setWorkspaceFolders(&.{repo});
            try workbench.openPath(source_path);
            try workbench.enableLanguageFeatures();
            const editor = workbench.activeTab().?.editor;
            const model = editor.model;
            try std.testing.expectEqualStrings("zig", model.getLanguageId());
            const fields = try repositorySourcePosition(model, "startLineNumber: usize");
            const type_offset = fields.column - 1 + "startLineNumber: ".len;
            const registry = @import("../../../editor/common/tokenizationRegistry.zig").TokenizationRegistry;
            model.forceTokenization(fields.lineNumber);
            var lexical_tokens = try model.tokenization().getLineTokens(fields.lineNumber);
            defer lexical_tokens.deinit();
            const lexical_color = registry.instance.getColorForToken(lexical_tokens.getForeground(lexical_tokens.findTokenIndexAtOffset(type_offset))) orelse return error.RepositoryLexicalColorMissing;
            const call = try repositorySourcePosition(model, "Position.init(self.startLineNumber");
            const method = Position.init(call.lineNumber, call.column + "Position.".len + 1);
            const range_declaration = try repositorySourcePosition(model, "pub const Range = struct");
            const literal_call = try repositorySourcePosition(model, "Range.init(1, 2, 1, 3)");
            const extension_host = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = extension_path }}, data_path, "host/dist");
            defer extension_host.deinit();
            const features = workbench.language_features.?;

            const deadline = time_compat.milliTimestamp() + 60_000;
            while ((!model.hasCompleteSemanticTokens() or !features.hover_provider.has(model) or !features.completion_provider.has(model)) and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(20);
            }
            try std.testing.expect(extension_host.activated);
            try std.testing.expect(model.hasCompleteSemanticTokens() and model.hasSomeSemanticTokens());
            // Use the real default theme, not an all-token fixture override.
            model.forceTokenization(fields.lineNumber);
            var tokens = try model.tokenization().getLineTokens(fields.lineNumber);
            defer tokens.deinit();
            const type_color = @import("../../../editor/common/tokenizationRegistry.zig").TokenizationRegistry.instance.getColorForToken(tokens.getForeground(tokens.findTokenIndexAtOffset(type_offset))) orelse return error.RepositorySemanticColorMissing;
            try std.testing.expectEqual(@as(u8, 0x4e), type_color.r);
            try std.testing.expectEqual(@as(u8, 0xc9), type_color.g);
            try std.testing.expectEqual(@as(u8, 0xb0), type_color.b);
            try std.testing.expect(lexical_color.r != type_color.r or lexical_color.g != type_color.g or lexical_color.b != type_color.b);
            // Exercise the native editor DOM/layout/paint path, not just
            // the semantic store. At least one actual `usize` must use the
            // semantic foreground in the rendered terminal cell grid.
            try editor.setCursorPosition(fields);
            const watermark = @import("../../browser/parts/editor/editorGroupWatermark.zig");
            const surface = workbench.editor_surface;
            try workbench.part.layoutEditorArea(surface, false, watermark.Colors.fromTheme(workbench.theme_palette), workbench.watermarkShortcuts());
            try workbench.activeTab().?.view.paint();
            try surface.paintFrame();
            const grid = surface.grid();
            const wanted = ui.cell.packColor(.{ .r = type_color.r, .g = type_color.g, .b = type_color.b });
            var painted_type = false;
            const glyphs = [_]u32{ 'u', 's', 'i', 'z', 'e' };
            for (0..grid.rows) |row| for (0..grid.cols -| (glyphs.len - 1)) |col| {
                const index = grid.index(col, row);
                if (std.mem.eql(u32, grid.cluster[index..][0..glyphs.len], &glyphs)) {
                    var matched = true;
                    for (grid.fg[index..][0..glyphs.len]) |color| if (color != wanted) {
                        matched = false;
                        break;
                    };
                    painted_type = painted_type or matched;
                }
            };
            try std.testing.expect(painted_type);

            const HoverController = @import("../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
            try editor.setCursorPosition(method);
            try workbench.commands.execute("editor.action.showHover");
            const hover = editor.getInstantiatedContribution(HoverController).?;
            var hover_found = false;
            const hover_deadline = time_compat.milliTimestamp() + 10000;
            while (!hover_found and time_compat.milliTimestamp() < hover_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (0..12) |i| if (hover.wrapper.getAccessibleWidgetContentAtIndex(@intCast(i))) |content| {
                    hover_found = hover_found or (std.mem.indexOf(u8, content, "fn init") != null and std.mem.indexOf(u8, content, "Position") != null);
                };
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(hover_found and hover.isVisible());
            hover.hideContentHover();

            const Probe = struct {
                completion: ?bool = null,
                symbol: ?bool = null,
                fn completions(context: *anyopaque, _: *anyopaque, result: anyerror!@import("../../../editor/common/languages/completion.zig").CompletionList) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.completion = false;
                    if (result) |list| {
                        for (list.items) |item| if (std.mem.eql(u8, item.label, "init")) {
                            self.completion = true;
                            break;
                        };
                    } else |_| {}
                }
                fn symbols(context: *anyopaque, result: []const @import("../../../editor/common/languages.zig").DocumentSymbol) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.symbol = false;
                    for (result) |symbol| if (std.mem.eql(u8, symbol.name, "Range")) {
                        self.symbol = true;
                        break;
                    };
                }
            };
            var probe: Probe = .{};
            const completion_providers = try features.completion_provider.ordered(a, model, false);
            var completion: ?@import("../../../editor/common/languages/completion.zig").CompletionRequest = null;
            for (completion_providers) |provider| if (provider.provide_completion_items_deferred) |request| {
                completion = try request(provider.context, a, model, Position.init(call.lineNumber, call.column + "Position.ini".len), .{}, .None);
                if (completion != null) break;
            };
            const completion_request = completion orelse return error.RepositoryCompletionMissing;
            defer completion_request.cancel(completion_request.context);
            completion_request.on_complete(completion_request.context, &probe, Probe.completions);
            const symbols = try features.document_symbol_provider.ordered(a, model, false);
            const symbol_provider = symbols[0];
            const symbol_request = (try symbol_provider.request_document_symbols.?(symbol_provider.context, a, model, .{ .context = &probe, .complete = Probe.symbols })).?;
            defer if (probe.symbol == null) symbol_request.dispose();
            const probe_deadline = time_compat.milliTimestamp() + 10000;
            while ((probe.completion == null or probe.symbol == null) and time_compat.milliTimestamp() < probe_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(probe.completion orelse false);
            try std.testing.expect(probe.symbol orelse false);

            try editor.setCursorPosition(method);
            try editor.growSelection(true);
            const selection_deadline = time_compat.milliTimestamp() + 5000;
            while (editor.smart_select.pending != null and time_compat.milliTimestamp() < selection_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            const selections = try editor.getModelSelections();
            defer allocator.free(selections);
            try std.testing.expect(!selections[0].isEmpty());
            try std.testing.expect(editor.folding.regionStartingAt(range_declaration.lineNumber) != null);

            try editor.setCursorPosition(Position.init(literal_call.lineNumber, literal_call.column + "Range.init(1,".len));
            try workbench.commands.execute("editor.action.triggerParameterHints");
            const ParameterHintsController = @import("../../../editor/contrib/parameterHints/browser/parameterHints.zig").ParameterHintsController;
            const hints = editor.getInstantiatedContribution(ParameterHintsController).?;
            const InlayController = @import("../../../editor/contrib/inlayHints/browser/inlayHintsController.zig").InlayHintsController;
            const inlay = editor.getInstantiatedContribution(InlayController).?;
            const hints_deadline = time_compat.milliTimestamp() + 10000;
            var literal_inlay = false;
            while ((hints.model.hints() == null or !literal_inlay) and time_compat.milliTimestamp() < hints_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (inlay.parts) |part| if (part.item.anchor.range.startLineNumber == literal_call.lineNumber) {
                    literal_inlay = true;
                    break;
                };
                time_compat.sleepMillis(10);
            }
            const signature = hints.model.hints() orelse return error.RepositorySignatureMissing;
            try std.testing.expect(std.mem.indexOf(u8, signature.signatures[0].label, "startLineNumber") != null);
            try std.testing.expect(literal_inlay);
            try workbench.commands.execute("closeParameterHints");

            // Real workspace symbol search must find the checked-in Range
            // method, not a symbol in the synthetic fixture.
            try workbench.commands.execute("workbench.action.showAllSymbols");
            const picker = workbench.quick_access.controller.pickerRef();
            try picker.setValue("#strictContainsRange");
            const workspace_deadline = time_compat.milliTimestamp() + 60_000;
            var symbol_found = false;
            while (!symbol_found and time_compat.milliTimestamp() < workspace_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (picker.items.items, 0..) |item, index| if (item == .item and std.mem.eql(u8, item.item.label, "strictContainsRange")) {
                    picker.setActiveIndex(index);
                    symbol_found = true;
                    break;
                };
                time_compat.sleepMillis(20);
            }
            try std.testing.expect(symbol_found);
            picker.accept();
            try std.testing.expect(!workbench.quick_access.isOpen());
            const selected_path = try std_uri.fsPath(workbench.activeTab().?.editor.model.uri(), a);
            try std.testing.expectEqualStrings(source_path, try std.Io.Dir.cwd().realPathFileAlloc(io, selected_path, a));
            const strict_contains = try repositorySourcePosition(model, "pub fn strictContainsRange(");
            try std.testing.expectEqual(strict_contains.lineNumber, editor.modelCursorPosition().lineNumber);

            // Exercise prepareRename against an actual local symbol and
            // cancel the input so no repo source is changed.
            const parameter = try repositorySourcePosition(model, "otherRange: *const Range");
            try editor.setCursorPosition(Position.init(parameter.lineNumber, parameter.column + 1));
            try workbench.commands.execute("editor.action.rename");
            const RenameController = @import("../../../editor/contrib/rename/browser/rename.zig").RenameController;
            const rename = editor.getInstantiatedContribution(RenameController).?;
            const rename_deadline = time_compat.milliTimestamp() + 10000;
            while (!rename.widget.visible and time_compat.milliTimestamp() < rename_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(rename.widget.visible);
            try std.testing.expectEqualStrings("otherRange", rename.widget.input.getValue());
            try workbench.commands.execute("cancelRenameInput");
            try std.testing.expect(!rename.widget.visible);

            // Navigate from the real Range implementation into its imported
            // Position definition; this requires real cross-file resolution.
            try editor.setCursorPosition(method);
            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.revealDefinition"));
            try waitNavigation(workbench);
            const opened = workbench.activeTab().?.editor;
            const actual_path = try std_uri.fsPath(opened.model.uri(), a);
            try std.testing.expectEqualStrings(definition_path, try std.Io.Dir.cwd().realPathFileAlloc(io, actual_path, a));
            const definition = try repositorySourcePosition(opened.model, "pub fn init(line:");
            try std.testing.expectEqual(definition.lineNumber, opened.modelCursorPosition().lineNumber);

            // The reported real-world crash used wakeSignal.zig while ZLS
            // updated semantic tokens and inlay hints. Mount and paint before
            // those requests complete, then keep painting the retained view
            // as callbacks arrive and change wrapping/visible rows.
            const wake_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "src/tui/wakeSignal.zig", a);
            const original_wake = try std.Io.Dir.cwd().readFileAlloc(io, wake_path, a, .limited(1024 * 1024));
            try workbench.openPath(wake_path);
            const wake_editor = workbench.activeTab().?.editor;
            const wake_model = wake_editor.model;
            wake_editor.setWordWrapOptions(.word_wrap_column, 50, .Same, false);
            try wake_editor.setCursorPosition(Position.init(18, 1));
            try paintRepositoryEditor(workbench);
            const wake_inlay = wake_editor.getInstantiatedContribution(InlayController).?;
            const wake_deadline = time_compat.milliTimestamp() + 15000;
            while ((!wake_model.hasCompleteSemanticTokens() or wake_inlay.active == null) and time_compat.milliTimestamp() < wake_deadline) {
                if (workbench.window_events.dispatch(time_compat.milliTimestamp())) try paintRepositoryEditor(workbench);
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(wake_model.hasCompleteSemanticTokens() and wake_model.hasSomeSemanticTokens());
            try std.testing.expect(wake_inlay.active != null);
            for (0..24) |step| {
                _ = wake_editor.scrollViewLines(if (step % 8 < 4) 3 else -3);
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                try paintRepositoryEditor(workbench);
            }
            workbench.editor_surface.box_tree.markFullRebuild();
            try paintRepositoryEditor(workbench);

            // Neither navigation nor the provider requests may write to disk.
            try std.testing.expectEqualStrings(original_source, try std.Io.Dir.cwd().readFileAlloc(io, source_path, a, .limited(1024 * 1024)));
            try std.testing.expectEqualStrings(original_definition, try std.Io.Dir.cwd().readFileAlloc(io, definition_path, a, .limited(1024 * 1024)));
            try std.testing.expectEqualStrings(original_wake, try std.Io.Dir.cwd().readFileAlloc(io, wake_path, a, .limited(1024 * 1024)));
        }

        fn paintRepositoryEditor(workbench: *terminal_window_type) !void {
            const watermark = @import("../../browser/parts/editor/editorGroupWatermark.zig");
            const surface = workbench.editor_surface;
            const tab = workbench.activeTab().?;
            try tab.view.refresh();
            try workbench.part.layoutEditorArea(surface, false, watermark.Colors.fromTheme(workbench.theme_palette), workbench.watermarkShortcuts());
            try tab.view.paint();
            try surface.paintFrame();
        }

        fn repositorySourcePosition(model: *TextModel, needle: []const u8) !Position {
            for (1..model.getLineCount() + 1) |line| {
                if (std.mem.indexOf(u8, try model.borrowLineContent(line), needle)) |offset| return Position.init(line, offset + 1);
            }
            return error.RepositorySourceAnchorMissing;
        }

        fn verifyRealZig(extension_path: []const u8, zig_path: []const u8, zls_path: []const u8, workspace_activation: bool) !void {
            const io = time_compat.io;
            const allocator = std.testing.allocator;
            try std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{});
            try std.Io.Dir.cwd().access(io, zig_path, .{});
            try std.Io.Dir.cwd().access(io, zls_path, .{});
            // ZLS excludes all hidden/zig-cache path components from workspace
            // symbol indexing. std.testing.tmpDir lives under .zig-cache, so
            // use a normal directory in the platform's temporary directory.
            const temp_root = if (std.c.getenv("TMPDIR") orelse std.c.getenv("TEMP") orelse std.c.getenv("TMP")) |value| std.mem.span(value) else if (@import("builtin").os.tag == .windows) return error.TempDirectoryUnavailable else "/tmp";
            const parent = try std.Io.Dir.openDirAbsolute(io, temp_root, .{});
            defer parent.close(io);
            var random: [12]u8 = undefined;
            io.random(&random);
            const name = std.fmt.bytesToHex(random, .lower);
            const directory = try parent.createDirPathOpen(io, &name, .{});
            defer parent.deleteTree(io, &name) catch {};
            defer directory.close(io);
            const root = try directory.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(root);
            const settings = try std.json.Stringify.valueAlloc(allocator, .{
                .@"zig.path" = zig_path,
                .@"zig.zls.path" = zls_path,
                .@"zig.zls.enabled" = "on",
                .@"zig.zls.trace.server" = "verbose",
                .@"editor.semanticHighlighting.enabled" = true,
                .@"workbench.colorTheme" = "LSP Semantic Fixture",
            }, .{});
            defer allocator.free(settings);
            try directory.writeFile(io, .{ .sub_path = "settings.json", .data = settings });
            try directory.writeFile(io, .{ .sub_path = "theme.json", .data = "{\"semanticHighlighting\":true,\"colors\":{\"editor.background\":\"#1e1e1e\",\"editor.foreground\":\"#cccccc\"},\"semanticTokenColors\":{\"*\":{\"foreground\":\"#12ab34\",\"bold\":true}}}" });
            const settings_path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
            defer allocator.free(settings_path);
            try directory.writeFile(io, .{ .sub_path = "sample.zig", .data = "/// Returns the answer.\npub fn answer() u32 { return 42; }\npub fn example() u32 { return answer(); }\npub fn multiline() void {\n    const x = 1;\n    _ = x;\n}\npub fn add(value: u32, other: u32) u32 { return value + other; }\npub fn callAdd() u32 { return add(1, 2); }\npub const Thing = struct { value: u32 };\npub fn makeThing() Thing { return .{ .value = 1 }; }\npub fn useThing() u32 { const t = makeThing(); return t.value; }\n" });
            const document_path = try std.fs.path.join(allocator, &.{ root, "sample.zig" });
            defer allocator.free(document_path);
            var catalog = try @import("../../services/extensions/common/extensionsRegistry.zig").scan(allocator, &.{extension_path});
            defer catalog.deinit();
            const window = try TestWindow.initWithOptions(allocator, io, &.{}, 100, 30, .{ .initial_user_settings_paths = &.{settings_path} }, null);
            defer window.deinit();
            const workbench = window.workbench;
            workbench.setDeclarativeExtensions(&catalog);
            if (workspace_activation) {
                try directory.writeFile(io, .{ .sub_path = "build.zig", .data = "const std = @import(\"std\");\npub fn build(b: *std.Build) void { _ = b; }\n" });
                try workbench.setWorkspaceFolders(&.{root});
            } else {
                try workbench.openPath(document_path);
            }
            try workbench.enableLanguageFeatures();
            try workbench.registerThemeSources(&.{.{ .root = root, .id = "LSP Semantic Fixture", .settings_id = "LSP Semantic Fixture", .label = "LSP Semantic Fixture", .ui_theme = "vs-dark", .path = "theme.json" }});
            workbench.applyThemeSettings();
            const extension_host = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = extension_path }}, if (workspace_activation) ".cache-ext/data-zig-workspace-test" else ".cache-ext/data-zig-test", "host/dist");
            defer extension_host.deinit();
            try std.testing.expectEqualStrings("ziglang.vscode-zig", extension_host.descriptions[0].identifier);
            if (workspace_activation) {
                // No document is open: activation must come from the pinned
                // host's workspaceContains:build.zig path, not onLanguage.
                const activation_deadline = time_compat.milliTimestamp() + 30_000;
                while (!extension_host.activated and time_compat.milliTimestamp() < activation_deadline) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    time_compat.sleepMillis(20);
                }
                try std.testing.expect(extension_host.activated);
                try workbench.openPath(document_path);
            }
            const model = workbench.activeTab().?.editor.model;
            try std.testing.expectEqualStrings("zig", model.getLanguageId());
            const features = workbench.language_features.?;
            const token = @import("../../../base/common/cancellation.zig").CancellationToken.None;
            const deadline = time_compat.milliTimestamp() + 30_000;
            var hover_received = false;
            var edited_document = false;
            while (time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                const statuses = try workbench.language_status.getLanguageStatus(allocator, model);
                defer allocator.free(statuses);
                var zig_status = false;
                var zls_status = false;
                for (statuses) |status| {
                    zig_status = zig_status or std.mem.endsWith(u8, status.id, "/zig.status");
                    zls_status = zls_status or std.mem.endsWith(u8, status.id, "/zig.zls.status");
                }
                if (hover_received and zig_status and zls_status) {
                    if (!edited_document) {
                        // A second, changed doc comment must be reflected by
                        // ZLS rather than by a native textual hover fallback.
                        const editor = workbench.activeTab().?.editor;
                        try editor.setCursorPosition(Position.init(1, model.getLineMaxColumn(1)));
                        try editor.insertText(" Updated by the editor.");
                        edited_document = true;
                        hover_received = false;
                    } else {
                        try std.testing.expect(workbench.statusbar.model().findEntry("status.languageStatus") != null);
                        // Invoke the real extension's output command, not a
                        // workbench-only log viewer shortcut.
                        try workbench.commands.execute("zig.zls.openOutput");
                        const output_id = @import("../../services/output/common/output.zig").OUTPUT_VIEW_ID;
                        const output_deadline = time_compat.milliTimestamp() + 5_000;
                        while (time_compat.milliTimestamp() < output_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            if (workbench.output_service.active) |channel| {
                                if (workbench.views_api.isViewVisible(output_id) and
                                    std.mem.endsWith(u8, channel.descriptor.id, ".ZLS language server.log") and
                                    std.mem.indexOf(u8, channel.model.content, "Received response 'initialize") != null) break;
                            }
                            time_compat.sleepMillis(20);
                        }
                        try std.testing.expect(workbench.views_api.isViewVisible(output_id));
                        const output_channel = workbench.output_service.active orelse return error.ZlsOutputNotReceived;
                        try std.testing.expect(std.mem.endsWith(u8, output_channel.descriptor.id, ".ZLS language server.log"));
                        try std.testing.expect(std.mem.indexOf(u8, output_channel.model.content, "Received response 'initialize") != null);
                        try workbench.views_api.closeView(output_id);
                        try std.testing.expect(!workbench.views_api.isViewVisible(output_id));
                        if (workspace_activation) {
                            try workbench.commands.execute("workbench.action.showAllSymbols");
                            const picker = workbench.quick_access.controller.pickerRef();
                            try picker.setValue("#answer");
                            const symbols_deadline = time_compat.milliTimestamp() + 30_000;
                            var found = false;
                            while (time_compat.milliTimestamp() < symbols_deadline) {
                                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                                for (picker.items.items, 0..) |item, index| {
                                    if (item == .item and std.mem.eql(u8, item.item.label, "answer")) {
                                        picker.setActiveIndex(index);
                                        found = true;
                                        break;
                                    }
                                }
                                if (found) break;
                                time_compat.sleepMillis(20);
                            }
                            try std.testing.expect(found);
                            picker.accept();
                            try std.testing.expect(!workbench.quick_access.isOpen());
                            try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
                        }
                        const selection_editor = workbench.activeTab().?.editor;
                        for ([_][]const u8{ "editor.action.revealDefinition", "editor.action.revealDeclaration" }) |command| {
                            try selection_editor.setCursorPosition(Position.init(3, 32));
                            try std.testing.expect(runLspCommand(workbench.extensionHostServices(), command));
                            try waitNavigation(workbench);
                            try std.testing.expectEqual(@as(usize, 2), selection_editor.modelCursorPosition().lineNumber);
                        }
                        const type_column = (std.mem.indexOf(u8, try model.borrowLineContent(12), "t.value") orelse return error.ZlsTypeFixtureMissing) + 1;
                        try selection_editor.setCursorPosition(Position.init(12, type_column));
                        try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToTypeDefinition"));
                        try waitNavigation(workbench);
                        try std.testing.expectEqual(@as(usize, 10), selection_editor.modelCursorPosition().lineNumber);
                        // VS Code's compact reference search excludes the declaration
                        // when there is just one use; start from the declaration.
                        try selection_editor.setCursorPosition(Position.init(2, 9));
                        try std.testing.expect(runLspCommand(workbench.extensionHostServices(), "editor.action.goToReferences"));
                        try waitNavigation(workbench);
                        if (workbench.quick_access.isOpen()) {
                            workbench.quick_access.inputService().hide();
                        } else {
                            try std.testing.expectEqual(@as(usize, 3), selection_editor.modelCursorPosition().lineNumber);
                        }
                        // Query the actual extension providers, not the lexical
                        // fallback or an independently launched ZLS process.
                        const RealProviderProbe = struct {
                            completion_found: ?bool = null,
                            symbol_found: ?bool = null,
                            highlight_count: ?usize = null,
                            fn completions(context: *anyopaque, _: *anyopaque, result: anyerror!@import("../../../editor/common/languages/completion.zig").CompletionList) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                self.completion_found = false;
                                if (result) |list| {
                                    for (list.items) |item| if (std.mem.eql(u8, item.label, "answer")) {
                                        self.completion_found = true;
                                        break;
                                    };
                                } else |_| {}
                            }
                            fn symbols(context: *anyopaque, result: []const @import("../../../editor/common/languages.zig").DocumentSymbol) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                self.symbol_found = false;
                                for (result) |symbol| if (std.mem.eql(u8, symbol.name, "answer")) {
                                    self.symbol_found = true;
                                    break;
                                };
                            }
                            fn highlights(context: *anyopaque, result: anyerror!?[]const @import("../../../editor/common/languages.zig").DocumentHighlight) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                self.highlight_count = if (result) |value| if (value) |items| items.len else 0 else |_| 0;
                            }
                        };
                        var probe_arena = std.heap.ArenaAllocator.init(allocator);
                        defer probe_arena.deinit();
                        const probe_allocator = probe_arena.allocator();
                        var probe: RealProviderProbe = .{};
                        const completion_providers = try features.completion_provider.ordered(probe_allocator, model, false);
                        var completion: ?@import("../../../editor/common/languages/completion.zig").CompletionRequest = null;
                        for (completion_providers) |provider| if (provider.provide_completion_items_deferred) |request| {
                            completion = try request(provider.context, probe_allocator, model, Position.init(3, 34), .{}, .None);
                            if (completion != null) break;
                        };
                        const completion_request = completion orelse return error.ZlsCompletionProviderMissing;
                        defer completion_request.cancel(completion_request.context);
                        completion_request.on_complete(completion_request.context, &probe, RealProviderProbe.completions);
                        const symbol_providers = try features.document_symbol_provider.ordered(probe_allocator, model, false);
                        const symbol_provider = symbol_providers[0];
                        const symbol_request = (try symbol_provider.request_document_symbols.?(symbol_provider.context, probe_allocator, model, .{ .context = &probe, .complete = RealProviderProbe.symbols })).?;
                        defer if (probe.symbol_found == null) symbol_request.dispose();
                        const highlight_providers = try features.document_highlight_provider.ordered(probe_allocator, model, false);
                        var highlight_request: ?@import("../../../base/common/lifecycle.zig").IDisposable = null;
                        for (highlight_providers) |provider| if (provider.request_document_highlights) |request| {
                            highlight_request = try request(provider.context, probe_allocator, model, Position.init(3, 32), .None, .{ .context = &probe, .complete = RealProviderProbe.highlights });
                            if (highlight_request != null) break;
                        };
                        defer if (probe.highlight_count == null) if (highlight_request) |request| request.dispose();
                        const probe_deadline = time_compat.milliTimestamp() + 5000;
                        while ((probe.completion_found == null or probe.symbol_found == null or probe.highlight_count == null) and time_compat.milliTimestamp() < probe_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(probe.completion_found orelse false);
                        try std.testing.expect(probe.symbol_found orelse false);
                        try std.testing.expect((probe.highlight_count orelse 0) >= 2);
                        const RangeSemanticProbe = struct {
                            ready: bool = false,
                            has_tokens: bool = false,
                            fn complete(context: *anyopaque, value: anyerror!?@import("../../../editor/common/languages.zig").SemanticTokensResult) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                self.ready = true;
                                if (value) |response| {
                                    if (response) |result| self.has_tokens = result.payload == .full and result.payload.full.len >= 5;
                                } else |_| {}
                            }
                        };
                        var range_semantic: RangeSemanticProbe = .{};
                        const range_providers = try features.document_range_semantic_tokens_provider.ordered(probe_allocator, model, false);
                        try std.testing.expect(range_providers.len > 0);
                        const range_provider = range_providers[0];
                        const range_request = try range_provider.request_document_range_semantic_tokens(range_provider.context, probe_allocator, model, Range.init(2, 1, 3, model.getLineMaxColumn(3)), .{ .context = &range_semantic, .complete = RangeSemanticProbe.complete });
                        const range_deadline = time_compat.milliTimestamp() + 5000;
                        while (!range_semantic.ready and time_compat.milliTimestamp() < range_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        if (!range_semantic.ready) range_request.dispose();
                        try std.testing.expect(range_semantic.ready and range_semantic.has_tokens);
                        try selection_editor.setCursorPosition(Position.init(3, 32));
                        try selection_editor.growSelection(true);
                        try std.testing.expect(selection_editor.smart_select.pending != null);
                        const selection_deadline = time_compat.milliTimestamp() + 5000;
                        while (selection_editor.smart_select.pending != null and time_compat.milliTimestamp() < selection_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(selection_editor.smart_select.pending == null);
                        const selection = try selection_editor.getModelSelections();
                        defer allocator.free(selection);
                        try std.testing.expect(!selection[0].isEmpty());
                        const folding_deadline = time_compat.milliTimestamp() + 5000;
                        while (selection_editor.folding.regionStartingAt(4) == null and time_compat.milliTimestamp() < folding_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(selection_editor.folding.regionStartingAt(4) != null);
                        const ParameterHintsController = @import("../../../editor/contrib/parameterHints/browser/parameterHints.zig").ParameterHintsController;
                        try selection_editor.setCursorPosition(Position.init(9, 35));
                        try workbench.commands.execute("editor.action.triggerParameterHints");
                        const hints = selection_editor.getInstantiatedContribution(ParameterHintsController).?;
                        const hints_deadline = time_compat.milliTimestamp() + 5000;
                        while (hints.model.hints() == null and time_compat.milliTimestamp() < hints_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        const signature_help = hints.model.hints() orelse return error.ZlsSignatureHelpUnavailable;
                        try std.testing.expect(std.mem.indexOf(u8, signature_help.signatures[0].label, "value") != null);
                        try std.testing.expect(selection_editor.parameter_hints_visible);
                        try workbench.commands.execute("closeParameterHints");
                        const InlayHintsController = @import("../../../editor/contrib/inlayHints/browser/inlayHintsController.zig").InlayHintsController;
                        const inlay_controller = selection_editor.getInstantiatedContribution(InlayHintsController).?;
                        const zls_inlay_deadline = time_compat.milliTimestamp() + 5000;
                        while (inlay_controller.parts.len == 0 and time_compat.milliTimestamp() < zls_inlay_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(inlay_controller.parts.len > 0);
                        const semantic_deadline = time_compat.milliTimestamp() + 5000;
                        while (!model.hasCompleteSemanticTokens() and time_compat.milliTimestamp() < semantic_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(model.hasCompleteSemanticTokens());
                        try std.testing.expect(model.hasSomeSemanticTokens());
                        var semantic_line = try model.tokenization().getLineTokens(8);
                        defer semantic_line.deinit();
                        const registry = @import("../../../editor/common/tokenizationRegistry.zig").TokenizationRegistry;
                        var color_found = false;
                        for (0..semantic_line.getCount()) |i| {
                            const metadata = semantic_line.getMetadata(i);
                            if (registry.instance.getColorForToken(metadata.foreground)) |color| {
                                if (metadata.fontStyle.bold and color.r == 0x12 and color.g == 0xab and color.b == 0x34) color_found = true;
                            }
                        }
                        try std.testing.expect(color_found);
                        const RenameController = @import("../../../editor/contrib/rename/browser/rename.zig").RenameController;
                        try selection_editor.setCursorPosition(Position.init(8, 9));
                        try workbench.commands.execute("editor.action.rename");
                        const rename_controller = selection_editor.getInstantiatedContribution(RenameController).?;
                        const rename_deadline = time_compat.milliTimestamp() + 5000;
                        while (!rename_controller.widget.visible and time_compat.milliTimestamp() < rename_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(rename_controller.widget.visible);
                        try std.testing.expectEqualStrings("add", rename_controller.widget.input.getValue());
                        try rename_controller.widget.input.setValue("sumValues");
                        try workbench.commands.execute("acceptRenameInput");
                        const rename_edit_deadline = time_compat.milliTimestamp() + 5000;
                        while (rename_controller.state != .idle and time_compat.milliTimestamp() < rename_edit_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(std.mem.indexOf(u8, try model.borrowLineContent(8), "fn sumValues(") != null);
                        try std.testing.expect(std.mem.indexOf(u8, try model.borrowLineContent(9), "return sumValues(") != null);
                        // The real server's formatting response must be applied
                        // before the save lifecycle writes the renamed document.
                        try selection_editor.formatDocument();
                        const format_deadline = time_compat.milliTimestamp() + 5000;
                        while (std.mem.indexOf(u8, try model.borrowLineContent(2), "return 42") != null and time_compat.milliTimestamp() < format_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expectEqualStrings("pub fn answer() u32 {", try model.borrowLineContent(2));
                        try workbench.commands.execute("workbench.action.files.save");
                        const save_deadline = time_compat.milliTimestamp() + 10000;
                        var saved = false;
                        while (!saved and time_compat.milliTimestamp() < save_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            const contents = try directory.readFileAlloc(io, "sample.zig", allocator, .limited(64 * 1024));
                            defer allocator.free(contents);
                            saved = std.mem.indexOf(u8, contents, "fn sumValues(") != null and std.mem.indexOf(u8, contents, "return sumValues(") != null and std.mem.indexOf(u8, contents, "    return 42;") != null;
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(saved);
                        // A real Zig diagnostic must reach the marker service and
                        // be included in the language client's quick-fix request.
                        const last_line = model.getLineCount();
                        try selection_editor.setCursorPosition(Position.init(last_line, model.getLineMaxColumn(last_line)));
                        try selection_editor.insertText("pub fn invalid() void {\n    const unused = 1;\n}\n");
                        var diagnostic_resource = try @import("../../../platform/markers/common/markers.zig").Resource.fromUri(allocator, model.uri());
                        defer diagnostic_resource.deinit(allocator);
                        const diagnostic_deadline = time_compat.milliTimestamp() + 10000;
                        var diagnostic_range: ?Range = null;
                        while (diagnostic_range == null and time_compat.milliTimestamp() < diagnostic_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            const markers = try workbench.marker_service.?.read(probe_allocator, .{ .resource = diagnostic_resource });
                            for (markers) |marker| if (std.mem.indexOf(u8, marker.message, "unused local constant") != null) {
                                diagnostic_range = Range.init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column);
                                break;
                            };
                            time_compat.sleepMillis(10);
                        }
                        const fix_range = diagnostic_range orelse return error.ZlsDiagnosticMissing;
                        const actions_mod = @import("../../../editor/contrib/codeAction/browser/codeAction.zig");
                        const action_kinds = @import("../../../editor/contrib/codeAction/common/types.zig");
                        const bulk = @import("../../../editor/browser/services/bulkEditService.zig");
                        const RealActionProbe = struct {
                            actions: ?*actions_mod.ManagedCodeActionSet = null,
                            applied: ?bool = null,
                            failure: ?anyerror = null,
                            fn ready(context: *anyopaque, result: anyerror!*actions_mod.ManagedCodeActionSet) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                if (result) |value| self.actions = value else |err| self.failure = err;
                            }
                            fn appliedEdit(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
                                const self: *@This() = @ptrCast(@alignCast(context));
                                if (result) |value| self.applied = value.is_applied else |err| self.failure = err;
                            }
                        };
                        var action_probe: RealActionProbe = .{};
                        const action_request = (try actions_mod.getCodeActions(allocator, &features.code_action_provider, model, fix_range, .{ .type = .Invoke, .trigger_action = .QuickFix, .filter = .{ .include = action_kinds.CodeActionKind.QuickFix } }, .None, .{ .context = &action_probe, .complete = RealActionProbe.ready })).?;
                        const action_deadline = time_compat.milliTimestamp() + 5000;
                        while (action_probe.actions == null and action_probe.failure == null and time_compat.milliTimestamp() < action_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        if (action_probe.actions == null and action_probe.failure == null) action_request.dispose();
                        const action_set = action_probe.actions orelse return error.ZlsQuickFixMissing;
                        defer action_set.dispose();
                        var edit: ?@import("../../../editor/common/languages.zig").WorkspaceEdit = null;
                        for (action_set.valid_actions) |item| if (item.action.edit) |value| {
                            edit = value;
                            break;
                        };
                        const apply_request = try workbench.bulk_edit_api.apply(edit orelse return error.ZlsQuickFixEditMissing, .{ .editor = selection_editor }, .{ .context = &action_probe, .complete = RealActionProbe.appliedEdit });
                        const apply_deadline = time_compat.milliTimestamp() + 5000;
                        while (action_probe.applied == null and action_probe.failure == null and time_compat.milliTimestamp() < apply_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            time_compat.sleepMillis(10);
                        }
                        if (action_probe.applied == null and action_probe.failure == null) if (apply_request) |request| request.dispose();
                        try std.testing.expect(action_probe.applied orelse false);
                        try std.testing.expectEqualStrings("    _ = unused; // autofix", try model.borrowLineContent(last_line + 2));
                        try std.testing.expectEqualStrings("}", try model.borrowLineContent(last_line + 3));
                        const diagnostic_clear_deadline = time_compat.milliTimestamp() + 10000;
                        var diagnostic_cleared = false;
                        while (!diagnostic_cleared and time_compat.milliTimestamp() < diagnostic_clear_deadline) {
                            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                            const markers = try workbench.marker_service.?.read(probe_allocator, .{ .resource = diagnostic_resource });
                            diagnostic_cleared = true;
                            for (markers) |marker| if (marker.severity == @import("../../../platform/markers/common/markers.zig").MarkerSeverity.Error or std.mem.indexOf(u8, marker.message, "unused local constant") != null) {
                                diagnostic_cleared = false;
                                break;
                            };
                            time_compat.sleepMillis(10);
                        }
                        try std.testing.expect(diagnostic_cleared);
                        model.setLanguage("plaintext");
                        try std.testing.expect(workbench.statusbar.model().findEntry("status.languageStatus") == null);
                        return;
                    }
                }
                const providers = try features.hover_provider.ordered(allocator, model, false);
                defer allocator.free(providers);
                for (providers) |provider| {
                    const result = provider.provide_hover(provider.context, model, Position.init(3, 32), token, null) catch continue;
                    if (result) |hover| for (hover.contents) |contents| {
                        if (std.mem.indexOf(u8, contents.value, if (edited_document) "Updated by the editor." else "Returns the answer.") != null) hover_received = true;
                    };
                }
                time_compat.sleepMillis(20);
            }
            return if (hover_received) error.ZigLanguageStatusNotReceived else error.ZlsHoverNotReceived;
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
                    try waitNavigation(workbench);
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
            try waitReferences(workbench);
            try std.testing.expect(workbench.quick_access.isOpen());
            const reference_picker = workbench.quick_access.inputService().pickerRef();
            try std.testing.expect(reference_picker.items.items.len >= 3);
            reference_picker.accept();
            try workbench.commands.execute("references-view.pickFromHistory");
            try std.testing.expectEqualStrings("value", reference_picker.items.items[0].item.label);
            reference_picker.accept();
            try waitReferences(workbench);
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
                const format_deadline = time_compat.milliTimestamp() + 5_000;
                while (tab.editor.pending_format != null and time_compat.milliTimestamp() < format_deadline) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    time_compat.sleepMillis(1);
                }
                try std.testing.expect(tab.editor.pending_format == null);
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
            try std.testing.expect(controllers.hover.?.isVisible());
            const content = controllers.hover.?.widget().getWidgetContent() orelse return error.TestUnexpectedResult;
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

        test "Extensions: on-type formatting yields, minimizes edits, and cancels on newer typing" {
            if (!build_options.e2e) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "on-type.json", .data = "{}" });
            const path = try tmp.dir.realPathFileAlloc(io, "on-type.json", allocator);
            defer allocator.free(path);
            const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}" });
            const settings_path = try tmp.dir.realPathFileAlloc(io, "settings.json", allocator);
            defer allocator.free(settings_path);
            try workbench.setUserSettingsPaths(&.{settings_path});
            try workbench.setUserConfigurationValue("editor.formatOnType", .{ .bool = true });
            const ext = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/on-type-fixture", "host/dist");
            defer ext.deinit();
            const editor = workbench.activeTab().?.editor;
            const FormatOnType = @import("../../../editor/contrib/format/browser/formatActions.zig").FormatOnType;
            const contribution = editor.getContribution(FormatOnType) orelse return error.MissingFormatContribution;
            const activation_deadline = time_compat.milliTimestamp() + 5000;
            while (contribution.typing_listener == null and time_compat.milliTimestamp() < activation_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(contribution.typing_listener != null);
            try editor.setCursorPosition(Position.init(1, 2));
            try editor.typeCharacter(";");
            try std.testing.expect(contribution.pending != null);
            try std.testing.expectEqualStrings("{;}", try editor.model.borrowLineContent(1));
            const first_deadline = time_compat.milliTimestamp() + 5000;
            while (contribution.pending != null and time_compat.milliTimestamp() < first_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(contribution.pending == null);
            try std.testing.expectEqualStrings("{!}", try editor.model.borrowLineContent(1));
            try editor.undo();
            try std.testing.expectEqualStrings("{;}", try editor.model.borrowLineContent(1));

            try editor.setCursorPosition(Position.init(1, 3));
            try editor.typeCharacter(";");
            try std.testing.expect(contribution.pending != null);
            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
            try editor.typeCharacter("x");
            const second_deadline = time_compat.milliTimestamp() + 5000;
            while (contribution.pending != null and time_compat.milliTimestamp() < second_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(contribution.pending == null);
            try std.testing.expectEqualStrings("{;;x}", try editor.model.borrowLineContent(1));
        }

        test "Extensions: transport activates an extension and exchanges a large RPC" {
            if (!build_options.e2e) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "transport.txt", .data = "transport fixture" });
            try tmp.dir.writeFile(io, .{ .sub_path = "background.txt", .data = "background fixture" });
            const path = try tmp.dir.realPathFileAlloc(io, "transport.txt", allocator);
            defer allocator.free(path);
            const data = try tmp.dir.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(data);
            const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
            defer window.deinit();
            const workbench = window.workbench;
            const ext = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/transport", .is_under_development = true }}, data, "host/dist");
            defer ext.deinit();
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const payload = try a.alloc(u8, 192 * 1024);
            for (payload, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);
            const Probe = struct {
                host: *manager.HostManager,
                queue: *@import("../../../base/common/windowDispatch.zig").Queue,
                arena: std.mem.Allocator,
                payload: []const u8,
                done: bool = false,

                fn run(self: *@This()) anyerror!std.json.Value {
                    defer self.done = true;
                    const activation = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService);
                    _ = try self.host.requestAwait(self.queue, self.arena, activation, "$activateByEvent", &.{ .{ .json = .{ .string = "*" } }, .{ .json = .{ .integer = 0 } } }, null, 10_000);
                    const command = proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands);
                    return self.host.requestAwait(self.queue, self.arena, command, "$executeContributedCommand", &.{ .{ .json = .{ .string = "fixture.transportEcho" } }, .{ .json = .{ .string = self.payload } } }, null, 10_000);
                }
            };
            var probe: Probe = .{ .host = ext.host, .queue = &workbench.window_events, .arena = a, .payload = payload };
            var future = try workbench.window_events.io.concurrent(Probe.run, .{&probe});
            const deadline = time_compat.milliTimestamp() + 20_000;
            while (!probe.done and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            if (!probe.done) {
                _ = future.cancel(workbench.window_events.io) catch {};
                return error.TransportTimeout;
            }
            const result = try future.await(workbench.window_events.io);
            try std.testing.expectEqualStrings(payload, result.object.get("value").?.string);
            try std.testing.expectEqualStrings("background fixture", result.object.get("background").?.string);
            try std.testing.expect(result.object.get("missingRejected").?.bool);
            try std.testing.expect(result.object.get("activeUnchanged").?.bool);
            try std.testing.expect(result.object.get("backgroundHidden").?.bool);
            try std.testing.expect(!result.object.get("missingMirrored").?.bool);
            const document = result.object.get("document").?.string;
            const extension = result.object.get("extension").?.string;
            const text_files = @import("../../services/textfile/common/textFileService.zig");
            try std.testing.expect(text_files.samePath(allocator, io, path, document));
            try std.testing.expect(text_files.samePath(allocator, io, "host/test-fixtures/transport", extension));

            // A real OutputChannel uses the registered file-backed channel,
            // byte offsets, and panel visibility instead of a log-only stub.
            const output_id = @import("../../services/output/common/output.zig").OUTPUT_VIEW_ID;
            const channel_id = "extension-output-minecode.transport-fixture-#1-Transport Output";
            const steps = [_]struct { command: []const u8, content: ?[]const u8, visible: bool }{
                .{ .command = "fixture.outputWrite", .content = "firsté\n", .visible = true },
                .{ .command = "fixture.outputReplace", .content = "replacement\n", .visible = true },
                .{ .command = "fixture.outputClear", .content = "", .visible = true },
                .{ .command = "fixture.outputHide", .content = "", .visible = false },
                .{ .command = "fixture.outputDispose", .content = null, .visible = false },
            };
            for (steps) |step| {
                try ext.host.executeContributedCommand(step.command, &.{});
                const output_deadline = time_compat.milliTimestamp() + 5000;
                var matched = false;
                while (time_compat.milliTimestamp() < output_deadline) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    const channel = workbench.output_service.getChannel(channel_id);
                    const content_matches = if (step.content) |expected| channel != null and std.mem.eql(u8, expected, channel.?.model.content) else channel == null;
                    if (content_matches and workbench.views_api.isViewVisible(output_id) == step.visible) {
                        matched = true;
                        break;
                    }
                    time_compat.sleepMillis(10);
                }
                if (!matched) std.debug.print("Output fixture step failed: {s}\n", .{step.command});
                try std.testing.expect(matched);
            }
            // Real RelativePattern outside a workspace must start a native watch.
            try ext.host.executeContributedCommand("fixture.watchStart", &.{});
            const watcher_service = workbench.file_watcher_service.?;
            const watcher_actor = &ext.file_events_actor.?;
            const watch_channel = "extension-output-minecode.transport-fixture-#2-Watcher Events";
            const watch_deadline = time_compat.milliTimestamp() + 5000;
            while (time_compat.milliTimestamp() < watch_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                if (watcher_actor.watches.count() == 1 and watcher_service.isReady() and workbench.output_service.getChannel(watch_channel) != null) break;
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqual(@as(usize, 1), watcher_actor.watches.count());
            try std.testing.expect(watcher_service.isReady());
            const watcher_steps = [_][]const u8{ "created example.watch", "changed example.watch", "deleted example.watch" };
            for (watcher_steps, 0..) |expected, index| {
                switch (index) {
                    0 => try tmp.dir.writeFile(io, .{ .sub_path = "example.watch", .data = "first" }),
                    1 => try tmp.dir.writeFile(io, .{ .sub_path = "example.watch", .data = "second longer" }),
                    2 => try tmp.dir.deleteFile(io, "example.watch"),
                    else => unreachable,
                }
                const until = time_compat.milliTimestamp() + 5000;
                var received = false;
                while (time_compat.milliTimestamp() < until) {
                    _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                    if (workbench.output_service.getChannel(watch_channel)) |channel| {
                        if (std.mem.indexOf(u8, channel.model.content, expected) != null) {
                            received = true;
                            break;
                        }
                    }
                    time_compat.sleepMillis(10);
                }
                if (!received) std.debug.print("Watcher fixture missing event: {s}\n", .{expected});
                try std.testing.expect(received);
            }
            try ext.host.executeContributedCommand("fixture.watchStop", &.{});
            const stop_deadline = time_compat.milliTimestamp() + 5000;
            while (time_compat.milliTimestamp() < stop_deadline and watcher_actor.watches.count() != 0) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expectEqual(@as(usize, 0), watcher_actor.watches.count());
            // withProgress's report, cancellation and completion travel over
            // the real Node actor, not a simulated status message.
            try ext.host.executeContributedCommand("fixture.progressStart", &.{});
            const progress_deadline = time_compat.milliTimestamp() + 5000;
            var progress_item: ?*@import("../../common/notifications.zig").NotificationViewItem = null;
            while (time_compat.milliTimestamp() < progress_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                for (workbench.notification_service.model.notifications.items) |item| {
                    if (item.actions.primary.len > 0 and std.mem.eql(u8, item.actions.primary[0].id(), "progress.cancel") and item.progress().state.worked == 25) {
                        progress_item = item;
                        break;
                    }
                }
                if (progress_item != null) break;
                time_compat.sleepMillis(10);
            }
            const item = progress_item orelse return error.ProgressNotificationMissing;
            try std.testing.expectEqual(@as(?i64, 100), item.progress().state.total);
            try item.actions.primary[0].execute(null);
            const cancel_deadline = time_compat.milliTimestamp() + 5000;
            var cancelled = false;
            while (time_compat.milliTimestamp() < cancel_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                if (workbench.output_service.getChannel(watch_channel)) |channel| {
                    if (std.mem.indexOf(u8, channel.model.content, "progress cancelled") != null and ext.progress_actor.?.entries.count() == 0 and workbench.progress_service.tasks.items.len == 0) {
                        cancelled = true;
                        break;
                    }
                }
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(cancelled);
            try ext.host.executeContributedCommand("fixture.windowProgressStart", &.{});
            const status_deadline = time_compat.milliTimestamp() + 5000;
            while (time_compat.milliTimestamp() < status_deadline and workbench.statusbar.model().findEntry("status.progress") == null) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(workbench.statusbar.model().findEntry("status.progress") != null);
            try ext.host.executeContributedCommand("fixture.windowProgressEnd", &.{});
            const end_deadline = time_compat.milliTimestamp() + 5000;
            while (time_compat.milliTimestamp() < end_deadline and workbench.statusbar.model().findEntry("status.progress") != null) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(10);
            }
            try std.testing.expect(workbench.statusbar.model().findEntry("status.progress") == null);
        }

        test "Extensions: task activation and provider results resume on the window" {
            if (!build_options.e2e) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
            const workbench_window = try TestWindow.init(allocator, io, &.{}, 100, 30);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            const ext = try Extensions.init(allocator, io, workbench.extensionHostServices(), &.{.{ .path = "host/test-fixtures/task-provider", .is_under_development = true }}, ".cache-ext/task-fixture", "host/dist");
            defer ext.deinit();

            try workbench.commands.execute("workbench.action.tasks.runTask");
            const picker = workbench.quick_access.inputService().pickerRef();
            try std.testing.expectEqualStrings("fixture", picker.activeItem().?.id);
            picker.accept();
            try std.testing.expect(ext.task_service.pending != null);
            try std.testing.expect(!workbench.quick_access.isOpen());
            const deadline = time_compat.milliTimestamp() + 5000;
            while (ext.task_service.pending != null and time_compat.milliTimestamp() < deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(ext.task_service.pending == null);
            try std.testing.expect(workbench.quick_access.isOpen());
            try std.testing.expectEqualStrings("Fixture task", picker.activeItem().?.label);
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
                        _ = host.services.window.dispatch(time_compat.milliTimestamp());
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
            const manage_deadline = time_compat.milliTimestamp() + 5000;
            while (ext.accounts.action.pending != null and time_compat.milliTimestamp() < manage_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(ext.accounts.action.pending == null);
            try std.testing.expectEqualStrings("Fixture user", picker.activeItem().?.label);
            picker.accept();
            picker.setActiveIndex(1);
            picker.accept();
            const signout_deadline = time_compat.milliTimestamp() + 5000;
            while (ext.accounts.action.pending != null and time_compat.milliTimestamp() < signout_deadline) {
                _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
                time_compat.sleepMillis(1);
            }
            try std.testing.expect(ext.accounts.action.pending == null);
            try std.testing.expectEqual(@as(usize, 0), (try ext.accounts.accounts(a, "fixture")).array.items.len);
            try result.request(ext, false, "read");
            try result.wait(ext, false);
            try std.testing.expect(!result.success.?);
        }
    };
}
