// Regression coverage for the upstream glyphHoverComputer.ts behavior:
// model decorations, compacted lanes and independent line-number messages.
const std = @import("std");
const model_mod = @import("../../../../common/model.zig");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const Range = @import("../../../../common/core/range.zig").Range;
const computer = @import("../../browser/glyphHoverComputer.zig");

test "GlyphHoverComputer: collects all matching model decoration messages in lane order, independent of line numbers" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "one\ntwo\nthree", "plaintext");
    defer text.deinit();
    var center = model_mod.ModelDecorationOptions.init("center", .AlwaysGrowsWhenTypingAtEdges);
    center.glyphMarginHoverMessage = &.{ "center message", "second center message" };
    center.lineNumberHoverMessage = &.{"line number message"};
    var right = model_mod.ModelDecorationOptions.init("right", .AlwaysGrowsWhenTypingAtEdges);
    right.glyphMargin = .{ .position = .Right, .persistLane = null };
    right.glyphMarginHoverMessage = &.{"right message"};
    var empty = model_mod.ModelDecorationOptions.init("empty", .AlwaysGrowsWhenTypingAtEdges);
    empty.glyphMarginHoverMessage = &.{""};
    const ids = try text.model.deltaDecorations(&.{}, &.{
        .{ .range = Range.init(1, 1, 2, 2), .options = &center },
        .{ .range = Range.init(2, 1, 2, 1), .options = &right },
        .{ .range = Range.init(2, 1, 2, 1), .options = &empty },
    }, 0);
    defer a.free(ids);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const center_messages = try computer.GlyphHoverComputer.computeSync(arena, text.model, .{ .lineNumber = 2, .laneOrLine = .{ .lane = .Center } });
    try std.testing.expectEqual(2, center_messages.len);
    try std.testing.expectEqualStrings("center message", center_messages[0].value);
    try std.testing.expectEqualStrings("second center message", center_messages[1].value);
    const right_messages = try computer.GlyphHoverComputer.computeSync(arena, text.model, .{ .lineNumber = 2, .laneOrLine = .{ .lane = .Right } });
    try std.testing.expectEqual(1, right_messages.len);
    try std.testing.expectEqualStrings("right message", right_messages[0].value);
    const line_messages = try computer.GlyphHoverComputer.computeSync(arena, text.model, .{ .lineNumber = 2, .laneOrLine = .line_no });
    try std.testing.expectEqual(1, line_messages.len);
    try std.testing.expectEqualStrings("line number message", line_messages[0].value);
    const unrelated = try computer.GlyphHoverComputer.computeSync(arena, text.model, .{ .lineNumber = 3, .laneOrLine = .line_no });
    try std.testing.expectEqual(0, unrelated.len);
}
