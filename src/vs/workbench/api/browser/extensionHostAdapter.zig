// TUI adapter for the pinned VS Code extension host.
//
// The portable pieces (transport, RPC, generated protocol table, host boot)
// live under `src/vs/workbench/services/extensions/`. This file owns only the
// terminal-specific state: the active tab's document mirror, the command
// surface VSCodeVim calls back into, and the key path that sends typed text
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
const LastContentChange = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").LastContentChange;
const ChangeListener = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").ChangeListener;
const TextEdit = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const Workbench = @import("../../browser/workbench.zig").Workbench;
const SplitDirection = @import("../../browser/workbench.zig").SplitDirection;
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
const MainThreadCommands = @import("./mainThreadCommands.zig").MainThreadCommands;
const MainThreadConfiguration = @import("./mainThreadConfiguration.zig").MainThreadConfiguration;
const documents_and_editors = @import("./mainThreadDocumentsAndEditors.zig");
const MainThreadDocuments = @import("./mainThreadDocuments.zig").MainThreadDocuments;
const MainThreadTextEditors = @import("./mainThreadTextEditors.zig").MainThreadTextEditors;
const EditSpec = @import("./mainThreadTextEditors.zig").EditSpec;
const MainThreadEditorTabs = @import("./mainThreadEditorTabs.zig").MainThreadEditorTabs;
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
    editor: *Editor,
    uri: []u8,
    id: []const u8 = "1",
    version: u32 = 1,
    language_id: []u8,
};

/// Source of a cursor-selection change, using upstream's
/// `ICursorSelectionChangedEvent.source` strings. The extension host maps
/// `"mouse"`/`"keyboard"` to `TextEditorSelectionChangeKind`; VSCodeVim
/// accepts a mouse change even though it did not make it itself, which is what
/// keeps its own cursor in step with a click.
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

pub const Extensions = struct {
    allocator: Allocator,
    io: Io,
    workbench: *Workbench,
    host: *manager.HostManager,
    /// Loadable extensions: the user extension (usually VSCodeVim) first, then
    /// any built-in extensions. The host receives all of them in one init-data
    /// payload; activation events select which one runs.
    descriptions: []manager.ExtensionDescription,
    extension_ptrs: []const *const manager.ExtensionDescription,
    user_data_dir: []u8,
    active: ?ActiveDocument = null,
    /// Cursor produced by the last host-driven type. VSCodeVim computes its
    /// own cursor from the requested text, which does not include automatic
    /// indentation; ignore that one stale selection update.
    pending_type_selection: ?Selection = null,
    vim_active: bool = false,
    vim_mode_insert: bool = false,
    decoration_count: usize = 0,
    activated: bool = false,
    activation_tracker: extension_service.ActivationTracker,
    needs_render: bool = false,
    /// The active editor whose scroll events are mirrored to the host.
    scroll_listener_editor: ?*Editor = null,
    visible_ranges_dirty: bool = false,
    pasting: bool = false,
    language_features_actor: ?MainThreadLanguageFeatures = null,
    diagnostics_actor: ?*MainThreadDiagnostics = null,
    storage_actor: ?MainThreadStorage = null,
    statusbar_actor: ?MainThreadStatusBar = null,
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
        workbench: *Workbench,
        extension_paths: []const ExtensionPath,
        user_data_dir: []const u8,
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
            workbench.registerExtensionConfiguration(description.manifest, description.identifier);
        }

        const data = try allocator.dupe(u8, user_data_dir);
        errdefer allocator.free(data);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workbench = workbench,
            .host = undefined,
            .descriptions = owned_descriptions,
            .extension_ptrs = extension_ptrs,
            .user_data_dir = data,
            .activation_tracker = extension_service.ActivationTracker.init(allocator),
            .last_selections = std.array_list.Managed(Selection).init(allocator),
        };

        const host_script = try std.fs.path.join(allocator, &.{ "host", "dist", "extensionHost.mjs" });
        defer allocator.free(host_script);
        // Fail before spawning node: without the bundle the host can never
        // connect, and the manager would otherwise wait for its socket timeout.
        std.Io.Dir.cwd().access(io, host_script, .{}) catch return error.ExtensionHostBundleMissing;
        const workspace_path = try std.fs.path.resolve(allocator, &.{workbench.workspaceFolderPath() orelse "."});
        defer allocator.free(workspace_path);
        self.host = try manager.HostManager.start(allocator, .{
            .host_script = host_script,
            .extensions = self.extension_ptrs,
            .workspace_path = workspace_path,
            .workspace_name = "workspace",
            .user_data_dir = data,
            .app_root = ".",
            .parent_pid = @intCast(manager.currentProcessId()),
        });
        errdefer self.host.deinit();

        self.storage_actor = try MainThreadStorage.init(allocator);
        self.statusbar_actor = try MainThreadStatusBar.init(allocator, &workbench.statusbar, .{
            .context = workbench,
            .callback = refreshWorkbenchStatus,
        });
        self.commands_actor = try MainThreadCommands.init(allocator, self.host, .{
            .context = self,
            .execute = executeHostCommand,
        });
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
        self.registerActors();
        self.initLanguageActors() catch |err| {
            std.log.warn("language feature actors unavailable: {s}", .{@errorName(err)});
        };
        try self.boot();
        return self;
    }

    pub fn deinit(self: *Extensions) void {
        self.setScrollListener(null);
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
        if (self.active) |*active| {
            self.allocator.free(active.uri);
            self.allocator.free(active.language_id);
        }
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
            if (nid == 26) {
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
        const features = self.workbench.language_features orelse return;
        const marker_service = self.workbench.marker_service orelse return;
        self.language_features_actor = MainThreadLanguageFeatures.init(self.allocator, features, .{
            .context = self,
            .request = languageFeaturesRequest,
            .notify = languageFeaturesNotify,
        });
        self.diagnostics_actor = try MainThreadDiagnostics.init(self.allocator, marker_service, .{
            .context = self,
            .notify = diagnosticsNotify,
        }, .{ .context = self, .model_for = diagnosticsModelFor });
    }

    fn languageFeaturesRequest(context: *anyopaque, allocator: Allocator, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, timeout_ms: u32) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(context));
        return self.host.requestSync(allocator, proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures), method, args, token, timeout_ms);
    }

    fn languageFeaturesNotify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguageFeatures), method, args);
    }

    fn diagnosticsNotify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDiagnostics), method, args);
    }

    fn refreshWorkbenchStatus(context: *anyopaque) void {
        const workbench: *Workbench = @ptrCast(@alignCast(context));
        workbench.refreshStatus();
    }

    fn diagnosticsModelFor(context: *anyopaque, resource: markers_mod.Resource) ?*TextModel {
        const self: *Extensions = @ptrCast(@alignCast(context));
        for (self.workbench.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                var candidate = markers_mod.Resource.fromUri(self.allocator, tab.editor.model.uri()) catch continue;
                defer candidate.deinit(self.allocator);
                if (!std.mem.eql(u8, candidate.scheme, resource.scheme)) continue;
                if (!std.mem.eql(u8, candidate.authority, resource.authority)) continue;
                if (!std.mem.eql(u8, candidate.path, resource.path)) continue;
                return tab.editor.model;
            }
        }
        return null;
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
        if (self.commands_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
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
        const path = uriPath(uri) orelse return false;
        self.workbench.openPath(path) catch return false;
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

    fn editorTabsCloseTabHost(context: *anyopaque, tab_id: []const u8) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const closed = self.workbench.closePath(tab_id) catch false;
        self.needs_render = true;
        return closed;
    }

    fn editorTabsCloseGroupHost(context: *anyopaque, group_id: i64) anyerror!bool {
        _ = group_id;
        const self: *Extensions = @ptrCast(@alignCast(context));
        while (self.workbench.tabCount() > 0) {
            if (!(self.workbench.closeActive() catch false)) break;
        }
        self.needs_render = true;
        return true;
    }

    fn documentsOpenHost(context: *anyopaque, uri: std.json.Value, options: std.json.Value, arena: Allocator) anyerror!std.json.Value {
        _ = options;
        const self: *Extensions = @ptrCast(@alignCast(context));
        const path = uriPath(uri) orelse return .null;
        self.workbench.openPath(path) catch {};
        // Make the document known before `workspace.openTextDocument`
        // resolves; the extension host otherwise waits for the next pump.
        self.syncActiveDocument() catch {};
        self.needs_render = true;
        // Return the resource the document mirror registered, not the caller's
        // path spelling, so an extension-requested open joins the same
        // document (`$tryOpenDocument` resolves to this URI).
        const opened = self.workbench.findOpenInput(path) orelse return .null;
        return try std_uri.jsonComponents(arena, opened.editor.model.uri());
    }

    fn documentsCreateHost(context: *anyopaque, options: std.json.Value, arena: Allocator) anyerror!std.json.Value {
        _ = options;
        _ = context;
        return manager.fileUri(arena, "/tmp/untitled");
    }

    fn documentsSaveHost(context: *anyopaque, uri: std.json.Value) anyerror!bool {
        _ = uri;
        const self: *Extensions = @ptrCast(@alignCast(context));
        const active = self.active orelse return false;
        active.editor.save() catch return false;
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
            if (self.pending_type_selection) |pending| {
                if (sameSelection(pending, selections[0])) {
                    self.pending_type_selection = null;
                } else if (isStaleAutoIndentSelection(editor, pending, selections[0])) {
                    var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena_instance.deinit();
                    self.sendSelection(arena_instance.allocator(), .command) catch {};
                    return;
                } else {
                    self.pending_type_selection = null;
                }
            }
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
        self.workbench.openPath(path) catch {};
        if (self.workbench.activeTab()) |tab| applyShowDocumentSelection(tab.editor, options);
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
        return self.workbench.configurationData(arena);
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

    fn boot(self: *Extensions) !void {
        try self.host.expectControl(2, 10_000);
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const workspace = try std.fs.path.resolve(arena, &.{self.workbench.workspaceFolderPath() orelse "."});
        const init_data = try manager.buildInitData(arena, .{
            .host_script = "",
            .extensions = self.extension_ptrs,
            .workspace_path = workspace,
            .workspace_name = "workspace",
            .user_data_dir = self.user_data_dir,
            .app_root = ".",
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

        const configuration_data = try self.workbench.configurationData(arena);
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

        // VSCodeVim activates on `onStartupFinished`; wait for that before the
        // first document delta so its listeners see the initial model. Other
        // extensions (TypeScript) activate on `onLanguage` below, after the
        // document delta has been queued.
        var wait_for_startup_extension = false;
        for (self.descriptions) |description| {
            if (std.mem.eql(u8, description.identifier, "vscodevim.vim")) wait_for_startup_extension = true;
        }
        if (wait_for_startup_extension) {
            const deadline = time_compat.milliTimestamp() + 10_000;
            while (!self.activated and time_compat.milliTimestamp() < deadline) {
                _ = self.host.pump();
                time_compat.sleepMillis(5);
            }
        }
        try self.syncActiveDocument();
        self.activateActiveLanguage();
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

    /// Fires `onLanguage:<id>` once per language, after the document delta has
    /// been queued. Upstream's workbench language service does the same; the
    /// terminal has a per-editor language service, so the extension bridge
    /// derives the event from the active document.
    fn activateActiveLanguage(self: *Extensions) void {
        const tab = self.workbench.activeTab() orelse return;
        self.activation_tracker.activateLanguage(self.host, tab.editor.languageId());
    }

    /// Drains incoming extension messages. Returns true when the TUI should
    /// repaint (an edit, selection, or status entry changed).
    pub fn pump(self: *Extensions) bool {
        self.needs_render = false;
        _ = self.host.pump();
        if (self.diagnostics_actor) |actor| actor.flush() catch {};
        self.syncActiveDocument() catch {};
        self.activateActiveLanguage();
        self.syncSelection() catch {};
        if (self.visible_ranges_dirty) self.sendVisibleRanges() catch {};
        const result = self.needs_render;
        self.needs_render = false;
        return result;
    }

    fn syncActiveDocument(self: *Extensions) !void {
        const tab = self.workbench.activeTab() orelse {
            // Closing the last tab frees its editor. Drop the mirror before
            // any handler or selection sync can dereference it.
            if (self.active != null) try self.removeActiveDocument();
            return;
        };
        if (self.active) |active| {
            if (active.editor == tab.editor) {
                try self.syncTabs();
                return;
            }
            try self.removeActiveDocument();
        }

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        // The mirror resource must be the text model's URI: language-feature
        // requests carry `model.uri()`, and a raw relative editor path would
        // name a document the extension host never opened. That mismatch made
        // `gd` and the F12 actions return no result for relative paths.
        const uri = try self.allocator.dupe(u8, try std_uri.fsPath(tab.editor.model.uri(), arena));
        errdefer self.allocator.free(uri);
        const language = try self.allocator.dupe(u8, tab.editor.languageId());
        errdefer self.allocator.free(language);

        const selections = try tab.editor.getSelections();
        defer tab.editor.allocator.free(selections);
        const delta = try documents_and_editors.addDocumentDelta(
            arena,
            tab.editor.model,
            language,
            tab.editor.dirty_state,
            .{
                .tab_size = tab.editor.cursor_config.tabSize,
                .indent_size = tab.editor.cursor_config.indentSize,
                .insert_spaces = tab.editor.cursor_config.insertSpaces,
            },
            selections,
        );
        var args = [_]rpc.Arg{.{ .json = delta }};
        _ = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback);

        self.active = .{ .editor = tab.editor, .uri = uri, .language_id = language };
        self.setScrollListener(tab.editor);
        self.captureSelections(tab.editor);
        try self.syncTabs();
        self.needs_render = true;
    }

    fn syncTabs(self: *Extensions) !void {
        const active_tab = self.workbench.activeTab() orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var specs = std.array_list.Managed(documents_and_editors.TabSpec).init(arena);
        for (self.workbench.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                try specs.append(.{
                    .path = try std_uri.fsPath(tab.editor.model.uri(), arena),
                    .label = std.fs.path.basename(tab.editor.path),
                    .is_active = tab == active_tab,
                    .is_dirty = tab.editor.dirty_state,
                });
            }
        }
        if (self.editor_tabs_actor) |*actor| {
            try actor.sync(arena, try std_uri.fsPath(active_tab.editor.model.uri(), arena), specs.items);
        }
    }

    fn removeActiveDocument(self: *Extensions) !void {
        const active = self.active orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const delta = try documents_and_editors.removedDocumentDelta(arena, active.uri);
        var args = [_]rpc.Arg{.{ .json = delta }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback) catch {};
        self.setScrollListener(null);
        self.allocator.free(active.uri);
        self.allocator.free(active.language_id);
        self.active = null;
        self.needs_render = true;
    }

    pub fn handleKey(self: *Extensions, event: *const ui.KeyEvent) bool {
        if (!self.vim_active) return false;
        if (self.workbench.activeTab() == null) return false;
        switch (event.key) {
            .paste_start => {
                self.pasting = true;
                return false;
            },
            .paste_end => {
                self.pasting = false;
                return false;
            },
            .f12 => return false,
            .text => |text| {
                if (self.pasting) return false;
                if (event.mods.ctrl or event.mods.alt) return false;
                var view = std.unicode.Utf8View.init(text) catch return false;
                var iterator = view.iterator();
                while (iterator.nextCodepoint()) |codepoint| {
                    if (codepoint == '\n' or codepoint == '\r') {
                        self.typeText("\n");
                    } else {
                        var buffer: [4]u8 = undefined;
                        const length = std.unicode.utf8Encode(codepoint, &buffer) catch continue;
                        self.typeText(buffer[0..length]);
                    }
                }
                return true;
            },
            .char => |char| {
                if (event.mods.ctrl and !event.mods.alt) {
                    // Ctrl-Space belongs to the editor suggest controller, not
                    // to VSCodeVim's key handler; otherwise completion never
                    // reaches the language provider.
                    if (char == 's' or char == 'q' or char == ' ') return false;
                    var command_buffer: [32]u8 = undefined;
                    const command = std.fmt.bufPrint(&command_buffer, "extension.vim_ctrl+{c}", .{std.ascii.toLower(@intCast(char))}) catch return false;
                    self.executeCommand(command, &.{});
                    return true;
                }
                if (event.mods.alt) return false;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(char, &buffer) catch return false;
                self.typeText(buffer[0..length]);
                return true;
            },
            .enter => {
                self.typeText("\n");
                return true;
            },
            .escape => {
                self.executeCommand("extension.vim_escape", &.{});
                return true;
            },
            .insert => {
                self.executeCommand("extension.vim_insert", &.{});
                return true;
            },
            .backspace => {
                if (event.mods.shift and !event.mods.ctrl) {
                    self.executeCommand("extension.vim_shift+backspace", &.{});
                    return true;
                }
                self.executeCommand("extension.vim_backspace", &.{});
                return true;
            },
            .delete => {
                self.executeCommand("extension.vim_delete", &.{});
                return true;
            },
            .tab => {
                // VSCodeVim disables its Tab binding in insert mode; the
                // editor owns it there so insertSpaces/tabSize apply instead
                // of inserting the literal "<tab>" notation.
                if (self.vim_mode_insert) {
                    if (self.workbench.activeTab()) |tab| tab.editor.insertTab() catch {};
                    return true;
                }
                self.executeCommand("extension.vim_tab", &.{});
                return true;
            },
            .backtab => {
                if (self.vim_mode_insert) {
                    if (self.workbench.activeTab()) |tab| tab.editor.outdent() catch {};
                    return true;
                }
                self.executeCommand("extension.vim_shift+tab", &.{});
                return true;
            },
            .left => {
                self.executeCommand("extension.vim_left", &.{});
                return true;
            },
            .right => {
                self.executeCommand("extension.vim_right", &.{});
                return true;
            },
            .up => {
                self.executeCommand("extension.vim_up", &.{});
                return true;
            },
            .down => {
                self.executeCommand("extension.vim_down", &.{});
                return true;
            },
            .home => {
                self.executeCommand(if (event.mods.ctrl) "extension.vim_ctrl+home" else "extension.vim_home", &.{});
                return true;
            },
            .end => {
                self.executeCommand(if (event.mods.ctrl) "extension.vim_ctrl+end" else "extension.vim_end", &.{});
                return true;
            },
            .page_up => {
                self.executeCommand(if (event.mods.ctrl) "extension.vim_ctrl+pageup" else "extension.vim_ctrl+b", &.{});
                return true;
            },
            .page_down => {
                self.executeCommand(if (event.mods.ctrl) "extension.vim_ctrl+pagedown" else "extension.vim_ctrl+f", &.{});
                return true;
            },
        }
        return false;
    }

    fn typeText(self: *Extensions, text: []const u8) void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var arg: std.json.ObjectMap = .empty;
        arg.put(arena, "text", .{ .string = text }) catch return;
        var args = [_]rpc.Arg{
            .{ .json = .{ .string = "type" } },
            .{ .json = .{ .object = arg } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &args, null, manager.noop_callback) catch return;
    }

    fn executeCommand(self: *Extensions, command: []const u8, command_args: []const std.json.Value) void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var args_array = std.json.Array.init(arena);
        for (command_args) |value| args_array.append(value) catch return;
        var args = [_]rpc.Arg{
            .{ .json = .{ .string = command } },
            .{ .json = .{ .array = args_array } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &args, null, manager.noop_callback) catch {};
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        _ = args;
        _ = context;
        if (std.mem.eql(u8, method, "$getTools")) {
            return .{ .json = .{ .array = std.json.Array.init(arena) } };
        }
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            return .{ .json = .{ .bool = true } };
        }
        return .empty;
    }

    fn applyType(self: *Extensions, arena: Allocator, editor: *Editor, text: []const u8) !void {
        const before = try editor.getSelections();
        defer editor.allocator.free(before);
        const start = if (before.len > 0) before[0].getStartPosition() else Position.init(1, 1);
        self.pending_type_selection = null;
        try editor.typeCharacter(text);
        const post_type = try editor.getSelections();
        defer editor.allocator.free(post_type);
        self.pending_type_selection = if (post_type.len > 0) post_type[0] else null;
        const changes = try editor.takeContentChanges(self.allocator);
        defer {
            for (changes) |change| self.allocator.free(change.text);
            self.allocator.free(changes);
        }
        const active = &(self.active orelse return);
        active.version += 1;
        if (changes.len > 0) {
            try self.sendModelChanges(arena, changes);
        } else {
            try self.sendModelChanged(arena, text, start, start);
        }
        try self.sendSelection(arena, .command);
        self.needs_render = true;
    }

    /// Mirrors the result of a command that may edit or move the cursor. Used
    /// by the generic command bridge and by the ported `cursorMove`, scroll and
    /// fold commands. Multi-change batches are handled by `takeContentChanges`
    /// once the editor has collected the whole model event.
    fn syncAfterEditorCommand(self: *Extensions, arena: Allocator, editor: *Editor) !void {
        const active = &(self.active orelse return);
        const changes = try editor.takeContentChanges(self.allocator);
        defer {
            for (changes) |change| self.allocator.free(change.text);
            self.allocator.free(changes);
        }
        if (changes.len > 0) {
            active.version += 1;
            try self.sendModelChanges(arena, changes);
        }
        try self.syncSelection();
        self.sendVisibleRanges() catch {};
        self.needs_render = true;
    }

    fn applyCommandEdit(self: *Extensions, arena: Allocator, editor: *Editor) !void {
        const active = &(self.active orelse return);
        const post_selections = try editor.getSelections();
        defer editor.allocator.free(post_selections);
        self.pending_type_selection = if (post_selections.len > 0) post_selections[0] else null;
        active.version += 1;
        const changes = try editor.takeContentChanges(self.allocator);
        defer {
            for (changes) |change| self.allocator.free(change.text);
            self.allocator.free(changes);
        }
        if (changes.len > 0) try self.sendModelChanges(arena, changes);
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
        const active = &(self.active orelse return);
        active.version += 1;
        const changes = try editor.takeContentChanges(self.allocator);
        defer {
            for (changes) |change| self.allocator.free(change.text);
            self.allocator.free(changes);
        }
        if (changes.len > 0) try self.sendModelChanges(arena, changes);
        try self.sendSelection(arena, .keyboard);
        self.needs_render = true;
    }

    fn sendModelChanged(self: *Extensions, arena: Allocator, text: []const u8, start: Position, end: Position) !void {
        const active = self.active orelse return;
        const event = try documents_and_editors.modelChangedEvent(
            arena,
            active.editor.model,
            .{
                .text = text,
                .start = .{ .line = start.lineNumber, .column = start.column },
                .end = .{ .line = end.lineNumber, .column = end.column },
            },
            active.version,
        );
        var args = [_]rpc.Arg{
            .{ .json = try manager.fileUri(arena, active.uri) },
            .{ .json = event },
            .{ .json = .{ .bool = false } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocuments), "$acceptModelChanged", &args, null, manager.noop_callback) catch {};
    }

    fn sendModelChanges(self: *Extensions, arena: Allocator, changes: []const LastContentChange) !void {
        const active = self.active orelse return;
        var specs = std.array_list.Managed(documents_and_editors.ChangeSpec).init(arena);
        for (changes) |change| {
            try specs.append(.{
                .text = change.text,
                .start = .{ .line = change.range.startLineNumber, .column = change.range.startColumn },
                .end = .{ .line = change.range.endLineNumber, .column = change.range.endColumn },
            });
        }
        const event = try documents_and_editors.modelChangesEvent(arena, active.editor.model, specs.items, active.version);
        var args = [_]rpc.Arg{
            .{ .json = try manager.fileUri(arena, active.uri) },
            .{ .json = event },
            .{ .json = .{ .bool = false } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocuments), "$acceptModelChanged", &args, null, manager.noop_callback) catch {};
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
        self.visible_ranges_dirty = false;
        self.captureSelections(active.editor);
    }

    fn onEditorScroll(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.visible_ranges_dirty = true;
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
        self.visible_ranges_dirty = false;
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

    /// VSCodeVim computes its post-type cursor from the requested text. When
    /// auto-indent inserted extra whitespace, that cursor lands before the
    /// indentation; keep the editor's real cursor instead.
    fn isStaleAutoIndentSelection(editor: *Editor, pending: Selection, incoming: Selection) bool {
        if (incoming.startLineNumber != pending.startLineNumber or
            incoming.startColumn >= pending.startColumn or
            incoming.startColumn != incoming.endColumn)
        {
            return false;
        }
        const line = editor.model.getLineContent(incoming.startLineNumber) catch return false;
        defer line.deinit();
        const prefix_end = @min(incoming.startColumn - 1, line.items.len);
        for (line.items[0..prefix_end]) |ch| {
            if (ch != ' ' and ch != '\t') return false;
        }
        return true;
    }

    fn sameSelection(a: Selection, b: Selection) bool {
        return a.startLineNumber == b.startLineNumber and a.startColumn == b.startColumn and
            a.endLineNumber == b.endLineNumber and a.endColumn == b.endColumn;
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
    /// VSCodeVim keeps its own cursor and the next Vim key snaps the caret
    /// back to where it was before the click.
    fn syncSelection(self: *Extensions) !void {
        const active = self.active orelse return;
        const selections = try active.editor.getSelections();
        defer active.editor.allocator.free(selections);
        if (sameSelections(self.last_selections.items, selections)) return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        try self.sendSelection(arena_instance.allocator(), self.selection_source);
    }
};

/// Maps command ids issued by extensions/VSCodeVim to the workbench LSP
/// actions. Returns true when the command was recognized, even when the
/// action produced no result.
pub fn runLspCommand(workbench: *Workbench, command: []const u8) bool {
    if (std.mem.eql(u8, command, "editor.action.showHover")) {
        _ = workbench.showHover() catch false;
        return true;
    }
    if (std.mem.eql(u8, command, "outline.focus") or
        std.mem.eql(u8, command, "workbench.action.gotoSymbol"))
    {
        _ = workbench.gotoSymbolInEditor() catch false;
        return true;
    }

    const id = if (std.mem.eql(u8, command, "editor.action.goToDeclaration"))
        go_to_commands.definition.id
    else if (std.mem.eql(u8, command, "editor.action.findReferences"))
        go_to_commands.peek_references.id
    else
        command;
    if (go_to_commands.find(id) == null) return false;
    _ = workbench.runLspAction(id) catch false;
    return true;
}

fn currentVisibleRange(editor: *Editor) ?Range {
    if (editor.viewLineCount() == 0) return null;
    const top = editor.topViewLine();
    const bottom = @min(top + editor.textHeight() -| 1, editor.viewLineCount());
    const start_line = editor.modelLineNumber(top);
    const end_line = editor.modelLineNumber(bottom);
    if (start_line < 1 or end_line < 1) return null;
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

fn executeHostCommand(context: *anyopaque, command: []const u8, command_args: std.json.Value, arena: Allocator) anyerror!?std.json.Value {
    const self: *Extensions = @ptrCast(@alignCast(context));
    const args: []const std.json.Value = if (command_args == .array) command_args.array.items else &.{};
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
    // VSCodeVim's insert-mode Backspace/Delete actions do not edit the
    // document themselves: they delegate to the editor's core
    // `deleteLeft`/`deleteRight` command.
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
        self.workbench.findInFiles() catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.splitEditorRight") or std.mem.eql(u8, command, "workbench.action.splitEditorDown")) {
        const direction: SplitDirection = if (std.mem.eql(u8, command, "workbench.action.splitEditorRight")) .horizontal else .vertical;
        self.workbench.splitActive(direction) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.closeActiveEditor")) {
        _ = self.workbench.closeActive() catch false;
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "moveActiveEditor")) {
        if (args.len > 0 and args[0] == .object) {
            const object = args[0].object;
            const to = objectString(object, "to") orelse "";
            const by = objectString(object, "by") orelse "tab";
            const value = objectUsize(object, "value") orelse 1;
            self.workbench.moveActiveEditor(to, by, value) catch {};
            self.needs_render = true;
        }
        return null;
    }
    if (std.mem.startsWith(u8, command, "workbench.action.openEditorAtIndex")) {
        if (args.len > 0 and args[0] == .integer and args[0].integer >= 0) {
            self.workbench.activateIndex(@intCast(args[0].integer)) catch {};
            self.needs_render = true;
        } else if (std.mem.eql(u8, command, "workbench.action.openEditorAtIndex1")) {
            self.workbench.activateIndex(0) catch {};
            self.needs_render = true;
        }
        return null;
    }
    if (runLspCommand(self.workbench, command)) {
        // VSCodeVim reads `activeTextEditor` immediately after the command
        // resolves. Publish the new document/selection on the same channel
        // before the command reply so `gd` sees the target cursor.
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
        self.workbench.switchTab(1) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "workbench.action.previousEditorInGroup")) {
        self.workbench.switchTab(-1) catch {};
        self.needs_render = true;
        return null;
    }
    if (std.mem.eql(u8, command, "vscode.open")) {
        if (args.len > 0 and args[0] == .object) {
            if (args[0].object.get("path")) |path| {
                if (path == .string) {
                    self.workbench.openPath(path.string) catch {};
                    self.needs_render = true;
                }
            }
        }
        return null;
    }
    if (std.mem.eql(u8, command, "_setContext") or std.mem.eql(u8, command, "setContext")) {
        if (args.len >= 2 and args[0] == .string) {
            const key_value = args[0];
            if (std.mem.eql(u8, key_value.string, "vim.active")) {
                if (args[1] == .bool) {
                    self.vim_active = args[1].bool;
                    if (!self.vim_active) self.vim_mode_insert = false;
                }
            } else if (std.mem.eql(u8, key_value.string, "vim.mode")) {
                const mode = args[1];
                self.vim_mode_insert = mode == .string and
                    (std.mem.eql(u8, mode.string, "Insert") or std.mem.eql(u8, mode.string, "Replace"));
            }
        }
        return null;
    }
    if (self.workbench.commands.get(command) != null) {
        self.workbench.commands.execute(command) catch |err| {
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
/// TUI. VSCodeVim's insert-mode Backspace and Delete actions are wrappers
/// around these core commands; the caller mirrors the resulting edit.
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

test "Extensions: insert-mode Backspace and Delete run the core editor commands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abc", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // VSCodeVim's BackspaceInInsertMode delegates to `deleteLeft`; the key is
    // not an edit by itself, so the TUI must run the command.
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

test "Extensions: VSCodeVim inserts text into the active TUI editor" {
    if (!build_options.e2e) return error.SkipZigTest;
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(time_compat.io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = time_compat.io;
    const tmp = std.testing.tmpDir(.{});
    var tmp_value = tmp;
    defer tmp_value.cleanup();
    try tmp_value.dir.writeFile(io, .{ .sub_path = "vim.txt", .data = "hello\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp_value.dir.realPathFile(io, "vim.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();

    var extension_host = try Extensions.init(allocator, io, workbench, &.{.{ .path = ".cache-ext/vim/extension", .is_under_development = true }}, ".cache-ext/data-tui-test");
    defer extension_host.deinit();

    const deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null) break;
        time_compat.sleepMillis(10);
    }
    try std.testing.expect(extension_host.active != null);

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'i' } });
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'X' } });
    const until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < until) {
        _ = extension_host.pump();
        var line = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer line.deinit();
        if (std.mem.startsWith(u8, line.items, "Xhello")) break;
        time_compat.sleepMillis(10);
    }
    var line = try workbench.activeTab().?.editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("Xhello", line.items);

    // The TUI routes Backspace to VSCodeVim while it is active. In insert mode
    // VSCodeVim delegates the edit back through the core `deleteLeft` command;
    // the bridge must run it instead of swallowing the key.
    _ = extension_host.handleKey(&.{ .key = .backspace });
    const backspace_until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < backspace_until) {
        _ = extension_host.pump();
        var current = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer current.deinit();
        if (std.mem.eql(u8, current.items, "hello")) break;
        time_compat.sleepMillis(10);
    }
    var after_backspace = try workbench.activeTab().?.editor.model.getLineContent(1);
    defer after_backspace.deinit();
    try std.testing.expectEqualStrings("hello", after_backspace.items);

    // Restore the typed prefix for the normal-mode `x` check below.
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'X' } });
    const retype_until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < retype_until) {
        _ = extension_host.pump();
        var current = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer current.deinit();
        if (std.mem.startsWith(u8, current.items, "Xhello")) break;
        time_compat.sleepMillis(10);
    }

    _ = extension_host.handleKey(&.{ .key = .escape });
    const mode_deadline = time_compat.milliTimestamp() + 3_000;
    while (extension_host.vim_mode_insert and time_compat.milliTimestamp() < mode_deadline) {
        _ = extension_host.pump();
        time_compat.sleepMillis(10);
    }
    _ = extension_host.pump();
    time_compat.sleepMillis(100);
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'x' } });
    const delete_until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < delete_until) {
        _ = extension_host.pump();
        var current = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer current.deinit();
        if (std.mem.eql(u8, current.items, "hello")) break;
        time_compat.sleepMillis(10);
    }
    var deleted = try workbench.activeTab().?.editor.model.getLineContent(1);
    defer deleted.deinit();
    try std.testing.expectEqualStrings("hello", deleted.items);

    // Regression: a pointer click moves the TUI caret without VSCodeVim
    // seeing it. `pump` must report the selection change (source "mouse"),
    // otherwise the next Vim key starts from its stale cursor and the caret
    // jumps back to where it was before the click.
    try workbench.activeTab().?.editor.setCursorPosition(Position.init(1, 4));
    extension_host.selection_source = .mouse;
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);
    _ = extension_host.handleKey(&.{ .key = .right });
    const arrow_until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < arrow_until) {
        _ = extension_host.pump();
        if (workbench.activeTab().?.editor.modelCursorPosition().column == 5) break;
        time_compat.sleepMillis(10);
    }
    const clicked = workbench.activeTab().?.editor.modelCursorPosition();
    try std.testing.expectEqual(@as(usize, 1), clicked.lineNumber);
    try std.testing.expectEqual(@as(usize, 5), clicked.column);
}

test "Extensions: VSCodeVim vertical motion uses its character column" {
    if (!build_options.e2e) return error.SkipZigTest;
    const io = time_compat.io;
    std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "\twhile (pos < source.length && depth > 0) {\n\t\tconst ch = source[pos];\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "tabs.js", .data = content });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPathFile(io, "tabs.js", &path_buffer);

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_length]}, 80, 24);
    defer workbench.deinit();
    var extension_host = try Extensions.init(allocator, io, workbench, &.{.{ .path = ".cache-ext/vim/extension", .is_under_development = true }}, ".cache-ext/data-tui-test");
    defer extension_host.deinit();

    const deadline = time_compat.milliTimestamp() + 15_000;
    while (time_compat.milliTimestamp() < deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null and extension_host.vim_active) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(extension_host.active != null);
    try std.testing.expect(extension_host.vim_active);
    time_compat.sleepMillis(500);
    _ = extension_host.pump();

    const editor = workbench.activeTab().?.editor;
    var line1 = try editor.model.getLineContent(1);
    defer line1.deinit();
    var line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try editor.setCursorPosition(Position.init(1, 27));
    extension_host.selection_source = .mouse;
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);
    _ = extension_host.pump();
    try std.testing.expectEqual(@as(usize, 30), CursorColumns.toStatusbarColumn(line1.items, 27, editor.tabSize()));

    // The editor's own vertical movement preserves the rendered column: one
    // tab on line 1 and two tabs on line 2 both put visible column 29 before
    // `h` and before `]`.
    try editor.moveDown(false);
    const native = editor.modelCursorPosition();
    try std.testing.expectEqual(@as(usize, 2), native.lineNumber);
    try std.testing.expectEqual(@as(usize, 24), native.column);
    try std.testing.expectEqual(@as(usize, 30), CursorColumns.toStatusbarColumn(line2.items, native.column, editor.tabSize()));

    // VSCodeVim 1.32.4 instead applies its character-based `desiredColumn`
    // (26) to line 2, which has only 25 code units. Normal mode then clamps
    // to the last character, landing before `;` (column 25) and one rendered
    // column to the right. That is upstream behavior (VSCodeVim#8840) and
    // reproduces in VS Code; the bridge must keep applying its selection.
    try editor.setCursorPosition(Position.init(1, 27));
    extension_host.selection_source = .mouse;
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);
    _ = extension_host.pump();
    const before = editor.modelCursorPosition();
    try std.testing.expectEqual(Position.init(1, 27), before);

    _ = extension_host.handleKey(&.{ .key = .down });
    const move_deadline = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < move_deadline) {
        _ = extension_host.pump();
        if (editor.modelCursorPosition().lineNumber == 2) break;
        time_compat.sleepMillis(10);
    }
    const after = editor.modelCursorPosition();
    try std.testing.expectEqual(@as(usize, 2), after.lineNumber);
    try std.testing.expectEqual(@as(usize, 25), after.column);
    try std.testing.expectEqual(@as(usize, 31), CursorColumns.toStatusbarColumn(line2.items, after.column, editor.tabSize()));
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

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();

    var extension_host = try Extensions.init(allocator, io, workbench, &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-language-fixture");
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

    // VSCodeVim's command names reach the same workbench actions.
    try std.testing.expect(runLspCommand(workbench, "editor.action.goToDeclaration"));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(runLspCommand(workbench, "editor.action.revealDeclaration"));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(runLspCommand(workbench, "editor.action.goToImplementation"));
    try std.testing.expectEqual(@as(usize, 3), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(runLspCommand(workbench, "editor.action.goToTypeDefinition"));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);

    try std.testing.expect(runLspCommand(workbench, "editor.action.goToReferences"));
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
    try std.testing.expect(runLspCommand(workbench, "editor.action.findReferences"));
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
    try std.testing.expect(runLspCommand(workbench, "outline.focus"));
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
    try std.testing.expect(runLspCommand(workbench, "editor.action.showHover"));
    try std.testing.expect(workbench.activeTab().?.controllers.?.hover.isVisible());
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

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();

    var extension_host = try Extensions.init(
        allocator,
        io,
        workbench,
        &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }},
        ".cache-ext/data-relative-fixture",
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

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_length]}, 100, 30);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    var extension_host = try Extensions.init(
        allocator,
        io,
        workbench,
        &.{.{ .path = "host/dist/extensions/typescript-language-features", .is_builtin = true }},
        ".cache-ext/data-ts-test",
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

test "Extensions: TypeScript and VSCodeVim share one host" {
    if (!build_options.e2e) return error.SkipZigTest;
    const io = time_compat.io;
    std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, "host/dist/extensions/typescript-language-features/package.json", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, "host/dist/extensions/node_modules/typescript/lib/tsserver.js", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "both.ts", .data = "const value: number = \"text\";\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPathFile(io, "both.ts", &path_buffer);

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_length]}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    var extension_host = try Extensions.init(
        allocator,
        io,
        workbench,
        &.{
            .{ .path = ".cache-ext/vim/extension", .is_under_development = true },
            .{ .path = "host/dist/extensions/typescript-language-features", .is_builtin = true },
        },
        ".cache-ext/data-ts-vim-test",
    );
    defer extension_host.deinit();
    try std.testing.expectEqual(@as(usize, 2), extension_host.descriptions.len);

    const marker_service = workbench.marker_service.?;
    const model = workbench.activeTab().?.editor.model;
    var resource = try markers_mod.Resource.fromUri(allocator, model.uri());
    defer resource.deinit(allocator);

    // The TypeScript extension in the same host also publishes diagnostics.
    var found = false;
    const diagnostics_deadline = time_compat.milliTimestamp() + 30_000;
    while (time_compat.milliTimestamp() < diagnostics_deadline) {
        _ = extension_host.pump();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const list = marker_service.read(arena.allocator(), .{ .resource = resource }) catch &.{};
        for (list) |marker| {
            if (std.mem.indexOf(u8, marker.message, "not assignable") != null) {
                found = true;
                break;
            }
        }
        if (found) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(found);
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

test "Extensions: VSCodeVim navigation commands reach the workbench actions" {
    if (!build_options.e2e) return error.SkipZigTest;
    const io = time_compat.io;
    std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, "host/test-fixtures/language-features/package.json", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "vim-lsp.json", .data = "{\n  \"a\": 1\n}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, "vim-lsp.json", &path_buffer);

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_len]}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();

    var extension_host = try Extensions.init(allocator, io, workbench, &.{
        .{ .path = "host/test-fixtures/language-features", .is_under_development = true },
        .{ .path = ".cache-ext/vim/extension", .is_under_development = true },
    }, ".cache-ext/data-vim-lsp-test");
    defer extension_host.deinit();

    const startup_deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < startup_deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null) break;
        time_compat.sleepMillis(10);
    }
    try std.testing.expect(extension_host.active != null);
    const vim_deadline = time_compat.milliTimestamp() + 10_000;
    while (!extension_host.vim_active and time_compat.milliTimestamp() < vim_deadline) {
        _ = extension_host.pump();
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(extension_host.vim_active);
    _ = extension_host.handleKey(&.{ .key = .escape });
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);

    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(3, 1));
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'g' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'd' } });
    const definition_deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < definition_deadline) {
        _ = extension_host.pump();
        if (tab.editor.modelCursorPosition().lineNumber == 1) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expectEqual(@as(usize, 1), tab.editor.modelCursorPosition().lineNumber);

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'g' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'h' } });
    const hover_deadline = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < hover_deadline) {
        _ = extension_host.pump();
        if (tab.controllers != null and tab.controllers.?.hover.isVisible()) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(tab.controllers != null and tab.controllers.?.hover.isVisible());

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'g' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'O' } });
    const symbol_deadline = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < symbol_deadline) {
        _ = extension_host.pump();
        if (workbench.quick_access.isOpen()) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
}

test "Extensions: VSCodeVim z commands scroll the viewport" {
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
    const io = time_compat.io;
    std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var contents = std.array_list.Managed(u8).init(allocator);
    defer contents.deinit();
    var line: usize = 1;
    var line_buffer: [32]u8 = undefined;
    while (line <= 60) : (line += 1) {
        const text = try std.fmt.bufPrint(&line_buffer, "line {d}\n", .{line});
        try contents.appendSlice(text);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "vim-scroll.txt", .data = contents.items });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, "vim-scroll.txt", &path_buffer);

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_len]}, 80, 24);
    defer workbench.deinit();
    var extension_host = try Extensions.init(allocator, io, workbench, &.{
        .{ .path = ".cache-ext/vim/extension", .is_under_development = true },
    }, ".cache-ext/data-vim-scroll-test");
    defer extension_host.deinit();

    const startup_deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < startup_deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null and extension_host.vim_active) break;
        time_compat.sleepMillis(10);
    }
    try std.testing.expect(extension_host.vim_active);
    _ = extension_host.handleKey(&.{ .key = .escape });
    _ = extension_host.pump();

    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(40, 1));
    _ = extension_host.pump();
    const initial_top = tab.editor.topViewLine();

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'z' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'z' } });
    const center_deadline = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < center_deadline) {
        _ = extension_host.pump();
        if (tab.editor.topViewLine() != initial_top) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(tab.editor.topViewLine() != initial_top);
    try std.testing.expect(tab.editor.topViewLine() <= 40);

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'z' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 't' } });
    const top_deadline = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < top_deadline) {
        _ = extension_host.pump();
        if (tab.editor.topViewLine() == 40) break;
        time_compat.sleepMillis(20);
    }
    try std.testing.expectEqual(@as(usize, 40), tab.editor.topViewLine());
}

test "Extensions: VSCodeVim gf opens the file under the cursor at a line" {
    if (!build_options.e2e) return error.SkipZigTest;
    const io = time_compat.io;
    std.Io.Dir.cwd().access(io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "target.txt:2\n" });
    var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_len = try tmp.dir.realPathFile(io, "source.txt", &source_buffer);

    var workbench = try Workbench.init(allocator, io, &.{source_buffer[0..source_len]}, 80, 24);
    defer workbench.deinit();

    var extension_host = try Extensions.init(allocator, io, workbench, &.{
        .{ .path = ".cache-ext/vim/extension", .is_under_development = true },
    }, ".cache-ext/data-vim-gf-test");
    defer extension_host.deinit();

    const startup_deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < startup_deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null) break;
        time_compat.sleepMillis(10);
    }
    try std.testing.expect(extension_host.active != null);
    const vim_deadline = time_compat.milliTimestamp() + 10_000;
    while (!extension_host.vim_active and time_compat.milliTimestamp() < vim_deadline) {
        _ = extension_host.pump();
        time_compat.sleepMillis(20);
    }
    try std.testing.expect(extension_host.vim_active);

    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(1, 1));
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'g' } });
    _ = extension_host.pump();
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'f' } });
    const deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < deadline) {
        _ = extension_host.pump();
        if (workbench.activeTab()) |opened| {
            if (std.mem.endsWith(u8, opened.editor.path, "target.txt") and
                opened.editor.modelCursorPosition().lineNumber == 2) break;
        }
        time_compat.sleepMillis(20);
    }
    const opened = workbench.activeTab().?;
    try std.testing.expect(std.mem.endsWith(u8, opened.editor.path, "target.txt"));
    try std.testing.expectEqual(@as(usize, 2), opened.editor.modelCursorPosition().lineNumber);
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
