const std = @import("std");
const Config = @import("../../common/terminalConfiguration.zig").Config;
const TerminalTabbedView = @import("../../browser/terminalTabbedView.zig").TerminalTabbedView;
const TerminalTabList = @import("../../browser/terminalTabsList.zig").TerminalTabList;
const ui = @import("ui");

test "terminal tabs live beside the terminal and hide for a single instance by default" {
    const view: TerminalTabbedView = .{};
    const rect: ui.Rect = .{ .x = 3, .y = 8, .w = 70, .h = 9 };

    const single = view.layout(rect, .{}, 1, 1);
    try std.testing.expectEqual(@as(?usize, null), single.sash_x);
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 9, .w = 70, .h = 8 }, single.terminal);

    const right = view.layout(rect, .{}, 2, 1);
    try std.testing.expectEqual(ui.Rect{ .x = 57, .y = 9, .w = 16, .h = 8 }, right.tabs);
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 9, .w = 53, .h = 8 }, right.terminal);
    try std.testing.expectEqual(@as(?usize, 56), right.sash_x);

    const left = view.layout(rect, .{ .tabs_location = .left }, 2, 2);
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 9, .w = 16, .h = 8 }, left.tabs);
    try std.testing.expectEqual(ui.Rect{ .x = 20, .y = 9, .w = 53, .h = 8 }, left.terminal);
    try std.testing.expectEqual(@as(?usize, 19), left.sash_x);
}

test "terminal tabs apply the configured hide condition to groups and instances" {
    var config: Config = .{ .tabs_hide_condition = .singleGroup };
    try std.testing.expect(!TerminalTabbedView.shouldShowTabs(config, 2, 1));
    try std.testing.expect(TerminalTabbedView.shouldShowTabs(config, 2, 2));

    config.tabs_hide_condition = .never;
    try std.testing.expect(TerminalTabbedView.shouldShowTabs(config, 1, 1));
    config.tabs_enabled = false;
    try std.testing.expect(!TerminalTabbedView.shouldShowTabs(config, 3, 2));
}

test "terminal tab list reveals selection and snaps between narrow and text widths" {
    var list: TerminalTabList = .{};
    list.reveal(8, 10, 3);
    try std.testing.expectEqual(@as(usize, 6), list.first_visible);
    list.scroll(10, 10, 3);
    try std.testing.expectEqual(@as(usize, 7), list.first_visible);
    list.reveal(1, 10, 3);
    try std.testing.expectEqual(@as(usize, 1), list.first_visible);

    list.resize(6);
    try std.testing.expectEqual(@as(usize, 5), list.width);
    list.resize(8);
    try std.testing.expectEqual(@as(usize, 10), list.width);
    list.resize(40);
    try std.testing.expectEqual(@as(usize, 40), list.width);
}

test "terminal tab list restores its width from the user profile" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(profile);

    var original: TerminalTabbedView = .{};
    defer original.deinit(allocator);
    try original.setProfileStorage(allocator, io, profile);
    original.tab_list.resize(23);
    try original.storeListWidth(io);

    var restored: TerminalTabbedView = .{};
    defer restored.deinit(allocator);
    try restored.setProfileStorage(allocator, io, profile);
    try std.testing.expectEqual(@as(usize, 23), restored.tab_list.width);
}
