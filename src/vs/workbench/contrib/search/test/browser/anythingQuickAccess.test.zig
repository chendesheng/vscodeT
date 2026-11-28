// Adapted file-picker cases for the TUI `AnythingQuickAccessProvider`
// subset: recent files, file results, separators, no-results and accept.

const std = @import("std");
const cancellation = @import("../../../../../base/common/cancellation.zig");
const anything = @import("../../browser/anythingQuickAccess.zig");
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;

const State = struct {
    recent_items: [1]anything.RecentFile = .{
        .{ .path = "/ws/src/main.zig", .label = "main.zig", .description = "src" },
    },
    file_items: [1]anything.FileMatch = .{
        .{
            .path = "/ws/src/alpha.zig",
            .label = "alpha.zig",
            .description = "src",
            .label_matches = &.{.{ .start = 0, .end = 3 }},
        },
    },
    empty: [0]anything.FileMatch = .{},
    opened: [64]u8 = std.mem.zeroes([64]u8),
    opened_len: usize = 0,
    started: usize = 0,
    requested: usize = 0,

    fn start(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.started += 1;
    }

    fn request(context: *anyopaque, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.requested += 1;
    }

    fn hasResult(_: *anyopaque, _: []const u8) bool {
        return true;
    }

    fn isIndexing(_: *anyopaque) bool {
        return false;
    }

    fn recent(context: *anyopaque, _: std.mem.Allocator) anyerror![]anything.RecentFile {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.recent_items[0..];
    }

    fn search(
        context: *anyopaque,
        filter: []const u8,
        _: usize,
        _: std.mem.Allocator,
    ) anyerror![]anything.FileMatch {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.startsWith(u8, filter, "alp")) return self.file_items[0..];
        return self.empty[0..];
    }

    fn open(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const len = @min(path.len, self.opened.len);
        @memcpy(self.opened[0..len], path[0..len]);
        self.opened_len = len;
    }
};

test "anythingQuickAccess: recent files on empty filter and file results while typing" {
    var state = State{};
    const provider = try anything.AnythingQuickAccessProvider.init(
        std.testing.allocator,
        .{
            .context = &state,
            .start = State.start,
            .request = State.request,
            .has_result = State.hasResult,
            .is_indexing = State.isIndexing,
            .recent = State.recent,
            .search = State.search,
        },
        .{ .context = &state, .open = State.open },
    );
    defer {
        if (provider.interface().dispose) |dispose| dispose(provider);
    }

    var picker = QuickPick.init(std.testing.allocator, std.testing.io);
    defer picker.deinit();
    var source = try cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();
    const interface = provider.interface();

    picker.show();
    try interface.provide(interface.context, &picker, token);
    try std.testing.expect(picker.items.items.len == 2);
    try std.testing.expect(switch (picker.items.items[0]) {
        .separator => true,
        .item => false,
    });
    try std.testing.expectEqualStrings("recently opened", picker.items.items[0].separator.label);
    try std.testing.expectEqualStrings("main.zig", picker.activeItem().?.label);
    try std.testing.expectEqual(@as(usize, 0), state.started);

    try picker.setValue("alp");
    try interface.refresh(interface.context, &picker);
    try std.testing.expectEqual(@as(usize, 1), state.started);
    try std.testing.expectEqualStrings("alpha.zig", picker.activeItem().?.label);
    try std.testing.expectEqualStrings("src", picker.activeItem().?.description);

    picker.accept();
    try interface.accept(interface.context, &picker);
    try std.testing.expectEqualStrings("/ws/src/alpha.zig", state.opened[0..state.opened_len]);
    try std.testing.expect(!picker.visible);

    try picker.setValue("zzz");
    try interface.refresh(interface.context, &picker);
    try std.testing.expectEqualStrings("No matching results", picker.activeItem().?.label);
}
