// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/ast.ts`.
//
// Node lengths are UTF-8 byte lengths. Native ownership adaptation:
// cached subtrees are reference-counted, and a parser region is reclaimed
// when its last live node is released. The 2-3 tree's mutable path is
// copied only when shared, analogous to upstream's immutable list nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel.zig").TextModel;
const CursorColumns = @import("../../../core/cursorColumns.zig").CursorColumns;
const length_mod = @import("./length.zig");
const Length = length_mod.Length;
const lengthAdd = length_mod.lengthAdd;
const lengthLineCount = length_mod.lengthLineCount;
const lengthColumnCount = length_mod.lengthColumnCount;
const set_mod = @import("./smallImmutableSet.zig");
const SmallImmutableSet = set_mod.SmallImmutableSet;
const tokenizer_mod = @import("./tokenizer.zig");
const Token = tokenizer_mod.Token;
const BracketInfo = tokenizer_mod.BracketInfo;

pub const NodeKind = enum { text, bracket, pair, invalid_bracket, list };

pub const Data = union(enum) {
    text: void,
    bracket: BracketData,
    pair: PairData,
    invalid_bracket: InvalidData,
    list: ListData,
};

pub const BracketData = struct {
    info: BracketInfo,
    bracket_ids: SmallImmutableSet,
    colorized_bracket_ids: SmallImmutableSet = .{},
};

pub const PairData = struct {
    opening: *AstNode,
    child: ?*AstNode,
    closing: ?*AstNode,
};

pub const InvalidData = struct {
    info: BracketInfo,
    missing: SmallImmutableSet,
};

pub const ListData = struct {
    children: ArrayList(*AstNode),
    mutable: bool,
    cached_min_indentation: i64 = -1,
};

/// Storage for one parse operation. Nodes can outlive its document through
/// shared subtrees, but a region never retains an entire previous document.
/// During parsing we track retained nodes from older regions so an allocation
/// failure can dispose the uncommitted arena without leaking references.
pub const NodeRegion = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    live_nodes: usize = 0,
    parsing: bool = true,
    external_refs: std.AutoHashMap(*AstNode, usize),

    pub fn create(allocator: Allocator) !*NodeRegion {
        const self = try allocator.create(NodeRegion);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .external_refs = .init(allocator) };
        return self;
    }

    pub fn retain(self: *NodeRegion, node: *AstNode) !*AstNode {
        std.debug.assert(self.parsing and node.region != null);
        if (node.region != self) {
            const entry = try self.external_refs.getOrPut(node);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        node.refs += 1;
        return node;
    }

    fn releaseDuringParse(self: *NodeRegion, node: *AstNode) void {
        if (node.region != self) {
            const count = self.external_refs.getPtr(node).?;
            count.* -= 1;
            if (count.* == 0) _ = self.external_refs.remove(node);
        }
        node.release();
    }

    pub fn commit(self: *NodeRegion) void {
        self.external_refs.deinit();
        self.parsing = false;
        if (self.live_nodes == 0) self.destroy();
    }

    pub fn abort(self: *NodeRegion) void {
        var entries = self.external_refs.iterator();
        while (entries.next()) |entry| {
            for (0..entry.value_ptr.*) |_| entry.key_ptr.*.release();
        }
        self.external_refs.deinit();
        self.destroy();
    }

    fn destroy(self: *NodeRegion) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const AstNode = struct {
    kind: NodeKind,
    length: Length,
    list_height: u32,
    missing: SmallImmutableSet,
    data: Data,
    region: ?*NodeRegion = null,
    refs: usize = 1,

    pub fn release(self: *AstNode) void {
        const region = self.region orelse return;
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        switch (self.data) {
            .pair => |pair| {
                pair.opening.release();
                if (pair.child) |child_node| child_node.release();
                if (pair.closing) |closing| closing.release();
            },
            .list => |list| for (list.children.items) |child_node| child_node.release(),
            else => {},
        }
        region.live_nodes -= 1;
        if (region.live_nodes == 0 and !region.parsing) region.destroy();
    }

    pub fn childrenLength(self: *const AstNode) usize {
        return switch (self.data) {
            .text, .bracket, .invalid_bracket => 0,
            .pair => blk: {
                const pair = self.data.pair;
                break :blk 1 + @as(usize, if (pair.child != null) 1 else 0) + @as(usize, if (pair.closing != null) 1 else 0);
            },
            .list => self.data.list.children.items.len,
        };
    }

    pub fn child(self: *const AstNode, index: usize) ?*AstNode {
        return switch (self.data) {
            .pair => |pair| switch (index) {
                0 => pair.opening,
                1 => pair.child,
                2 => pair.closing,
                else => null,
            },
            .list => |list| if (index < list.children.items.len) list.children.items[index] else null,
            else => null,
        };
    }

    pub fn clone(self: *const AstNode, allocator: Allocator) !*AstNode {
        const node = try allocator.create(AstNode);
        node.* = self.*;
        node.region = null;
        node.refs = 1;
        switch (self.data) {
            .text => {},
            .bracket => {},
            .invalid_bracket => {},
            .pair => |pair| {
                node.data.pair.opening = try pair.opening.clone(allocator);
                node.data.pair.child = if (pair.child) |c| try c.clone(allocator) else null;
                node.data.pair.closing = if (pair.closing) |closing| try closing.clone(allocator) else null;
            },
            .list => |list| {
                var children = ArrayList(*AstNode).init(allocator);
                for (list.children.items) |c| try children.append(try c.clone(allocator));
                node.data.list.children = children;
                node.data.list.mutable = true;
            },
        }
        return node;
    }

    fn recomputeList(self: *AstNode) void {
        const list = &self.data.list;
        var length: Length = 0;
        var missing = SmallImmutableSet.empty();
        for (list.children.items) |c| {
            length = lengthAdd(length, c.length);
            missing = missing.merge(c.missing);
        }
        self.length = length;
        self.missing = missing;
        list.cached_min_indentation = -1;
    }

    /// Consumes one reference. A shared list copies its immediate children,
    /// not the subtrees beneath them.
    pub fn toMutable(self: *AstNode, allocator: Allocator, region: ?*NodeRegion) !*AstNode {
        const owner = region orelse return self;
        if (self.region == owner and self.refs == 1) return self;
        const list = self.data.list;
        var children = ArrayList(*AstNode).init(allocator);
        try children.ensureTotalCapacity(@max(@as(usize, 3), list.children.items.len));
        for (list.children.items) |child_node| children.appendAssumeCapacity(try owner.retain(child_node));
        const node = try allocator.create(AstNode);
        node.* = self.*;
        node.region = owner;
        node.refs = 1;
        node.data.list.children = children;
        node.data.list.mutable = true;
        owner.live_nodes += 1;
        owner.releaseDuringParse(self);
        return node;
    }

    pub fn makeLastElementMutable(self: *AstNode, allocator: Allocator, region: ?*NodeRegion) !?*AstNode {
        if (self.data != .list or self.data.list.children.items.len == 0) return null;
        const item = &self.data.list.children.items[self.data.list.children.items.len - 1];
        if (item.*.data == .list) item.* = try item.*.toMutable(allocator, region);
        return item.*;
    }

    pub fn makeFirstElementMutable(self: *AstNode, allocator: Allocator, region: ?*NodeRegion) !?*AstNode {
        if (self.data != .list or self.data.list.children.items.len == 0) return null;
        const item = &self.data.list.children.items[0];
        if (item.*.data == .list) item.* = try item.*.toMutable(allocator, region);
        return item.*;
    }

    pub fn appendChildOfSameHeight(self: *AstNode, node: *AstNode) void {
        const list = &self.data.list;
        list.children.append(node) catch return;
        // A descendant may have split immediately before insertion, so
        // upstream recomputes from the current children, not the old length.
        self.recomputeList();
    }

    pub fn unappendChild(self: *AstNode) ?*AstNode {
        const list = &self.data.list;
        if (list.children.items.len == 0) return null;
        const removed = list.children.pop().?;
        self.recomputeList();
        return removed;
    }

    pub fn prependChildOfSameHeight(self: *AstNode, node: *AstNode) void {
        const list = &self.data.list;
        list.children.insert(0, node) catch return;
        self.recomputeList();
    }

    pub fn unprependChild(self: *AstNode) ?*AstNode {
        const list = &self.data.list;
        if (list.children.items.len == 0) return null;
        const removed = list.children.orderedRemove(0);
        self.recomputeList();
        return removed;
    }

    pub fn handleChildrenChanged(self: *AstNode) void {
        self.recomputeList();
    }

    pub fn flattenLists(self: *AstNode, allocator: Allocator) !*AstNode {
        switch (self.data) {
            .list => |list| {
                var items = ArrayList(*AstNode).init(allocator);
                defer items.deinit();
                for (list.children.items) |c| {
                    const normalized = try c.flattenLists(allocator);
                    if (normalized.data == .list) {
                        try items.appendSlice(normalized.data.list.children.items);
                    } else {
                        try items.append(normalized);
                    }
                }
                return try makeList(allocator, items.items, if (items.items.len > 0) items.items[0].list_height else 0);
            },
            else => return self,
        }
    }

    pub fn canBeReused(self: *const AstNode, opened: SmallImmutableSet) bool {
        return switch (self.data) {
            .text => true,
            .invalid_bracket => false,
            .bracket => false,
            .pair => |pair| pair.closing != null and !opened.intersects(self.missing),
            .list => |list| list.children.items.len > 0 and !opened.intersects(self.missing),
        };
    }
};

/// Upstream uses `Number.MAX_SAFE_INTEGER` for "no indentation found".
pub const max_safe_integer: i64 = 9007199254740991;

/// Upstream `AstNode.computeMinIndentation`.
///
/// The minimum visible column of the first non-whitespace character in the
/// subtree's text. Text nodes that start mid-line contribute nothing for that
/// first line (the tokenizer guarantees they have no partial indentation).
/// Bracket leaf nodes contribute nothing.
pub fn computeMinIndentation(node: *AstNode, offset: Length, model: *TextModel) anyerror!i64 {
    switch (node.data) {
        .text => {
            const start_line_count = lengthLineCount(offset);
            const start_column_count = lengthColumnCount(offset);
            const start_line_number = (if (start_column_count == 0) start_line_count else start_line_count + 1) + 1;
            const end_line_number = lengthLineCount(lengthAdd(offset, node.length)) + 1;

            var result = max_safe_integer;
            var line_number = start_line_number;
            while (line_number <= end_line_number) : (line_number += 1) {
                const first_non_ws_column = try model.getLineFirstNonWhitespaceColumn(line_number);
                if (first_non_ws_column == 0) continue;

                var line_content = try model.getLineContent(line_number);
                defer line_content.deinit();
                const visible_column = CursorColumns.visibleColumnFromColumn(
                    line_content.items,
                    first_non_ws_column,
                    model.getOptions().tabSize,
                );
                result = @min(result, @as(i64, @intCast(visible_column)));
            }
            return result;
        },
        .bracket, .invalid_bracket => return max_safe_integer,
        .pair => |pair| {
            if (pair.child) |child| {
                return computeMinIndentation(child, lengthAdd(offset, pair.opening.length), model);
            }
            return max_safe_integer;
        },
        .list => |*list| {
            if (list.cached_min_indentation != -1) {
                return list.cached_min_indentation;
            }

            var min_indentation = max_safe_integer;
            var child_offset = offset;
            for (list.children.items) |child| {
                min_indentation = @min(min_indentation, try computeMinIndentation(child, child_offset, model));
                child_offset = lengthAdd(child_offset, child.length);
            }

            list.cached_min_indentation = min_indentation;
            return min_indentation;
        },
    }
}

pub fn allocNode(allocator: Allocator) !*AstNode {
    return try allocator.create(AstNode);
}

pub fn makeText(allocator: Allocator, length: Length) !*AstNode {
    return makeTextIn(allocator, length, null);
}

pub fn makeTextIn(allocator: Allocator, length: Length, region: ?*NodeRegion) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{ .kind = .text, .length = length, .list_height = 0, .missing = SmallImmutableSet.empty(), .data = .{ .text = {} } };
    node.region = region;
    if (region) |owner| owner.live_nodes += 1;
    return node;
}

pub fn makeBracket(allocator: Allocator, token: Token) !*AstNode {
    return makeBracketIn(allocator, token, null);
}

pub fn makeBracketIn(allocator: Allocator, token: Token, region: ?*NodeRegion) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .bracket,
        .length = token.length,
        .list_height = 0,
        .missing = SmallImmutableSet.empty(),
        .data = .{ .bracket = .{
            .info = token.bracket.?,
            .bracket_ids = token.bracket_ids,
            .colorized_bracket_ids = token.colorized_bracket_ids,
        } },
    };
    node.region = region;
    if (region) |owner| owner.live_nodes += 1;
    return node;
}

pub fn makeInvalid(allocator: Allocator, token: Token) !*AstNode {
    return makeInvalidIn(allocator, token, null);
}

pub fn makeInvalidIn(allocator: Allocator, token: Token, region: ?*NodeRegion) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .invalid_bracket,
        .length = token.length,
        .list_height = 0,
        .missing = token.bracket_ids,
        .data = .{ .invalid_bracket = .{ .info = token.bracket.?, .missing = token.bracket_ids } },
    };
    node.region = region;
    if (region) |owner| owner.live_nodes += 1;
    return node;
}

pub fn makePair(allocator: Allocator, opening: *AstNode, child: *AstNode, closing: ?*AstNode) !*AstNode {
    return makePairIn(allocator, opening, child, closing, null);
}

pub fn makePairIn(allocator: Allocator, opening: *AstNode, child: *AstNode, closing: ?*AstNode, region: ?*NodeRegion) !*AstNode {
    const node = try allocNode(allocator);
    var length = opening.length;
    length = lengthAdd(length, child.length);
    if (closing) |c| length = lengthAdd(length, c.length);
    node.* = .{
        .kind = .pair,
        .length = length,
        .list_height = 0,
        .missing = child.missing,
        .data = .{ .pair = .{ .opening = opening, .child = child, .closing = closing } },
    };
    node.region = region;
    if (region) |owner| owner.live_nodes += 1;
    return node;
}

pub fn makeList(allocator: Allocator, items: []const *AstNode, height: u32) !*AstNode {
    return makeListIn(allocator, items, height, null);
}

pub fn makeListIn(allocator: Allocator, items: []const *AstNode, height: u32, region: ?*NodeRegion) !*AstNode {
    var children = ArrayList(*AstNode).init(allocator);
    if (items.len > 0) try children.ensureTotalCapacity(@max(@as(usize, 3), items.len));
    try children.appendSlice(items);
    var length: Length = 0;
    var missing = SmallImmutableSet.empty();
    for (items) |item| {
        length = lengthAdd(length, item.length);
        missing = missing.merge(item.missing);
    }
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .list,
        .length = length,
        .list_height = height,
        .missing = missing,
        .data = .{ .list = .{ .children = children, .mutable = true } },
    };
    node.region = region;
    if (region) |owner| owner.live_nodes += 1;
    return node;
}

pub fn makeEmptyList(allocator: Allocator) !*AstNode {
    return try makeList(allocator, &[_]*AstNode{}, 0);
}

/// Upstream `ListAstNode.create23`.
pub fn create23(allocator: Allocator, item1: *AstNode, item2: *AstNode, item3: ?*AstNode) !*AstNode {
    return create23In(allocator, item1, item2, item3, null);
}

pub fn create23In(allocator: Allocator, item1: *AstNode, item2: *AstNode, item3: ?*AstNode, region: ?*NodeRegion) !*AstNode {
    if (item1.list_height != item2.list_height) return error.InvalidListHeights;
    if (item3) |third| {
        if (item1.list_height != third.list_height) return error.InvalidListHeights;
    }
    var items: [3]*AstNode = undefined;
    items[0] = item1;
    items[1] = item2;
    var count: usize = 2;
    if (item3) |third| {
        items[2] = third;
        count = 3;
    }
    return try makeListIn(allocator, items[0..count], item1.list_height + 1, region);
}
