// TUI adapter for the pinned VS Code extension host.
//
// The portable pieces (transport, RPC, generated protocol table, host boot)
// live under `src/vs/workbench/services/extensions/`. This file owns only the
// terminal-specific state: the active tab's document mirror, the command
// surface VSCodeVim calls back into, and the key path that sends typed text
// through the `type` command.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const manager = @import("../vs/workbench/services/extensions/common/extensionHostManager.zig");
const extension_service = @import("../vs/workbench/services/extensions/common/extensionService.zig");
const rpc = @import("../vs/workbench/services/extensions/common/rpcProtocol.zig");
const proxyIdentifier = @import("../vs/workbench/services/extensions/common/proxyIdentifier.zig");
const protocol = @import("../vs/workbench/api/common/extHost.protocol.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextEdit = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const Workbench = @import("./workbench.zig").Workbench;
const SplitDirection = @import("./workbench.zig").SplitDirection;
const statusbar = @import("../vs/workbench/services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../vs/workbench/browser/parts/statusbar/statusbarPart.zig");
const configuration = @import("../vs/platform/configuration/common/configuration.zig");
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const ui = @import("ui");
const MainThreadLanguageFeatures = @import("../vs/workbench/api/browser/mainThreadLanguageFeatures.zig").MainThreadLanguageFeatures;
const languageFeaturesHost = @import("../vs/workbench/api/browser/mainThreadLanguageFeatures.zig").HostProxy;
const MainThreadDiagnostics = @import("../vs/workbench/api/browser/mainThreadDiagnostics.zig").MainThreadDiagnostics;
const MainThreadStorage = @import("../vs/workbench/api/browser/mainThreadStorage.zig").MainThreadStorage;
const MainThreadStatusBar = @import("../vs/workbench/api/browser/mainThreadStatusBar.zig").MainThreadStatusBar;
const MainThreadCommands = @import("../vs/workbench/api/browser/mainThreadCommands.zig").MainThreadCommands;
const MainThreadConfiguration = @import("../vs/workbench/api/browser/mainThreadConfiguration.zig").MainThreadConfiguration;
const documents_and_editors = @import("../vs/workbench/api/browser/mainThreadDocumentsAndEditors.zig");
const MainThreadDocuments = @import("../vs/workbench/api/browser/mainThreadDocuments.zig").MainThreadDocuments;
const MainThreadTextEditors = @import("../vs/workbench/api/browser/mainThreadTextEditors.zig").MainThreadTextEditors;
const EditSpec = @import("../vs/workbench/api/browser/mainThreadTextEditors.zig").EditSpec;
const MainThreadEditorTabs = @import("../vs/workbench/api/browser/mainThreadEditorTabs.zig").MainThreadEditorTabs;
const MainThreadWindow = @import("../vs/workbench/api/browser/mainThreadWindow.zig").MainThreadWindow;
const MainThreadExtensionService = @import("../vs/workbench/api/browser/mainThreadExtensionService.zig").MainThreadExtensionService;
const diagnosticsHost = @import("../vs/workbench/api/browser/mainThreadDiagnostics.zig").HostProxy;
const markers_mod = @import("../vs/platform/markers/common/markers.zig");
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const position_converter = @import("../vs/workbench/api/common/positionConverter.zig");

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
    data_path: []u8,
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
        data_path: []const u8,
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

        const data = try allocator.dupe(u8, data_path);
        errdefer allocator.free(data);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workbench = workbench,
            .host = undefined,
            .descriptions = owned_descriptions,
            .extension_ptrs = extension_ptrs,
            .data_path = data,
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
            .data_path = data,
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
        self.allocator.free(self.data_path);
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

    fn languageFeaturesRequest(context: *anyopaque, allocator: Allocator, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, timeout_ms: u32) anyerror!std.json.Value {
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

    fn invokeLanguageFeatures(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.language_features_actor) |*actor| return actor.invoke(method, args, token, arena);
        return .empty;
    }

    fn invokeDiagnostics(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.diagnostics_actor) |actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeStorage(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.storage_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeStatusBar(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.statusbar_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeCommands(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.commands_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeConfiguration(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.configuration_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeDocuments(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.documents_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeTextEditors(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.text_editors_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeEditorTabs(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.editor_tabs_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeWindow(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.window_actor) |*actor| return actor.invoke(method, args, arena);
        return .empty;
    }

    fn invokeExtensionService(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
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
        self.needs_render = true;
        return manager.fileUri(arena, path);
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
        _ = options;
        const self: *Extensions = @ptrCast(@alignCast(context));
        const path = uriPath(uri) orelse return null;
        self.workbench.openPath(path) catch {};
        self.needs_render = true;
        return "1";
    }

    fn textEditorRevealHost(context: *anyopaque) anyerror!void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (self.active) |active| active.editor.ensureCursorVisible();
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
            .data_path = self.data_path,
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

        const uri_path = tab.editor.path;
        const uri = try self.allocator.dupe(u8, uri_path);
        errdefer self.allocator.free(uri);
        const language = try self.allocator.dupe(u8, tab.editor.languageId());
        errdefer self.allocator.free(language);

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const selections = try tab.editor.getSelections();
        defer tab.editor.allocator.free(selections);
        const delta = try documents_and_editors.addDocumentDelta(
            arena,
            tab.editor.model,
            uri_path,
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
                    .path = tab.editor.path,
                    .label = std.fs.path.basename(tab.editor.path),
                    .is_active = tab == active_tab,
                    .is_dirty = tab.editor.dirty_state,
                });
            }
        }
        if (self.editor_tabs_actor) |*actor| try actor.sync(arena, active_tab.editor.path, specs.items);
    }

    fn removeActiveDocument(self: *Extensions) !void {
        const active = self.active orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const delta = try documents_and_editors.removedDocumentDelta(arena, active.uri);
        var args = [_]rpc.Arg{.{ .json = delta }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback) catch {};
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

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
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
        const change = editor.takeLastContentChange();
        defer if (change) |value| editor.allocator.free(value.text);
        const active = &(self.active orelse return);
        active.version += 1;
        if (change) |value| {
            try self.sendModelChanged(arena, value.text, value.range.getStartPosition(), value.range.getEndPosition());
        } else {
            try self.sendModelChanged(arena, text, start, start);
        }
        try self.sendSelection(arena, .command);
        self.needs_render = true;
    }

    fn applyCommandEdit(self: *Extensions, arena: Allocator, editor: *Editor) !void {
        const active = &(self.active orelse return);
        const post_selections = try editor.getSelections();
        defer editor.allocator.free(post_selections);
        self.pending_type_selection = if (post_selections.len > 0) post_selections[0] else null;
        active.version += 1;
        if (editor.takeLastContentChange()) |change| {
            defer editor.allocator.free(change.text);
            try self.sendModelChanged(arena, change.text, change.range.getStartPosition(), change.range.getEndPosition());
        }
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
        for (text_edits.items) |edit| {
            try self.sendModelChanged(arena, edit.text, edit.range.getStartPosition(), edit.range.getStartPosition());
        }
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

    fn sendSelection(self: *Extensions, arena: Allocator, source: SelectionSource) !void {
        const active = self.active orelse return;
        const selections = try active.editor.getSelections();
        defer active.editor.allocator.free(selections);
        const value = try documents_and_editors.editorPropertiesChanged(arena, "1", active.editor.model, selections, source.wireName());
        if (value != .array or value.array.items.len < 2) return;
        var args = [_]rpc.Arg{
            .{ .json = value.array.items[0] },
            .{ .json = value.array.items[1] },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditors), "$acceptEditorPropertiesChanged", &args, null, manager.noop_callback) catch {};
        self.captureSelections(active.editor);
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

fn executeHostCommand(context: *anyopaque, command: []const u8, command_args: std.json.Value, arena: Allocator) anyerror!?std.json.Value {
    const self: *Extensions = @ptrCast(@alignCast(context));
    const args: []const std.json.Value = if (command_args == .array) command_args.array.items else &.{};
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
    if (std.mem.eql(u8, command, "editor.action.revealDefinition")) {
        _ = self.workbench.revealDefinition() catch false;
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
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
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

test "Extensions: language feature registration reaches the workbench registries" {
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
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
        @import("../vs/base/common/cancellation.zig").CancellationToken.None,
        null,
    );
    try std.testing.expect(hover != null);

    const completion_providers = try features.completion_provider.ordered(allocator, model, false);
    defer allocator.free(completion_providers);
    try std.testing.expect(completion_providers.len > 0);

    const symbol_providers = try features.document_symbol_provider.ordered(allocator, model, false);
    defer allocator.free(symbol_providers);
    try std.testing.expect(symbol_providers.len > 0);
}

test "Extensions: real TypeScript extension drives the language features" {
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
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
    const token = @import("../vs/base/common/cancellation.zig").CancellationToken.None;

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
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
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
