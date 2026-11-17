// Port of the terminal-adapted cases from
// `src/vs/workbench/test/browser/parts/statusbar/statusbarPart.test.ts`.
//
// The upstream file focuses on DOM styling, window focus and floating-panel
// layout. The terminal has no theme/window/floating-panel services, so this
// file covers the portable part behavior: accessors, visibility, overrides,
// item layout, hit testing, focus and the plain-text tooltip.

const std = @import("std");
const ui = @import("ui");
const part_mod = @import("../../../../browser/parts/statusbar/statusbarPart.zig");
const StatusbarPart = part_mod.StatusbarPart;
const statusbar = @import("../../../../services/statusbar/browser/statusbar.zig");

fn rowText(grid: *ui.CellGrid, row: usize) ![]u8 {
    return grid.rowText(std.testing.allocator, row);
}

test "StatusbarPart: left/right order, compact location and hit testing" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();

    const left = try part.addEntry(.{ .name = "left", .text = "L" }, "left", .left, .{ .number = 3 });
    _ = left;
    const right = try part.addEntry(.{ .name = "right", .text = "R" }, "right", .right, .{ .number = 1 });
    _ = right;
    const compact = try part.addEntry(.{ .name = "compact", .text = "C" }, "compact", .left, .{
        .location = .{
            .location = .{ .id = "left", .priority = 0 },
            .alignment = .left,
            .compact = true,
        },
    });
    _ = compact;

    var grid = try ui.CellGrid.init(std.testing.allocator, 24, 1);
    defer grid.deinit();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 1 }, .{});

    const row = try rowText(&grid, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "L") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "C") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "R") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "C").? < std.mem.indexOf(u8, row, "L").?);
    try std.testing.expect(std.mem.lastIndexOfScalar(u8, row, 'R').? >= 20);

    try std.testing.expect(try part.hitAt(1, 0) != null);
    try std.testing.expect(try part.hitAt(23, 0) != null);
    try std.testing.expect(try part.hitAt(24, 0) == null);
}

test "StatusbarPart: visibility, overrides and duplicate-id disposal" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();

    const first = try part.addEntry(.{ .name = "first", .text = "A" }, "same", .left, .{ .number = 2 });
    const second = try part.addEntry(.{ .name = "second", .text = "B" }, "same", .left, .{ .number = 1 });
    var grid = try ui.CellGrid.init(std.testing.allocator, 16, 1);
    defer grid.deinit();

    try part.render(&grid, .{ .x = 0, .y = 0, .w = 16, .h = 1 }, .{});
    var row = try rowText(&grid, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "B") != null);

    part.updateEntryVisibility("same", false);
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 16, .h = 1 }, .{});
    std.testing.allocator.free(row);
    row = try rowText(&grid, 0);
    try std.testing.expect(std.mem.indexOf(u8, row, "A") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "B") == null);

    part.updateEntryVisibility("same", true);
    const override = try part.overrideEntry("same", .{ .text = "OVR" });
    defer override.dispose();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 16, .h = 1 }, .{});
    std.testing.allocator.free(row);
    row = try rowText(&grid, 0);
    try std.testing.expect(std.mem.indexOf(u8, row, "OVR") != null);

    second.dispose();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 16, .h = 1 }, .{});
    std.testing.allocator.free(row);
    row = try rowText(&grid, 0);
    try std.testing.expect(std.mem.indexOf(u8, row, "OVR") != null);
    first.dispose();
}

test "StatusbarPart: focus skips hidden entries and tooltip paints above" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();

    const first = try part.addEntry(.{
        .name = "first",
        .text = "A",
        .tooltip = "first tooltip",
    }, "first", .left, .{ .number = 2 });
    _ = try part.addEntry(.{ .name = "second", .text = "B" }, "second", .left, .{ .number = 1 });
    part.updateEntryVisibility("second", false);

    const focused = part.focusNextEntry().?;
    try std.testing.expectEqualStrings("first", focused.id);
    try std.testing.expect(part.focusNextEntry() == null);

    var grid = try ui.CellGrid.init(std.testing.allocator, 24, 2);
    defer grid.deinit();
    part.setHovered(first.handle);
    try part.render(&grid, .{ .x = 0, .y = 1, .w = 24, .h = 1 }, .{});
    const tooltip = try rowText(&grid, 0);
    defer std.testing.allocator.free(tooltip);
    try std.testing.expect(std.mem.indexOf(u8, tooltip, "first tooltip") != null);
}

test "StatusbarPart: style override priority" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();
    const low = try part.overrideStyle(.{ .priority = 10, .background = .{ 1, 2, 3 } });
    defer low.dispose();
    const high = try part.overrideStyle(.{ .priority = 1, .background = .{ 4, 5, 6 } });
    defer high.dispose();
    const active = part.activeStyleOverride().?;
    try std.testing.expectEqual(@as(f64, 1), active.priority);
    try std.testing.expectEqual([3]u8{ 4, 5, 6 }, active.background.?);
}

test "StatusbarPart: multiple right entries stay on the row" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();
    _ = try part.addEntry(.{ .name = "left", .text = "L" }, "left", .left, .{ .number = 1 });
    _ = try part.addEntry(.{ .name = "r1", .text = "R1" }, "r1", .right, .{ .number = 3 });
    _ = try part.addEntry(.{ .name = "r2", .text = "R2" }, "r2", .right, .{ .number = 2 });
    _ = try part.addEntry(.{ .name = "r3", .text = "R3" }, "r3", .right, .{ .number = 1 });

    var grid = try ui.CellGrid.init(std.testing.allocator, 30, 1);
    defer grid.deinit();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 30, .h = 1 }, .{});
    const row = try rowText(&grid, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "R2") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "R3") != null);
}
