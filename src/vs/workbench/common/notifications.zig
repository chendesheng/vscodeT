// Port of `src/vs/workbench/common/notifications.ts`.
// Terminal adaptation: view items and status messages retain their model-owned
// storage until the last handle is released. Action callback contexts are
// borrowed from their contribution, which must outlive the notification.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const linked = @import("../../base/common/linkedText.zig");
const notification = @import("../../platform/notification/common/notification.zig");
const Severity = @import("../../base/common/severity.zig").Severity;
const IAction = @import("../../base/common/actions.zig").IAction;

pub const NotificationChangeType = enum { ADD, CHANGE, EXPAND_COLLAPSE, REMOVE };
pub const NotificationViewItemContentChangeKind = enum { SEVERITY, MESSAGE, ACTIONS, PROGRESS };
pub const INotificationViewItemContentChangeEvent = struct {
    kind: NotificationViewItemContentChangeKind,
    active_progress_changed: ?bool = null,
};
pub const INotificationChangeEvent = struct {
    index: usize,
    item: *NotificationViewItem,
    kind: NotificationChangeType,
    detail: ?NotificationViewItemContentChangeKind = null,
    active_progress_changed: ?bool = null,
};
pub const StatusMessageChangeType = enum { ADD, REMOVE };
pub const IStatusMessageChangeEvent = struct { kind: StatusMessageChangeType, item: *const StatusMessageViewItem };
pub const INotificationsFilter = struct {
    global: notification.NotificationsFilter = .OFF,
    sources: std.StringHashMapUnmanaged(notification.NotificationsFilter) = .empty,
};
pub const FilterChange = struct { global: ?notification.NotificationsFilter = null, sources: bool = false };

pub const INotificationMessage = struct {
    arena: std.heap.ArenaAllocator,
    raw: []const u8,
    linked_text: linked.LinkedText,

    fn parse(allocator: Allocator, input: notification.NotificationMessage, legacy: bool) !?INotificationMessage {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const raw = try messageString(a, input);
        if (raw.len == 0) {
            arena.deinit();
            return null;
        }
        const nodes: []const linked.LinkedTextNode = switch (input) {
            .content => |content| content.nodes,
            else => &.{.{ .text = raw }},
        };
        var normalized = try normalizeLinkedText(a, nodes);
        if (legacy and input != .content) {
            normalized = try linked.parseLinkedText(a, try normalized.toString(a));
        }
        return .{ .arena = arena, .raw = raw, .linked_text = normalized };
    }

    fn deinit(self: *INotificationMessage) void {
        self.arena.deinit();
    }

    fn equals(self: INotificationMessage, other: INotificationMessage) bool {
        if (!std.mem.eql(u8, self.raw, other.raw) or self.linked_text.nodes.len != other.linked_text.nodes.len) return false;
        for (self.linked_text.nodes, other.linked_text.nodes) |left, right| {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
            switch (left) {
                .text => |text| if (!std.mem.eql(u8, text, right.text)) return false,
                .link => |link| if (!std.mem.eql(u8, link.label, right.link.label) or !std.mem.eql(u8, link.href, right.link.href) or !optionalEqual(link.title, right.link.title)) return false,
            }
        }
        return true;
    }
};

fn messageString(allocator: Allocator, input: notification.NotificationMessage) ![]u8 {
    return switch (input) {
        .text, .error_message => |value| allocator.dupe(u8, value),
        .content => |value| value.toString(allocator),
        .error_with_actions => |value| allocator.dupe(u8, value.message),
        .cancelled => allocator.dupe(u8, ""),
    };
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}

// Upstream counts UTF-16 code units. Do not split a UTF-8 scalar at the
// terminal boundary; a truncated supplementary scalar becomes U+FFFD.
fn normalizeLabel(a: Allocator, text: []const u8, remaining: usize) !struct { value: []const u8, length: usize } {
    var output = std.Io.Writer.Allocating.init(a);
    defer output.deinit();
    var length: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        const bytes = std.unicode.utf8ByteSequenceLength(text[position]) catch 1;
        const end = @min(position + bytes, text.len);
        const scalar = std.unicode.utf8Decode(text[position..end]) catch 0xfffd;
        const units: usize = if (scalar > 0xffff) 2 else 1;
        if (length + units <= remaining) {
            if (scalar == '\r') try output.writer.writeByte(' ') else if (scalar == '\n') {
                if (position == 0 or text[position - 1] != '\r') try output.writer.writeByte(' ');
            } else try output.writer.writeAll(text[position..end]);
        } else if (length < remaining) try output.writer.writeAll("\xef\xbf\xbd");
        length += units;
        position = end;
    }
    return .{ .value = try output.toOwnedSlice(), .length = length };
}

fn normalizeLinkedText(a: Allocator, input: []const linked.LinkedTextNode) !linked.LinkedText {
    var nodes: std.ArrayList(linked.LinkedTextNode) = .empty;
    var length: usize = 0;
    for (input) |node| {
        const label = switch (node) {
            .text => |value| value,
            .link => |value| value.label,
        };
        const normalized = try normalizeLabel(a, label, 1000 - length);
        if (normalized.value.len != 0) {
            switch (node) {
                .text => {
                    if (nodes.items.len != 0 and nodes.items[nodes.items.len - 1] == .text) {
                        const previous = &nodes.items[nodes.items.len - 1];
                        previous.text = try std.mem.concat(a, u8, &.{ previous.text, normalized.value });
                    } else try nodes.append(a, .{ .text = normalized.value });
                },
                .link => |value| try nodes.append(a, .{ .link = .{
                    .label = normalized.value,
                    .href = try a.dupe(u8, value.href),
                    .title = if (value.title) |title| try a.dupe(u8, title) else null,
                } }),
            }
        }
        length += normalized.length;
        if (length > 1000) {
            try nodes.append(a, .{ .text = "..." });
            break;
        }
    }
    if (nodes.items.len != 0 and nodes.items[0] == .text) nodes.items[0].text = std.mem.trimStart(u8, nodes.items[0].text, " \t\r\n\x0b\x0c");
    if (nodes.items.len != 0 and nodes.items[nodes.items.len - 1] == .text) {
        const last = &nodes.items[nodes.items.len - 1];
        last.text = std.mem.trimEnd(u8, last.text, " \t\r\n\x0b\x0c");
    }
    var i: usize = 0;
    while (i < nodes.items.len) {
        if (nodes.items[i] == .text and nodes.items[i].text.len == 0) _ = nodes.orderedRemove(i) else i += 1;
    }
    return .{ .nodes = try nodes.toOwnedSlice(a) };
}

pub const INotificationViewItemProgressState = struct {
    infinite: bool = false,
    total: ?i64 = null,
    worked: ?i64 = null,
    done: bool = false,
};

pub const NotificationViewItemProgress = struct {
    item: *NotificationViewItem,
    state: INotificationViewItemProgressState = .{},

    pub fn infinite(self: *NotificationViewItemProgress) void {
        if (self.state.infinite) return;
        const before = self.item.hasActiveProgress();
        self.state = .{ .infinite = true };
        self.changed(before);
    }
    pub fn done(self: *NotificationViewItemProgress) void {
        if (self.state.done) return;
        const before = self.item.hasActiveProgress();
        self.state = .{ .done = true };
        self.changed(before);
    }
    pub fn total(self: *NotificationViewItemProgress, value: i64) void {
        if (self.state.total == value) return;
        const before = self.item.hasActiveProgress();
        self.state.total = value;
        self.state.infinite = false;
        self.state.done = false;
        self.changed(before);
    }
    pub fn worked(self: *NotificationViewItemProgress, value: i64) void {
        const before = self.item.hasActiveProgress();
        self.state.worked = (self.state.worked orelse 0) +| value;
        self.state.infinite = false;
        self.state.done = false;
        self.changed(before);
    }
    fn changed(self: *NotificationViewItemProgress, before: bool) void {
        self.item.contentChanged(.{ .kind = .PROGRESS, .active_progress_changed = before != self.item.hasActiveProgress() });
    }
    fn fromContext(ctx: *anyopaque) *NotificationViewItemProgress {
        return @ptrCast(@alignCast(ctx));
    }
    fn inf(ctx: *anyopaque) void {
        fromContext(ctx).infinite();
    }
    fn end(ctx: *anyopaque) void {
        fromContext(ctx).done();
    }
    fn setTotal(ctx: *anyopaque, value: i64) void {
        fromContext(ctx).total(value);
    }
    fn addWorked(ctx: *anyopaque, value: i64) void {
        fromContext(ctx).worked(value);
    }
    pub fn interface(self: *NotificationViewItemProgress) notification.INotificationProgress {
        return .{ .context = self, .infinite_fn = inf, .done_fn = end, .total_fn = setTotal, .worked_fn = addWorked };
    }
};

pub const NotificationViewItem = struct {
    allocator: Allocator,
    model: ?*NotificationsModel = null,
    arena: std.heap.ArenaAllocator,
    id: ?[]const u8,
    severity: Severity,
    explicit_sticky: bool,
    priority: notification.NotificationPriority,
    message: INotificationMessage,
    source: ?[]const u8,
    source_id: ?[]const u8,
    actions: notification.INotificationActions = .{},
    legacy_links: bool,
    expanded: bool = false,
    visible: bool = false,
    progress_value: ?NotificationViewItemProgress = null,
    closed: bool = false,
    retained_handle: bool = false,
    notifying: usize = 0,
    on_did_change_expansion: Emitter(void),
    on_did_change_visibility: Emitter(bool),
    on_did_change_content: Emitter(INotificationViewItemContentChangeEvent),
    on_did_close: Emitter(void),

    pub fn create(allocator: Allocator, input: notification.INotification, filter: INotificationsFilter) !?*NotificationViewItem {
        var message = (try INotificationMessage.parse(allocator, input.message, input.legacy_extension_link_parsing != null)) orelse return null;
        errdefer message.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = if (input.source) |s| try a.dupe(u8, switch (s) {
            .text => |text| text,
            .source => |v| v.label,
        }) else null;
        const source_id = if (input.source) |s| switch (s) {
            .text => null,
            .source => |v| try a.dupe(u8, v.id),
        } else null;
        var priority = input.priority;
        if ((priority == .DEFAULT or priority == .OPTIONAL) and input.severity != .Error) {
            if (filter.global == .ERROR or (source_id != null and filter.sources.get(source_id.?) == .ERROR)) priority = .SILENT;
        }
        const id = if (input.id) |value| try a.dupe(u8, value) else null;
        const self = try allocator.create(NotificationViewItem);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = arena,
            .id = id,
            .severity = input.severity,
            .explicit_sticky = input.sticky,
            .priority = priority,
            .message = message,
            .source = source,
            .source_id = source_id,
            .legacy_links = input.legacy_extension_link_parsing != null,
            .on_did_change_expansion = .init(allocator),
            .on_did_change_visibility = .init(allocator),
            .on_did_change_content = .init(allocator),
            .on_did_close = .init(allocator),
        };
        try self.setActions(input.actions orelse if (input.message == .error_with_actions) .{ .primary = input.message.error_with_actions.actions } else null);
        if (input.progress) |value| {
            if (value.infinite) self.progress().infinite() else if (value.total) |total| {
                if (total != 0) {
                    self.progress().total(total);
                    if (value.worked) |worked| if (worked != 0) self.progress().worked(worked);
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *NotificationViewItem) void {
        self.allocator.free(self.actions.primary);
        self.allocator.free(self.actions.secondary);
        self.message.deinit();
        self.arena.deinit();
        self.on_did_change_expansion.deinit();
        self.on_did_change_visibility.deinit();
        self.on_did_change_content.deinit();
        self.on_did_close.deinit();
        self.allocator.destroy(self);
    }
    fn setActions(self: *NotificationViewItem, input: ?notification.INotificationActions) !void {
        const actions = input orelse notification.INotificationActions{};
        const primary = try self.allocator.dupe(IAction, actions.primary);
        errdefer self.allocator.free(primary);
        const secondary = try self.allocator.dupe(IAction, actions.secondary);
        self.allocator.free(self.actions.primary);
        self.allocator.free(self.actions.secondary);
        self.actions = .{ .primary = primary, .secondary = secondary };
        self.expanded = primary.len != 0;
    }
    pub fn canCollapse(self: *const NotificationViewItem) bool {
        return self.actions.primary.len == 0;
    }
    pub fn hasProgress(self: *const NotificationViewItem) bool {
        return self.progress_value != null;
    }
    pub fn hasActiveProgress(self: *const NotificationViewItem) bool {
        const value = self.progress_value orelse return false;
        return !value.state.done and (value.state.infinite or value.state.total != null or value.state.worked != null);
    }
    pub fn sticky(self: *const NotificationViewItem) bool {
        return self.explicit_sticky or (!self.canCollapse() and self.severity == .Error) or (self.canCollapse() and self.expanded) or self.hasActiveProgress();
    }
    pub fn progress(self: *NotificationViewItem) *NotificationViewItemProgress {
        if (self.progress_value == null) self.progress_value = .{ .item = self };
        return &self.progress_value.?;
    }
    pub fn updateSeverity(self: *NotificationViewItem, severity: Severity) void {
        if (self.closed or self.severity == severity) return;
        self.severity = severity;
        self.contentChanged(.{ .kind = .SEVERITY });
    }
    pub fn updateMessage(self: *NotificationViewItem, input: notification.NotificationMessage) !void {
        if (self.closed) return;
        var value = (try INotificationMessage.parse(self.allocator, input, self.legacy_links)) orelse return;
        if (self.message.equals(value)) {
            value.deinit();
            return;
        }
        self.message.deinit();
        self.message = value;
        self.contentChanged(.{ .kind = .MESSAGE });
    }
    pub fn updateActions(self: *NotificationViewItem, actions: ?notification.INotificationActions) !void {
        if (self.closed) return;
        try self.setActions(actions);
        self.contentChanged(.{ .kind = .ACTIONS });
    }
    fn contentChanged(self: *NotificationViewItem, event: INotificationViewItemContentChangeEvent) void {
        if (self.closed) return;
        self.notifying += 1;
        defer self.endNotification();
        if (self.model) |model| model.fireChange(self, .CHANGE, event);
        self.on_did_change_content.fire(event) catch {};
    }
    pub fn updateVisibility(self: *NotificationViewItem, visible: bool) void {
        if (self.visible == visible) return;
        self.visible = visible;
        self.notifying += 1;
        defer self.endNotification();
        self.on_did_change_visibility.fire(visible) catch {};
    }
    pub fn expand(self: *NotificationViewItem) void {
        if (self.closed or self.expanded or !self.canCollapse()) return;
        self.expanded = true;
        self.expansionChanged();
    }
    pub fn collapse(self: *NotificationViewItem, skip_events: bool) void {
        if (self.closed or !self.expanded or !self.canCollapse()) return;
        self.expanded = false;
        if (!skip_events) self.expansionChanged();
    }
    pub fn toggle(self: *NotificationViewItem) void {
        if (self.expanded) self.collapse(false) else self.expand();
    }
    fn expansionChanged(self: *NotificationViewItem) void {
        self.notifying += 1;
        defer self.endNotification();
        if (self.model) |model| model.fireChange(self, .EXPAND_COLLAPSE, null);
        self.on_did_change_expansion.fire({}) catch {};
    }
    pub fn close(self: *NotificationViewItem) void {
        if (self.closed) return;
        self.closed = true;
        self.notifying += 1;
        defer self.endNotification();
        if (self.model) |model| model.remove(self);
        self.on_did_close.fire({}) catch {};
    }
    pub fn equals(self: *const NotificationViewItem, other: *const NotificationViewItem) bool {
        if (self.hasProgress() or other.hasProgress()) return false;
        if (self.id != null or other.id != null) return optionalEqual(self.id, other.id);
        if (!optionalEqual(self.source, other.source)) return false;
        if (self.source_id != null and !optionalEqual(self.source_id, other.source_id)) return false;
        if (!self.message.equals(other.message) or self.actions.primary.len != other.actions.primary.len) return false;
        for (self.actions.primary, other.actions.primary) |a, b| {
            if (!std.mem.eql(u8, a.id(), b.id()) or !std.mem.eql(u8, a.label(), b.label())) return false;
        }
        return true;
    }
    fn endNotification(self: *NotificationViewItem) void {
        self.notifying -= 1;
        self.releaseIfClosed();
    }
    fn releaseIfClosed(self: *NotificationViewItem) void {
        if (!self.closed or self.notifying != 0 or self.retained_handle) return;
        if (self.model) |model| model.destroyItem(self);
    }
    fn fromContext(ctx: *anyopaque) *NotificationViewItem {
        return @ptrCast(@alignCast(ctx));
    }
    fn handleSeverity(ctx: *anyopaque, severity: Severity) void {
        fromContext(ctx).updateSeverity(severity);
    }
    fn handleMessage(ctx: *anyopaque, message: notification.NotificationMessage) void {
        fromContext(ctx).updateMessage(message) catch {};
    }
    fn handleActions(ctx: *anyopaque, actions: ?notification.INotificationActions) void {
        fromContext(ctx).updateActions(actions) catch {};
    }
    fn handleClose(ctx: *anyopaque) void {
        const self = fromContext(ctx);
        if (self.model) |model| if (model.findNotification(self)) |live| {
            live.close();
            return;
        };
        self.close();
    }
    fn handleRelease(ctx: *anyopaque) void {
        const self = fromContext(ctx);
        self.retained_handle = false;
        self.releaseIfClosed();
    }
    fn handleVisible(ctx: *anyopaque) bool {
        return fromContext(ctx).visible;
    }
    // The progress property is lazy upstream. Don't initialize it until the
    // handle actually uses a progress operation (deduplication depends on it).
    fn progressInfinite(ctx: *anyopaque) void {
        fromContext(ctx).progress().infinite();
    }
    fn progressDone(ctx: *anyopaque) void {
        fromContext(ctx).progress().done();
    }
    fn progressTotal(ctx: *anyopaque, n: i64) void {
        fromContext(ctx).progress().total(n);
    }
    fn progressWorked(ctx: *anyopaque, n: i64) void {
        fromContext(ctx).progress().worked(n);
    }
    pub fn interface(self: *NotificationViewItem) notification.INotificationHandle {
        return .{
            .context = self,
            .progress = .{ .context = self, .infinite_fn = progressInfinite, .done_fn = progressDone, .total_fn = progressTotal, .worked_fn = progressWorked },
            .update_severity_fn = handleSeverity,
            .update_message_fn = handleMessage,
            .update_actions_fn = handleActions,
            .close_fn = handleClose,
            .release_fn = handleRelease,
            .visible_fn = handleVisible,
            .on_did_close = &self.on_did_close,
            .on_did_change_visibility = &self.on_did_change_visibility,
        };
    }
};

pub const StatusMessageViewItem = struct {
    model: *NotificationsModel,
    message: []const u8,
    options: ?notification.IStatusMessageOptions,
    retained: bool = true,
    notifying: usize = 0,
    fn close(ctx: *anyopaque) void {
        const self: *StatusMessageViewItem = @ptrCast(@alignCast(ctx));
        if (self.model.status_message == self) {
            self.model.status_message = null;
            self.notifying += 1;
            self.model.on_did_change_status_message.fire(.{ .kind = .REMOVE, .item = self }) catch {};
            self.notifying -= 1;
            self.releaseIfReplaced();
        }
    }
    fn release(ctx: *anyopaque) void {
        const self: *StatusMessageViewItem = @ptrCast(@alignCast(ctx));
        self.retained = false;
        self.releaseIfReplaced();
    }
    fn releaseIfReplaced(self: *StatusMessageViewItem) void {
        if (!self.retained and self.notifying == 0 and self.model.status_message != self) self.model.destroyStatus(self);
    }
    fn interface(self: *StatusMessageViewItem) notification.IStatusHandle {
        return .{ .context = self, .close_fn = close, .release_fn = release };
    }
};

pub const NotificationsModel = struct {
    allocator: Allocator,
    notifications: std.ArrayList(*NotificationViewItem) = .empty,
    all_items: std.ArrayList(*NotificationViewItem) = .empty,
    status_message: ?*StatusMessageViewItem = null,
    statuses: std.ArrayList(*StatusMessageViewItem) = .empty,
    filter: INotificationsFilter = .{},
    on_did_change_notification: Emitter(INotificationChangeEvent),
    on_did_change_status_message: Emitter(IStatusMessageChangeEvent),
    on_did_change_filter: Emitter(FilterChange),
    no_op: notification.NoOpNotification = .{},

    pub fn init(allocator: Allocator) NotificationsModel {
        return .{ .allocator = allocator, .on_did_change_notification = .init(allocator), .on_did_change_status_message = .init(allocator), .on_did_change_filter = .init(allocator) };
    }
    pub fn deinit(self: *NotificationsModel) void {
        for (self.all_items.items) |item| item.deinit();
        self.all_items.deinit(self.allocator);
        self.notifications.deinit(self.allocator);
        for (self.statuses.items) |item| {
            self.allocator.free(item.message);
            self.allocator.destroy(item);
        }
        self.statuses.deinit(self.allocator);
        var keys = self.filter.sources.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.filter.sources.deinit(self.allocator);
        self.on_did_change_notification.deinit();
        self.on_did_change_status_message.deinit();
        self.on_did_change_filter.deinit();
    }
    pub fn setFilter(self: *NotificationsModel, global: ?notification.NotificationsFilter, sources: ?*const std.StringHashMapUnmanaged(notification.NotificationsFilter)) !void {
        var change: FilterChange = .{};
        if (sources) |value| {
            var equal = value.count() == self.filter.sources.count();
            var entries = value.iterator();
            while (entries.next()) |entry| if (self.filter.sources.get(entry.key_ptr.*) != entry.value_ptr.*) {
                equal = false;
                break;
            };
            if (!equal) {
                var replacement: std.StringHashMapUnmanaged(notification.NotificationsFilter) = .empty;
                errdefer {
                    var it = replacement.keyIterator();
                    while (it.next()) |key| self.allocator.free(key.*);
                    replacement.deinit(self.allocator);
                }
                entries = value.iterator();
                while (entries.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(key);
                    try replacement.put(self.allocator, key, entry.value_ptr.*);
                }
                var keys = self.filter.sources.keyIterator();
                while (keys.next()) |key| self.allocator.free(key.*);
                self.filter.sources.deinit(self.allocator);
                self.filter.sources = replacement;
                change.sources = true;
            }
        }
        if (global) |value| if (value != self.filter.global) {
            self.filter.global = value;
            change.global = value;
        };
        if (change.global != null or change.sources) self.on_did_change_filter.fire(change) catch {};
    }
    pub fn addNotification(self: *NotificationsModel, input: notification.INotification) !notification.INotificationHandle {
        const item = (try NotificationViewItem.create(self.allocator, input, self.filter)) orelse return self.no_op.interface();
        errdefer item.deinit();
        try self.all_items.ensureUnusedCapacity(self.allocator, 1);
        try self.notifications.ensureUnusedCapacity(self.allocator, 1);
        item.model = self;
        item.retained_handle = true;
        if (self.findNotification(item)) |duplicate| duplicate.close();
        self.all_items.appendAssumeCapacity(item);
        self.notifications.insertAssumeCapacity(0, item);
        self.on_did_change_notification.fire(.{ .item = item, .index = 0, .kind = .ADD }) catch {};
        return item.interface();
    }
    fn findNotification(self: *NotificationsModel, item: *const NotificationViewItem) ?*NotificationViewItem {
        for (self.notifications.items) |candidate| if (candidate.equals(item)) return candidate;
        return null;
    }
    fn fireChange(self: *NotificationsModel, item: *NotificationViewItem, kind: NotificationChangeType, detail: ?INotificationViewItemContentChangeEvent) void {
        const index = std.mem.indexOfScalar(*NotificationViewItem, self.notifications.items, item) orelse return;
        self.on_did_change_notification.fire(.{ .item = item, .index = index, .kind = kind, .detail = if (detail) |value| value.kind else null, .active_progress_changed = if (detail) |value| value.active_progress_changed else null }) catch {};
    }
    fn remove(self: *NotificationsModel, item: *NotificationViewItem) void {
        const index = std.mem.indexOfScalar(*NotificationViewItem, self.notifications.items, item) orelse return;
        _ = self.notifications.orderedRemove(index);
        self.on_did_change_notification.fire(.{ .item = item, .index = index, .kind = .REMOVE }) catch {};
    }
    fn destroyItem(self: *NotificationsModel, item: *NotificationViewItem) void {
        const index = std.mem.indexOfScalar(*NotificationViewItem, self.all_items.items, item) orelse return;
        _ = self.all_items.swapRemove(index);
        item.deinit();
    }
    pub fn showStatusMessage(self: *NotificationsModel, message: notification.NotificationMessage, options: ?notification.IStatusMessageOptions) !notification.IStatusHandle {
        const text = try messageString(self.allocator, message);
        errdefer self.allocator.free(text);
        if (text.len == 0) {
            self.allocator.free(text);
            return .{ .context = self, .close_fn = noStatus };
        }
        const item = try self.allocator.create(StatusMessageViewItem);
        errdefer self.allocator.destroy(item);
        item.* = .{ .model = self, .message = text, .options = options };
        try self.statuses.append(self.allocator, item);
        const previous = self.status_message;
        self.status_message = item;
        if (previous) |value| value.releaseIfReplaced();
        self.on_did_change_status_message.fire(.{ .kind = .ADD, .item = item }) catch {};
        return item.interface();
    }
    fn noStatus(_: *anyopaque) void {}
    fn destroyStatus(self: *NotificationsModel, item: *StatusMessageViewItem) void {
        const index = std.mem.indexOfScalar(*StatusMessageViewItem, self.statuses.items, item) orelse return;
        _ = self.statuses.swapRemove(index);
        self.allocator.free(item.message);
        self.allocator.destroy(item);
    }
};

pub const NotificationsPosition = enum { bottom_right, bottom_left, top_right };
