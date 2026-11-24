// Workbench-side lifecycle for the active editor's extension-host inline
// completion request. Replies arrive through the normal event-loop pump.
const std = @import("std");
const Workbench = @import("../../browser/workbench.zig").Workbench;
const Editor = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../../tui/editorView.zig").View;
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
    workbench: *Workbench,
    host: *manager.HostManager,
    arena: std.heap.ArenaAllocator,
    editor: ?*Editor = null,
    view: ?*View = null,
    version: u32 = 0,
    position: Position = .{ .lineNumber = 1, .column = 1 },
    due: ?i64 = null,
    pending: ?u32 = null,
    handle: u32 = 0,
    supports_events: bool = false,
    sent_at: i64 = 0,
    stale: bool = false,
    list_id: ?i64 = null,
    command: ?std.json.Value = null,
    changed: bool = false,

    pub fn deinit(self: *Session) void {
        if (self.pending) |id| self.host.rpc.cancel(id);
        self.dismiss();
        self.arena.deinit();
    }

    pub fn dismiss(self: *Session) void {
        self.stale = true;
        self.due = null;
        if (self.editor) |editor| {
            if (self.workbench.ownsEditor(editor)) {
                if (self.view) |view| {
                    if (view.ghost_text.text != null) {
                        view.ghost_text.clear();
                        view.invalidate();
                        self.changed = true;
                    }
                }
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

    pub fn tick(self: *Session, actor: *features.MainThreadLanguageFeatures) !bool {
        defer self.changed = false;
        const tab = self.workbench.activeTab();
        if (tab == null or self.workbench.focus != .editor or tab.?.editor.read_only or actor.inline_providers.entries.items.len == 0) {
            if (self.editor != null) self.dismiss();
            self.editor = null;
            self.view = null;
            return self.changed;
        }
        const editor = tab.?.editor;
        const now = time.milliTimestamp();
        const version = editor.model.getVersionId();
        const position = editor.modelCursorPosition();
        if (self.editor != editor or self.version != version or !self.position.equals(position)) {
            const edited = self.editor == editor and self.version != version;
            self.dismiss();
            self.editor = editor;
            self.view = tab.?.view;
            self.version = version;
            self.position = position;
            if (edited and editor.cursorCount() == 1 and editor.modelSelection().isEmpty()) self.due = now + 200;
        }
        if (self.pending) |request| {
            if (now - self.sent_at < 15_000) return self.changed;
            self.host.rpc.cancel(request);
            self.pending = null;
        }
        if (self.due == null or self.due.? > now) return self.changed;
        self.due = null;
        if (self.workbench.configuration) |cfg| {
            if (!cfg.getBool("editor.inlineSuggest.enabled", true)) return self.changed;
        }
        const a = self.arena.allocator();
        const providers = try actor.inline_providers.ordered(a, editor.model, false);
        if (providers.len == 0) return self.changed;
        self.handle = providers[0].handle;
        self.supports_events = providers[0].supports_events;
        self.sent_at = now;
        var uuid: [16]u8 = undefined;
        self.workbench.io.random(&uuid);
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
            .{ .json = .{ .integer = self.handle } },                          .{ .json = try uri.jsonComponents(a, editor.model.uri()) },
            .{ .json = try features.positionJson(a, editor.model, position) }, .{ .json = .{ .object = ctx } },
        }, .None, .{ .context = self, .callback = receive });
        return self.changed;
    }

    fn receive(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.pending = null;
        if (reply != .json or reply.json != .object) return;
        const list = reply.json.object;
        const id = list.get("pid") orelse return;
        if (id != .integer) return;
        defer if (self.list_id == null) self.release(id.integer);
        const tab = self.workbench.activeTab() orelse return;
        const editor = tab.editor;
        if (self.stale or self.workbench.focus != .editor or editor != self.editor or editor.model.getVersionId() != self.version or !editor.modelCursorPosition().equals(self.position)) return;
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
            self.list_id = id.integer;
            if (self.supports_events) {
                if (item.object.get("idx")) |index| self.host.notify(endpoint, "$handleInlineCompletionDidShow", &.{
                    .{ .json = .{ .integer = self.handle } }, .{ .json = id }, .{ .json = index }, .{ .json = text },
                }) catch {};
            }
            if (item.object.get("command")) |cmd| self.command = rpc.cloneJsonValue(self.arena.allocator(), cmd) catch null;
            self.changed = true;
            tab.view.invalidate();
            return;
        }
    }

    pub fn accept(self: *Session) !bool {
        const tab = self.workbench.activeTab() orelse return false;
        if (tab.editor != self.editor or !try tab.view.ghost_text.accept()) return false;
        if (self.command) |cmd| {
            if (cmd == .object) {
                if (cmd.object.get("id")) |id| {
                    const args = cmd.object.get("arguments") orelse std.json.Value{ .array = std.json.Array.init(self.arena.allocator()) };
                    if (id == .string and args == .array) try self.host.executeContributedCommand(id.string, args.array.items);
                }
            }
        }
        self.dismiss();
        tab.view.invalidate();
        return true;
    }
};
