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

const view_mod = @import("../../../browser/widget/multiDiffEditor/compressedVirtualizedScrollView.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

const TestItem = struct {
    height: usize,
    change: Emitter(void) = .init(testing.allocator),
    render_context: ?view_mod.ICompressedVirtualizedScrollItemContext = null,
    next_render_height: ?usize = null,

    fn interface(self: *TestItem) view_mod.ICompressedVirtualizedScrollItem {
        return .{ .context = self, .size = size, .max_scroll = maxScroll, .on_did_change = &self.change, .render = render, .hide = hide };
    }
    fn size(ctx: *anyopaque) usize {
        const self: *TestItem = @ptrCast(@alignCast(ctx));
        return self.height;
    }
    fn maxScroll(_: *anyopaque) usize {
        return 0;
    }
    fn render(ctx: *anyopaque, _: OffsetRange, _: usize, _: usize, _: OffsetRange, context: view_mod.ICompressedVirtualizedScrollItemContext) !void {
        const self: *TestItem = @ptrCast(@alignCast(ctx));
        self.render_context = context;
        if (self.next_render_height) |height| {
            self.next_render_height = null;
            try self.setSize(height);
        }
    }
    fn hide(_: *anyopaque) void {}
    fn setSize(self: *TestItem, height: usize) !void {
        if (self.height == height) return;
        self.height = height;
        try self.change.fire({});
    }
    fn deinit(self: *TestItem) void {
        self.change.deinit();
    }
};
const Fixture = struct {
    queue: dispatch.Queue = .{ .io = testing.io },
    now: i64 = 0,
    view: *view_mod.CompressedVirtualizedScrollView = undefined,
    items: []TestItem = &.{},

    fn clock(ctx: *anyopaque) i64 {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn init(self: *Fixture, heights: []const usize, viewport: usize, gap: usize) !void {
        self.items = try testing.allocator.alloc(TestItem, heights.len);
        errdefer testing.allocator.free(self.items);
        for (self.items, heights) |*item, height| item.* = .{ .height = height };
        errdefer for (self.items) |*item| item.deinit();
        self.view = try .create(testing.allocator, &self.queue, .{ .context = self, .now = clock });
        errdefer self.view.destroy();
        self.view.beginUpdate();
        try self.view.setDimensions(800, viewport, gap);
        try self.replaceItems(self.items);
        try self.view.endUpdate();
    }
    fn replaceItems(self: *Fixture, items: []TestItem) !void {
        const interfaces = try testing.allocator.alloc(view_mod.ICompressedVirtualizedScrollItem, items.len);
        defer testing.allocator.free(interfaces);
        for (interfaces, items) |*i, *item| i.* = item.interface();
        try self.view.setItems(interfaces);
    }
    fn deinit(self: *Fixture) void {
        self.view.destroy();
        for (self.items) |*item| item.deinit();
        testing.allocator.free(self.items);
    }
    fn scroll(self: *Fixture, top: isize) !void {
        try self.view.setScrollPosition(top, null);
    }
    fn advance(self: *Fixture, elapsed: i64) void {
        self.now += elapsed;
        _ = self.queue.dispatch(self.now);
    }
};

fn assertAnchor(view: *view_mod.CompressedVirtualizedScrollView, top: usize, offset: usize, rendered_top: isize) !void {
    try testing.expectEqual(top, view.getScrollPosition().scrollTop);
    try testing.expectEqual(offset, view.layout.items[1].scrollOffset);
    try testing.expectEqual(rendered_top, @as(isize, @intCast(view.layout.items[1].renderedRange.start)) - @as(isize, @intCast(view.layout.renderedViewport.start)));
}

test "CompressedVirtualizedScrollView: keeps the rendered anchor stable when content grows above it" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 260, 1100 }, 480, 12);
    defer fixture.deinit();
    try fixture.scroll(800);
    try assertAnchor(fixture.view, 800, 528, 0);
    try fixture.items[0].setSize(360);
    try assertAnchor(fixture.view, 900, 528, 0);
    try fixture.items[1].setSize(1200);
    try assertAnchor(fixture.view, 900, 528, 0);
}

test "CompressedVirtualizedScrollView: does not treat item-local scrolling as anchor movement" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 260, 1100 }, 480, 12);
    defer fixture.deinit();
    for ([_]isize{ 400, 800, 700, 200, 850 }) |top| {
        try fixture.scroll(top);
        try testing.expectEqual(@as(usize, @intCast(top)), fixture.view.getScrollPosition().scrollTop);
    }
}

test "CompressedVirtualizedScrollView: moves native scrolling of the content into the virtual scroll position" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 260, 1100 }, 480, 12);
    defer fixture.deinit();
    try fixture.scroll(200);
    // Native DOM scrollTop is replaced by the host's reveal displacement.
    try fixture.view.applyNativeScroll(100, 0);
    try testing.expectEqual(@as(usize, 300), fixture.view.getScrollPosition().scrollTop);
}

test "CompressedVirtualizedScrollView: preserves geometry compensation during outer scrolling" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 260, 1100 }, 480, 12);
    defer fixture.deinit();
    try fixture.scroll(800);
    fixture.view.beginUpdate();
    try fixture.items[0].setSize(360);
    try fixture.scroll(700);
    try fixture.view.endUpdate();
    try assertAnchor(fixture.view, 800, 428, 0);
}

test "CompressedVirtualizedScrollView: uses trailing slack to preserve a near-bottom anchor and consumes it when scrolling up" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 500, 500 }, 400, 12);
    defer fixture.deinit();
    try fixture.scroll(600);
    try fixture.items[1].setSize(100);
    const layout = &fixture.view.layout;
    try testing.expectEqual(@as(usize, 600), layout.scrollTop);
    try testing.expectEqual(@as(usize, 612), layout.logicalScrollHeight);
    try testing.expectEqual(@as(usize, 1000), layout.scrollHeight);
    try testing.expectEqual(@as(usize, 388), layout.trailingScrollSlack);
    try fixture.scroll(500);
    try testing.expectEqual(@as(usize, 500), layout.scrollTop);
    try testing.expectEqual(@as(usize, 900), layout.scrollHeight);
    try testing.expectEqual(@as(usize, 288), layout.trailingScrollSlack);
}

fn shrinkFirst(fixture: *Fixture) !void {
    const Action = struct {
        fn run(context: *anyopaque) !void {
            const item: *TestItem = @ptrCast(@alignCast(context));
            try item.setSize(50);
        }
    };
    try fixture.view.runWithScrollAnchor(.{ .revision = fixture.view.layout.revision, .offset = 100 }, .{ .context = &fixture.items[0], .run = Action.run });
}

test "CompressedVirtualizedScrollView: uses leading slack for an operation anchor and consumes it when scrolling down" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 100, 500 }, 400, 12);
    defer fixture.deinit();
    try shrinkFirst(&fixture);
    const layout = &fixture.view.layout;
    try testing.expectEqual(@as(usize, 0), layout.scrollTop);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = -50, .endExclusive = 350 }, layout.contentViewport);
    try testing.expectEqual(@as(usize, 50), layout.leadingScrollSlack);
    try fixture.scroll(100);
    try testing.expectEqual(@as(usize, 50), layout.scrollTop);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = 50, .endExclusive = 450 }, layout.contentViewport);
    try testing.expectEqual(@as(usize, 0), layout.leadingScrollSlack);
}

test "CompressedVirtualizedScrollView: resets transient scroll state when equal-height items are replaced" {
    var replacement = [_]TestItem{ .{ .height = 50 }, .{ .height = 500 } };
    defer for (&replacement) |*item| item.deinit();
    var fixture: Fixture = .{};
    try fixture.init(&.{ 100, 500 }, 400, 12);
    defer fixture.deinit();
    try shrinkFirst(&fixture);
    const layout = &fixture.view.layout;
    try testing.expectEqual(@as(u64, 1), layout.revision);
    try testing.expectEqual(@as(usize, 50), layout.leadingScrollSlack);
    try testing.expectEqual(.logical, fixture.view.last_geometry_edit.?.anchorKind);
    try fixture.replaceItems(&replacement);
    try testing.expectEqual(@as(u64, 1), layout.revision);
    try testing.expectEqual(@as(usize, 0), layout.leadingScrollSlack);
    try testing.expectEqual(@as(usize, 0), layout.trailingScrollSlack);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = 0, .endExclusive = 400 }, layout.contentViewport);
    try testing.expect(fixture.view.last_geometry_edit == null);
}

test "CompressedVirtualizedScrollView: converts logical reveal positions after leading slack" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 100, 500 }, 400, 12);
    defer fixture.deinit();
    try shrinkFirst(&fixture);
    try fixture.view.setLogicalScrollPosition(112);
    const layout = &fixture.view.layout;
    try testing.expectEqual(@as(usize, 112), layout.scrollTop);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = 112, .endExclusive = 512 }, layout.contentViewport);
    try testing.expectEqual(@as(usize, 0), layout.leadingScrollSlack);
}

test "CompressedVirtualizedScrollView: keeps an item-local semantic anchor stable when its offset and item size change" {
    var fixture: Fixture = .{};
    try fixture.init(&.{1000}, 400, 0);
    defer fixture.deinit();
    try fixture.scroll(250);
    const Anchor = struct {
        item: *TestItem,
        offset: usize = 300,
        next: usize = 500,
        fn get(ctx: *anyopaque) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.offset;
        }
        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.offset = self.next;
            try self.item.setSize(1200);
        }
        fn apply(self: *@This()) !void {
            try self.item.render_context.?.runWithScrollAnchor(.{ .context = self, .get = get }, .{ .context = self, .run = run });
        }
    };
    var anchor: Anchor = .{ .item = &fixture.items[0] };
    const layout = &fixture.view.layout;
    try testing.expectEqual(@as(isize, 50), @as(isize, @intCast(anchor.offset)) - layout.contentViewport.start);
    try anchor.apply();
    try testing.expectEqual(@as(u64, 1), layout.revision);
    try testing.expectEqual(@as(usize, 450), layout.scrollTop);
    try testing.expectEqual(@as(isize, 50), @as(isize, @intCast(anchor.offset)) - layout.contentViewport.start);
    anchor.next = 550;
    try anchor.apply();
    try testing.expectEqual(.item, fixture.view.last_geometry_edit.?.anchorKind);
    try testing.expectEqual(@as(u64, 1), layout.revision);
    try testing.expectEqual(@as(usize, 500), layout.scrollTop);
    try testing.expectEqual(@as(isize, 50), @as(isize, @intCast(anchor.offset)) - layout.contentViewport.start);
    const edit = fixture.view.last_geometry_edit.?;
    try testing.expectEqual(@as(u64, 1), edit.fromRevision);
    try testing.expectEqual(@as(u64, 1), edit.toRevision);
    try testing.expectEqual(@as(usize, 0), edit.edits.len);
    const items_ptr = layout.items.ptr;
    try anchor.apply();
    try testing.expectEqual(items_ptr, layout.items.ptr);
    try testing.expectEqualDeep(edit, fixture.view.last_geometry_edit.?);
}

fn assertDirection(view: *view_mod.CompressedVirtualizedScrollView, top: usize, offset: isize, bottom: bool) !void {
    try testing.expectEqual(top, view.layout.scrollTop);
    const reference = if (bottom) view.layout.contentViewport.endExclusive else view.layout.contentViewport.start;
    try testing.expectEqual(offset, reference - @as(isize, @intCast(view.layout.items[1].contentRange.start)));
    try testing.expectEqual(@as(@TypeOf(view.last_geometry_edit.?.anchorKind), if (bottom) .viewportBottom else .viewportTop), view.last_geometry_edit.?.anchorKind);
}

test "CompressedVirtualizedScrollView: anchors geometry edits based on recent scroll direction" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 500, 1000 }, 400, 0);
    defer fixture.deinit();
    try fixture.scroll(600);
    fixture.items[0].next_render_height = 40;
    try fixture.scroll(499);
    try assertDirection(fixture.view, 39, 399, true);
    try fixture.items[0].setSize(500);
    try assertDirection(fixture.view, 499, 399, true);
    fixture.advance(60);
    try fixture.scroll(498);
    fixture.advance(60);
    try fixture.items[0].setSize(600);
    try assertDirection(fixture.view, 598, 398, true);
    fixture.advance(50);
    try fixture.items[1].setSize(900);
    try assertDirection(fixture.view, 598, -2, false);
}

test "CompressedVirtualizedScrollView: keeps a shrunk item in view when it removes the content at a viewport-bottom anchor" {
    var fixture: Fixture = .{};
    try fixture.init(&.{ 535450, 103396, 500, 24 }, 792, 0);
    defer fixture.deinit();
    try fixture.scroll(2400);
    try fixture.scroll(2310);
    fixture.view.beginUpdate();
    for (fixture.items, [_]usize{ 1074, 2838, 500, 24 }) |*item, height| try item.setSize(height);
    try fixture.view.endUpdate();
    const layout = &fixture.view.layout;
    try testing.expectEqual(.viewportBottom, fixture.view.last_geometry_edit.?.anchorKind);
    try testing.expectEqual(@as(usize, 282), layout.scrollTop);
    try testing.expectEqual(@as(usize, 0), layout.leadingScrollSlack);
    try testing.expectEqual(layout_mod.LogicalRange{ .start = 282, .endExclusive = 1074 }, layout.contentViewport);
    for (layout.items, [_]layout_mod.CompressedVirtualizedItemVisibility{ .visible, .after, .after, .after }) |item, visibility| try testing.expectEqual(visibility, item.visibility);
}
