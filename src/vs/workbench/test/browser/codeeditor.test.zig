// Port of the `RangeHighlightDecorations` cases in
// `src/vs/workbench/test/browser/codeeditor.test.ts`, adapted to the terminal
// host callback instead of a browser editor service.

const std = @import("std");
const codeeditor = @import("../../browser/codeeditor.zig");
const Range = @import("../../../editor/common/core/range.zig").Range;

const State = struct {
    active: []const u8 = "/active.zig",
    range: ?Range = null,
    removals: usize = 0,

    fn activeResource(context: *anyopaque) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.active;
    }

    fn setRange(context: *anyopaque, range: ?Range) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.range = range;
    }

    fn removed(_: void, context: *@This()) !void {
        context.removals += 1;
    }
};

test "rangeHighlight: inactive resource does not clear a previous highlight" {
    var state = State{};
    var highlights = codeeditor.RangeHighlightDecorations.init(std.testing.allocator, .{
        .context = &state,
        .active_resource = State.activeResource,
        .set_range_highlight = State.setRange,
    });
    defer highlights.deinit();
    _ = try highlights.on_highlight_removed.listen(&state, State.removed);

    const range = Range.init(1, 1, 1, 4);
    highlights.highlightRange("/active.zig", range);
    try std.testing.expect(Range.equalsRange(state.range.?, range));

    highlights.highlightRange("/other.zig", Range.init(2, 1, 2, 2));
    try std.testing.expect(Range.equalsRange(state.range.?, range));
    try std.testing.expectEqual(@as(usize, 0), state.removals);

    state.active = "/other.zig";
    highlights.onActiveEditorChanged();
    try std.testing.expect(state.range == null);
    try std.testing.expectEqual(@as(usize, 1), state.removals);
}
