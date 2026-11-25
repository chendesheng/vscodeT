// Terminal visual and hit-test coverage for the portable subset of
// src/vs/workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts.
// The existing terminal regression cases preserve fixed-cell sizing and
// pointer semantics; upstream DOM-specific browser fixtures are not copied.
const std = @import("std");
const ui = @import("ui");
const tabs_control = @import("../../../../browser/parts/editor/multiEditorTabsControl.zig");
const file_icon = @import("../../../../services/themes/browser/fileIconThemeData.zig");
const CellGrid = ui.CellGrid;
const TabInfo = tabs_control.TabInfo;
const Hit = tabs_control.Hit;
const draw = tabs_control.draw;
const hitAt = tabs_control.hitAt;
const closeHitAt = tabs_control.closeHitAt;
const dropIndexAt = tabs_control.dropIndexAt;
const tabCloseButtonVisible = tabs_control.tabCloseButtonVisible;

test "tabBar draws labels, active state and hits" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 32, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt" },
        .{ .label = "b.ts", .file_name = "b.ts", .dirty = true },
        .{ .label = "c.md", .file_name = "c.md" },
    };
    _ = try draw(&grid, &tabs, 1, 0, 0, grid.cols, &hits, .{}, null);

    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expectEqual(@as(usize, 1), hitAt(hits.items, hits.items[1].start).?);
    try std.testing.expectEqual(@as(?usize, null), hitAt(hits.items, hits.items[0].end));

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b.ts") != null);
    try std.testing.expectEqual(@as(u32, 0xE628), grid.cluster[grid.index(hits.items[1].start + 1, 0)]);
    // The dirty tab paints its dot in the close cell.
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25CF}") != null);
}

test "tabBar close hits and hovered close" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 32, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt" },
        .{ .label = "b.txt", .file_name = "b.txt" },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .hovered = 1 }, null);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    // Inactive tab has no close glyph unless hovered/active.
    try std.testing.expect(hits.items[0].close_start != null);
    try std.testing.expect(hits.items[1].close_start != null);
    try std.testing.expectEqual(@as(?usize, 1), closeHitAt(hits.items, hits.items[1].close_start.?));
}

test "tabBar can place the close cell on the left" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 20, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt" },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .close_button_left = true }, null);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(@as(?usize, 0), hits.items[0].close_start);
    try std.testing.expectEqual(@as(u32, 0x00D7), grid.cluster[grid.index(0, 0)]);
    try std.testing.expectEqual(@as(?usize, 0), closeHitAt(hits.items, 0));
}

test "tabBar supports fit, shrink and fixed sizing" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 40, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();
    const tabs = [_]TabInfo{
        .{ .label = "very-long-file-name-a.ts", .file_name = "a.ts" },
        .{ .label = "very-long-file-name-b.ts", .file_name = "b.ts" },
        .{ .label = "very-long-file-name-c.ts", .file_name = "c.ts" },
    };

    _ = try draw(&grid, &tabs, 0, 0, 0, 40, &hits, .{ .tab_sizing = .fixed }, null);
    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expectEqual(@as(usize, 12), hits.items[0].end - hits.items[0].start);

    _ = try draw(&grid, &tabs, 0, 0, 0, 40, &hits, .{ .tab_sizing = .fit }, null);
    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expect(hits.items[0].end - hits.items[0].start <= 13);
}

test "tabBar scrolls to keep the active tab visible" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 10, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "first.txt", .file_name = "first.txt" },
        .{ .label = "second.txt", .file_name = "second.txt" },
        .{ .label = "third.txt", .file_name = "third.txt" },
    };
    _ = try draw(&grid, &tabs, 2, 0, 0, grid.cols, &hits, .{}, null);

    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), hits.items[hits.items.len - 1].index);
    try std.testing.expectEqual(@as(?usize, 2), hitAt(hits.items, hits.items[hits.items.len - 1].start));
}

test "tabBar italicizes preview tabs" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 24, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "p.ts", .file_name = "p.ts", .pinned = false },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{}, null);
    var col = hits.items[0].start;
    var found_italic = false;
    while (col < hits.items[0].end) : (col += 1) {
        if (grid.attrs[col] & ui.cell.Attr.italic != 0) found_italic = true;
    }
    try std.testing.expect(found_italic);
}

test "tabBar: title action reserves the right corner and reports its hit" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 30, 1);
    defer grid.deinit();
    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.md", .file_name = "a.md" },
        .{ .label = "b.md", .file_name = "b.md" },
    };
    const action_hit = (try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{
        .title_action = .{ .active = true },
        .drop_index = 2,
    }, null)).?;
    try std.testing.expectEqual(@as(usize, 28), action_hit.start);
    try std.testing.expectEqual(@as(usize, 30), action_hit.end);
    try std.testing.expectEqual(@as(u32, 0x25EB), grid.cluster[grid.index(28, 0)]);
    try std.testing.expectEqual(@as(u32, 0x2315), grid.cluster[grid.index(29, 0)]);
    for (hits.items) |hit| try std.testing.expect(hit.end <= 27);
}

test "tabBar: file icons come from the shared Explorer table" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 70, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "app.js", .file_name = "app.js" },
        .{ .label = "main.zig", .file_name = "main.zig" },
        .{ .label = "notes.unknown", .file_name = "notes.unknown" },
        .{ .label = "no-file", .file_name = "" },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{}, null);

    const expected = [_]file_icon.Icon{
        file_icon.file("app.js"),
        file_icon.file("main.zig"),
        file_icon.file("notes.unknown"),
    };
    for (expected, 0..) |icon, index| {
        const icon_col = hits.items[index].start + 1;
        try std.testing.expectEqual(@as(u32, icon.glyph), grid.cluster[grid.index(icon_col, 0)]);
        try std.testing.expectEqual(ui.cell.packColor(icon.color), grid.fg[grid.index(icon_col, 0)]);
    }
    // An empty file name suppresses the icon; the label starts in its place.
    try std.testing.expectEqual(@as(u32, 'n'), grid.cluster[grid.index(hits.items[3].start + 1, 0)]);
}

test "tabBar: drop index follows the tab halves" {
    const hits = [_]Hit{
        .{ .start = 2, .end = 10, .index = 0 },
        .{ .start = 11, .end = 20, .index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), dropIndexAt(&hits, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), dropIndexAt(&hits, 6, 3));
    try std.testing.expectEqual(@as(usize, 1), dropIndexAt(&hits, 7, 3));
    try std.testing.expectEqual(@as(usize, 1), dropIndexAt(&hits, 10, 3));
    try std.testing.expectEqual(@as(usize, 1), dropIndexAt(&hits, 15, 3));
    try std.testing.expectEqual(@as(usize, 2), dropIndexAt(&hits, 16, 3));
    try std.testing.expectEqual(@as(usize, 3), dropIndexAt(&hits, 25, 3));
    try std.testing.expectEqual(@as(usize, 0), dropIndexAt(&hits, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), dropIndexAt(&[_]Hit{}, 0, 3));
}

test "tabBar: drop preview marks the insertion cell" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 30, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt" },
        .{ .label = "b.txt", .file_name = "b.txt" },
    };

    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .drop_index = 1 }, null);
    try std.testing.expectEqual(@as(u32, 0x258F), grid.cluster[grid.index(hits.items[1].start, 0)]);

    // An end-of-strip insertion prefers the free cell after the last tab.
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .drop_index = 2 }, null);
    try std.testing.expectEqual(@as(u32, 0x258F), grid.cluster[grid.index(hits.items[1].end, 0)]);
}

test "tabBar: drop preview uses a cell-border stroke when available" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 30, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt" },
        .{ .label = "b.txt", .file_name = "b.txt" },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{
        .drop_index = 1,
        .cell_borders = true,
    }, null);
    const set = grid.borderSetAt(hits.items[1].start, 0);
    try std.testing.expect(set.strokeAt(ui.cell_border.Segment.left) != null);
}

test "tabBar: hover background and last-pinned separator" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 40, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .file_name = "a.txt", .pinned = true },
        .{ .label = "b.txt", .file_name = "b.txt", .pinned = false },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .hovered = 1 }, null);

    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 31, .g = 31, .b = 31 }),
        grid.bg[grid.index(hits.items[1].start + 1, 0)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 204, .g = 195, .b = 195 }),
        grid.fg[grid.index(hits.items[1].start - 1, 0)],
    );
}

test "Workbench: tab close button honors the off setting" {
    try std.testing.expect(tabCloseButtonVisible("right"));
    try std.testing.expect(tabCloseButtonVisible("left"));
    try std.testing.expect(!tabCloseButtonVisible("off"));
}
