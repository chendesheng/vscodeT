// TUI adapter for the pinned VS Code extension host.
//
// The portable pieces (transport, RPC, generated protocol table, host boot)
// live under `src/vs/workbench/services/extensions/`. This file owns only the
// terminal-specific state: the active tab's document mirror, the command
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
const LastContentChange = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").LastContentChange;
const ChangeListener = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").ChangeListener;
const TextEdit = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const Workbench = @import("../../browser/workbench.zig").Workbench;
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
    language_id: []u8,
    /// The document contents the extension host currently mirrors. Change
    /// ranges are expressed against this snapshot, not against the already
    /// edited model, so end columns past a shortened line stay valid.
    lines: std.array_list.Managed([]u8),
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

fn freeDocumentLines(allocator: Allocator, lines: *std.array_list.Managed([]u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit();
}

fn captureDocumentLines(allocator: Allocator, model: *TextModel) !std.array_list.Managed([]u8) {
    var lines = std.array_list.Managed([]u8).init(allocator);
    errdefer freeDocumentLines(allocator, &lines);
    var line_number: usize = 1;
    while (line_number <= model.getLineCount()) : (line_number += 1) {
        var line = try model.getLineContent(line_number);
        defer line.deinit();
        const copy = try allocator.dupe(u8, line.items);
        errdefer allocator.free(copy);
        try lines.append(copy);
    }
    return lines;
}

/// Applies one model change to the extension host's mirrored lines. The change
/// ranges are byte columns of the mirrored snapshot, matching the model's
/// pre-edit coordinates; this is also what makes UTF-16 range conversion work
/// when an edit deletes the end of a line.
fn applyChangeToDocumentLines(
    allocator: Allocator,
    lines: *std.array_list.Managed([]u8),
    change: LastContentChange,
) !void {
    const start_line = change.range.startLineNumber;
    const end_line = change.range.endLineNumber;
    if (start_line == 0 or end_line < start_line or end_line > lines.items.len) return error.InvalidChange;
    const start_column = @min(@max(change.range.startColumn, 1), lines.items[start_line - 1].len + 1);
    const end_column = @min(@max(change.range.endColumn, 1), lines.items[end_line - 1].len + 1);

    var segment = std.array_list.Managed(u8).init(allocator);
    defer segment.deinit();
    try segment.appendSlice(lines.items[start_line - 1][0 .. start_column - 1]);
    try segment.appendSlice(change.text);
    try segment.appendSlice(lines.items[end_line - 1][end_column - 1 ..]);

    var replacement = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (replacement.items) |line| allocator.free(line);
        replacement.deinit();
    }
    var split = std.mem.splitScalar(u8, segment.items, '\n');
    while (split.next()) |line| try replacement.append(try allocator.dupe(u8, line));

    const remove_count = end_line - start_line + 1;
    const removed = try allocator.alloc([]u8, remove_count);
    defer allocator.free(removed);
    @memcpy(removed, lines.items[start_line - 1 .. end_line]);
    try lines.replaceRange(start_line - 1, remove_count, replacement.items);
    for (removed) |line| allocator.free(line);
    replacement.deinit();
}

fn utf16ColumnInLines(lines: []const []u8, line_number: usize, column: usize) usize {
    if (line_number == 0 or line_number > lines.len) return column;
    return position_converter.utf16OffsetForColumn(lines[line_number - 1], column);
}

pub const Extensions = struct {
    allocator: Allocator,
    io: Io,
    workbench: *Workbench,
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
    /// Signature of the last tab set sent to the editor-tabs actor. The pump
    /// runs on every loop iteration, so an unchanged tab rail must not rebuild
    /// its arena/spec list or call the actor.
    tabs_signature: u64 = 0,
    /// The active editor whose scroll events are mirrored to the host.
    scroll_listener_editor: ?*Editor = null,
    /// The active editor whose content changes are mirrored to the host. This
    /// is the single content-event path for host edits, terminal typing and
    /// built-in extensions such as native Vim.
    content_listener_editor: ?*Editor = null,
    visible_ranges_dirty: bool = false,
    inline_completions: @import("inlineCompletionSession.zig").Session = undefined,
    language_features_actor: ?MainThreadLanguageFeatures = null,
    diagnostics_actor: ?*MainThreadDiagnostics = null,
    storage_actor: ?MainThreadStorage = null,
    statusbar_actor: ?MainThreadStatusBar = null,
    task_actor: @import("mainThreadTask.zig").MainThreadTask = undefined,
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
            workbench.registerExtensionConfiguration(description.manifest, description.identifier);
        }

        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        const data = try std.fs.path.resolve(allocator, &.{ cwd, user_data_dir });
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

        const host_script = try std.fs.path.join(allocator, &.{ runtime_dir, "extensionHost.mjs" });
        defer allocator.free(host_script);
        // Fail before spawning node: without the bundle the host can never
        // connect, and the manager would otherwise wait for its socket timeout.
        std.Io.Dir.cwd().access(io, host_script, .{}) catch return error.ExtensionHostBundleMissing;
        const workspace_path = try std.fs.path.resolve(allocator, &.{ cwd, workbench.workspaceFolderPath() orelse "." });
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
        self.inline_completions = .{ .workbench = workbench, .host = self.host, .arena = .init(allocator) };

        self.storage_actor = try MainThreadStorage.init(allocator);
        self.statusbar_actor = try MainThreadStatusBar.init(allocator, &workbench.statusbar, .{
            .context = workbench,
            .callback = refreshWorkbenchStatus,
        });
        self.commands_actor = try MainThreadCommands.init(allocator, self.host, .{
            .context = self,
            .execute = executeHostCommand,
        }, &workbench.commands, self.descriptions, try workbench.ensureContextKeys());
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
        try self.task_actor.init(workbench, self.host, self.descriptions);
        errdefer self.task_actor.deinit();
        self.registerActors();
        self.initLanguageActors() catch |err| {
            std.log.warn("language feature actors unavailable: {s}", .{@errorName(err)});
        };
        try self.boot(runtime_dir);
        return self;
    }

    pub fn deinit(self: *Extensions) void {
        self.task_actor.deinit();
        self.inline_completions.deinit();
        self.setScrollListener(null);
        self.setContentListener(null);
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
            freeDocumentLines(self.allocator, &active.lines);
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

    fn boot(self: *Extensions, runtime_dir: []const u8) !void {
        try self.host.expectControl(2, 10_000);
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", arena);
        const workspace = try std.fs.path.resolve(arena, &.{ cwd, self.workbench.workspaceFolderPath() orelse "." });
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

        try self.syncActiveDocument();
        self.activateActiveLanguage();
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
        // A closed tab frees its editor before this pump observes the active
        // document change. Retire the mirror first: the frames dispatched by
        // `host.pump` below can carry editor requests, and their handlers must
        // not dereference the freed editor.
        self.removeClosedActiveDocument();
        _ = self.host.pump();
        if (self.diagnostics_actor) |actor| actor.flush() catch {};
        self.syncActiveDocument() catch {};
        self.activateActiveLanguage();
        self.syncSelection() catch {};
        if (self.visible_ranges_dirty) self.sendVisibleRanges() catch {};
        if (self.language_features_actor) |*actor| {
            if (self.inline_completions.tick(actor) catch false) self.needs_render = true;
        }
        const result = self.needs_render;
        self.needs_render = false;
        return result;
    }

    /// Retires the document mirror when its editor was freed by a tab close.
    /// Called before dispatching host frames, because handlers for those
    /// frames dereference the active editor.
    fn removeClosedActiveDocument(self: *Extensions) void {
        const active = self.active orelse return;
        if (self.workbench.ownsEditor(active.editor)) return;
        self.removeActiveDocument() catch {};
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

        const language_ids = try tab.editor.language_service.getRegisteredLanguageIds(arena);
        var ids = std.json.Array.init(arena);
        for (language_ids) |id| try ids.append(.{ .string = id });
        try self.host.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostLanguages), "$acceptLanguageIds", &.{.{ .json = .{ .array = ids } }});

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

        var lines = try captureDocumentLines(self.allocator, tab.editor.model);
        errdefer freeDocumentLines(self.allocator, &lines);
        self.active = .{ .editor = tab.editor, .uri = uri, .language_id = language, .lines = lines };
        self.setScrollListener(tab.editor);
        self.setContentListener(tab.editor);
        self.captureSelections(tab.editor);
        try self.syncTabs();
        self.needs_render = true;
    }

    fn syncTabs(self: *Extensions) !void {
        const active_tab = self.workbench.activeTab() orelse return;
        // The tab rail is mostly static; pumping it on every loop iteration
        // rebuilt the spec list and called the actor even when nothing moved.
        var hasher = std.hash.Wyhash.init(0);
        var tab_count: usize = 0;
        for (self.workbench.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab_count += 1;
                const editor_ptr: usize = @intFromPtr(tab.editor);
                hasher.update(std.mem.asBytes(&editor_ptr));
                hasher.update(&[_]u8{@intFromBool(tab.editor.dirty_state)});
            }
        }
        const active_ptr: usize = @intFromPtr(active_tab.editor);
        hasher.update(std.mem.asBytes(&active_ptr));
        hasher.update(std.mem.asBytes(&tab_count));
        const signature = hasher.final();
        if (signature == self.tabs_signature) return;

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
            // Only remember a delivered state; do not skip a later retry when
            // there was no actor yet.
            self.tabs_signature = signature;
        }
    }

    fn removeActiveDocument(self: *Extensions) !void {
        var active = self.active orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const delta = try documents_and_editors.removedDocumentDelta(arena, active.uri);
        var args = [_]rpc.Arg{.{ .json = delta }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback) catch {};
        self.setScrollListener(null);
        self.setContentListener(null);
        self.allocator.free(active.uri);
        self.allocator.free(active.language_id);
        freeDocumentLines(self.allocator, &active.lines);
        self.active = null;
        self.needs_render = true;
    }

    fn executeCommand(self: *Extensions, command: []const u8, command_args: []const std.json.Value) void {
        self.host.executeContributedCommand(command, command_args) catch {};
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        if (std.mem.eql(u8, method, "$startFileSearch")) {
            const self: *Extensions = @ptrCast(@alignCast(context));
            return .{ .json = try @import("mainThreadWorkspace.zig").findFiles(self.io, self.allocator, arena, self.workbench.workspaceFolderPath(), args) };
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
    /// handled once, by the active editor's content listener.
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

    fn sendModelChanges(self: *Extensions, arena: Allocator, changes: []const LastContentChange) !void {
        const active = if (self.active) |*value| value else return;
        var specs = std.array_list.Managed(documents_and_editors.ChangeSpec).init(arena);
        for (changes) |change| {
            try specs.append(.{
                .text = change.text,
                .start = .{ .line = change.range.startLineNumber, .column = change.range.startColumn },
                .end = .{ .line = change.range.endLineNumber, .column = change.range.endColumn },
                // Convert against the host's mirrored document, not the model
                // that already contains the edit. A deletion's end column is
                // past the shortened line in the new model and would otherwise
                // collapse to a zero-width change.
                .start_utf16 = utf16ColumnInLines(active.lines.items, change.range.startLineNumber, change.range.startColumn),
                .end_utf16 = utf16ColumnInLines(active.lines.items, change.range.endLineNumber, change.range.endColumn),
            });
        }
        const event = try documents_and_editors.modelChangesEvent(arena, active.editor.model, specs.items, active.editor.model.getVersionId());
        var args = [_]rpc.Arg{
            .{ .json = try manager.fileUri(arena, active.uri) },
            .{ .json = event },
            .{ .json = .{ .bool = false } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocuments), "$acceptModelChanged", &args, null, manager.noop_callback) catch {};

        for (changes) |change| {
            applyChangeToDocumentLines(self.allocator, &active.lines, change) catch {
                // A malformed change must not poison every later edit; the
                // model is already at the post-batch state, so resnapshot it.
                freeDocumentLines(self.allocator, &active.lines);
                active.lines = captureDocumentLines(self.allocator, active.editor.model) catch
                    std.array_list.Managed([]u8).init(self.allocator);
                break;
            };
        }
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

    fn onEditorContent(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        const active = self.active orelse return;
        if (active.editor.last_content_changes.items.len == 0) return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        self.sendModelChanges(arena_instance.allocator(), active.editor.last_content_changes.items) catch {};
    }

    fn setContentListener(self: *Extensions, editor: ?*Editor) void {
        if (self.content_listener_editor == editor) return;
        if (self.content_listener_editor) |old| {
            detachEditorListenerIfOwned(
                self.workbench,
                old,
                .content,
                .{ .context = self, .callback = onEditorContent },
            );
        }
        self.content_listener_editor = null;
        if (editor) |value| {
            value.addWorkingCopyContentListener(.{ .context = self, .callback = onEditorContent });
            self.content_listener_editor = value;
        }
    }

    fn onEditorScroll(context: *anyopaque) void {
        const self: *Extensions = @ptrCast(@alignCast(context));
        self.visible_ranges_dirty = true;
        self.needs_render = true;
    }

    fn setScrollListener(self: *Extensions, editor: ?*Editor) void {
        if (self.scroll_listener_editor == editor) return;
        if (self.scroll_listener_editor) |old| {
            detachEditorListenerIfOwned(
                self.workbench,
                old,
                .scroll,
                .{ .context = self, .callback = onEditorScroll },
            );
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
        const active = self.active orelse return;
        const selections = try active.editor.getSelections();
        defer active.editor.allocator.free(selections);
        if (sameSelections(self.last_selections.items, selections)) return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        try self.sendSelection(arena_instance.allocator(), self.selection_source);
    }
};

const EditorListenerKind = enum { scroll, content };

/// Detaches one of the extension bridge's editor listeners, but only while the
/// workbench still owns the editor.
///
/// Closing a tab frees its editor immediately, while the bridge only observes
/// the active-document change on the next `pump`. The raw pointer kept by
/// `Extensions` is therefore stale until then, and the workbench's live tab
/// views are the only safe way to test it: dereferencing the freed editor to
/// remove the listener is a use-after-free (the `removeChangeListener` crash
/// in `codeEditorWidgetTerminal.zig`).
fn detachEditorListenerIfOwned(
    workbench: *const Workbench,
    editor: *Editor,
    kind: EditorListenerKind,
    listener: ChangeListener,
) void {
    if (!workbench.ownsEditor(editor)) return;
    switch (kind) {
        .scroll => editor.removeScrollListener(listener),
        .content => editor.removeWorkingCopyContentListener(listener),
    }
}

/// Maps command ids issued by Node extensions to the workbench LSP
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

fn executeHostCommand(context: *anyopaque, command: []const u8, command_args: std.json.Value, arena: Allocator) anyerror!?std.json.Value {
    const self: *Extensions = @ptrCast(@alignCast(context));
    const args: []const std.json.Value = if (command_args == .array) command_args.array.items else &.{};
    if (std.mem.eql(u8, command, "workbench.action.browser.open") or std.mem.eql(u8, command, "simpleBrowser.show")) {
        try self.workbench.openBrowser(if (args.len > 0 and args[0] == .string) args[0].string else null);
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
        self.workbench.findInFiles() catch {};
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
            self.workbench.preferredSideBySideDirection()
        else if (std.mem.eql(u8, command, "workbench.action.splitEditorOrthogonal"))
            if (self.workbench.preferredSideBySideDirection() == .RIGHT) .DOWN else .RIGHT
        else
            .RIGHT;
        self.workbench.splitActiveInDirection(direction) catch {};
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
        // Context keys are accepted for extension compatibility; the Node API
        // surface does not yet expose a terminal context-key registry.
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

test "Extensions: listener detach ignores editors the workbench no longer owns" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "owned.txt", .data = "alpha" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, "owned.txt", &path_buffer);

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_len]}, 40, 9);
    defer workbench.deinit();

    var content_calls: usize = 0;
    var scroll_calls: usize = 0;
    const content_listener = ChangeListener{ .context = &content_calls, .callback = countListenerCall };
    const scroll_listener = ChangeListener{ .context = &scroll_calls, .callback = countListenerCall };

    // An editor that the workbench still owns is detached normally.
    const owned = workbench.activeTab().?.editor;
    owned.addWorkingCopyContentListener(content_listener);
    owned.addScrollListener(scroll_listener);
    detachEditorListenerIfOwned(workbench, owned, .content, content_listener);
    detachEditorListenerIfOwned(workbench, owned, .scroll, scroll_listener);
    try owned.typeCharacter("x");
    owned.emitCurrentViewState();
    try std.testing.expectEqual(@as(usize, 0), content_calls);
    try std.testing.expectEqual(@as(usize, 0), scroll_calls);
    // A clean editor closes without the dirty confirmation.
    try owned.save();

    // A live editor outside the tab views stands in for one freed by a tab
    // close. Detaching must skip it: the real pointer is already freed by the
    // close, and dereferencing it to remove the listener is the crash this
    // guard prevents (`removeChangeListener` in codeEditorWidgetTerminal.zig).
    var stale = try Editor.createFromText(allocator, io, "beta", "stale.txt", 40, 9);
    defer {
        stale.deinit();
        allocator.destroy(stale);
    }
    stale.addWorkingCopyContentListener(content_listener);
    stale.addScrollListener(scroll_listener);
    detachEditorListenerIfOwned(workbench, stale, .content, content_listener);
    detachEditorListenerIfOwned(workbench, stale, .scroll, scroll_listener);
    try stale.typeCharacter("y");
    stale.emitCurrentViewState();
    try std.testing.expect(content_calls > 0);
    try std.testing.expect(scroll_calls > 0);

    // The exact crash sequence: Ctrl-W frees the active editor, and the next
    // pump's `removeActiveDocument` detaches its listeners. The freed pointer
    // must only be compared against the live tab views; dereferencing it here
    // crashed in `removeChangeListener`.
    try workbench.activeTab().?.ensureControllers();
    const closed = workbench.activeTab().?.editor;
    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    const TabKeyResult = @import("../../browser/workbench.zig").TabKeyResult;
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expect(!workbench.ownsEditor(closed));
    detachEditorListenerIfOwned(workbench, closed, .content, content_listener);
    detachEditorListenerIfOwned(workbench, closed, .scroll, scroll_listener);
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

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();

    var extension_host = try Extensions.init(allocator, io, workbench, &.{.{ .path = "host/test-fixtures/language-features", .is_under_development = true }}, ".cache-ext/data-language-fixture", "host/dist");
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
    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(1, model.getLineMaxColumn(1)));
    try tab.editor.insertText("é");
    _ = extension_host.pump();
    const inline_deadline = time_compat.milliTimestamp() + 5_000;
    while (!tab.view.ghost_text.isVisible() and time_compat.milliTimestamp() < inline_deadline) {
        _ = extension_host.pump();
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

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();

    var extension_host = try Extensions.init(
        allocator,
        io,
        workbench,
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

    var workbench = try Workbench.init(allocator, io, &.{path_buffer[0..path_length]}, 100, 30);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    var extension_host = try Extensions.init(
        allocator,
        io,
        workbench,
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
    var workbench = try Workbench.init(allocator, io, &.{buf[0..len]}, 100, 30);
    defer workbench.deinit();
    workbench.setDeclarativeExtensions(&catalog);
    try workbench.enableLanguageFeatures();
    var extensions = try Extensions.init(allocator, io, workbench, &.{.{
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
    var workbench = try Workbench.init(allocator, io, &.{path}, 80, 25);
    defer workbench.deinit();
    var host = try Extensions.init(allocator, io, workbench, &.{.{ .path = "host/dist/extensions/merge-conflict", .is_builtin = true }}, ".cache-ext/test-merge", "host/dist");
    defer host.deinit();
    const command = "merge-conflict.accept.all-incoming";
    const deadline = time_compat.milliTimestamp() + 10_000;
    while (workbench.commands.get(command) == null and time_compat.milliTimestamp() < deadline) {
        _ = host.pump();
        time_compat.sleepMillis(10);
    }
    const action = workbench.commands.get(command) orelse return error.MissingMergeCommand;
    try std.testing.expect(action.show_in_palette and action.precondition.?(action.context));
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
