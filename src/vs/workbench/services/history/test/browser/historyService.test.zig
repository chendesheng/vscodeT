// Adapted editor-history cases for the TUI quick-open history subset.

const std = @import("std");
const history = @import("../../common/history.zig");
const editor = @import("../../../../common/editor.zig");
const text_editor = @import("../../../../browser/parts/editor/textEditor.zig");
const Selection = @import("../../../../../editor/common/core/selection.zig").Selection;

test "historyService: most recent first and deduplicated" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();

    try service.add("/a");
    try service.add("/b");
    try service.add("/a");
    try std.testing.expectEqual(@as(usize, 2), service.getHistory().len);
    try std.testing.expectEqualStrings("/a", service.getHistory()[0]);
    try std.testing.expectEqualStrings("/b", service.getHistory()[1]);
}

test "historyService: caps the history and supports removal" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();
    service.max = 2;

    try service.add("/a");
    try service.add("/b");
    try service.add("/c");
    try std.testing.expectEqual(@as(usize, 2), service.getHistory().len);
    try std.testing.expectEqualStrings("/c", service.getHistory()[0]);

    service.remove("/c");
    try std.testing.expectEqual(@as(usize, 1), service.getHistory().len);
    try std.testing.expectEqualStrings("/b", service.getHistory()[0]);
}

fn selection(allocator: std.mem.Allocator, line: usize) !editor.IEditorPaneSelection {
    const snapshot = try text_editor.TextEditorPaneSelection.create(allocator, Selection.init(line, 1, line, 1));
    return snapshot.interface();
}

test "historyService: navigation stacks filter and scope entries" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();

    try service.recordNavigation(1, "/a", try selection(std.testing.allocator, 1), 1, .USER);
    try service.recordNavigation(1, "/b", try selection(std.testing.allocator, 2), 1, .NAVIGATION);

    const back = service.goBack(.DEFAULT, .NONE, 1, "/b").?;
    try std.testing.expectEqualStrings("/a", back.path);
    const forward = service.goForward(.DEFAULT, .NONE, 1, "/a").?;
    try std.testing.expectEqualStrings("/b", forward.path);

    try std.testing.expect(service.goBack(.DEFAULT, .NAVIGATION, 1, "/b") == null);
    try std.testing.expect(service.goBack(.DEFAULT, .EDITS, 1, "/b") == null);
}

test "historyService: group and editor scoped stacks are independent" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();

    try service.recordNavigation(1, "/a", try selection(std.testing.allocator, 1), 1, .USER);
    try service.recordNavigation(1, "/a2", try selection(std.testing.allocator, 2), 1, .USER);
    try service.recordNavigation(2, "/b", try selection(std.testing.allocator, 3), 1, .USER);
    try service.recordNavigation(2, "/b", try selection(std.testing.allocator, 4), 1, .USER);

    const group_back = service.goBack(.EDITOR_GROUP, .NONE, 1, "/a2").?;
    try std.testing.expectEqualStrings("/a", group_back.path);
    const editor_back = service.goBack(.EDITOR, .NONE, 2, "/b").?;
    try std.testing.expectEqualStrings("/b", editor_back.path);
}
