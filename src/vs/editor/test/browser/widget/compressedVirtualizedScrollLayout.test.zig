// Port of the layout cases in
// `src/vs/editor/test/browser/widget/compressedVirtualizedScrollLayout.test.ts`.
// View-level anchor and event cases are exercised by the scroll-view port.
const std = @import("std");
const layout_mod = @import("../../../browser/widget/multiDiffEditor/compressedVirtualizedScrollLayout.zig");
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const testing = std.testing;

test "CompressedVirtualizedScrollLayout: describes mixed-height content in complete and rendered coordinates" {
    var layout = try layout_mod.computeCompressedVirtualizedScrollLayout(testing.allocator, .{ .scrollTop = 500, .viewportHeight = 400, .itemGap = 10, .itemHeights = &.{ 200, 900, 300 } });
    defer layout.deinit();
    try testing.expectEqual(@as(usize, 500), layout.scrollTop);
    try testing.expectEqual(@as(usize, 1420), layout.scrollHeight);
    try testing.expectEqual(@as(usize, 920), layout.renderedHeight);
    try testing.expectEqual(@as(usize, 210), layout.renderedViewport.start);
    try testing.expectEqual(@as(usize, 290), layout.hiddenContentHeightAboveViewport);
    const expected = [_]layout_mod.ICompressedVirtualizedItemLayout{
        .{ .contentRange = .init(0, 200), .renderedRange = .init(0, 200), .maxScrollOffset = 0, .scrollOffset = 0, .visibility = .before },
        .{ .contentRange = .init(210, 1110), .renderedRange = .init(210, 610), .maxScrollOffset = 500, .scrollOffset = 290, .visibility = .visible },
        .{ .contentRange = .init(1120, 1420), .renderedRange = .init(620, 920), .maxScrollOffset = 0, .scrollOffset = 0, .visibility = .after },
    };
    try testing.expectEqualSlices(layout_mod.ICompressedVirtualizedItemLayout, &expected, layout.items);
}

test "CompressedVirtualizedScrollLayout: conserves vertical displacement" {
    var prng = std.Random.DefaultPrng.init(873245);
    const random = prng.random();
    for (0..2000) |_| {
        const viewport = random.intRangeLessThan(usize, 1, 1000);
        const gap = random.intRangeLessThan(usize, 0, 41);
        var heights_buffer: [30]usize = undefined;
        const heights = heights_buffer[0..random.intRangeLessThan(usize, 0, 31)];
        for (heights) |*height| height.* = random.intRangeLessThan(usize, 0, 2501);
        var initial = try layout_mod.computeCompressedVirtualizedScrollLayout(testing.allocator, .{ .scrollTop = random.intRangeLessThan(isize, 0, 50001), .viewportHeight = viewport, .itemGap = gap, .itemHeights = heights });
        defer initial.deinit();
        var next = try layout_mod.computeCompressedVirtualizedScrollLayout(testing.allocator, .{ .scrollTop = @as(isize, @intCast(initial.scrollTop)) + random.intRangeLessThan(isize, -2000, 2001), .viewportHeight = viewport, .itemGap = gap, .itemHeights = heights });
        defer next.deinit();
        const scroll_delta = @as(isize, @intCast(next.scrollTop)) - @as(isize, @intCast(initial.scrollTop));
        const rendered_delta = @as(isize, @intCast(next.renderedViewport.start)) - @as(isize, @intCast(initial.renderedViewport.start));
        const hidden_delta = @as(isize, @intCast(next.hiddenContentHeightAboveViewport)) - @as(isize, @intCast(initial.hiddenContentHeightAboveViewport));
        try testing.expectEqual(scroll_delta, rendered_delta + hidden_delta);
        for (next.items) |item| {
            try testing.expect(item.scrollOffset <= item.maxScrollOffset);
            try testing.expectEqual(item.contentRange.length() - item.renderedRange.length(), item.maxScrollOffset);
        }
    }
}

test "CompressedVirtualizedScrollLayout: keeps transient scroll slack outside logical item ranges" {
    var layout = try layout_mod.computeCompressedVirtualizedScrollLayout(testing.allocator, .{ .revision = layout_mod.asLayoutRevision(7), .scrollTop = 0, .viewportHeight = 400, .itemGap = 10, .itemHeights = &.{ 200, 300 }, .leadingScrollSlack = 100, .trailingScrollSlack = 150 });
    defer layout.deinit();
    try testing.expectEqual(@as(u64, 7), layout.revision);
    try testing.expectEqual(@as(usize, 510), layout.logicalScrollHeight);
    try testing.expectEqual(@as(usize, 760), layout.scrollHeight);
    try testing.expectEqual(@as(usize, 760), layout.renderedHeight);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = -100, .endExclusive = 300 }, layout.contentViewport);
    try testing.expectEqual(OffsetRange.init(0, 200), layout.items[0].contentRange);
    try testing.expectEqual(OffsetRange.init(210, 510), layout.items[1].contentRange);
    try testing.expectEqual(OffsetRange.init(100, 300), layout.items[0].renderedRange);
    try testing.expectEqual(OffsetRange.init(310, 610), layout.items[1].renderedRange);
}

test "CompressedVirtualizedScrollLayout: maps a revisioned viewport anchor through simultaneous size edits" {
    var edit = try layout_mod.createAnchoredSizeEditBatch(testing.allocator, layout_mod.asLayoutRevision(3), layout_mod.asLayoutRevision(4), &.{ 200, 900, 300 }, &.{ 300, 40, 500 }, 10, 10, 750);
    defer edit.deinit();
    const expected = [_]layout_mod.ISizeEdit{
        .{ .oldRange = .init(0, 200), .newRange = .init(0, 300) },
        .{ .oldRange = .init(210, 1110), .newRange = .init(310, 350) },
        .{ .oldRange = .init(1120, 1420), .newRange = .init(360, 860) },
    };
    try testing.expectEqualSlices(layout_mod.ISizeEdit, &expected, edit.edits);
    try testing.expectEqual(layout_mod.ILogicalPosition{ .revision = 3, .offset = 750 }, edit.anchor);
    try testing.expectEqual(layout_mod.ILogicalPosition{ .revision = 4, .offset = 310 }, try layout_mod.mapLogicalPosition(edit.anchor, edit, .itemStart));
    try testing.expectEqual(layout_mod.ILogicalPosition{ .revision = 4, .offset = 350 }, try layout_mod.mapLogicalPosition(edit.anchor, edit, .itemEnd));
    try testing.expectEqual(layout_mod.ILogicalPosition{ .revision = 4, .offset = 860 }, try layout_mod.mapLogicalPosition(.{ .revision = 3, .offset = 1420 }, edit, .itemStart));
    try testing.expectError(error.LayoutRevisionMismatch, layout_mod.mapLogicalPosition(.{ .revision = 2, .offset = 750 }, edit, .itemStart));
}
