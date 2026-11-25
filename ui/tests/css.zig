const std = @import("std");
const ui = @import("ui");
const ComputedStyle = ui.css.ComputedStyle;
const StyleTable = ui.css.StyleTable;
const mergeClasses = ui.css.mergeClasses;
const resolveElementStyle = ui.css.resolveElementStyle;

test "StyleTable: append, explicit base and lookup" {
    const allocator = std.testing.allocator;
    var table = StyleTable{};
    defer table.deinit(allocator);

    const first = try table.addStyle(allocator, .{ .color = .{ .r = 1, .g = 2, .b = 3 } });
    try std.testing.expectEqual(@as(u16, 0), first);
    const second = try table.addStyle(allocator, .{ .bold = true });
    try std.testing.expectEqual(@as(u16, 1), second);
    try std.testing.expectEqual(@as(?bool, true), table.get(second).?.bold);
    try std.testing.expect(table.get(9) == null);

    const base = try table.register(allocator, .{
        .base = 4,
        .styles = &.{ .{ .color = .{ .r = 9, .g = 9, .b = 9 } }, .{ .dim = true } },
    });
    try std.testing.expectEqual(@as(u16, 4), base);
    try std.testing.expectEqual(@as(usize, 6), table.styles.items.len);
    // The gap before an explicit base is padded with empty declarations.
    try std.testing.expect(table.get(3).?.color == null);
    try std.testing.expectEqual(@as(?bool, true), table.get(5).?.dim);

    // Re-registering the same range updates it in place.
    _ = try table.register(allocator, .{
        .base = 4,
        .styles = &.{ .{ .color = .{ .r = 7, .g = 7, .b = 7 } }, .{ .dim = false } },
    });
    try std.testing.expectEqual(@as(u8, 7), table.get(4).?.color.?.r);
    try std.testing.expectEqual(@as(?bool, false), table.get(5).?.dim);
}

test "css: mergeClasses keeps order and inline wins" {
    const allocator = std.testing.allocator;
    var table = StyleTable{};
    defer table.deinit(allocator);

    const Class = enum(u16) { base, selected };
    _ = try table.register(allocator, .{
        .styles = &.{
            .{ .color = .{ .r = 1, .g = 1, .b = 1 }, .bold = false },
            .{ .color = .{ .r = 2, .g = 2, .b = 2 } },
        },
    });

    const all = [_]Class{ Class.base, Class.selected };
    const merged = mergeClasses(&table, &all);
    try std.testing.expectEqual(@as(u8, 2), merged.color.?.r);
    // The second class leaves bold unspecified, so the first class's explicit
    // false survives.
    try std.testing.expectEqual(@as(?bool, false), merged.bold);

    const base_only = [_]Class{Class.base};
    const resolved = resolveElementStyle(ComputedStyle.initial(.block), &table, &base_only, .{
        .color = .{ .r = 3, .g = 3, .b = 3 },
    }, .block);
    try std.testing.expectEqual(@as(u8, 3), resolved.color.?.r);
    try std.testing.expectEqual(@as(?bool, false), resolved.bold);
}
