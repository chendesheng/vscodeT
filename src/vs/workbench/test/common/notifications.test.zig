// Port of `src/vs/workbench/test/common/notifications.test.ts`. The unique
// legacy link capability is enforced by the Zig type system rather than the
// upstream JavaScript runtime test of boolean and lookalike capabilities.
const std = @import("std");
const t = std.testing;
const a = t.allocator;
const n = @import("../../../platform/notification/common/notification.zig");
const legacy = @import("../../../platform/notification/common/notificationLegacy.zig").legacyExtensionLinkParsing;
const Text = @import("../../../platform/notification/common/notificationMessage.zig").NotificationText;
const m = @import("../../common/notifications.zig");
const Action = @import("../../../base/common/actions.zig").Action;
const Item = m.NotificationViewItem;
const Severity = @import("../../../base/common/severity.zig").Severity;

fn xs(comptime len: usize) *const [len:0]u8 {
    const text = comptime blk: {
        var bytes: [len:0]u8 = undefined;
        @memset(bytes[0..len], 'x');
        bytes[len] = 0;
        break :blk bytes;
    };
    return &text;
}

fn create(input: n.INotification) !*Item {
    return (try Item.create(a, input, .{})).?;
}
fn expectText(item: *Item, expected: []const u8) !void {
    const text = try item.message.linked_text.toString(a);
    defer a.free(text);
    try t.expectEqualStrings(expected, text);
}
const Count = struct {
    value: usize = 0,
    fn empty(_: void, self: *Count) !void {
        self.value += 1;
    }
    fn boolean(_: bool, self: *Count) !void {
        self.value += 1;
    }
    fn content(_: m.INotificationViewItemContentChangeEvent, self: *Count) !void {
        self.value += 1;
    }
};

test "Notifications: renders strings and errors literally by default" {
    const message = "README.md [Open](command:workbench.action.files.newUntitledFile \"Open README\") [Help](https://example.com) <b>text</b>";
    for ([_]n.INotification{ .{ .severity = .Info, .message = .{ .text = message } }, .{ .severity = .Error, .message = .{ .error_message = message } }, .{ .severity = .Warning, .message = .{ .text = message } } }) |input| {
        const item = try create(input);
        defer item.deinit();
        try t.expectEqualStrings(message, item.message.raw);
        try t.expectEqual(@as(usize, 1), item.message.linked_text.nodes.len);
        try t.expectEqualStrings(message, item.message.linked_text.nodes[0].text);
    }
}

test "Notifications: preserves explicit links without interpreting literal fragments or link labels" {
    const filename = "[Open](command:unexpected)";
    var link = try Text.link(a, filename, "command:showLogs?%5B%22file%22%5D", "Show Logs");
    defer link.deinit();
    var message = try Text.format(a, "Cannot open {0}. {1}", &.{ .{ .text = filename }, .{ .content = &link } });
    defer message.deinit();
    const item = try create(.{ .severity = .Error, .message = .{ .content = &message } });
    defer item.deinit();
    try t.expectEqualStrings("Cannot open " ++ filename ++ ". " ++ filename, item.message.raw);
    const nodes = item.message.linked_text.nodes;
    try t.expectEqual(@as(usize, 2), nodes.len);
    try t.expectEqualStrings("Cannot open " ++ filename ++ ". ", nodes[0].text);
    try t.expectEqualStrings(filename, nodes[1].link.label);
    try t.expectEqualStrings(link.nodes[0].link.href, nodes[1].link.href);
    try t.expectEqualStrings("Show Logs", nodes[1].link.title.?);
}

test "Notifications: updating a structured message with plain text removes links even when text is unchanged" {
    var link = try Text.link(a, "Details", "command:showDetails", null);
    defer link.deinit();
    const item = try create(.{ .severity = .Info, .message = .{ .content = &link } });
    defer item.deinit();
    var count: Count = .{};
    _ = try item.on_did_change_content.listen(&count, Count.content);
    try item.updateMessage(.{ .text = "Details" });
    try item.updateMessage(.{ .text = "Details" });
    try t.expectEqualStrings("Details", item.message.linked_text.nodes[0].text);
    try t.expectEqual(@as(usize, 1), count.value);
}

test "Notifications: updates link targets without requiring a label change" {
    var first = try Text.link(a, "Details", "command:first", null);
    defer first.deinit();
    var second = try Text.link(a, "Details", "command:second", null);
    defer second.deinit();
    const item = try create(.{ .severity = .Info, .message = .{ .content = &first } });
    defer item.deinit();
    var count: Count = .{};
    _ = try item.on_did_change_content.listen(&count, Count.content);
    try item.updateMessage(.{ .content = &second });
    try item.updateMessage(.{ .content = &second });
    try t.expectEqualStrings("Details", item.message.linked_text.nodes[0].link.label);
    try t.expectEqualStrings("command:second", item.message.linked_text.nodes[0].link.href);
    try t.expectEqual(@as(usize, 1), count.value);
}

test "Notifications: does not deduplicate literal text and different links with the same label" {
    var first = try Text.link(a, "Details", "command:first", null);
    defer first.deinit();
    var second = try Text.link(a, "Details", "command:second", null);
    defer second.deinit();
    const items = [_]*Item{
        try create(.{ .severity = .Info, .message = .{ .text = "Details" } }),
        try create(.{ .severity = .Info, .message = .{ .content = &first } }),
        try create(.{ .severity = .Info, .message = .{ .content = &first } }),
        try create(.{ .severity = .Info, .message = .{ .content = &second } }),
    };
    defer for (items) |item| item.deinit();
    try t.expect(!items[0].equals(items[1]));
    try t.expect(!items[1].equals(items[3]));
    try t.expect(items[1].equals(items[2]));
}

test "Notifications: preserves legacy parsing and updates with the extension capability" {
    const item = try create(.{ .severity = .Info, .message = .{ .text = "  [Show Logs](command:python.viewOutput)\r\n[Help](https://example.com)  " }, .legacy_extension_link_parsing = legacy });
    defer item.deinit();
    const nodes = item.message.linked_text.nodes;
    try t.expectEqual(@as(usize, 3), nodes.len);
    try t.expectEqualStrings("Show Logs", nodes[0].link.label);
    try t.expectEqualStrings("command:python.viewOutput", nodes[0].link.href);
    try t.expectEqualStrings(" ", nodes[1].text);
    try t.expectEqualStrings("Help", nodes[2].link.label);
    try t.expectEqualStrings("https://example.com", nodes[2].link.href);
    try item.updateMessage(.{ .text = "[Check details](command:java.show.server.task.status \"Build Status\")" });
    try t.expectEqualStrings("Check details", item.message.linked_text.nodes[0].link.label);
    try t.expectEqualStrings("command:java.show.server.task.status", item.message.linked_text.nodes[0].link.href);
    try t.expectEqualStrings("Build Status", item.message.linked_text.nodes[0].link.title.?);
}

test "Notifications: normalizes and truncates messages while preserving original text" {
    const message = "  line one\r\nline two\rline three\n" ++ xs(1000);
    const item = try create(.{ .severity = .Info, .message = .{ .text = message } });
    defer item.deinit();
    try t.expectEqualStrings(message, item.message.raw);
    try expectText(item, "line one line two line three " ++ xs(1000 - "  line one\r\nline two\rline three\n".len) ++ "...");
    const legacy_item = try create(.{ .severity = .Info, .message = .{ .text = xs(995) ++ "[Open](command:unexpected)" }, .legacy_extension_link_parsing = legacy });
    defer legacy_item.deinit();
    try t.expectEqual(@as(usize, 1), legacy_item.message.linked_text.nodes.len);
    try t.expectEqualStrings(xs(995) ++ "[Open...", legacy_item.message.linked_text.nodes[0].text);
}

test "Notifications: truncates structured labels without changing link targets" {
    const href = "command:showLogs?" ++ xs(1100);
    var link = try Text.link(a, "Details", href, null);
    defer link.deinit();
    var message = try Text.concat(a, &.{ .{ .text = xs(999) }, .{ .content = &link } });
    defer message.deinit();
    const item = try create(.{ .severity = .Info, .message = .{ .content = &message } });
    defer item.deinit();
    try t.expectEqual(@as(usize, 3), item.message.linked_text.nodes.len);
    try t.expectEqualStrings(xs(999), item.message.linked_text.nodes[0].text);
    try t.expectEqualStrings("D", item.message.linked_text.nodes[1].link.label);
    try t.expectEqualStrings(href, item.message.linked_text.nodes[1].link.href);
    try t.expectEqualStrings("...", item.message.linked_text.nodes[2].text);
}

test "Notifications: shows structured status messages as plain text" {
    var model = m.NotificationsModel.init(a);
    defer model.deinit();
    var link = try Text.link(a, "logs", "command:showLogs", null);
    defer link.deinit();
    var message = try Text.concat(a, &.{ .{ .text = "Open " }, .{ .content = &link } });
    defer message.deinit();
    const handle = try model.showStatusMessage(.{ .content = &message }, null);
    defer handle.release();
    try t.expectEqualStrings("Open logs", model.status_message.?.message);
    handle.close();
}

test "Notifications: Items" {
    try t.expect((try Item.create(a, .{ .severity = .Error, .message = .{ .text = "" } }, .{})) == null);
    try t.expect((try Item.create(a, .{ .severity = .Error, .message = .cancelled }, .{})) == null);
    var first_action = Action.init(a, "id", "label", null, true, null, undefined);
    defer first_action.deinit();
    var second_action = Action.init(a, "id2", "label", null, true, null, undefined);
    defer second_action.deinit();
    const items = [_]*Item{
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" } }),
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" } }),
        try create(.{ .severity = .Info, .message = .{ .text = "Info Message" } }),
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" }, .source = .{ .text = "Source" } }),
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" }, .actions = .{ .primary = &.{first_action.interface()} } }),
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" }, .actions = .{ .primary = &.{first_action.interface()} }, .progress = .{ .infinite = true } }),
        try create(.{ .severity = .Info, .message = .{ .text = "Info Message" }, .id = "same" }),
        try create(.{ .severity = .Error, .message = .{ .text = "Error Message" }, .id = "same" }),
    };
    defer for (items) |item| item.deinit();
    for (items[0..5]) |item| try t.expect(item.equals(item));
    try t.expect(items[0].equals(items[1]));
    for (items[2..5]) |item| try t.expect(!items[0].equals(item));
    try t.expect(items[6].equals(items[7]));
    try t.expect(!items[6].equals(items[2]));
    try t.expect(!items[0].hasProgress() and !items[0].hasActiveProgress());
    try t.expect(items[5].hasProgress() and items[5].hasActiveProgress());
    try t.expect(items[4].expanded and !items[4].canCollapse());
    var expansion: Count = .{};
    _ = try items[0].on_did_change_expansion.listen(&expansion, Count.empty);
    items[0].expand();
    items[0].expand();
    items[0].collapse(false);
    items[0].collapse(false);
    try t.expectEqual(@as(usize, 2), expansion.value);
    var content: Count = .{};
    _ = try items[0].on_did_change_content.listen(&content, Count.content);
    items[0].progress().infinite();
    items[0].progress().done();
    try t.expectEqual(@as(usize, 2), content.value);
    try items[0].updateMessage(.{ .text = "message update" });
    items[0].updateSeverity(.Error);
    try items[0].updateActions(.{ .primary = &.{second_action.interface()} });
    try t.expectEqual(@as(usize, 4), content.value);
    var visibility: Count = .{};
    _ = try items[0].on_did_change_visibility.listen(&visibility, Count.boolean);
    items[0].updateVisibility(true);
    items[0].updateVisibility(false);
    items[0].updateVisibility(false);
    try t.expectEqual(@as(usize, 2), visibility.value);
    var closed: Count = .{};
    _ = try items[0].on_did_close.listen(&closed, Count.empty);
    items[0].close();
    try t.expectEqual(@as(usize, 1), closed.value);
    const error_action = try create(.{ .severity = .Error, .message = .{ .error_with_actions = .{ .message = "Hello Error", .actions = &.{first_action.interface()} } } });
    defer error_action.deinit();
    try t.expectEqual(@as(usize, 1), error_action.actions.primary.len);
    var filter: m.INotificationsFilter = .{ .global = .ERROR };
    defer filter.sources.deinit(a);
    for ([_]Severity{ .Error, .Warning }) |severity| {
        const item = (try Item.create(a, .{ .severity = severity, .message = .{ .text = "Error Message" } }, filter)).?;
        defer item.deinit();
        try t.expectEqual(if (severity == .Error) n.NotificationPriority.DEFAULT else .SILENT, item.priority);
    }
    try t.expectEqual(n.NotificationPriority.DEFAULT, items[1].priority);
    filter.global = .OFF;
    try filter.sources.put(a, "test.source", .ERROR);
    const sources = [_]n.INotification{
        .{ .severity = .Warning, .message = .{ .text = "Error Message" }, .source = .{ .text = "test.source" } },
        .{ .severity = .Warning, .message = .{ .text = "Error Message" }, .source = .{ .source = .{ .id = "test.source", .label = "foo" } } },
        .{ .severity = .Warning, .message = .{ .text = "Error Message" }, .source = .{ .source = .{ .id = "test.source2", .label = "foo" } } },
    };
    for (sources, [_]n.NotificationPriority{ .DEFAULT, .SILENT, .DEFAULT }) |input, priority| {
        const item = (try Item.create(a, input, filter)).?;
        defer item.deinit();
        try t.expectEqual(priority, item.priority);
    }
}

test "Notifications: Progress activity tracks starts, updates, completion, and restart" {
    const item = try create(.{ .severity = .Info, .message = .{ .text = "Progress" } });
    defer item.deinit();
    const State = struct { has_progress: bool, active: bool, sticky: bool, active_changed: ?bool = null };
    const Recorder = struct {
        item: *Item,
        states: std.ArrayList(State) = .empty,
        fn capture(self: *@This(), changed: ?bool) !void {
            try self.states.append(a, .{ .has_progress = self.item.hasProgress(), .active = self.item.hasActiveProgress(), .sticky = self.item.sticky(), .active_changed = changed });
        }
        fn event(e: m.INotificationViewItemContentChangeEvent, self: *@This()) !void {
            if (e.kind == .PROGRESS) try self.capture(e.active_progress_changed);
        }
    };
    var recorder: Recorder = .{ .item = item };
    defer recorder.states.deinit(a);
    _ = try item.on_did_change_content.listen(&recorder, Recorder.event);
    try recorder.capture(null);
    const progress = item.progress();
    try recorder.capture(null);
    progress.infinite();
    progress.total(100);
    progress.worked(10);
    progress.done();
    progress.infinite();
    try t.expectEqualSlices(State, &.{
        .{ .has_progress = false, .active = false, .sticky = false },
        .{ .has_progress = true, .active = false, .sticky = false },
        .{ .has_progress = true, .active = true, .sticky = true, .active_changed = true },
        .{ .has_progress = true, .active = true, .sticky = true, .active_changed = false },
        .{ .has_progress = true, .active = true, .sticky = true, .active_changed = false },
        .{ .has_progress = true, .active = false, .sticky = false, .active_changed = true },
        .{ .has_progress = true, .active = true, .sticky = true, .active_changed = true },
    }, recorder.states.items);
}

test "Notifications: completed progress notifications remain unique" {
    var model = m.NotificationsModel.init(a);
    defer model.deinit();
    const input: n.INotification = .{ .severity = .Info, .message = .{ .text = "Same message" } };
    const first = try model.addNotification(input);
    defer first.release();
    var count: Count = .{};
    _ = try first.on_did_close.?.listen(&count, Count.empty);
    first.progress.infinite();
    first.progress.done();
    const second = try model.addNotification(input);
    defer second.release();
    try t.expectEqual(@as(usize, 2), model.notifications.items.len);
    try t.expectEqual(@as(usize, 0), count.value);
    first.close();
    second.close();
}

test "Notifications: does not fire changed when message and severity did not change" {
    const item = try create(.{ .severity = .Error, .message = .{ .text = "Error Message" } });
    defer item.deinit();
    var count: Count = .{};
    _ = try item.on_did_change_content.listen(&count, Count.content);
    try item.updateMessage(.{ .text = "Error Message" });
    item.updateSeverity(.Error);
    try t.expectEqual(@as(usize, 0), count.value);
}

test "Notifications: Model" {
    var model = m.NotificationsModel.init(a);
    defer model.deinit();
    const Last = struct {
        event: ?m.INotificationChangeEvent = null,
        status: ?m.IStatusMessageChangeEvent = null,
        fn notificationChanged(e: m.INotificationChangeEvent, self: *@This()) !void {
            self.event = e;
        }
        fn statusChanged(e: m.IStatusMessageChangeEvent, self: *@This()) !void {
            self.status = e;
        }
        fn expect(self: *@This(), kind: m.NotificationChangeType, index: usize, detail: ?m.NotificationViewItemContentChangeKind) !void {
            try t.expectEqual(kind, self.event.?.kind);
            try t.expectEqual(index, self.event.?.index);
            try t.expectEqual(detail, self.event.?.detail);
        }
    };
    var last: Last = .{};
    _ = try model.on_did_change_notification.listen(&last, Last.notificationChanged);
    _ = try model.on_did_change_status_message.listen(&last, Last.statusChanged);
    var action = Action.init(a, "id", "label", null, true, null, undefined);
    defer action.deinit();
    const first = try model.addNotification(.{ .severity = .Error, .message = .{ .text = "Error Message" }, .actions = .{ .primary = &.{action.interface()} } });
    defer first.release();
    try last.expect(.ADD, 0, null);
    try t.expectEqual(Severity.Error, last.event.?.item.severity);
    try expectText(last.event.?.item, "Error Message");
    first.updateMessage(.{ .text = "Different Error Message" });
    try last.expect(.CHANGE, 0, .MESSAGE);
    first.updateSeverity(.Warning);
    try last.expect(.CHANGE, 0, .SEVERITY);
    first.updateActions(.{});
    try last.expect(.CHANGE, 0, .ACTIONS);
    first.progress.infinite();
    try last.expect(.CHANGE, 0, .PROGRESS);
    const warning: n.INotification = .{ .severity = .Warning, .message = .{ .text = "Warning Message" }, .source = .{ .text = "Some Source" } };
    const second = try model.addNotification(warning);
    defer second.release();
    try last.expect(.ADD, 0, null);
    try expectText(last.event.?.item, "Warning Message");
    const third = try model.addNotification(.{ .severity = .Info, .message = .{ .text = "Info Message" } });
    defer third.release();
    try last.expect(.ADD, 0, null);
    try expectText(last.event.?.item, "Info Message");
    try t.expectEqual(@as(usize, 3), model.notifications.items.len);
    var count: Count = .{};
    _ = try first.on_did_close.?.listen(&count, Count.empty);
    first.close();
    try t.expectEqual(@as(usize, 1), count.value);
    try t.expectEqual(@as(usize, 2), model.notifications.items.len);
    try last.expect(.REMOVE, 2, null);
    try expectText(last.event.?.item, "Different Error Message");
    const duplicate = try model.addNotification(warning);
    defer duplicate.release();
    try t.expectEqual(@as(usize, 2), model.notifications.items.len);
    try last.expect(.ADD, 0, null);
    try expectText(last.event.?.item, "Warning Message");
    second.close();
    try t.expectEqual(@as(usize, 1), model.notifications.items.len);
    try last.expect(.REMOVE, 0, null);
    try expectText(last.event.?.item, "Warning Message");
    model.notifications.items[0].expand();
    try last.expect(.EXPAND_COLLAPSE, 0, null);
    const status1 = try model.showStatusMessage(.{ .text = "Hello World" }, null);
    defer status1.release();
    try t.expectEqualStrings("Hello World", model.status_message.?.message);
    try t.expectEqual(m.StatusMessageChangeType.ADD, last.status.?.kind);
    status1.close();
    try t.expect(model.status_message == null);
    try t.expectEqual(m.StatusMessageChangeType.REMOVE, last.status.?.kind);
    const status2 = try model.showStatusMessage(.{ .text = "Hello World 2" }, null);
    defer status2.release();
    const status3 = try model.showStatusMessage(.{ .text = "Hello World 3" }, null);
    defer status3.release();
    status2.close();
    try t.expectEqualStrings("Hello World 3", model.status_message.?.message);
    status3.close();
    try t.expect(model.status_message == null);
    duplicate.close();
    third.close();
}
