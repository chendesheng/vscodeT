// Port of the core view behavior of `src/vs/base/browser/ui/tree/abstractTree.ts`.
//
// Terminal adaptation: rows are painted through `ListWidget` into a CellGrid
// instead of DOM rows. `AbstractTreeForModel` keeps the view model-agnostic so
// `CompressibleObjectTree` can drive it with `CompressedObjectTreeModel`, the
// same composition as upstream's `CompressibleObjectTree extends ObjectTree`.
// Filtering, async nodes, drag/drop, context menus and the browser
// accessibility layer are not ported yet.

const std = @import("std");
const ui = @import("ui");
const list = @import("../list/list.zig");
const list_widget = @import("../list/listWidget.zig");
const object_tree = @import("./objectTreeModel.zig");

pub fn AbstractTree(comptime T: type) type {
    return AbstractTreeForModel(T, object_tree.ObjectTreeModel(T));
}

/// View over any model exposing `Node`, `collectRendered` and
/// `setCollapsedElement`. This mirrors upstream `AbstractTree`'s use of the
/// `ITreeModel` contract instead of a concrete object model.
pub fn AbstractTreeForModel(comptime T: type, comptime Model: type) type {
    const Node = Model.Node;

    return struct {
        pub const RenderRow = *const fn (
            context: *anyopaque,
            row: *const list.Row,
            node: *const Node,
        ) void;

        pub const Renderer = struct {
            context: *anyopaque,
            render: RenderRow,
        };

        allocator: std.mem.Allocator,
        model: *Model,
        widget: list_widget.ListWidget,
        renderer: Renderer,
        rendered: std.array_list.Managed(*Node),
        selection_context: ?*anyopaque = null,
        on_activate: ?*const fn (context: ?*anyopaque, element: T) void = null,

        pub fn init(
            allocator: std.mem.Allocator,
            model: *Model,
            renderer: Renderer,
        ) !*AbstractTreeForModel(T, Model) {
            const self = try allocator.create(AbstractTreeForModel(T, Model));
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .model = model,
                .widget = list_widget.ListWidget.init(allocator, .{
                    .context = undefined,
                    .get_height = getHeight,
                    .get_template_id = getTemplateId,
                }, .{
                    .context = undefined,
                    .render = renderCallback,
                }),
                .renderer = renderer,
                .rendered = std.array_list.Managed(*Node).init(allocator),
            };
            self.widget.view.delegate.context = @ptrCast(self);
            self.widget.view.renderer.context = @ptrCast(self);
            try self.refresh();
            return self;
        }

        pub fn deinit(self: *AbstractTreeForModel(T, Model)) void {
            self.rendered.deinit();
            self.widget.deinit();
            self.allocator.destroy(self);
        }

        fn getHeight(context: *anyopaque, _: list.Element) f64 {
            _ = context;
            return 1;
        }

        fn getTemplateId(context: *anyopaque, _: list.Element) usize {
            _ = context;
            return 0;
        }

        fn renderCallback(context: *anyopaque, row: *const list.Row, element: list.Element) void {
            const self: *AbstractTreeForModel(T, Model) = @ptrCast(@alignCast(context));
            const node: *const Node = @ptrCast(@alignCast(element));
            self.renderer.render(self.renderer.context, row, node);
        }

        pub fn setFocus(self: *AbstractTreeForModel(T, Model), focus: bool) void {
            self.widget.setFocus(focus);
        }

        pub fn focused(self: *const AbstractTreeForModel(T, Model)) bool {
            return self.widget.focused;
        }

        pub fn count(self: *const AbstractTreeForModel(T, Model)) usize {
            return self.widget.count();
        }

        pub fn selection(self: *AbstractTreeForModel(T, Model)) ?*Node {
            const index = self.widget.selection() orelse return null;
            if (index >= self.rendered.items.len) return null;
            return self.rendered.items[index];
        }

        pub fn setSelectionNode(self: *AbstractTreeForModel(T, Model), node: ?*Node) void {
            if (node) |value| {
                for (self.rendered.items, 0..) |candidate, index| {
                    if (candidate == value) {
                        self.widget.setSelection(index);
                        return;
                    }
                }
            }
            self.widget.setSelection(null);
        }

        /// Rebuilds the rendered row projection after a model mutation.
        pub fn refresh(self: *AbstractTreeForModel(T, Model)) !void {
            const selected = self.selection();
            self.rendered.clearRetainingCapacity();
            try self.model.collectRendered(&self.rendered);

            var elements = try self.allocator.alloc(list.Element, self.rendered.items.len);
            defer self.allocator.free(elements);
            for (self.rendered.items, 0..) |node, i| elements[i] = @ptrCast(node);

            const old_count = self.widget.count();
            try self.widget.splice(0, old_count, elements);

            if (selected) |node| {
                for (self.rendered.items, 0..) |candidate, index| {
                    if (candidate == node) {
                        self.widget.view.setSelection(index);
                        return;
                    }
                }
            }
            if (self.widget.count() > 0) {
                self.widget.view.setSelection(0);
            } else {
                self.widget.view.setSelection(null);
            }
        }

        pub fn render(self: *AbstractTreeForModel(T, Model), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.widget.render(grid, rect);
        }

        pub fn handleKey(self: *AbstractTreeForModel(T, Model), event: *const ui.KeyEvent) bool {
            if (!self.widget.focused) return false;
            switch (event.key) {
                .left => {
                    const node = self.selection() orelse return true;
                    const element = node.element orelse return true;
                    if (node.collapsible and !node.collapsed) {
                        _ = self.model.setCollapsedElement(element, true, false) catch {};
                        self.refresh() catch {};
                    } else if (node.parent) |parent| {
                        if (parent.element != null) self.setSelectionNode(parent);
                    }
                    return true;
                },
                .right => {
                    const node = self.selection() orelse return true;
                    const element = node.element orelse return true;
                    if (node.collapsible and node.collapsed) {
                        _ = self.model.setCollapsedElement(element, false, false) catch {};
                        self.refresh() catch {};
                    } else if (node.children.items.len > 0) {
                        self.setSelectionNode(node.children.items[0]);
                    }
                    return true;
                },
                else => return self.widget.handleKey(event),
            }
        }

        pub fn handleMouse(self: *AbstractTreeForModel(T, Model), event: *const ui.MouseEvent) bool {
            return self.widget.handleMouse(event);
        }

        pub fn selectedElement(self: *AbstractTreeForModel(T, Model)) ?T {
            const node = self.selection() orelse return null;
            return node.element;
        }

        pub fn setActivateHandler(
            self: *AbstractTreeForModel(T, Model),
            context: ?*anyopaque,
            handler: *const fn (context: ?*anyopaque, element: T) void,
        ) void {
            self.selection_context = context;
            self.on_activate = handler;
            self.widget.activation_context = @ptrCast(self);
            self.widget.on_activate = activateCallback;
        }

        fn activateCallback(context: ?*anyopaque, _: usize) void {
            const self: *AbstractTreeForModel(T, Model) = @ptrCast(@alignCast(context orelse return));
            const node = self.selection() orelse return;
            if (node.element) |element| {
                if (self.on_activate) |handler| handler(self.selection_context, element);
            }
        }
    };
}
