// Port of `src/vs/editor/test/browser/view/viewLayer.test.ts`.
const std = @import("std");
const view_layer = @import("../../../browser/view/viewLayer.zig");

const TestLine = struct {
    id: []const u8,
    pinged: bool = false,
    pub fn onContentChanged(self: *TestLine) void {
        self.pinged = true;
    }
    pub fn onTokensChanged(self: *TestLine) void {
        self.pinged = true;
    }
};

fn createLine(_: *anyopaque) anyerror!TestLine {
    return .{ .id = "new" };
}

const Collection = view_layer.RenderedLinesCollection(TestLine);

fn reset(collection: *Collection, start: usize, ids: []const []const u8) !void {
    collection.lines.clearRetainingCapacity();
    collection.rend_line_number_start = start;
    for (ids) |id| try collection.lines.append(.{ .id = id });
}

fn assertState(collection: *const Collection, start: usize, ids: []const []const u8, pinged: []const bool) !void {
    try std.testing.expectEqual(start, collection.getStartLineNumber());
    try std.testing.expectEqual(ids.len, collection.getCount());
    for (ids, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, collection.lines.items[index].id);
        try std.testing.expectEqual(pinged[index], collection.lines.items[index].pinged);
    }
}

const InitialIds = [_][]const u8{ "old6", "old7", "old8", "old9" };
const NoPing = [_]bool{ false, false, false, false };

const DeletedCase = struct { from: usize, to: usize, deleted: []const []const u8, start: usize, lines: []const []const u8 };

const deleted_cases = [_]DeletedCase{
    .{ .from = 3, .to = 3, .deleted = &.{}, .start = 5, .lines = &InitialIds },
    .{ .from = 3, .to = 4, .deleted = &.{}, .start = 4, .lines = &InitialIds },
    .{ .from = 3, .to = 5, .deleted = &.{}, .start = 3, .lines = &InitialIds },
    .{ .from = 3, .to = 6, .deleted = &.{"old6"}, .start = 3, .lines = &.{ "old7", "old8", "old9" } },
    .{ .from = 3, .to = 7, .deleted = &.{ "old6", "old7" }, .start = 3, .lines = &.{ "old8", "old9" } },
    .{ .from = 3, .to = 8, .deleted = &.{ "old6", "old7", "old8" }, .start = 3, .lines = &.{"old9"} },
    .{ .from = 3, .to = 9, .deleted = &InitialIds, .start = 3, .lines = &.{} },
    .{ .from = 3, .to = 10, .deleted = &InitialIds, .start = 3, .lines = &.{} },
    .{ .from = 5, .to = 5, .deleted = &.{}, .start = 5, .lines = &InitialIds },
    .{ .from = 5, .to = 6, .deleted = &.{"old6"}, .start = 5, .lines = &.{ "old7", "old8", "old9" } },
    .{ .from = 5, .to = 7, .deleted = &.{ "old6", "old7" }, .start = 5, .lines = &.{ "old8", "old9" } },
    .{ .from = 5, .to = 8, .deleted = &.{ "old6", "old7", "old8" }, .start = 5, .lines = &.{"old9"} },
    .{ .from = 5, .to = 9, .deleted = &InitialIds, .start = 5, .lines = &.{} },
    .{ .from = 6, .to = 6, .deleted = &.{"old6"}, .start = 6, .lines = &.{ "old7", "old8", "old9" } },
    .{ .from = 6, .to = 8, .deleted = &.{ "old6", "old7", "old8" }, .start = 6, .lines = &.{"old9"} },
    .{ .from = 6, .to = 9, .deleted = &InitialIds, .start = 6, .lines = &.{} },
    .{ .from = 7, .to = 7, .deleted = &.{"old7"}, .start = 6, .lines = &.{ "old6", "old8", "old9" } },
    .{ .from = 7, .to = 9, .deleted = &.{ "old7", "old8", "old9" }, .start = 6, .lines = &.{"old6"} },
    .{ .from = 8, .to = 8, .deleted = &.{"old8"}, .start = 6, .lines = &.{ "old6", "old7", "old9" } },
    .{ .from = 8, .to = 9, .deleted = &.{ "old8", "old9" }, .start = 6, .lines = &.{ "old6", "old7" } },
    .{ .from = 9, .to = 9, .deleted = &.{"old9"}, .start = 6, .lines = &.{ "old6", "old7", "old8" } },
    .{ .from = 10, .to = 11, .deleted = &.{}, .start = 6, .lines = &InitialIds },
    .{ .from = 11, .to = 13, .deleted = &.{}, .start = 6, .lines = &InitialIds },
};

fn runDeleted(allocator: std.mem.Allocator, case: DeletedCase) !void {
    var collection = Collection.init(allocator, .{ .context = @ptrFromInt(@alignOf(usize)), .create = createLine });
    defer collection.deinit();
    try reset(&collection, 6, &InitialIds);
    const deleted = try collection.onLinesDeleted(case.from, case.to);
    if (deleted) |lines| {
        try std.testing.expectEqual(case.deleted.len, lines.len);
        for (case.deleted, lines) |expected, line| try std.testing.expectEqualStrings(expected, line.id);
        allocator.free(lines);
    } else {
        try std.testing.expectEqual(@as(usize, 0), case.deleted.len);
    }
    const pinged: [4]bool = @splat(false);
    try assertState(&collection, case.start, case.lines, pinged[0..case.lines.len]);
}

test "RenderedLinesCollection onLinesDeleted" {
    for (deleted_cases) |case| try runDeleted(std.testing.allocator, case);
}

const ChangedCase = struct { line: usize, pinged: bool, flags: []const bool };

const changed_cases = [_]ChangedCase{
    .{ .line = 3, .pinged = false, .flags = &NoPing },
    .{ .line = 4, .pinged = false, .flags = &NoPing },
    .{ .line = 5, .pinged = false, .flags = &NoPing },
    .{ .line = 6, .pinged = true, .flags = &.{ true, false, false, false } },
    .{ .line = 7, .pinged = true, .flags = &.{ false, true, false, false } },
    .{ .line = 8, .pinged = true, .flags = &.{ false, false, true, false } },
    .{ .line = 9, .pinged = true, .flags = &.{ false, false, false, true } },
    .{ .line = 10, .pinged = false, .flags = &NoPing },
    .{ .line = 11, .pinged = false, .flags = &NoPing },
};

test "RenderedLinesCollection onLineChanged" {
    const allocator = std.testing.allocator;
    for (changed_cases) |case| {
        var collection = Collection.init(allocator, .{ .context = @ptrFromInt(@alignOf(usize)), .create = createLine });
        defer collection.deinit();
        try reset(&collection, 6, &InitialIds);
        try std.testing.expectEqual(case.pinged, collection.onLinesChanged(case.line, 1));
        try assertState(&collection, 6, &InitialIds, case.flags);
    }
}

const inserted_cases = [_]DeletedCase{
    .{ .from = 3, .to = 3, .deleted = &.{}, .start = 7, .lines = &InitialIds },
    .{ .from = 3, .to = 5, .deleted = &.{}, .start = 9, .lines = &InitialIds },
    .{ .from = 3, .to = 7, .deleted = &.{}, .start = 11, .lines = &InitialIds },
    .{ .from = 3, .to = 10, .deleted = &.{}, .start = 14, .lines = &InitialIds },
    .{ .from = 5, .to = 5, .deleted = &.{}, .start = 7, .lines = &InitialIds },
    .{ .from = 5, .to = 8, .deleted = &.{}, .start = 10, .lines = &InitialIds },
    .{ .from = 6, .to = 6, .deleted = &.{}, .start = 7, .lines = &InitialIds },
    .{ .from = 6, .to = 10, .deleted = &.{}, .start = 11, .lines = &InitialIds },
    .{ .from = 7, .to = 7, .deleted = &.{"old9"}, .start = 6, .lines = &.{ "old6", "new", "old7", "old8" } },
    .{ .from = 7, .to = 8, .deleted = &.{ "old8", "old9" }, .start = 6, .lines = &.{ "old6", "new", "new", "old7" } },
    .{ .from = 7, .to = 9, .deleted = &.{ "old7", "old8", "old9" }, .start = 6, .lines = &.{"old6"} },
    .{ .from = 7, .to = 10, .deleted = &.{ "old7", "old8", "old9" }, .start = 6, .lines = &.{"old6"} },
    .{ .from = 8, .to = 8, .deleted = &.{"old9"}, .start = 6, .lines = &.{ "old6", "old7", "new", "old8" } },
    .{ .from = 8, .to = 9, .deleted = &.{ "old8", "old9" }, .start = 6, .lines = &.{ "old6", "old7" } },
    .{ .from = 9, .to = 9, .deleted = &.{"old9"}, .start = 6, .lines = &.{ "old6", "old7", "old8" } },
    .{ .from = 10, .to = 10, .deleted = &.{}, .start = 6, .lines = &InitialIds },
    .{ .from = 11, .to = 13, .deleted = &.{}, .start = 6, .lines = &InitialIds },
};

test "RenderedLinesCollection onLinesInserted" {
    const allocator = std.testing.allocator;
    for (inserted_cases) |case| {
        var collection = Collection.init(allocator, .{ .context = @ptrFromInt(@alignOf(usize)), .create = createLine });
        defer collection.deinit();
        try reset(&collection, 6, &InitialIds);
        const deleted = try collection.onLinesInserted(case.from, case.to);
        if (deleted) |lines| {
            try std.testing.expectEqual(case.deleted.len, lines.len);
            for (case.deleted, lines) |expected, line| try std.testing.expectEqualStrings(expected, line.id);
            allocator.free(lines);
        } else {
            try std.testing.expectEqual(@as(usize, 0), case.deleted.len);
        }
        const pinged: [4]bool = @splat(false);
        try assertState(&collection, case.start, case.lines, pinged[0..case.lines.len]);
    }
}

const TokensCase = struct { from: usize, to: usize, pinged: bool, flags: []const bool };

const tokens_cases = [_]TokensCase{
    .{ .from = 3, .to = 3, .pinged = false, .flags = &NoPing },
    .{ .from = 3, .to = 5, .pinged = false, .flags = &NoPing },
    .{ .from = 3, .to = 6, .pinged = true, .flags = &.{ true, false, false, false } },
    .{ .from = 6, .to = 6, .pinged = true, .flags = &.{ true, false, false, false } },
    .{ .from = 5, .to = 10, .pinged = true, .flags = &.{ true, true, true, true } },
    .{ .from = 8, .to = 9, .pinged = true, .flags = &.{ false, false, true, true } },
    .{ .from = 8, .to = 11, .pinged = true, .flags = &.{ false, false, true, true } },
    .{ .from = 10, .to = 10, .pinged = false, .flags = &NoPing },
    .{ .from = 10, .to = 11, .pinged = false, .flags = &NoPing },
};

test "RenderedLinesCollection onTokensChanged" {
    const allocator = std.testing.allocator;
    for (tokens_cases) |case| {
        var collection = Collection.init(allocator, .{ .context = @ptrFromInt(@alignOf(usize)), .create = createLine });
        defer collection.deinit();
        try reset(&collection, 6, &InitialIds);
        const pinged = collection.onTokensChanged(&.{.{ .from_line_number = case.from, .to_line_number = case.to }});
        try std.testing.expectEqual(case.pinged, pinged);
        try assertState(&collection, 6, &InitialIds, case.flags);
    }
}
