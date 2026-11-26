// Port of `src/vs/editor/browser/viewParts/overlayWidgets/overlayWidgets.ts`.
//
// Terminal adaptation: upstream positions widget DOM nodes from the layout
// info and page geometry; the terminal maps the same corner preferences to
// cells and builds each widget through the `ui` document. The widget list,
// add/remove/layout lifecycle and focus restoration stay view-part behavior.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const editorBrowser = @import("../../editorBrowser.zig");
const IOverlayWidget = editorBrowser.IOverlayWidget;

/// A placed widget rectangle, used by the host for hit testing.
pub const WidgetRect = struct {
    node: *ui.Node,
    left: usize,
    top: usize,
    width: usize,
    height: usize,

    pub fn contains(self: WidgetRect, x: usize, y: usize) bool {
        return x >= self.left and x < self.left + self.width and
            y >= self.top and y < self.top + self.height;
    }
};

/// Port of `ViewOverlayWidgets` (terminal paint boundary).
pub const ViewOverlayWidgets = struct {
    allocator: Allocator,
    widgets: std.array_list.Managed(IOverlayWidget),
    entries: std.array_list.Managed(WidgetRect),

    pub fn init(allocator: Allocator) ViewOverlayWidgets {
        return .{
            .allocator = allocator,
            .widgets = std.array_list.Managed(IOverlayWidget).init(allocator),
            .entries = std.array_list.Managed(WidgetRect).init(allocator),
        };
    }

    pub fn deinit(self: *ViewOverlayWidgets) void {
        self.prepareNodeReset(true);
        self.widgets.deinit();
        self.entries.deinit();
    }

    pub fn add(self: *ViewOverlayWidgets, widget: IOverlayWidget) !void {
        try self.widgets.append(widget);
    }

    pub fn remove(self: *ViewOverlayWidgets, id: []const u8) bool {
        for (self.widgets.items, 0..) |widget, index| {
            if (std.mem.eql(u8, widget.get_id(widget.context), id)) {
                if (widget.on_before_node_removed) |callback| callback(widget.context, true);
                _ = self.widgets.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn prepareNodeReset(self: *ViewOverlayWidgets, leaving_document: bool) void {
        for (self.widgets.items) |widget| {
            if (widget.on_before_node_removed) |callback| callback(widget.context, leaving_document);
        }
    }

    /// Port of `ViewOverlayWidgets.render`. Builds the widget subtree into the
    /// terminal document and records the placed rectangles.
    pub fn render(
        self: *ViewOverlayWidgets,
        doc: *ui.Document,
        root: *ui.Node,
        cols: usize,
        editor_height: usize,
    ) !void {
        self.entries.clearRetainingCapacity();
        for (self.widgets.items) |widget| {
            const width = @min(widget.width(widget.context, cols), cols);
            const height = @min(widget.height(widget.context), editor_height);
            if (width == 0 or height == 0) continue;

            const top: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .top_center, .top_left_corner => 0,
                .bottom_right_corner => editor_height -| height,
            };
            const left: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .bottom_right_corner => cols -| width,
                .top_center => (cols -| width) / 2,
                .top_left_corner => 0,
            };

            const container = try doc.createElement(.div);
            container.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
            });

            const content = try widget.build(widget.context, doc);
            _ = try container.appendChild(content);
            _ = try root.appendChild(container);
            try self.entries.append(.{
                .node = container,
                .left = left,
                .top = top,
                .width = width,
                .height = height,
            });

            if (widget.is_focused(widget.context)) {
                if (widget.focus_node(widget.context)) |node| {
                    _ = doc.focus(node);
                }
            }
        }
    }
};

const testing = std.testing;

const FakeWidget = struct {
    node: ?*ui.Node = null,

    fn id(_: *anyopaque) []const u8 {
        return "fake";
    }
    fn position(_: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        return .top_right_corner;
    }
    fn width(_: *anyopaque, _: usize) usize {
        return 6;
    }
    fn height(_: *anyopaque) usize {
        return 2;
    }
    fn build(context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node {
        const self: *FakeWidget = @ptrCast(@alignCast(context));
        self.node = try doc.createText("widget");
        return self.node.?;
    }
    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *FakeWidget = @ptrCast(@alignCast(context));
        return self.node;
    }
    fn isFocused(_: *anyopaque) bool {
        return false;
    }

    fn interface(self: *FakeWidget) IOverlayWidget {
        return .{
            .context = self,
            .get_id = id,
            .get_position = position,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }
};

test "overlay widgets places a top-left widget at the origin" {
    const allocator = testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 10 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    var widget = TopLeftWidget{};
    var part = ViewOverlayWidgets.init(allocator);
    defer part.deinit();
    try part.add(widget.interface());
    try part.render(&doc, root, 20, 10);

    try testing.expectEqual(@as(usize, 1), part.entries.items.len);
    const rect = part.entries.items[0];
    try testing.expectEqual(@as(usize, 0), rect.left);
    try testing.expectEqual(@as(usize, 0), rect.top);
    try testing.expectEqual(@as(usize, 20), rect.width);
    try testing.expectEqual(@as(usize, 2), rect.height);
    try testing.expect(rect.contains(0, 0));
    try testing.expect(rect.contains(19, 1));
}

const TopLeftWidget = struct {
    node: ?*ui.Node = null,

    fn id(_: *anyopaque) []const u8 {
        return "top-left";
    }
    fn position(_: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        return .top_left_corner;
    }
    fn width(_: *anyopaque, cols: usize) usize {
        return cols;
    }
    fn height(_: *anyopaque) usize {
        return 2;
    }
    fn build(context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node {
        const self: *TopLeftWidget = @ptrCast(@alignCast(context));
        self.node = try doc.createText("top-left");
        return self.node.?;
    }
    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TopLeftWidget = @ptrCast(@alignCast(context));
        return self.node;
    }
    fn isFocused(_: *anyopaque) bool {
        return false;
    }

    fn interface(self: *TopLeftWidget) IOverlayWidget {
        return .{
            .context = self,
            .get_id = id,
            .get_position = position,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }
};

test "overlay widgets places a top-right widget and records its rect" {
    const allocator = testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 10 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    var widget = FakeWidget{};
    var part = ViewOverlayWidgets.init(allocator);
    defer part.deinit();
    try part.add(widget.interface());
    try part.render(&doc, root, 20, 10);

    try testing.expectEqual(@as(usize, 1), part.entries.items.len);
    const rect = part.entries.items[0];
    try testing.expectEqual(@as(usize, 14), rect.left);
    try testing.expectEqual(@as(usize, 0), rect.top);
    try testing.expect(rect.contains(15, 1));
    try testing.expect(!rect.contains(1, 1));
    try testing.expect(part.remove("fake"));
    try testing.expectEqual(@as(usize, 0), part.widgets.items.len);
}

test "overlay widgets place bottom-right/top-center and restore focus" {
    const allocator = testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 10 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    const FlexWidget = struct {
        node: ?*ui.Node = null,
        pref: editorBrowser.OverlayWidgetPositionPreference,
        w: usize,
        h: usize,
        focused: bool,

        fn id(_: *anyopaque) []const u8 {
            return "flex";
        }
        fn position(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
            return @as(*@This(), @ptrCast(@alignCast(context))).pref;
        }
        fn width(context: *anyopaque, _: usize) usize {
            return @as(*@This(), @ptrCast(@alignCast(context))).w;
        }
        fn height(context: *anyopaque) usize {
            return @as(*@This(), @ptrCast(@alignCast(context))).h;
        }
        fn build(context: *anyopaque, d: *ui.Document) anyerror!*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(context));
            const node = try d.createElement(.div);
            node.asElement().focusable = true;
            self.node = node;
            return node;
        }
        fn focusNode(context: *anyopaque) ?*ui.Node {
            return @as(*@This(), @ptrCast(@alignCast(context))).node;
        }
        fn isFocused(context: *anyopaque) bool {
            return @as(*@This(), @ptrCast(@alignCast(context))).focused;
        }
        fn interface(self: *@This()) editorBrowser.IOverlayWidget {
            return .{
                .context = self,
                .get_id = id,
                .get_position = position,
                .width = width,
                .height = height,
                .build = build,
                .focus_node = focusNode,
                .is_focused = isFocused,
            };
        }
    };

    var bottom = FlexWidget{ .pref = .bottom_right_corner, .w = 5, .h = 2, .focused = false };
    var center = FlexWidget{ .pref = .top_center, .w = 4, .h = 1, .focused = true };
    var part = ViewOverlayWidgets.init(allocator);
    defer part.deinit();
    try part.add(bottom.interface());
    try part.add(center.interface());
    try part.render(&doc, root, 20, 10);

    try testing.expectEqual(@as(usize, 2), part.entries.items.len);
    try testing.expectEqual(@as(usize, 15), part.entries.items[0].left);
    try testing.expectEqual(@as(usize, 8), part.entries.items[0].top);
    try testing.expectEqual(@as(usize, 8), part.entries.items[1].left);
    try testing.expectEqual(@as(usize, 0), part.entries.items[1].top);
    try testing.expectEqual(center.node.?, doc.activeElement());
}
