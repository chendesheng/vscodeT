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
