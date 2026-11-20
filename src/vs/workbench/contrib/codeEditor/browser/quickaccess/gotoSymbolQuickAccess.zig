// Portable subset of
// `src/vs/workbench/contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.ts`.
//
// Terminal adaptations: fuzzy scoring and the browser quick-access registry are
// not ported (the TUI quick pick filters labels); the outline tree is flattened
// into depth-tagged entries and rendered with the same terminal glyphs used by
// the breadcrumb bar.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const Position = @import("../../../../../editor/common/core/position.zig").Position;
const outline_model = @import("../../../../../editor/contrib/documentSymbols/browser/outlineModel.zig");
const OutlineElement = outline_model.OutlineElement;
const OutlineModel = outline_model.OutlineModel;

pub const command_id = "workbench.action.gotoSymbol";
pub const command_label = "Go to Symbol in Editor...";
pub const placeholder = "Go to Symbol in Editor";
pub const no_provider_message = "The active text editor does not provide symbol information.";
pub const no_symbols_message = "No editor symbols";
pub const no_matching_message = "No matching editor symbols";

pub const Entry = struct {
    symbol: *const OutlineElement,
    depth: usize,
};

pub fn collect(allocator: Allocator, model: *const OutlineModel) ![]Entry {
    var result = std.array_list.Managed(Entry).init(allocator);
    errdefer result.deinit();
    for (model.roots) |root| try appendElement(&result, root, 0);
    return result.toOwnedSlice();
}

fn appendElement(result: *std.array_list.Managed(Entry), element: *const OutlineElement, depth: usize) !void {
    try result.append(.{ .symbol = element, .depth = depth });
    for (element.children) |child| try appendElement(result, child, depth + 1);
}

pub fn label(allocator: Allocator, entry: Entry) ![]u8 {
    const indent_len = entry.depth * 2;
    const indent = try allocator.alloc(u8, indent_len);
    defer allocator.free(indent);
    @memset(indent, ' ');
    return std.fmt.allocPrint(allocator, "{s}{s} {s}", .{
        indent,
        glyph(entry.symbol.symbol.kind),
        entry.symbol.symbol.name,
    });
}

pub fn glyph(kind: u32) []const u8 {
    return switch (kind) {
        1, 2, 3 => "N",
        4, 9, 10, 22 => "◇",
        5, 8, 11 => "ƒ",
        6, 7, 12, 13, 21 => "·",
        else => "◇",
    };
}

pub fn kindLabel(kind: u32) []const u8 {
    return switch (kind) {
        1 => "file",
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        15 => "string",
        16 => "number",
        17 => "boolean",
        18 => "array",
        19 => "object",
        20 => "key",
        21 => "null",
        22 => "enum member",
        23 => "struct",
        24 => "event",
        25 => "operator",
        26 => "type parameter",
        else => "symbol",
    };
}

/// Returns the last entry whose symbol range contains `position`, matching the
/// upstream "enclosing symbol" active-item selection.
pub fn activeIndex(entries: []const Entry, position: Position) ?usize {
    var owned_position = position;
    var active: ?usize = null;
    for (entries, 0..) |entry, index| {
        var range = entry.symbol.symbol.range;
        if (range.containsPosition(&owned_position)) active = index;
    }
    return active;
}

test "gotoSymbolQuickAccess: flatten, label and active symbol" {
    var child = OutlineElement{
        .symbol = .{
            .name = "child",
            .kind = 12,
            .range = Range.init(2, 1, 3, 2),
            .selection_range = Range.init(2, 1, 2, 6),
        },
    };
    var children = [_]*OutlineElement{&child};
    var root = OutlineElement{
        .symbol = .{
            .name = "root",
            .kind = 5,
            .range = Range.init(1, 1, 3, 2),
            .selection_range = Range.init(1, 7, 1, 11),
        },
        .children = children[0..],
    };
    var roots = [_]*OutlineElement{&root};
    const model = OutlineModel{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .roots = roots[0..],
    };
    defer model.arena.deinit();

    const entries = try collect(std.testing.allocator, &model);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 0), entries[0].depth);
    try std.testing.expectEqual(@as(usize, 1), entries[1].depth);

    const root_label = try label(std.testing.allocator, entries[0]);
    defer std.testing.allocator.free(root_label);
    try std.testing.expectEqualStrings("ƒ root", root_label);
    const child_label = try label(std.testing.allocator, entries[1]);
    defer std.testing.allocator.free(child_label);
    try std.testing.expectEqualStrings("  · child", child_label);
    try std.testing.expectEqualStrings("function", kindLabel(12));

    try std.testing.expectEqual(@as(?usize, 1), activeIndex(entries, Position.init(2, 3)));
    try std.testing.expectEqual(@as(?usize, 0), activeIndex(entries, Position.init(1, 2)));
    try std.testing.expectEqual(@as(?usize, null), activeIndex(entries, Position.init(4, 1)));
}
