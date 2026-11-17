// Port of the decoration-rendering helpers of
// `src/vs/editor/browser/viewParts/glyphMargin/glyphMargin.ts`
// (`DecorationToRender`, `LineDecorationToRender`,
// `VisibleLineDecorationsToRender`, `DedupOverlay._render`).
//
// Terminal adaptation: the glyph margin widget host itself (DOM widgets) is not
// ported; the `linesDecorations`/`marginDecorations` overlays share the dedup
// algorithm and receive the per-line decoration lists as data.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A decoration that should be shown along a range of lines.
pub const DecorationToRender = struct {
    start_line_number: usize,
    end_line_number: usize,
    class_name: []const u8,
    tooltip: ?[]const u8,
    z_index: i32 = 0,
};

/// A decoration that should be shown along a visible line.
pub const LineDecorationToRender = struct {
    class_name: []const u8,
    z_index: i32,
    tooltip: ?[]const u8,
};

/// Decorations to render on a visible line.
pub const VisibleLineDecorationsToRender = struct {
    decorations: std.array_list.Managed(LineDecorationToRender),

    pub fn init(allocator: Allocator) VisibleLineDecorationsToRender {
        return .{ .decorations = std.array_list.Managed(LineDecorationToRender).init(allocator) };
    }

    pub fn deinit(self: *VisibleLineDecorationsToRender) void {
        self.decorations.deinit();
    }

    pub fn add(self: *VisibleLineDecorationsToRender, decoration: LineDecorationToRender) !void {
        try self.decorations.append(decoration);
    }

    pub fn getDecorations(self: *const VisibleLineDecorationsToRender) []const LineDecorationToRender {
        return self.decorations.items;
    }
};

fn lessThan(_: void, a: DecorationToRender, b: DecorationToRender) bool {
    if (std.mem.eql(u8, a.class_name, b.class_name)) {
        if (a.start_line_number == b.start_line_number) return a.end_line_number < b.end_line_number;
        return a.start_line_number < b.start_line_number;
    }
    return std.mem.order(u8, a.class_name, b.class_name) == .lt;
}

/// Port of `DedupOverlay._render`.
///
/// Returns an element for each visible line. The caller owns the result and
/// frees it with `freeVisibleLineDecorations`. The input slice is sorted in
/// place (upstream sorts its local array).
pub fn renderVisibleLineDecorations(
    allocator: Allocator,
    visible_start_line_number: usize,
    visible_end_line_number: usize,
    decorations: []DecorationToRender,
) ![]VisibleLineDecorationsToRender {
    if (visible_end_line_number < visible_start_line_number) return allocator.alloc(VisibleLineDecorationsToRender, 0);

    const line_count = visible_end_line_number - visible_start_line_number + 1;
    const output = try allocator.alloc(VisibleLineDecorationsToRender, line_count);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |*line| line.deinit();
        allocator.free(output);
    }
    for (output) |*line| {
        line.* = VisibleLineDecorationsToRender.init(allocator);
        initialized += 1;
    }

    if (decorations.len == 0) return output;

    // Sort decorations by class name, then by start line and then by end line.
    std.mem.sort(DecorationToRender, decorations, {}, lessThan);

    var previous_class_name: ?[]const u8 = null;
    var previous_end_line_index: isize = 0;
    const start_line: isize = @intCast(visible_start_line_number);
    const end_line: isize = @intCast(visible_end_line_number);
    for (decorations) |decoration| {
        var start_line_index = @max(@as(isize, @intCast(decoration.start_line_number)), start_line) - start_line;
        const end_line_index = @min(@as(isize, @intCast(decoration.end_line_number)), end_line) - start_line;

        if (previous_class_name != null and std.mem.eql(u8, previous_class_name.?, decoration.class_name)) {
            // Avoid rendering the same class name multiple times on the same line.
            start_line_index = @max(previous_end_line_index + 1, start_line_index);
            previous_end_line_index = @max(previous_end_line_index, end_line_index);
        } else {
            previous_class_name = decoration.class_name;
            previous_end_line_index = end_line_index;
        }

        var line_index = start_line_index;
        while (line_index <= previous_end_line_index) : (line_index += 1) {
            if (line_index < 0 or line_index >= @as(isize, @intCast(line_count))) continue;
            try output[@intCast(line_index)].add(.{
                .class_name = decoration.class_name,
                .z_index = decoration.z_index,
                .tooltip = decoration.tooltip,
            });
        }
    }

    return output;
}

/// Frees a result returned by `renderVisibleLineDecorations`.
pub fn freeVisibleLineDecorations(allocator: Allocator, lines: []VisibleLineDecorationsToRender) void {
    for (lines) |*line| line.deinit();
    allocator.free(lines);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "visible line decorations sort by class, start line and end line" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 2, .end_line_number = 2, .class_name = "b", .tooltip = null },
        .{ .start_line_number = 1, .end_line_number = 3, .class_name = "a", .tooltip = "tip" },
        .{ .start_line_number = 1, .end_line_number = 1, .class_name = "a", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 3, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    // The same class is deduplicated per line: line 1 only gets the (1,1)
    // range, while lines 2 and 3 get the (1,3) range.
    try testing.expectEqual(@as(usize, 1), lines[0].getDecorations().len);
    try testing.expectEqualStrings("a", lines[0].getDecorations()[0].class_name);
    try testing.expect(lines[0].getDecorations()[0].tooltip == null);
    // Line 2 has both "a" and "b".
    try testing.expectEqual(@as(usize, 2), lines[1].getDecorations().len);
    try testing.expectEqualStrings("a", lines[1].getDecorations()[0].class_name);
    try testing.expectEqualStrings("tip", lines[1].getDecorations()[0].tooltip.?);
    try testing.expectEqualStrings("b", lines[1].getDecorations()[1].class_name);
    try testing.expectEqual(@as(usize, 1), lines[2].getDecorations().len);
    try testing.expectEqualStrings("a", lines[2].getDecorations()[0].class_name);
}

test "visible line decorations deduplicate overlapping ranges of one class" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 3, .class_name = "same", .tooltip = null },
        .{ .start_line_number = 2, .end_line_number = 5, .class_name = "same", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 5, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    for (lines) |line| {
        try testing.expectEqual(@as(usize, 1), line.getDecorations().len);
        try testing.expectEqualStrings("same", line.getDecorations()[0].class_name);
    }
}

test "visible line decorations clip to the visible range" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 10, .class_name = "wide", .tooltip = null },
        .{ .start_line_number = 3, .end_line_number = 4, .class_name = "small", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 3, 5, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 3), lines.len);
    // Both classes are visible on lines 3 and 4.
    try testing.expectEqual(@as(usize, 2), lines[0].getDecorations().len);
    try testing.expectEqual(@as(usize, 2), lines[1].getDecorations().len);
    // Only "wide" reaches line 5.
    try testing.expectEqual(@as(usize, 1), lines[2].getDecorations().len);
    try testing.expectEqualStrings("wide", lines[2].getDecorations()[0].class_name);
}

test "visible line decorations preserve zIndex" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 1, .class_name = "high", .tooltip = null, .z_index = 7 },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 1, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    try testing.expectEqual(@as(i32, 7), lines[0].getDecorations()[0].z_index);
}
