// Port of `src/vs/editor/browser/viewParts/contentWidgets/contentWidgets.ts`.
//
// Terminal adaptation: upstream positions each widget next to the view
// position in pixels and clamps the DOM box to the editor. The terminal maps
// the anchor to a cell column, places it above or below the anchor line and
// keeps it inside the text area. The widget registry, anchor-to-view-position
// mapping, focus restore and hit-test rectangles stay view-part behavior.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const editorBrowser = @import("../../editorBrowser.zig");
const IContentWidget = editorBrowser.IContentWidget;
const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;

/// A placed content widget, used by the host for hit testing.
pub const ContentWidgetEntry = struct {
    widget: IContentWidget,
    node: *ui.Node,
    left: usize,
    top: usize,
    width: usize,
    height: usize,

    pub fn contains(self: ContentWidgetEntry, x: usize, y: usize) bool {
        return x >= self.left and x < self.left + self.width and
            y >= self.top and y < self.top + self.height;
    }
};

/// Port of `ViewContentWidgets` (terminal paint boundary).
pub const ViewContentWidgets = struct {
    allocator: Allocator,
    widgets: std.array_list.Managed(IContentWidget),
    entries: std.array_list.Managed(ContentWidgetEntry),

    pub fn init(allocator: Allocator) ViewContentWidgets {
        return .{
            .allocator = allocator,
            .widgets = std.array_list.Managed(IContentWidget).init(allocator),
            .entries = std.array_list.Managed(ContentWidgetEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ViewContentWidgets) void {
        self.widgets.deinit();
        self.entries.deinit();
    }

    pub fn add(self: *ViewContentWidgets, widget: IContentWidget) !void {
        try self.widgets.append(widget);
    }

    pub fn remove(self: *ViewContentWidgets, id: []const u8) bool {
        for (self.widgets.items, 0..) |widget, index| {
            if (std.mem.eql(u8, widget.get_id(widget.context), id)) {
                _ = self.widgets.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Port of `ViewContentWidgets.render`. The caller supplies the text-area
    /// geometry because the terminal host owns the cell layout.
    pub fn render(
        self: *ViewContentWidgets,
        doc: *ui.Document,
        root: *ui.Node,
        editor: *Editor,
        cols: usize,
        text_right: usize,
        text_height: usize,
        gutter: usize,
        tab_size: usize,
    ) !void {
        self.entries.clearRetainingCapacity();
        if (text_right == 0) return;
        const top = editor.topViewLine();

        for (self.widgets.items) |widget| {
            const widget_position = widget.get_position(widget.context) orelse continue;
            const view_position = editor.viewPositionOfModelPosition(widget_position.position);
            if (view_position.lineNumber < top or view_position.lineNumber >= top + text_height) {
                continue;
            }
            const row = view_position.lineNumber - top;

            const width = @min(widget.width(widget.context, cols), text_right);
            const height = @min(widget.height(widget.context), text_height);
            if (width == 0 or height == 0) continue;

            const data = try editor.viewLineData(view_position.lineNumber);
            const model_line = editor.modelLineNumber(view_position.lineNumber);
            const model_column = editor.modelColumnOfViewPosition(view_position.lineNumber, view_position.column);
            const model_content = try editor.model.getLineContent(model_line);
            defer model_content.deinit();
            const anchor_cell = visibleOffset(
                model_content.items,
                model_column,
                tab_size,
                data.startVisibleColumn,
                data.minColumn - 1,
            );

            const left = @min(gutter + anchor_cell, text_right -| width);
            var widget_top: usize = switch (widget_position.preference) {
                .below => row + 1,
                .above => row -| height,
            };
            if (widget_top + height > text_height) {
                widget_top = text_height -| height;
            }

            const container = try doc.createElement(.div);
            container.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(widget_top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
            });

            const content = try widget.build(widget.context, doc);
            _ = try container.appendChild(content);
            _ = try root.appendChild(container);
            try self.entries.append(.{
                .widget = widget,
                .node = container,
                .left = left,
                .top = widget_top,
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

    fn visibleOffset(
        model_content: []const u8,
        column: usize,
        tab_size: usize,
        start_visible_column: usize,
        indent_cells: usize,
    ) usize {
        const visible = CursorColumns.visibleColumnFromColumn(model_content, column, tab_size);
        return (visible -| start_visible_column) + indent_cells;
    }
};

test "content widgets place below the anchor and clamp to the text area" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    var doc = try ui.Document.init(allocator, .{ .cols = 30, .rows = 6 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    const Widget = struct {
        node: ?*ui.Node = null,
        position: @import("../../../common/core/position.zig").Position,
        preference: editorBrowser.ContentWidgetPositionPreference,
        width_cells: usize,
        height_cells: usize,

        fn id(_: *anyopaque) []const u8 {
            return "test-content";
        }
        fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .position = self.position, .preference = self.preference };
        }
        fn width(context: *anyopaque, _: usize) usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.width_cells;
        }
        fn height(context: *anyopaque) usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.height_cells;
        }
        fn build(context: *anyopaque, d: *ui.Document) anyerror!*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.node = try d.createText("x");
            return self.node.?;
        }
        fn focusNode(_: *anyopaque) ?*ui.Node {
            return null;
        }
        fn isFocused(_: *anyopaque) bool {
            return false;
        }
        fn interface(self: *@This()) editorBrowser.IContentWidget {
            return .{
                .context = self,
                .get_id = id,
                .get_position = getPosition,
                .width = width,
                .height = height,
                .build = build,
                .focus_node = focusNode,
                .is_focused = isFocused,
            };
        }
    };

    var widget = Widget{
        .position = @import("../../../common/core/position.zig").Position.init(2, 1),
        .preference = .below,
        .width_cells = 5,
        .height_cells = 2,
    };
    var part = ViewContentWidgets.init(allocator);
    defer part.deinit();
    try part.add(widget.interface());
    try part.render(&doc, root, editor, 30, editor.textAreaRight(), editor.textHeight(), editor.gutterWidth(), 4);
    try testing.expectEqual(@as(usize, 1), part.entries.items.len);
    try testing.expectEqual(@as(usize, editor.gutterWidth()), part.entries.items[0].left);
    try testing.expectEqual(@as(usize, 2), part.entries.items[0].top);
    try testing.expectEqual(@as(usize, 5), part.entries.items[0].width);
    try testing.expectEqual(@as(usize, 2), part.entries.items[0].height);

    widget.preference = .above;
    try part.render(&doc, root, editor, 30, editor.textAreaRight(), editor.textHeight(), editor.gutterWidth(), 4);
    try testing.expectEqual(@as(usize, 0), part.entries.items[0].top);
}
