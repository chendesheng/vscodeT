// Port of the editor-history subset of
// `src/vs/workbench/services/history/common/history.ts`.
//
// The TUI keeps the most-recently-opened editor paths that quick open uses.
// Upstream also tracks navigation history (back/forward), multi-editor
// grouping, working-set order and persistence; those need services the
// terminal workbench does not have, so they are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HistoryService = struct {
    allocator: Allocator,
    paths: std.array_list.Managed([]u8),
    max: usize = 50,

    pub fn init(allocator: Allocator) HistoryService {
        return .{
            .allocator = allocator,
            .paths = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *HistoryService) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit();
    }

    /// Moves `path` to the front, deduplicating by exact path.
    pub fn add(self: *HistoryService, path: []const u8) !void {
        self.remove(path);
        const copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(copy);
        try self.paths.insert(0, copy);
        while (self.paths.items.len > self.max) {
            const removed = self.paths.pop().?;
            self.allocator.free(removed);
        }
    }

    pub fn remove(self: *HistoryService, path: []const u8) void {
        for (self.paths.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry, path)) {
                const removed = self.paths.orderedRemove(index);
                self.allocator.free(removed);
                return;
            }
        }
    }

    pub fn getHistory(self: *const HistoryService) []const []u8 {
        return self.paths.items;
    }

    pub fn clear(self: *HistoryService) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.clearRetainingCapacity();
    }
};

test "HistoryService: most-recent-first, dedupe, remove and cap" {
    var history = HistoryService.init(std.testing.allocator);
    defer history.deinit();
    history.max = 3;

    try history.add("/a");
    try history.add("/b");
    try history.add("/a");
    try std.testing.expectEqual(@as(usize, 2), history.getHistory().len);
    try std.testing.expectEqualStrings("/a", history.getHistory()[0]);
    try std.testing.expectEqualStrings("/b", history.getHistory()[1]);

    try history.add("/c");
    try history.add("/d");
    try std.testing.expectEqual(@as(usize, 3), history.getHistory().len);
    try std.testing.expectEqualStrings("/d", history.getHistory()[0]);
    try std.testing.expectEqualStrings("/c", history.getHistory()[1]);

    history.remove("/c");
    try std.testing.expectEqual(@as(usize, 2), history.getHistory().len);
}
