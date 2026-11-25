const std = @import("std");
const ui = @import("ui");
const dom = ui.dom;
const Document = dom.Document;
const ScrollView = ui.scroll_view.ScrollView;

test "scroll view clamps, translates and tracks a thumb" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .left = 1,
        .top = 1,
        .width = 20,
        .height = 8,
        .content_height = 30,
    });

    try testing.expect(view.has_scrollbar);
    try testing.expectEqual(@as(usize, 19), view.contentWidth());
    try testing.expectEqual(@as(usize, 22), view.maxScroll());
    try testing.expect(view.thumb != null);
    try testing.expectEqual(@as(f64, 0), view.content.style().translate_y);

    var wheel = dom.MouseEvent{ .kind = .wheel, .x = 2, .y = 2, .delta_y = 3 };
    doc.dispatchMouse(view.rootNode(), &wheel);
    try testing.expect(wheel.default_prevented);
    try testing.expectEqual(@as(usize, 3), view.scrollTop());
    try testing.expectEqual(@as(f64, -3), view.content.style().translate_y);

    _ = view.scrollBy(-100);
    try testing.expectEqual(@as(usize, 0), view.scrollTop());
    _ = view.scrollBy(1000);
    try testing.expectEqual(@as(usize, 22), view.scrollTop());
    try testing.expectEqual(@as(f64, -22), view.content.style().translate_y);

    const thumb_top = switch (view.thumb.?.style().top.?) {
        .cells => |value| value,
        else => -1,
    };
    try testing.expectEqual(@as(f64, 6), thumb_top);
}

test "scroll view without overflow has no scrollbar" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 10,
        .content_height = 4,
    });

    try testing.expect(!view.has_scrollbar);
    try testing.expectEqual(@as(usize, 20), view.contentWidth());
    try testing.expect(view.thumb == null);
    try testing.expect(!view.scrollBy(5));
    try testing.expectEqual(@as(usize, 0), view.scrollTop());
}

test "scroll view honours wide scrollbars and initial scroll" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 8,
        .content_height = 30,
        .initial_scroll = 100,
        .scrollbar_width = 2,
    });

    try testing.expectEqual(@as(usize, 18), view.contentWidth());
    try testing.expectEqual(@as(usize, 22), view.scrollTop());
    const thumb_width = switch (view.thumb.?.style().width.?) {
        .cells => |value| value,
        else => -1,
    };
    try testing.expectEqual(@as(f64, 2), thumb_width);
}

test "scroll view scrolls horizontally with wheel and bar" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 8,
        .content_width = 50,
        .content_height = 7,
        .horizontal_scrollbar = true,
    });

    try testing.expect(view.has_horizontal_scrollbar);
    try testing.expectEqual(@as(usize, 7), view.viewport_height);
    try testing.expectEqual(@as(usize, 30), view.maxScrollX());
    try testing.expectEqual(@as(usize, 0), view.scrollLeft());
    try testing.expectEqual(@as(f64, 0), view.content.style().translate_x);
    try testing.expect(view.horizontal_thumb != null);

    var wheel = dom.MouseEvent{ .kind = .wheel, .x = 2, .y = 2, .delta_x = 4 };
    doc.dispatchMouse(view.rootNode(), &wheel);
    try testing.expect(wheel.default_prevented);
    try testing.expectEqual(@as(usize, 4), view.scrollLeft());
    try testing.expectEqual(@as(f64, -4), view.content.style().translate_x);

    _ = view.scrollToX(1000);
    try testing.expectEqual(@as(usize, 30), view.scrollLeft());
    _ = view.scrollToX(0);
    try testing.expectEqual(@as(usize, 0), view.scrollLeft());
}

test "scroll view splits wheel axes and honors external callbacks" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const State = struct {
        scroll_left: usize = 0,
        scroll_top: usize = 0,
        calls: usize = 0,
        fn onScroll(context: ?*anyopaque, left: usize, top: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.calls += 1;
            self.scroll_left = left;
            self.scroll_top = top;
        }
    };
    var state = State{};

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 8,
        .content_width = 50,
        .content_height = 30,
        .horizontal_scrollbar = true,
        .on_scroll = .{ .context = &state, .callback = State.onScroll },
    });

    var wheel = dom.MouseEvent{ .kind = .wheel, .x = 2, .y = 2, .delta_x = 2, .delta_y = 1 };
    doc.dispatchMouse(view.rootNode(), &wheel);
    try testing.expectEqual(@as(usize, 2), state.scroll_left);
    try testing.expectEqual(@as(usize, 1), state.scroll_top);
    try testing.expectEqual(@as(usize, 1), state.calls);

    // Programmatic scrolling does not notify; hosts sync their own authority.
    _ = view.scrollToX(5);
    _ = view.scrollBy(2);
    try testing.expectEqual(@as(usize, 1), state.calls);

    // A wheel that cannot move either axis is left for the host.
    _ = view.scrollToX(0);
    _ = view.scrollTo(0);
    var blocked = dom.MouseEvent{ .kind = .wheel, .x = 2, .y = 2, .delta_x = -1, .delta_y = -1 };
    doc.dispatchMouse(view.rootNode(), &blocked);
    try testing.expect(!blocked.default_prevented);
    try testing.expectEqual(@as(usize, 1), state.calls);
}
