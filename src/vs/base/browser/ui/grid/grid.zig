// Port of the portable split-tree behavior of
// `src/vs/base/browser/ui/grid/grid.ts`.
//
// The browser grid owns DOM views, drag/drop and sash elements. This port keeps
// the parts the terminal workbench needs: oriented splits with a ratio, branch
// demotion when the last view leaves a branch, and rect assignment for a
// viewport. Rendering and hit-testing stay in the TUI layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

pub const Orientation = enum { horizontal, vertical };

pub fn Node(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .pointer) @compileError("Grid views must be pointer types");
    }
    return struct {
        const Self = @This();

        kind: union(enum) {
            leaf: T,
            split: Split,
        },
        rect: ui.Rect = .{},

        pub const Split = struct {
            direction: Orientation,
            ratio: f64,
            first: *Self,
            second: *Self,
        };
    };
}

pub fn Grid(comptime T: type) type {
    const View = Node(T);
    return struct {
        const Self = @This();

        allocator: Allocator,
        root: *View,

        pub fn init(allocator: Allocator, first: T) !Self {
            return .{ .allocator = allocator, .root = try initLeaf(T, allocator, first) };
        }

        pub fn deinit(self: *Self) void {
            deinitNode(T, self.allocator, self.root);
        }

        /// Replaces the leaf holding `target` with a split containing the old
        /// leaf and a new leaf for `new_view`.
        pub fn split(self: *Self, target: T, direction: Orientation, new_view: T) !void {
            const leaf = findLeafIn(T, self.root, target) orelse return error.ViewNotFound;
            const new_leaf = try initLeaf(T, self.allocator, new_view);
            errdefer deinitNode(T, self.allocator, new_leaf);

            const split_node = try self.allocator.create(View);
            errdefer self.allocator.destroy(split_node);
            split_node.* = .{
                .kind = .{ .split = .{
                    .direction = direction,
                    .ratio = 0.5,
                    .first = leaf,
                    .second = new_leaf,
                } },
                .rect = leaf.rect,
            };

            if (self.root == leaf) {
                self.root = split_node;
            } else if (!replaceChild(T, self.root, leaf, split_node)) {
                return error.ViewNotFound;
            }
        }

        pub fn findLeaf(self: *Self, target: T) ?*View {
            return findLeafIn(T, self.root, target);
        }

        /// Removes a leaf and promotes its sibling, mirroring Grid's branch
        /// demotion. The root leaf is kept.
        pub fn remove(self: *Self, target: T) bool {
            if (self.root.kind == .leaf) return false;
            return removeFrom(T, self.allocator, self.root, target);
        }

        /// Assigns a rectangle to every leaf. `gap_context`/`gap` decide the
        /// gutter between the two sides of a split.
        pub fn layout(
            self: *Self,
            rect: ui.Rect,
            gap_context: anytype,
            comptime gap: fn (@TypeOf(gap_context), Orientation, ui.Rect) f64,
        ) void {
            layoutNode(T, self.root, rect, gap_context, gap);
        }
    };
}

pub fn initNode(comptime T: type, allocator: Allocator, value: T) !*Node(T) {
    return initLeaf(T, allocator, value);
}

pub fn deinitRoot(comptime T: type, allocator: Allocator, root: *Node(T)) void {
    deinitNode(T, allocator, root);
}

pub fn splitRoot(
    comptime T: type,
    allocator: Allocator,
    root: **Node(T),
    target: T,
    direction: Orientation,
    new_view: T,
    new_first: bool,
) !void {
    const leaf = findLeafIn(T, root.*, target) orelse return error.ViewNotFound;
    const new_leaf = try initLeaf(T, allocator, new_view);
    errdefer deinitNode(T, allocator, new_leaf);

    const split_node = try allocator.create(Node(T));
    errdefer allocator.destroy(split_node);
    split_node.* = .{
        .kind = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = if (new_first) new_leaf else leaf,
            .second = if (new_first) leaf else new_leaf,
        } },
        .rect = leaf.rect,
    };

    if (root.* == leaf) {
        root.* = split_node;
    } else if (!replaceChild(T, root.*, leaf, split_node)) {
        return error.ViewNotFound;
    }
}

pub fn findLeaf(comptime T: type, root: *Node(T), target: T) ?*Node(T) {
    return findLeafIn(T, root, target);
}

pub fn removeRoot(comptime T: type, allocator: Allocator, root: **Node(T), target: T) bool {
    if (root.*.kind == .leaf) return false;
    return removeFrom(T, allocator, root.*, target);
}

/// Moves an existing leaf next to another leaf without destroying either.
/// `direction` is the split orientation; `new_first` places the moved leaf
/// before the target. Mirrors the part of `Grid.moveView` the terminal's
/// binary tree needs.
pub fn moveRoot(
    comptime T: type,
    allocator: Allocator,
    root: **Node(T),
    source: T,
    target: T,
    direction: Orientation,
    new_first: bool,
) !void {
    if (source == target) return error.ViewNotFound;
    const source_leaf = findLeafIn(T, root.*, source) orelse return error.ViewNotFound;
    const target_leaf = findLeafIn(T, root.*, target) orelse return error.ViewNotFound;
    if (source_leaf == target_leaf) return error.ViewNotFound;
    if (root.* == source_leaf) return error.LastView;

    const split_node = try allocator.create(Node(T));
    errdefer allocator.destroy(split_node);
    if (!detachFrom(T, allocator, root.*, source)) return error.ViewNotFound;

    // Detaching can promote the target's parent into another node, so re-find
    // its live leaf before building the new split.
    const current_target = findLeafIn(T, root.*, target) orelse return error.ViewNotFound;
    split_node.* = .{
        .kind = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = if (new_first) source_leaf else current_target,
            .second = if (new_first) current_target else source_leaf,
        } },
        .rect = current_target.rect,
    };

    if (root.* == current_target) {
        root.* = split_node;
    } else if (!replaceChild(T, root.*, current_target, split_node)) {
        return error.ViewNotFound;
    }
}

/// Like `removeFrom`, but keeps the removed leaf alive for re-insertion.
fn detachFrom(comptime T: type, allocator: Allocator, node: *Node(T), target: T) bool {
    switch (node.kind) {
        .leaf => return false,
        .split => |*split| {
            const first_matches = split.first.kind == .leaf and split.first.kind.leaf == target;
            const second_matches = split.second.kind == .leaf and split.second.kind.leaf == target;
            if (first_matches or second_matches) {
                const keep = if (first_matches) split.second else split.first;
                node.* = keep.*;
                allocator.destroy(keep);
                return true;
            }
            return detachFrom(T, allocator, split.first, target) or
                detachFrom(T, allocator, split.second, target);
        },
    }
}

pub fn layoutRoot(
    comptime T: type,
    root: *Node(T),
    rect: ui.Rect,
    gap_context: anytype,
    comptime gap: fn (@TypeOf(gap_context), Orientation, ui.Rect) f64,
) void {
    layoutNode(T, root, rect, gap_context, gap);
}

fn initLeaf(comptime T: type, allocator: Allocator, value: T) !*Node(T) {
    const node = try allocator.create(Node(T));
    node.* = .{ .kind = .{ .leaf = value } };
    return node;
}

fn deinitNode(comptime T: type, allocator: Allocator, node: *Node(T)) void {
    switch (node.kind) {
        .leaf => {},
        .split => |split| {
            deinitNode(T, allocator, split.first);
            deinitNode(T, allocator, split.second);
        },
    }
    allocator.destroy(node);
}

fn findLeafIn(comptime T: type, node: *Node(T), target: T) ?*Node(T) {
    switch (node.kind) {
        .leaf => |value| return if (value == target) node else null,
        .split => |split| {
            if (findLeafIn(T, split.first, target)) |found| return found;
            return findLeafIn(T, split.second, target);
        },
    }
}

fn replaceChild(comptime T: type, node: *Node(T), target: *Node(T), replacement: *Node(T)) bool {
    switch (node.kind) {
        .leaf => return false,
        .split => |*split| {
            if (split.first == target) {
                split.first = replacement;
                return true;
            }
            if (split.second == target) {
                split.second = replacement;
                return true;
            }
            return replaceChild(T, split.first, target, replacement) or
                replaceChild(T, split.second, target, replacement);
        },
    }
}

fn removeFrom(comptime T: type, allocator: Allocator, node: *Node(T), target: T) bool {
    switch (node.kind) {
        .leaf => return false,
        .split => |*split| {
            const first_matches = split.first.kind == .leaf and split.first.kind.leaf == target;
            const second_matches = split.second.kind == .leaf and split.second.kind.leaf == target;
            if (first_matches or second_matches) {
                const keep = if (first_matches) split.second else split.first;
                const removed = if (first_matches) split.first else split.second;
                // Promote the sibling's contents into this node, then release
                // only the sibling container.
                node.* = keep.*;
                allocator.destroy(keep);
                allocator.destroy(removed);
                return true;
            }
            return removeFrom(T, allocator, split.first, target) or
                removeFrom(T, allocator, split.second, target);
        },
    }
}

const SplitRects = struct { first: ui.Rect, second: ui.Rect };

pub fn splitRects(rect: ui.Rect, direction: Orientation, ratio: f64, gutter: f64) SplitRects {
    const extent = if (direction == .horizontal) rect.w else rect.h;
    return splitRectsAt(rect, direction, @floor(@max(extent - gutter, 0) * ratio), gutter);
}

/// Assigns the two adjacent grid views using the first view's SplitView size.
pub fn splitRectsAt(rect: ui.Rect, direction: Orientation, first_size: f64, gutter: f64) SplitRects {
    switch (direction) {
        .horizontal => {
            const available = @max(rect.w - gutter, 0);
            const first_width = std.math.clamp(first_size, 0, available);
            return .{
                .first = .{ .x = rect.x, .y = rect.y, .w = first_width, .h = rect.h },
                .second = .{ .x = rect.x + first_width + gutter, .y = rect.y, .w = available - first_width, .h = rect.h },
            };
        },
        .vertical => {
            const available = @max(rect.h - gutter, 0);
            const first_height = std.math.clamp(first_size, 0, available);
            return .{
                .first = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_height },
                .second = .{ .x = rect.x, .y = rect.y + first_height + gutter, .w = rect.w, .h = available - first_height },
            };
        },
    }
}

fn layoutNode(
    comptime T: type,
    node: *Node(T),
    rect: ui.Rect,
    gap_context: anytype,
    comptime gap: fn (@TypeOf(gap_context), Orientation, ui.Rect) f64,
) void {
    node.rect = rect;
    switch (node.kind) {
        .leaf => {},
        .split => |split| {
            const gutter = gap(gap_context, split.direction, rect);
            const positions = splitRects(rect, split.direction, split.ratio, gutter);
            layoutNode(T, split.first, positions.first, gap_context, gap);
            layoutNode(T, split.second, positions.second, gap_context, gap);
        },
    }
}
