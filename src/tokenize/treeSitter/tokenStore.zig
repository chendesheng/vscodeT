const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const usizeAdd = @import("../../basics/utils.zig").usizeAdd;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;

pub const ListNode = struct {
    parent: ?*ListNode,
    height: usize,
    _children: ArrayList(*Node),
    _length: usize,

    pub fn init(allocator: Allocator, height: usize) ListNode {
        return .{
            .parent = null,
            .height = height,
            ._children = ArrayList(*Node).init(allocator),
            ._length = 0,
        };
    }

    pub fn children(self: *const ListNode) []*Node {
        return self._children.items;
    }

    pub fn create(allocator: Allocator, node1: *Node, node2: *Node) !*Node {
        const node = try Node.createListNode(allocator, node1.height() + 1);
        try node.list.appendChild(node1);
        try node.list.appendChild(node2);
        return node;
    }

    pub fn canAppendChild(self: *const ListNode) bool {
        return self._children.items.len < 3;
    }

    pub fn appendChild(self: *ListNode, node: *Node) !void {
        if (!self.canAppendChild()) {
            return error.CannotInsertMoreThan3Children;
        }

        try self._children.append(node);

        self._length += node.length();
        self._updateParentLength(@as(isize, @intCast(node.length())));
        if (!node.isLeaf()) {
            node.setParent(self);
        }
    }

    fn _updateParentLength(self: *ListNode, delta: isize) void {
        var updateParent = self.parent;
        while (updateParent != null) {
            updateParent.?._length = usizeAdd(updateParent.?._length, delta);
            updateParent = updateParent.?.parent;
        }
    }

    pub fn unappendChild(self: *ListNode) !*Node {
        const child = self._children.pop().?;
        self._length -= child.length();
        self._updateParentLength(-@as(isize, @intCast(child.length())));
        return child;
    }

    pub fn prependChild(self: *ListNode, node: *Node) !void {
        if (self._children.items.len >= 3) {
            return error.CannotPrependMoreThan3Children;
        }
        try self._children.insert(0, node);

        self._length += node.length();
        self._updateParentLength(@as(isize, @intCast(node.length())));
        if (!node.isLeaf()) {
            node.setParent(self);
        }
    }

    pub fn unprependChild(self: *ListNode) !*Node {
        const child = self._children.orderedRemove(0);
        self._length -= child.length();
        self._updateParentLength(-@as(isize, @intCast(child.length())));
        return child;
    }

    // this will break the tree structure, so only use it when you know what you are doing
    fn detachChild(self: *ListNode, node: *Node) !void {
        if (std.mem.indexOfScalar(*Node, self._children.items, node)) |idx| {
            _ = self._children.orderedRemove(idx);
            // self._length -= node.length();
            // self._updateParentLength(-@as(isize, @intCast(node.length())));
        } else {
            return error.ChildNotFound;
        }
    }

    pub fn lastChild(self: *const ListNode) *Node {
        return self._children.getLast();
    }

    pub fn deinit(self: *ListNode) void {
        self._children.deinit();
    }
};

pub const TokenQuality = enum(u8) {
    none = 0,
    viewportGuess = 1,
    editGuess = 2,
    accurate = 3,
};

pub const LeafNode = struct {
    length: usize,
    token: u32,
    tokenQuality: TokenQuality,
};

pub const Node = union(enum) {
    list: ListNode,
    leaf: LeafNode,

    pub fn createLeafNode(allocator: Allocator, _length: ?usize, _token: ?u32, _tokenQuality: ?TokenQuality) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .leaf = .{
                .length = _length orelse 0,
                .token = _token orelse 0,
                .tokenQuality = _tokenQuality orelse .none,
            },
        };
        return node;
    }

    pub fn createListNode(allocator: Allocator, _height: ?usize) !*Node {
        const node = try allocator.create(Node);
        node.* = .{ .list = ListNode.init(allocator, _height orelse 0) };
        return node;
    }

    pub fn length(self: *const Node) usize {
        return switch (self.*) {
            .list => self.list._length,
            .leaf => self.leaf.length,
        };
    }

    pub fn setParent(self: *Node, parent: ?*ListNode) void {
        switch (self.*) {
            .list => self.list.parent = parent,
            .leaf => {},
        }
    }
    pub fn isLeaf(self: *const Node) bool {
        return switch (self.*) {
            .list => false,
            .leaf => true,
        };
    }

    pub fn height(self: *const Node) usize {
        return switch (self.*) {
            .list => self.list.height,
            .leaf => 0,
        };
    }

    pub fn lastChild(self: *const Node) ?*Node {
        return switch (self.*) {
            .list => self.list.lastChild(),
            .leaf => null,
        };
    }

    pub fn children(self: *const Node) []*Node {
        return switch (self.*) {
            .list => self.list.children(),
            .leaf => &[_]*Node{},
        };
    }

    pub fn token(self: *const Node) u32 {
        return switch (self.*) {
            .list => unreachable,
            .leaf => self.leaf.token,
        };
    }

    pub fn tokenQuality(self: *const Node) TokenQuality {
        return switch (self.*) {
            .list => unreachable,
            .leaf => self.leaf.tokenQuality,
        };
    }

    pub fn setTokenQuality(self: *Node, tq: TokenQuality) void {
        switch (self.*) {
            .list => {},
            .leaf => self.leaf.tokenQuality = tq,
        }
    }

    pub fn deinit(self: *Node) void {
        switch (self.*) {
            .list => self.list.deinit(),
            .leaf => {},
        }
    }
};

pub const TokenUpdate = struct {
    startOffsetInclusive: usize,
    length: usize,
    token: u32,
};

// Heavily inspired by https://github.com/microsoft/vscode/blob/4eb2658d592cb6114a7a393655574176cc790c5b/src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/concat23Trees.ts#L108-L109
fn append(allocator: Allocator, node: *Node, nodeToAppend: *Node) !*Node {
    var curNode = node;
    var parents = ArrayList(*ListNode).init(allocator);
    defer parents.deinit();
    var _nodeToAppendOfCorrectHeight: ?*Node = null;
    while (true) {
        if (nodeToAppend.height() == curNode.height()) {
            _nodeToAppendOfCorrectHeight = nodeToAppend;
            break;
        }

        if (curNode.isLeaf()) {
            return error.UnexpectedLeafNode;
        }
        try parents.append(&curNode.list);
        curNode = curNode.lastChild().?;
    }

    var i = parents.items.len;
    while (i != 0) {
        i -= 1;
        const parent = parents.items[i];
        if (_nodeToAppendOfCorrectHeight) |nodeToAppendOfCorrectHeight| {
            // Can we take the element?
            if (parent.children().len >= 3) {
                // we need to split to maintain (2,3)-tree property.
                // Send the third element + the new element to the parent.
                const newList = try ListNode.create(allocator, try parent.unappendChild(), nodeToAppendOfCorrectHeight);
                _nodeToAppendOfCorrectHeight = newList;
            } else {
                try parent.appendChild(nodeToAppendOfCorrectHeight);
                _nodeToAppendOfCorrectHeight = null;
            }
        }
    }

    if (_nodeToAppendOfCorrectHeight) |nodeToAppendOfCorrectHeight| {
        const newList = try Node.createListNode(allocator, nodeToAppendOfCorrectHeight.height() + 1);
        try newList.list.appendChild(node);
        try newList.list.appendChild(nodeToAppendOfCorrectHeight);
        return newList;
    } else {
        return node;
    }
}

fn prepend(allocator: Allocator, list: *Node, nodeToAppend: *Node) !*Node {
    var curNode = list;
    var parents = ArrayList(*ListNode).init(allocator);
    defer parents.deinit();
    while (nodeToAppend.height() != curNode.height()) {
        if (curNode.isLeaf()) {
            return error.UnexpectedLeafNode;
        }
        try parents.append(&curNode.list);
        // assert 2 <= curNode.childrenFast.length <= 3
        curNode = curNode.children()[0];
    }
    var _nodeToPrependOfCorrectHeight: ?*Node = nodeToAppend;
    // assert nodeToAppendOfCorrectHeight!.listHeight === curNode.listHeight
    var i = parents.items.len;
    while (i != 0) {
        i -= 1;
        const parent = parents.items[i];
        if (_nodeToPrependOfCorrectHeight) |nodeToPrependOfCorrectHeight| {
            // Can we take the element?
            if (parent.children().len >= 3) {
                // we need to split to maintain (2,3)-tree property.
                // Send the third element + the new element to the parent.
                _nodeToPrependOfCorrectHeight = try ListNode.create(allocator, nodeToPrependOfCorrectHeight, try parent.unprependChild());
            } else {
                try parent.prependChild(nodeToPrependOfCorrectHeight);
                _nodeToPrependOfCorrectHeight = null;
            }
        }
    }
    if (_nodeToPrependOfCorrectHeight) |nodeToPrependOfCorrectHeight| {
        return try ListNode.create(allocator, nodeToPrependOfCorrectHeight, list);
    } else {
        return list;
    }
}

fn concat(allocator: Allocator, node1: *Node, node2: *Node) !*Node {
    if (node1.height() == node2.height()) {
        return try ListNode.create(allocator, node1, node2);
    } else if (node1.height() > node2.height()) {
        // node1 is the tree we want to insert into
        return try append(allocator, node1, node2);
    } else {
        return try prepend(allocator, node2, node1);
    }
}

pub const TokenStore = struct {
    root: *Node,
    _textModel: *const TextModel,

    pub fn init(textModel: *const TextModel) !TokenStore {
        var self = TokenStore{
            .root = undefined,
            ._textModel = textModel,
        };
        self.root = try self.createEmptyRoot();
        return self;
    }

    fn getAllocator(self: *const TokenStore) Allocator {
        return self._textModel.getAllocator();
    }

    fn createEmptyRoot(self: *const TokenStore) !*Node {
        const allocator = self.getAllocator();
        return try Node.createLeafNode(allocator, self._textModel.getValueLength(null, false), null, null);
    }

    // @param update all the tokens for the document in sequence
    pub fn buildStore(self: *TokenStore, tokens: []const TokenUpdate, tokenQuality: TokenQuality) !void {
        const new_root = try self.createFromUpdates(tokens, tokenQuality);
        self.destroyNode(self.root);
        self.root = new_root;
    }

    fn createFromUpdates(self: *TokenStore, tokens: []const TokenUpdate, tokenQuality: TokenQuality) !*Node {
        if (tokens.len == 0) {
            return try self.createEmptyRoot();
        }
        const allocator = self.getAllocator();
        var newRoot = try Node.createLeafNode(allocator, tokens[0].length, tokens[0].token, tokenQuality);
        for (1..tokens.len) |j| {
            newRoot = try append(
                allocator,
                newRoot,
                try Node.createLeafNode(
                    allocator,
                    tokens[j].length,
                    tokens[j].token,
                    tokenQuality,
                ),
            );
        }
        return newRoot;
    }

    // @param tokens tokens are in sequence in the document.
    pub fn update(self: *TokenStore, length: usize, tokens: []const TokenUpdate, tokenQuality: TokenQuality) !void {
        if (tokens.len == 0) {
            return;
        }
        try self.replace(length, tokens[0].startOffsetInclusive, tokens, tokenQuality);
    }

    pub fn delete(self: *TokenStore, length: usize, startOffset: usize) !void {
        try self.replace(length, startOffset, &[_]TokenUpdate{}, .editGuess);
    }

    const NodeOffset = struct {
        node: *Node,
        offset: usize,
        parent: ?*ListNode = null,
    };

    // @param tokens tokens are in sequence in the document.
    fn replace(self: *TokenStore, length: usize, updateOffsetStart: usize, tokens: []const TokenUpdate, tokenQuality: TokenQuality) !void {
        const allocator = self.getAllocator();
        const old_root = self.root;
        const firstUnchangedOffsetAfterUpdate = updateOffsetStart + length;
        // Find the last unchanged node preceding the update
        var precedingNodes = ArrayList(*Node).init(allocator);
        defer precedingNodes.deinit();
        // Find the first unchanged node after the update
        var postcedingNodes = ArrayList(*Node).init(allocator);
        defer postcedingNodes.deinit();

        var stack = ArrayList(NodeOffset).init(allocator);
        defer stack.deinit();
        try stack.append(.{ .node = self.root, .offset = 0, .parent = null });

        while (stack.items.len > 0) {
            const tmp = stack.pop().?;
            const node = tmp.node;
            const currentOffset = tmp.offset;
            const parent = tmp.parent;

            if (currentOffset < updateOffsetStart and currentOffset + node.length() <= updateOffsetStart) {
                if (parent) |parent_node| {
                    try parent_node.detachChild(node);
                }
                node.setParent(null);
                try precedingNodes.append(node);
                continue;
            } else if (node.isLeaf() and (currentOffset < updateOffsetStart)) {
                // We have a partial preceding node
                try precedingNodes.append(
                    try Node.createLeafNode(allocator, updateOffsetStart - currentOffset, node.token(), node.tokenQuality()),
                );
                // Node could also be postceeding, so don't continue
            }

            if ((updateOffsetStart <= currentOffset) and (currentOffset + node.length() <= firstUnchangedOffsetAfterUpdate)) {
                continue;
            }

            if (currentOffset >= firstUnchangedOffsetAfterUpdate) {
                if (parent) |parent_node| {
                    try parent_node.detachChild(node);
                }
                node.setParent(null);
                try postcedingNodes.append(node);
                continue;
            } else if (node.isLeaf() and (currentOffset + node.length() > firstUnchangedOffsetAfterUpdate)) {
                // we have a partial postceeding node
                try postcedingNodes.append(
                    try Node.createLeafNode(
                        allocator,
                        currentOffset + node.length() - firstUnchangedOffsetAfterUpdate,
                        node.token(),
                        node.tokenQuality(),
                    ),
                );
                continue;
            }

            if (!node.isLeaf()) {
                // Push children in reverse order to process them left-to-right when popping
                var childOffset = currentOffset + node.length();
                var i = node.children().len;
                while (i != 0) {
                    i -= 1;
                    childOffset -= node.children()[i].length();
                    try stack.append(.{ .node = node.children()[i], .offset = childOffset, .parent = &node.list });
                }
            }
        }

        var allNodes = ArrayList(*Node).init(allocator);
        defer allNodes.deinit();
        if (tokens.len > 0) {
            try allNodes.appendSlice(precedingNodes.items);
            try allNodes.append(try self.createFromUpdates(tokens, tokenQuality));
            try allNodes.appendSlice(postcedingNodes.items);
        } else {
            try allNodes.appendSlice(precedingNodes.items);
            try allNodes.appendSlice(postcedingNodes.items);
        }
        var newRoot: ?*Node = null;
        if (allNodes.items.len > 0) {
            newRoot = allNodes.items[0];
            for (1..allNodes.items.len) |i| {
                newRoot = try concat(allocator, newRoot.?, allNodes.items[i]);
            }
        }
        self.root = newRoot orelse try self.createEmptyRoot();
        if (old_root != self.root) {
            self.destroyNode(old_root);
        }
    }
    // @param startOffsetInclusive
    // @param endOffsetExclusive
    // @param visitor Return true from visitor to exit early
    // @returns
    fn traverseInOrderInRange(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize, ctx: anytype, visitor: fn (
        ctx: @TypeOf(ctx),
        node: *Node,
        offset: usize,
    ) anyerror!bool) !void {
        const allocator = self.getAllocator();
        var stack = ArrayList(NodeOffset).init(allocator);
        defer stack.deinit();
        try stack.append(.{ .node = self.root, .offset = 0 });

        while (stack.items.len > 0) {
            const nodeOffset = stack.pop().?;
            const node = nodeOffset.node;
            const offset = nodeOffset.offset;
            const nodeEnd = offset + node.length();

            // Skip nodes that are completely before or after the range
            if (nodeEnd <= startOffsetInclusive or offset >= endOffsetExclusive) {
                continue;
            }

            if (try visitor(ctx, node, offset)) {
                return;
            }

            if (!node.isLeaf()) {
                // Push children in reverse order to process them left-to-right when popping
                var childOffset = offset + node.length();
                var i = node.children().len;
                while (i != 0) {
                    i -= 1;
                    childOffset -= node.children()[i].length();
                    try stack.append(.{ .node = node.children()[i], .offset = childOffset });
                }
            }
        }
    }

    fn getTokenAt(self: *TokenStore, offset: usize) ?TokenUpdate {
        var result: ?TokenUpdate = null;
        try self.traverseInOrderInRange(offset, self.root.length(), &result, struct {
            fn cb(ctx: *TokenUpdate, node: *Node, _offset: usize) bool {
                if (node.isLeaf()) {
                    ctx.* = .{ .token = node.token, .startOffsetInclusive = _offset, .length = node.length() };
                    return true;
                }
                return false;
            }
        }.cb);
        return result;
    }

    pub fn getTokensInRange(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize) ![]TokenUpdate {
        var result = ArrayList(TokenUpdate).init(self.getAllocator());
        defer result.deinit();

        try self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, .{ &result, startOffsetInclusive, endOffsetExclusive }, struct {
            fn cb(ctx: struct { *ArrayList(TokenUpdate), usize, usize }, node: *Node, offset: usize) anyerror!bool {
                if (node.isLeaf()) {
                    const startOffsetInclusive2 = ctx.@"1";
                    const endOffsetExclusive2 = ctx.@"2";

                    var clippedLength = node.length();
                    var clippedOffset = offset;
                    if ((offset < startOffsetInclusive2) and (offset + node.length() > endOffsetExclusive2)) {
                        clippedOffset = startOffsetInclusive2;
                        clippedLength = endOffsetExclusive2 - startOffsetInclusive2;
                    } else if (offset < startOffsetInclusive2) {
                        clippedLength -= (startOffsetInclusive2 - offset);
                        clippedOffset = startOffsetInclusive2;
                    } else if (offset + node.length() > endOffsetExclusive2) {
                        clippedLength -= (offset + node.length() - endOffsetExclusive2);
                    }
                    try ctx.@"0".append(.{ .token = node.token(), .startOffsetInclusive = clippedOffset, .length = clippedLength });
                }
                return false;
            }
        }.cb);
        return try result.toOwnedSlice();
    }

    pub fn markForRefresh(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize) void {
        try self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, {}, struct {
            fn cb(_: void, node: *Node, _: usize) bool {
                if (node.isLeaf()) {
                    node.setTokenQuality(.none);
                }
                return false;
            }
        }.cb);
    }

    pub fn rangeHasTokens(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize, minimumTokenQuality: TokenQuality) bool {
        var hasAny = true;
        self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, &hasAny, struct {
            fn cb(ctx: *bool, node: *Node, _: usize) bool {
                if (node.isLeaf() and (node.tokenQuality < minimumTokenQuality)) {
                    ctx.* = false;
                }
                return false;
            }
        }.cb);
        return hasAny;
    }

    pub fn rangeNeedsRefresh(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize) bool {
        var needsRefresh = false;
        try self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, &needsRefresh, struct {
            fn cb(ctx: *bool, node: *Node, _: usize) bool {
                if (node.isLeaf() and (node.tokenQuality() != .accurate)) {
                    ctx.* = true;
                }
                return false;
            }
        }.cb);
        return needsRefresh;
    }

    pub fn getNeedsRefresh(self: *TokenStore) ![]struct { startOffset: usize, endOffset: usize } {
        var result = ArrayList(struct { startOffset: usize, endOffset: usize }).init(self.getAllocator());
        defer result.deinit();

        try self.traverseInOrderInRange(0, self._textModel.getValueLength(), struct {
            fn cb(ctx: *ArrayList(struct { startOffset: usize, endOffset: usize }), node: *Node, offset: usize) bool {
                if (node.isLeaf() and (node.tokenQuality() != .accurate)) {
                    if (ctx.items.len > 0 and ctx.items[ctx.items.len - 1].endOffset == offset) {
                        ctx.items[ctx.items.len - 1].endOffset += node.length();
                    } else {
                        try ctx.append(.{
                            .startOffset = offset,
                            .endOffset = offset + node.length(),
                        });
                    }
                }
                return false;
            }
        }.cb);
        return try result.toOwnedSlice();
    }

    pub fn deepCopy(self: *TokenStore) !TokenStore {
        var newStore = try TokenStore.init(self._textModel);
        const new_root = try self._copyNodeIterative(self.root);
        newStore.destroyNode(newStore.root);
        newStore.root = new_root;
        return newStore;
    }

    fn _copyNodeIterative(self: *TokenStore, root: *const Node) !Node {
        const allocator = self.getAllocator();
        const newRoot = if (root.isLeaf())
            .{
                .leaf = .{
                    .length = root.length(),
                    .token = root.token(),
                    .tokenQuality = root.tokenQuality(),
                },
            }
        else
            .{ .list = ListNode.init(allocator, root.height()) };

        var stack = ArrayList([2]*Node).init(allocator);
        try stack.append([2]*Node{ root, newRoot });

        while (stack.length > 0) {
            const nodes = stack.pop().?;
            const oldNode = nodes[0];
            const clonedNode = nodes[1];
            if (!oldNode.isLeaf()) {
                for (oldNode.children()) |child| {
                    const childCopy = if (child.isLeaf())
                        .{
                            .leaf = .{
                                .length = child.length(),
                                .token = child.token(),
                                .tokenQuality = child.tokenQuality(),
                            },
                        }
                    else
                        .{ .list = ListNode.init(allocator, child.height()) };

                    clonedNode.list.appendChild(childCopy);
                    try stack.append([2]*Node{ child, childCopy });
                }
            }
        }

        return newRoot;
    }

    const NodeNumber = struct { *const Node, usize };

    // Returns a string representation of the token tree using an iterative approach
    pub fn printTree(self: *const TokenStore, _root: ?*const Node) !ArrayList(u8) {
        const allocator = self.getAllocator();
        const root = _root orelse self.root;
        var result = ArrayList(u8).init(allocator);
        var stack = ArrayList(NodeNumber).init(allocator);
        defer stack.deinit();
        try stack.append(.{ root, 0 });

        while (stack.items.len > 0) {
            const tmp = stack.pop().?;
            const node = tmp.@"0";
            const depth = tmp.@"1";

            for (0..depth) |_| {
                try result.appendSlice("  ");
            }

            if (node.isLeaf()) {
                try result.print("Leaf(length: {d}, token: {d}, refresh: {d})\n", .{ node.length(), node.token(), node.tokenQuality() });
            } else {
                try result.print("List(length: {d})\n", .{node.length()});
                // Push children in reverse order so they get processed left-to-right
                var i = node.children().len;
                while (i != 0) {
                    i -= 1;
                    try stack.append(.{ node.children()[i], depth + 1 });
                }
            }
        }

        return result;
    }

    fn destroyNode(self: *TokenStore, node: *Node) void {
        if (!node.isLeaf()) {
            defer node.deinit();
            for (node.children()) |child| {
                self.destroyNode(child);
            }
        }

        const allocator = self.getAllocator();
        allocator.destroy(node);
    }

    pub fn deinit(self: *TokenStore) void {
        self.destroyNode(self.root);
    }
};
