// Port of `src/vs/base/browser/ui/tree/dataTree.ts`.
//
// Terminal adaptation: this is the synchronous data-tree shell. Children are
// resolved eagerly from an `IDataSource`; the async data tree (`asyncDataTree.ts`)
// remains unported. The rendered view is the same `ObjectTree`/`AbstractTree`
// path as the object tree.

const std = @import("std");
const ui = @import("ui");
const object_tree = @import("./objectTree.zig");

pub fn DataTree(comptime T: type) type {
    const Tree = object_tree.ObjectTree(T);
    const Element = object_tree.ObjectTreeElement(T);

    return struct {
        pub const Node = Tree.Model.Node;
        pub const View = Tree.View;

        pub const DataSource = struct {
            context: *anyopaque,
            get_children: *const fn (context: *anyopaque, element: T) []const T,
            has_children: ?*const fn (context: *anyopaque, element: T) bool = null,
        };

        allocator: std.mem.Allocator,
        tree: *Tree,
        data_source: DataSource,
        input: ?T = null,

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            renderer: Tree.View.Renderer,
            data_source: DataSource,
            collapse_by_default: bool,
        ) !*DataTree(T) {
            const self = try allocator.create(DataTree(T));
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .tree = try Tree.init(allocator, user, renderer, collapse_by_default),
                .data_source = data_source,
            };
            return self;
        }

        pub fn deinit(self: *DataTree(T)) void {
            self.tree.deinit();
            self.allocator.destroy(self);
        }

        pub fn setInput(self: *DataTree(T), input: ?T) !void {
            self.input = input;
            if (input) |element| {
                const elements = try self.buildElements(element);
                defer {
                    self.freeElements(elements);
                    self.allocator.free(elements);
                }
                try self.tree.setChildren(null, elements);
            } else {
                try self.tree.setChildren(null, &.{});
            }
        }

        pub fn getInput(self: *const DataTree(T)) ?T {
            return self.input;
        }

        pub fn updateChildren(self: *DataTree(T)) !void {
            try self.setInput(self.input);
        }

        fn buildElements(self: *DataTree(T), element: T) ![]Element {
            const children = self.data_source.get_children(self.data_source.context, element);
            var list = std.array_list.Managed(Element).init(self.allocator);
            errdefer {
                for (list.items) |child| self.freeElement(child);
                list.deinit();
            }
            for (children) |child| {
                const nested = try self.buildElements(child);
                const has_children = if (self.data_source.has_children) |check|
                    check(self.data_source.context, child)
                else
                    nested.len > 0;
                try list.append(.{
                    .element = child,
                    .children = nested,
                    .collapsible = has_children,
                });
            }
            return list.toOwnedSlice();
        }

        fn freeElement(self: *DataTree(T), element: Element) void {
            self.freeElements(element.children);
            self.allocator.free(element.children);
        }

        fn freeElements(self: *DataTree(T), elements: []const Element) void {
            for (elements) |element| self.freeElement(element);
        }

        pub fn count(self: *DataTree(T)) usize {
            return self.tree.count();
        }

        pub fn setFocus(self: *DataTree(T), focus: bool) void {
            self.tree.setFocus(focus);
        }

        pub fn render(self: *DataTree(T), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.tree.render(grid, rect);
        }

        pub fn handleKey(self: *DataTree(T), event: *const ui.KeyEvent) bool {
            return self.tree.handleKey(event);
        }

        pub fn handleMouse(self: *DataTree(T), event: *const ui.MouseEvent) bool {
            return self.tree.handleMouse(event);
        }
    };
}
