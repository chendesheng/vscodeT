// Terminal adapter for inlineCompletionsController.ts. Active-editor/model
// events trigger the debounced provider request; stale RPC replies are discarded.
const std = @import("std");
const EditorService = @import("../../services/editor/browser/editorService.zig").EditorService;
const Tab = @import("../../browser/parts/editor/editorPane.zig").Tab;
const EditorInput = @import("../../common/editor/editorInput.zig").EditorInput;
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const dispatch = @import("../../../base/common/windowDispatch.zig");
const view_events = @import("../../../editor/common/viewEvents.zig");
const ViewEventHandler = @import("../../../editor/common/viewEventHandler.zig").ViewEventHandler;
const ModelChange = @import("../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const SuggestWidget = @import("../../../editor/contrib/suggest/browser/suggestWidget.zig").SuggestWidget;
const Position = @import("../../../editor/common/core/position.zig").Position;
const Range = @import("../../../editor/common/core/range.zig").Range;
const features = @import("mainThreadLanguageFeatures.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const time = @import("../../../base/common/timeCompat.zig");
const uri = @import("../../../base/common/stdUri.zig");
const endpoint = proxy(protocol.ExtHostContext.ExtHostLanguageFeatures);

pub const Session = struct {
    editors: EditorService,
    configuration: configuration.IConfigurationService,
    io: std.Io,
    window: *dispatch.Queue,
    host_context: *anyopaque,
    has_editor_focus: *const fn (*anyopaque) bool,
    request_frame: *const fn (*anyopaque) void,
    actor: ?*features.MainThreadLanguageFeatures = null,
    active_listener: ?usize = null,
    visible_listener: ?usize = null,
    provider_listener: ?usize = null,
    content_listener: ?usize = null,
    suggest_listener: ?usize = null,
    suggest_widget: ?*SuggestWidget = null,
    view_handler: ViewEventHandler = .{},
    edit_task: dispatch.Task = .{},
    request_task: dispatch.Task = .{},
    tab: ?*Tab = null,
    accepting: bool = false,
    host: *manager.HostManager,
    arena: std.heap.ArenaAllocator,
    version: u32 = 0,
    position: Position = .{ .lineNumber = 1, .column = 1 },
    pending: ?u32 = null,
    remaining: []const features.InlineProvider = &.{},
    handle: u32 = 0,
    supports_events: bool = false,
    stale: bool = false,
    list_id: ?i64 = null,
    command: ?std.json.Value = null,

    pub fn start(self: *Session, actor: *features.MainThreadLanguageFeatures) !void {
        self.actor = actor;
        self.edit_task = .{ .queue = self.window, .context = self, .run = onEditDeadline };
        self.request_task = .{ .queue = self.window, .context = self, .run = onRequestDeadline };
        self.active_listener = try self.editors.onDidActiveEditorChange().listen(self, onActiveEditorChange);
        self.visible_listener = try self.editors.onDidVisibleEditorsChange().listen(self, onVisibleEditorsChange);
        self.provider_listener = try actor.inline_providers.on_did_change.listen(self, onProvidersChanged);
        try self.updateActiveEditor();
    }

    pub fn deinit(self: *Session) void {
        if (self.active_listener) |listener| self.editors.onDidActiveEditorChange().unlisten(listener);
        if (self.visible_listener) |listener| self.editors.onDidVisibleEditorsChange().unlisten(listener);
        if (self.provider_listener) |listener| self.actor.?.inline_providers.on_did_change.unlisten(listener);
        self.detachEditor();
        self.arena.deinit();
    }

    fn detachEditor(self: *Session) void {
        self.dismiss();
        if (self.suggest_widget) |widget| {
            if (self.suggest_listener) |listener| widget.on_did_show.unlisten(listener);
        }
        self.suggest_widget = null;
        self.suggest_listener = null;
        if (self.tab) |tab| {
            if (self.content_listener) |listener| tab.editor.model.removeDidChangeContentListener(listener);
            tab.editor.removeViewEventHandler(&self.view_handler);
        }
        self.tab = null;
        self.content_listener = null;
    }

    fn onActiveEditorChange(_: ?*EditorInput, self: *Session) !void {
        try self.updateActiveEditor();
    }

    fn onVisibleEditorsChange(_: void, self: *Session) !void {
        try self.updateActiveEditor();
    }

    fn onProvidersChanged(count: usize, self: *Session) !void {
        if (count == 0) self.dismiss();
    }

    fn updateActiveEditor(self: *Session) !void {
        const next = self.editors.activeEditorPane();
        if (self.tab == next) return;
        self.detachEditor();
        const tab = next orelse return;
        if (tab.editor.read_only or tab.isImage() or tab.terminal_input != null or tab.markdown_preview != null) return;
        self.tab = tab;
        self.view_handler = ViewEventHandler.init(self, .{ .onCursorStateChanged = onCursorChange, .onFocusChanged = onFocusChange });
        self.content_listener = try tab.editor.model.onDidChangeContentWithContextId(self, onContentChange);
        tab.editor.addViewEventHandler(&self.view_handler);
    }

    fn onContentChange(_: ModelChange, self: *Session) !void {
        if (self.accepting) return;
        self.dismiss();
        // The command runner updates the cursor after the model emits content
        // changes. Observe the final selection in the next window turn.
        self.edit_task.schedule(time.milliTimestamp());
    }

    fn onCursorChange(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        if (!self.accepting and self.edit_task.at == null and
            (event.modelSelections.len != 1 or !event.modelSelections[0].isEmpty() or !event.modelSelections[0].getPosition().equals(self.position))) self.dismiss();
        return false;
    }

    fn onFocusChange(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        if (!event.isFocused) self.dismiss();
        return false;
    }

    fn onSuggestShown(_: *SuggestWidget, self: *Session) !void {
        self.dismiss();
    }

    fn onEditDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        const tab = self.tab orelse return false;
        if (!self.eligible(tab)) return false;
        if (tab.editor.cursorCount() != 1 or !tab.editor.modelSelection().isEmpty()) return false;
        if (tab.controllers) |controllers| {
            if (self.suggest_listener == null) {
                if (controllers.editor.getContribution(@import("../../../editor/contrib/suggest/browser/suggestController.zig").SuggestController)) |suggest| {
                    self.suggest_widget = suggest.widget;
                    self.suggest_listener = suggest.widget.on_did_show.listen(self, onSuggestShown) catch null;
                }
            }
        }
        self.version = tab.editor.model.getVersionId();
        self.position = tab.editor.modelCursorPosition();
        self.request_task.schedule(now + 200);
        return false;
    }

    fn eligible(self: *Session, tab: *Tab) bool {
        if (!self.has_editor_focus(self.host_context) or tab.editor.read_only or tab.markdown_preview != null) return false;
        if (self.actor == null or self.actor.?.inline_providers.entries.items.len == 0) return false;
        if (!self.configuration.getBool("editor.inlineSuggest.enabled", true)) return false;
        if (tab.editor.snippet_state.in_snippet_mode) return false;
        if (tab.controllers) |controllers| {
            if (controllers.suggest) |suggest| if (suggest.isOpen()) return false;
        }
        return true;
    }

    pub fn dismiss(self: *Session) void {
        self.edit_task.schedule(null);
        self.request_task.schedule(null);
        if (self.pending) |id| self.host.rpc.cancel(id);
        self.pending = null;
        self.remaining = &.{};
        self.stale = true;
        if (self.tab) |tab| {
            if (tab.view.ghost_text.text != null) {
                tab.view.ghost_text.clear();
                tab.view.invalidate();
                self.request_frame(self.host_context);
            }
        }
        if (self.list_id) |id| self.release(id);
        self.list_id = null;
        self.command = null;
        _ = self.arena.reset(.retain_capacity);
    }

    fn release(self: *Session, id: i64) void {
        var reason: std.json.ObjectMap = .empty;
        reason.put(self.arena.allocator(), "kind", .{ .string = "other" }) catch return;
        self.host.notify(endpoint, "$freeInlineCompletionsList", &.{ .{ .json = .{ .integer = self.handle } }, .{ .json = .{ .integer = id } }, .{ .json = .{ .object = reason } } }) catch {};
    }

    fn onRequestDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        self.requestNext(now) catch self.dismiss();
        return false;
    }

    fn requestNext(self: *Session, now: i64) !void {
        const tab = self.tab orelse return;
        if (!self.eligible(tab) or tab.editor.model.getVersionId() != self.version or !tab.editor.modelCursorPosition().equals(self.position)) {
            self.dismiss();
            return;
        }
        const editor = tab.editor;
        const a = self.arena.allocator();
        if (self.pending) |request| {
            self.host.rpc.cancel(request);
            self.pending = null;
        } else if (self.stale) {
            self.remaining = try self.actor.?.inline_providers.ordered(a, editor.model, false);
        }
        self.stale = false;
        if (self.remaining.len == 0) return;
        const provider = self.remaining[0];
        self.remaining = self.remaining[1..];
        self.handle = provider.handle;
        self.supports_events = provider.supports_events;
        var uuid: [16]u8 = undefined;
        self.io.random(&uuid);
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(uuid, .lower);
        const request_uuid = try std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..] });
        var ctx: std.json.ObjectMap = .empty;
        try ctx.put(a, "triggerKind", .{ .integer = 0 });
        try ctx.put(a, "requestUuid", .{ .string = request_uuid });
        try ctx.put(a, "includeInlineCompletions", .{ .bool = true });
        try ctx.put(a, "includeInlineEdits", .{ .bool = false });
        try ctx.put(a, "requestIssuedDateTime", .{ .integer = now });
        try ctx.put(a, "earliestShownDateTime", .{ .integer = now });
        self.stale = false;
        self.pending = try self.host.call(endpoint, "$provideInlineCompletions", &.{
            .{ .json = .{ .integer = self.handle } },                               .{ .json = try uri.jsonComponents(a, editor.model.uri()) },
            .{ .json = try features.positionJson(a, editor.model, self.position) }, .{ .json = .{ .object = ctx } },
        }, .None, .{ .context = self, .callback = receive });
        self.request_task.schedule(now + 15_000);
    }

    fn receive(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.pending = null;
        self.request_task.schedule(null);
        defer if (self.remaining.len > 0 and !self.stale) self.request_task.schedule(time.milliTimestamp());
        if (reply != .json or reply.json != .object) return;
        const list = reply.json.object;
        const id = list.get("pid") orelse return;
        if (id != .integer) return;
        defer if (self.list_id == null) self.release(id.integer);
        const tab = self.tab orelse return;
        const editor = tab.editor;
        if (self.stale or !self.eligible(tab) or editor.model.getVersionId() != self.version or !editor.modelCursorPosition().equals(self.position)) return;
        const items = list.get("items") orelse return;
        if (items != .array) return;
        for (items.array.items) |item| {
            if (item != .object) continue;
            const text = item.object.get("insertText") orelse continue;
            if (text != .string) continue;
            if (item.object.get("isInlineEdit")) |edit| {
                if (edit == .bool and edit.bool) continue;
            }
            const p = self.position;
            const range = if (item.object.get("range")) |raw| features.rangeFromJson(editor.model, raw) orelse continue else Range.init(p.lineNumber, p.column, p.lineNumber, p.column);
            if (!(tab.view.ghost_text.show(range, text.string) catch false)) continue;
            self.remaining = &.{};
            self.list_id = id.integer;
            if (self.supports_events) {
                if (item.object.get("idx")) |index| self.host.notify(endpoint, "$handleInlineCompletionDidShow", &.{
                    .{ .json = .{ .integer = self.handle } }, .{ .json = id }, .{ .json = index }, .{ .json = text },
                }) catch {};
            }
            if (item.object.get("command")) |cmd| self.command = rpc.cloneJsonValue(self.arena.allocator(), cmd) catch null;
            tab.view.invalidate();
            self.request_frame(self.host_context);
            return;
        }
    }

    pub fn accept(self: *Session) !bool {
        const tab = self.tab orelse return false;
        self.accepting = true;
        defer self.accepting = false;
        if (!self.eligible(tab) or !try tab.view.ghost_text.accept()) return false;
        if (self.command) |cmd| {
            if (cmd == .object) {
                if (cmd.object.get("id")) |id| {
                    const args = cmd.object.get("arguments") orelse std.json.Value{ .array = std.json.Array.init(self.arena.allocator()) };
                    if (id == .string and args == .array) try self.host.executeContributedCommand(id.string, args.array.items);
                }
            }
        }
        self.dismiss();
        self.request_frame(self.host_context);
        return true;
    }
};
