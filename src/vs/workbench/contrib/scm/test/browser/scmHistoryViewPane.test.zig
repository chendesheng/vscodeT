// Terminal tests for the SCM History view pane
// (`src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.zig`).
//
// Upstream covers the pane through the SCM history data source and the
// workbench tree. The terminal pane owns the row model, pagination and input
// handling directly, so these tests exercise that surface: page growth, the
// Load More row and the rendered row labels. The hover overlay is covered by
// the Workbench integration test in `workbench.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const history = @import("../../common/history.zig");
const scm_history = @import("../../browser/scmHistoryViewPane.zig");

const Emitter = @import("../../../../../base/common/event.zig").Emitter;

const TestHost = struct {
    opened: usize = 0,
    focused: usize = 0,
    picked: usize = 0,
    opened_history: usize = 0,

    fn openChange(context: *anyopaque, item: *const history.ISCMHistoryItem, change: *const history.ISCMHistoryItemChange) anyerror!void {
        _ = item;
        _ = change;
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened += 1;
    }

    fn openChanges(context: *anyopaque, _: *const history.ISCMHistoryItem, _: []const history.ISCMHistoryItemChange) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened_history += 1;
    }

    fn focusEditor(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.focused += 1;
    }

    fn pickRefs(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.picked += 1;
    }
};

/// Linear history provider: `total` commits, newest first. `provideHistoryItems`
/// slices `[skip, skip + limit)` like the Git extension and records the request
/// so the pane's pagination is observable.
const TestHistoryProvider = struct {
    allocator: Allocator,
    total: usize,
    base: history.ISCMHistoryProvider = undefined,
    current: history.ISCMHistoryItemRef = undefined,
    refs_changed: Emitter(history.ISCMHistoryItemRefsChangeEvent) = undefined,
    fetch_count: usize = 0,
    last_skip: ?usize = null,
    last_limit: usize = 0,
    /// When set, every history item also has a second parent that is not part
    /// of the loaded page, the shape that used to rasterize as a diagonal.
    merge_parents: bool = false,

    fn init(self: *TestHistoryProvider, allocator: Allocator, total: usize) !void {
        self.allocator = allocator;
        self.total = total;
        self.fetch_count = 0;
        self.last_skip = null;
        self.last_limit = 0;
        self.merge_parents = false;
        self.refs_changed = Emitter(history.ISCMHistoryItemRefsChangeEvent).init(allocator);
        self.current = .{ .id = "main", .name = "main", .revision = "commit-0" };
        self.base = .{
            .context = self,
            .history_item_ref = self.current,
            .on_did_change_history_item_refs = &self.refs_changed,
            .provide_history_item_refs_fn = provideRefs,
            .provide_history_items_fn = provideItems,
            .provide_history_item_changes_fn = provideChanges,
            .resolve_history_item_refs_common_ancestor_fn = resolveCommonAncestor,
        };
    }

    fn deinit(self: *TestHistoryProvider) void {
        self.refs_changed.deinit();
    }

    fn interface(self: *TestHistoryProvider) *history.ISCMHistoryProvider {
        return &self.base;
    }

    fn provideRefs(context: *anyopaque, allocator: Allocator, ids: ?[]const []const u8) ![]history.ISCMHistoryItemRef {
        _ = context;
        _ = ids;
        return allocator.alloc(history.ISCMHistoryItemRef, 0);
    }

    fn provideChanges(context: *anyopaque, allocator: Allocator, id: []const u8, parent: ?[]const u8) ![]history.ISCMHistoryItemChange {
        _ = context;
        _ = id;
        _ = parent;
        return allocator.alloc(history.ISCMHistoryItemChange, 0);
    }

    fn resolveCommonAncestor(context: *anyopaque, allocator: Allocator, ids: []const []const u8) !?[]u8 {
        _ = context;
        _ = allocator;
        _ = ids;
        return null;
    }

    fn provideItems(context: *anyopaque, allocator: Allocator, options: history.ISCMHistoryOptions) ![]history.ISCMHistoryItem {
        const self: *TestHistoryProvider = @ptrCast(@alignCast(context));
        self.fetch_count += 1;
        self.last_skip = options.skip;
        const requested = switch (options.limit) {
            .count => |count| count,
            .none => self.total,
            .id => 1,
        };
        self.last_limit = requested;
        const skip = options.skip orelse 0;
        if (skip >= self.total) return allocator.alloc(history.ISCMHistoryItem, 0);
        const end = @min(self.total, skip + requested);

        const items = try allocator.alloc(history.ISCMHistoryItem, end - skip);
        for (items, skip..) |*item, index| {
            const id = try std.fmt.allocPrint(allocator, "commit-{d}", .{index});
            const subject = try std.fmt.allocPrint(allocator, "subject {d}", .{index});
            const parent_count: usize = if (index + 1 < self.total)
                (if (self.merge_parents) 2 else 1)
            else
                0;
            const parent_ids = try allocator.alloc([]const u8, parent_count);
            if (parent_count > 0) {
                parent_ids[0] = try std.fmt.allocPrint(allocator, "commit-{d}", .{index + 1});
            }
            if (parent_count > 1) {
                parent_ids[1] = try std.fmt.allocPrint(allocator, "side-{d}", .{index});
            }
            item.* = .{
                .id = id,
                .parent_ids = parent_ids,
                .subject = subject,
                .message = try allocator.dupe(u8, subject),
                .author = "Test Author",
                .display_id = id,
                .references = &.{},
            };
        }
        return items;
    }
};

fn testRect() ui.Rect {
    return .{ .x = 0, .y = 0, .w = 40, .h = 12 };
}

fn createView(allocator: Allocator, host: *TestHost, provider: *TestHistoryProvider) !*scm_history.SCMHistoryViewPane {
    const view = try scm_history.SCMHistoryViewPane.init(allocator, .{
        .context = host,
        .open_change = TestHost.openChange,
        .focus_editor = TestHost.focusEditor,
        .pick_refs = TestHost.pickRefs,
    }, null);
    view.setConfig(.{ .page_size = 2, .page_on_scroll = false });
    view.setProvider(provider.interface());
    return view;
}

test "SCM history view pane: hover exposes Open Changes without expanding the row" {
    const allocator = testing.allocator;
    var host = TestHost{};
    var provider: TestHistoryProvider = undefined;
    try provider.init(allocator, 6);
    defer provider.deinit();
    const view = try createView(allocator, &host, &provider);
    defer {
        view.deinit();
        allocator.destroy(view);
    }
    view.host.open_changes = TestHost.openChanges;
    const rect = testRect();
    var grid = try ui.CellGrid.init(allocator, 40, 12);
    defer grid.deinit();
    try view.render(&grid, rect, false);
    try testing.expect(grid.cluster[grid.index(37, 0)] != scm_history.open_changes_glyph);
    _ = try view.handleMouse(&.{ .kind = .move, .x = 9, .y = 0 }, rect);
    try view.render(&grid, rect, false);
    try testing.expectEqual(@as(u32, scm_history.open_changes_glyph), grid.cluster[grid.index(37, 0)]);
    const rows_before = view.rows.items.len;
    try testing.expect(try view.handleMouse(&.{ .kind = .down, .button = .left, .x = 37, .y = 0 }, rect));
    try testing.expectEqual(@as(usize, 1), host.opened_history);
    try testing.expectEqual(rows_before, view.rows.items.len);
}

test "SCM history view pane: the scrollbar thumb follows wheel scrolling" {
    const allocator = testing.allocator;
    var host = TestHost{};
    var provider: TestHistoryProvider = undefined;
    try provider.init(allocator, 6);
    defer provider.deinit();
    const view = try createView(allocator, &host, &provider);
    defer {
        view.deinit();
        allocator.destroy(view);
    }
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 2 };
    var grid = try ui.CellGrid.init(allocator, 40, 2);
    defer grid.deinit();
    const track = ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 });
    const thumb = ui.cell.packColor(.{ .r = 105, .g = 108, .b = 122 });
    try view.render(&grid, rect, false);
    try testing.expectEqual(thumb, grid.bg[grid.index(39, 0)]);
    try testing.expectEqual(track, grid.bg[grid.index(39, 1)]);
    try testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(39, 1)]);

    try testing.expect(try view.handleMouse(&.{ .kind = .wheel, .x = 39, .y = 0, .delta_y = 1 }, rect));
    try view.render(&grid, rect, false);
    try testing.expectEqual(track, grid.bg[grid.index(39, 0)]);
    try testing.expectEqual(thumb, grid.bg[grid.index(39, 1)]);
    try testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(39, 0)]);
}

test "SCM history view pane: load more appends the next page" {
    const allocator = testing.allocator;
    var host = TestHost{};
    var provider: TestHistoryProvider = undefined;
    try provider.init(allocator, 6);
    defer provider.deinit();

    const view = try createView(allocator, &host, &provider);
    defer {
        view.deinit();
        allocator.destroy(view);
    }

    // One page of two commits plus the Load More row.
    try testing.expectEqual(@as(usize, 3), view.rows.items.len);
    try testing.expectEqual(@as(usize, 1), provider.fetch_count);
    try testing.expectEqual(@as(usize, 2), provider.last_limit);
    try view.loadMore();
    try testing.expectEqual(@as(usize, 5), view.rows.items.len);
    try testing.expectEqual(@as(usize, 4), provider.last_limit);
    try testing.expectEqual(@as(usize, 4), view.rows.items.len - 1);

    // The third page consumes the rest of the history.
    try view.loadMore();
    try testing.expectEqual(@as(usize, 6), view.rows.items.len);
    try testing.expectEqual(@as(usize, 6), provider.last_limit);
}

test "SCM history view pane: one click on Load More loads the next page" {
    const allocator = testing.allocator;
    var host = TestHost{};
    var provider: TestHistoryProvider = undefined;
    try provider.init(allocator, 6);
    defer provider.deinit();

    const view = try createView(allocator, &host, &provider);
    defer {
        view.deinit();
        allocator.destroy(view);
    }

    var grid = try ui.CellGrid.init(allocator, 40, 12);
    defer grid.deinit();
    const rect = testRect();
    try view.render(&grid, rect, true);

    // The graph cell and the subject are separated by one space, matching the
    // gap upstream's IconLabel places after the leading icon.
    const first_row = try grid.rowText(allocator, 0);
    defer allocator.free(first_row);
    const subject_at = std.mem.indexOf(u8, first_row, "subject 0") orelse return error.TestUnexpectedResult;
    try testing.expect(subject_at > 0);
    try testing.expectEqual(@as(u8, ' '), first_row[subject_at - 1]);

    // The Load More row is the third row; a single click activates it.
    var click = ui.MouseEvent{ .kind = .down, .x = 2, .y = 2, .button = .left };
    try testing.expect(try view.handleMouse(&click, rect));
    try testing.expectEqual(@as(usize, 5), view.rows.items.len);
    try testing.expectEqual(@as(usize, 4), provider.last_limit);
}

test "SCM history view pane: merge graph uses orthogonal connectors" {
    const allocator = testing.allocator;
    var host = TestHost{};
    var provider: TestHistoryProvider = undefined;
    try provider.init(allocator, 6);
    defer provider.deinit();
    // Every commit merges a side branch that is not in the loaded page, so the
    // graph opens one lane per row. Before the cell-connection rewrite these
    // rows were `╲` diagonals that read as a single slope.
    provider.merge_parents = true;

    const view = try createView(allocator, &host, &provider);
    defer {
        view.deinit();
        allocator.destroy(view);
    }

    var grid = try ui.CellGrid.init(allocator, 80, 12);
    defer grid.deinit();
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 80, .h = 12 }, true);

    const first_row = try grid.rowText(allocator, 0);
    defer allocator.free(first_row);
    const second_row = try grid.rowText(allocator, 1);
    defer allocator.free(second_row);

    for ([_][]const u8{ first_row, second_row }) |row| {
        try testing.expect(std.mem.indexOf(u8, row, "\u{2571}") == null); // ╱
        try testing.expect(std.mem.indexOf(u8, row, "\u{2572}") == null); // ╲
        try testing.expect(std.mem.indexOf(u8, row, "subject") != null);
    }
    // Row 0 opens the first side lane with a corner; row 1 crosses that lane
    // and opens the next one.
    try testing.expect(std.mem.indexOf(u8, first_row, "\u{256E}") != null); // ╮
    try testing.expect(std.mem.indexOf(u8, second_row, "\u{253C}") != null); // ┼
}
