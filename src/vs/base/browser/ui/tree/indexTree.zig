// Port of `src/vs/base/browser/ui/tree/indexTree.ts`.
//
// Terminal adaptation: `IndexTreeModel` plus a virtualized `ListWidget`
// viewport. Rows are painted through the terminal renderer; expansion,
// selection, scrolling and keyboard navigation follow the ported list view.

const std = @import("std");
const ui = @import("ui");
const index_model = @import("./indexTreeModel.zig");
const list = @import("../list/list.zig");
const list_widget = @import("../list/listWidget.zig");

pub fn IndexTree(comptime T: type) type {
    const IndexModel = index_model.IndexTreeModel(T);
    const IndexNode = IndexModel.Node;

    return struct {
        pub const Node = IndexNode;

        pub const RenderRow = *const fn (
            context: *anyopaque,
            row: *const list.Row,
            node: *const IndexNode,
        ) void;

        pub const Renderer = struct {
            context: *anyopaque,
            render: RenderRow,
        };

        allocator: std.mem.Allocator,
        user: []const u8,
        model: IndexModel,
        widget: list_widget.ListWidget,
        renderer: Renderer,
        rendered: std.array_list.Managed(*IndexNode),

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            root_element: T,
            renderer: Renderer,
        ) !*IndexTree(T) {
            const self = try allocator.create(IndexTree(T));
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .user = user,
                .model = try IndexModel.init(allocator, user, root_element, .{}),
                .widget = list_widget.ListWidget.init(allocator, .{
                    .context = undefined,
                    .get_height = getHeight,
                    .get_template_id = getTemplateId,
                }, .{
                    .context = undefined,
                    .render = renderCallback,
                }),
                .renderer = renderer,
                .rendered = std.array_list.Managed(*IndexNode).init(allocator),
            };
            self.widget.view.delegate.context = @ptrCast(self);
            self.widget.view.renderer.context = @ptrCast(self);
            try self.refresh();
            return self;
        }

        pub fn deinit(self: *IndexTree(T)) void {
            self.rendered.deinit();
            self.widget.deinit();
            self.model.deinit();
            self.allocator.destroy(self);
        }

        fn getHeight(_: *anyopaque, _: list.Element) f64 {
            return 1;
        }

        fn getTemplateId(_: *anyopaque, _: list.Element) usize {
            return 0;
        }

        fn renderCallback(context: *anyopaque, row: *const list.Row, element: list.Element) void {
            const self: *IndexTree(T) = @ptrCast(@alignCast(context));
            const node: *const IndexNode = @ptrCast(@alignCast(element));
            self.renderer.render(self.renderer.context, row, node);
        }

        pub fn splice(self: *IndexTree(T), location: []const usize, delete_count: usize, children: []const IndexModel.Element) !void {
            try self.model.splice(location, delete_count, children);
            try self.refresh();
        }

        pub fn refresh(self: *IndexTree(T)) !void {
            self.rendered.clearRetainingCapacity();
            try self.model.collectRendered(&self.rendered);
            var elements = try self.allocator.alloc(list.Element, self.rendered.items.len);
            defer self.allocator.free(elements);
            for (self.rendered.items, 0..) |node, i| elements[i] = @ptrCast(node);
            try self.widget.splice(0, self.widget.count(), elements);
            if (self.widget.count() > 0) self.widget.view.setSelection(0);
        }

        pub fn count(self: *IndexTree(T)) usize {
            return self.widget.count();
        }

        pub fn selection(self: *IndexTree(T)) ?*IndexNode {
            const index = self.widget.selection() orelse return null;
            if (index >= self.rendered.items.len) return null;
            return self.rendered.items[index];
        }

        fn locationOf(self: *IndexTree(T), node: *IndexNode) ![]usize {
            var depth: usize = 0;
            var current: ?*IndexNode = node;
            while (current) |value| : (current = value.parent) {
                if (value.parent != null) depth += 1;
            }
            const location = try self.allocator.alloc(usize, depth);
            var index = depth;
            current = node;
            while (current) |value| {
                if (value.parent) |parent| {
                    var child_index: usize = 0;
                    for (parent.children.items, 0..) |child, i| {
                        if (child == value) {
                            child_index = i;
                            break;
                        }
                    }
                    index -= 1;
                    location[index] = child_index;
                }
                current = value.parent;
            }
            return location;
        }

        pub fn setFocus(self: *IndexTree(T), focus: bool) void {
            self.widget.setFocus(focus);
        }

        pub fn render(self: *IndexTree(T), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.widget.render(grid, rect);
        }

        pub fn handleKey(self: *IndexTree(T), event: *const ui.KeyEvent) bool {
            if (!self.widget.focused) return false;
            const node = self.selection() orelse return false;
            switch (event.key) {
                .left => {
                    if (node.collapsible and !node.collapsed) {
                        const location = self.locationOf(node) catch return false;
                        defer self.allocator.free(location);
                        _ = self.model.setCollapsed(location, true, false) catch return false;
                        self.refresh() catch return false;
                    } else if (node.parent) |parent| {
                        if (parent.parent != null) self.setSelectionNode(parent);
                    }
                    return true;
                },
                .right => {
                    if (node.collapsible and node.collapsed) {
                        const location = self.locationOf(node) catch return false;
                        defer self.allocator.free(location);
                        _ = self.model.setCollapsed(location, false, false) catch return false;
                        self.refresh() catch return false;
                    } else if (node.children.items.len > 0) {
                        self.setSelectionNode(node.children.items[0]);
                    }
                    return true;
                },
                else => return self.widget.handleKey(event),
            }
        }

        pub fn handleMouse(self: *IndexTree(T), event: *const ui.MouseEvent) bool {
            return self.widget.handleMouse(event);
        }

        fn setSelectionNode(self: *IndexTree(T), node: *IndexNode) void {
            for (self.rendered.items, 0..) |candidate, index| {
                if (candidate == node) {
                    self.widget.setSelection(index);
                    return;
                }
            }
        }
    };
}
