// Port of `src/vs/editor/common/model/decorationProvider.ts`.
const std = @import("std");
const Range = @import("../core/range.zig").Range;
const ModelDecoration = @import("../model.zig").ModelDecoration;

pub const DecorationProvider = struct {
    context: *anyopaque,
    getDecorationsInRange: *const fn (
        context: *anyopaque,
        range: Range,
        ownerId: ?usize,
        filterOutValidation: bool,
        filterFontDecorations: bool,
    ) []const ModelDecoration,
    getAllDecorations: *const fn (
        context: *anyopaque,
        ownerId: ?usize,
        filterOutValidation: bool,
        filterFontDecorations: bool,
        onlyMinimapDecorations: bool,
    ) []const ModelDecoration,
};

pub const LineHeightChangingDecoration = struct {
    ownerId: usize,
    decorationId: []const u8,
    lineNumber: usize,
    lineHeight: ?usize,

    pub fn toKey(allocator: std.mem.Allocator, decoration: LineHeightChangingDecoration) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d};{s};{d}", .{ decoration.ownerId, decoration.decorationId, decoration.lineNumber });
    }
};

pub const LineFontChangingDecoration = struct {
    ownerId: usize,
    decorationId: []const u8,
    lineNumber: usize,

    pub fn toKey(allocator: std.mem.Allocator, decoration: LineFontChangingDecoration) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d};{s};{d}", .{ decoration.ownerId, decoration.decorationId, decoration.lineNumber });
    }
};

test "decorationProvider: line decoration keys" {
    const allocator = std.testing.allocator;
    const key = try LineHeightChangingDecoration.toKey(allocator, .{
        .ownerId = 1,
        .decorationId = "d",
        .lineNumber = 2,
        .lineHeight = null,
    });
    defer allocator.free(key);
    try std.testing.expectEqualStrings("1;d;2", key);
}
