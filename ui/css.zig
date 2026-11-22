//! Class styles for the terminal UI.
//!
//! There is no CSS parser and no selector engine. A class name is an integer
//! index into the document's array-backed stylesheet; `addClass` passes only
//! that name. A `*_css.zig` port defines an enum of class IDs plus the style
//! declarations for them and registers the sheet on the document.

const std = @import("std");
const style_mod = @import("style.zig");

pub const Style = style_mod.Style;
pub const ComputedStyle = style_mod.ComputedStyle;

/// A batch of class styles. Styles are copied into the document; the slice may
/// be temporary (for example a themed stack array). With a `base`, the styles
/// occupy `base .. base + styles.len`; without one they are appended.
pub const Sheet = struct {
    base: ?u16 = null,
    styles: []const Style,
};

/// The document stylesheet: a dense array where the class ID is the index.
/// Lookup is one bounds-checked index; there is no hash map.
pub const StyleTable = struct {
    styles: std.ArrayListUnmanaged(Style) = .empty,

    pub fn deinit(self: *StyleTable, allocator: std.mem.Allocator) void {
        self.styles.deinit(allocator);
    }

    /// Appends one style and returns its class ID.
    pub fn addStyle(self: *StyleTable, allocator: std.mem.Allocator, style: Style) !u16 {
        var one = [_]Style{style};
        return self.register(allocator, .{ .styles = &one });
    }

    /// Copies a sheet into the array and returns its base class ID. Without a
    /// base the sheet is appended; with a base it overwrites that range and
    /// grows with empty declarations when needed.
    pub fn register(self: *StyleTable, allocator: std.mem.Allocator, sheet: Sheet) !u16 {
        const start: usize = if (sheet.base) |base| base else self.styles.items.len;
        const end = start + sheet.styles.len;
        if (end > @as(usize, std.math.maxInt(u16)) + 1) return error.ClassIdOverflow;

        try self.styles.ensureTotalCapacity(allocator, end);
        while (self.styles.items.len < end) self.styles.appendAssumeCapacity(.{});
        @memcpy(self.styles.items[start..end], sheet.styles);
        return @intCast(start);
    }

    /// The declaration for `id`, or null when no class occupies that index.
    pub fn get(self: *const StyleTable, id: u16) ?*const Style {
        if (id >= self.styles.items.len) return null;
        return &self.styles.items[id];
    }
};

/// Converts a class name enum (or a plain integer) to its stored ID.
pub fn classId(value: anytype) u16 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@backingInt(value)),
        .int, .comptime_int => @intCast(value),
        else => @compileError("class name must be an enum or integer"),
    };
}

/// Merges class declarations in list order, skipping IDs with no rule.
pub fn mergeClasses(table: *const StyleTable, classes: anytype) Style {
    var result = Style{};
    for (classes) |class| {
        const id = classId(class);
        if (table.get(id)) |declaration| result = Style.merge(result, declaration.*);
    }
    return result;
}

/// Cascade for one element: classes in order, inline declaration last, then
/// resolve inherited and initial values against the parent.
pub fn resolveElementStyle(
    parent: ComputedStyle,
    table: *const StyleTable,
    classes: anytype,
    inline_style: Style,
    default_display: style_mod.Display,
) ComputedStyle {
    var declaration = mergeClasses(table, classes);
    declaration = Style.merge(declaration, inline_style);
    return declaration.resolve(parent, default_display);
}

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
