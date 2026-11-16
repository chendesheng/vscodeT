// Port of `src/vs/base/browser/ui/tree/objectTree.ts`.
//
// Terminal adaptation: wraps the ported `ObjectTreeModel` and `AbstractTree`.
// Sorter/identity-provider options and sticky scroll are not part of this
// terminal subset yet.

const std = @import("std");
const ui = @import("ui");
const object_model = @import("./objectTreeModel.zig");
const abstract_tree = @import("./abstractTree.zig");

pub fn ObjectTree(comptime T: type) type {
    return struct {
        pub const Model = object_model.ObjectTreeModel(T);
        pub const View = abstract_tree.AbstractTree(T);
        pub const Element = object_model.ObjectTreeElement(T);

        allocator: std.mem.Allocator,
        model: *Model,
        view: *View,

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            renderer: View.Renderer,
            collapse_by_default: bool,
        ) !*ObjectTree(T) {
            const self = try allocator.create(ObjectTree(T));
            errdefer allocator.destroy(self);
            const model = try allocator.create(Model);
            errdefer allocator.destroy(model);
            model.* = try Model.init(allocator, user, collapse_by_default);
            errdefer model.deinit();

            self.* = .{
                .allocator = allocator,
                .model = model,
                .view = try View.init(allocator, model, renderer),
            };
            return self;
        }

        pub fn deinit(self: *ObjectTree(T)) void {
            self.view.deinit();
            self.model.deinit();
            self.allocator.destroy(self.model);
            self.allocator.destroy(self);
        }

        pub fn setChildren(self: *ObjectTree(T), element: ?T, children: []const Element) !void {
            try self.model.setChildren(element, children);
            try self.view.refresh();
        }

        pub fn count(self: *ObjectTree(T)) usize {
            return self.view.count();
        }

        pub fn hasElement(self: *ObjectTree(T), element: T) bool {
            return self.model.has(element);
        }

        pub fn getListRenderCount(self: *ObjectTree(T), element: ?T) !usize {
            return self.model.getListRenderCount(element);
        }

        pub fn isCollapsed(self: *ObjectTree(T), element: ?T) bool {
            return self.model.isCollapsed(element);
        }

        pub fn setCollapsed(self: *ObjectTree(T), element: ?T, collapsed: bool, recursive: bool) !bool {
            const changed = try self.model.setCollapsed(element, collapsed, recursive);
            if (changed) try self.view.refresh();
            return changed;
        }

        pub fn refilter(self: *ObjectTree(T)) !void {
            try self.model.refilter();
            try self.view.refresh();
        }

        pub fn setFilter(self: *ObjectTree(T), filter: ?@import("./tree.zig").TreeFilter(T)) !void {
            try self.model.setFilter(filter);
            try self.view.refresh();
        }

        pub fn selection(self: *ObjectTree(T)) ?*Model.Node {
            return self.view.selection();
        }

        pub fn setFocus(self: *ObjectTree(T), focus: bool) void {
            self.view.setFocus(focus);
        }

        pub fn render(self: *ObjectTree(T), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.view.render(grid, rect);
        }

        pub fn handleKey(self: *ObjectTree(T), event: *const ui.KeyEvent) bool {
            return self.view.handleKey(event);
        }

        pub fn handleMouse(self: *ObjectTree(T), event: *const ui.MouseEvent) bool {
            return self.view.handleMouse(event);
        }
    };
}

pub fn ObjectTreeElement(comptime T: type) type {
    return @import("./objectTreeModel.zig").ObjectTreeElement(T);
}
