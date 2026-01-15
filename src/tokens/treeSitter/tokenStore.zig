const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const usizeAdd = @import("../../basics/utils.zig").usizeAdd;

pub const ListNode = struct {
    parent: ?*ListNode,
    height: usize,
    _children: ArrayList(*Node),
    _length: usize,

    pub fn init(allocator: Allocator, height: usize) ListNode {
        return .{
            .parent = null,
            .height = height,
            ._children = ArrayList(*Node).initCapacity(allocator, 3),
            ._length = 0,
        };
    }

    pub fn create(node1: *Node, node2: *Node) ListNode {
        const list = ListNode.init(node1.allocator, node1.height + 1);
        list.appendChild(node1);
        list.appendChild(node2);
        return list;
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
        self._updateParentLength(node.length());
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
        self._updateParentLength(-child.length());
        return child;
    }

    pub fn prependChild(self: *ListNode, node: *Node) !void {
        if (self._children.items.len >= 3) {
            return error.CannotPrependMoreThan3Children;
        }
        try self._children.insert(0, node);

        self._length += node.length();
        self._updateParentLength(node.length());
        if (!node.isLeaf()) {
            node.setParent(self);
        }
    }

    pub fn unprependChild(self: *ListNode) !*Node {
        const child = self._children.orderedRemove(0);
        self._length -= child.length();
        self._updateParentLength(-child.length());
        return child;
    }

    pub fn lastChild(self: *const ListNode) *Node {
        return self._children.getLast();
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
    token: usize,
    tokenQuality: TokenQuality,
};

pub const Node = union {
    list: ListNode,
    leaf: LeafNode,

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
            .list => self.list._children.items,
            .leaf => &[_]*Node{},
        };
    }

    pub fn token(self: *const Node) usize {
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
};

pub const TokenUpdate = struct {
    startOffsetInclusive: usize,
    length: usize,
    token: usize,
};

// Heavily inspired by https://github.com/microsoft/vscode/blob/4eb2658d592cb6114a7a393655574176cc790c5b/src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/concat23Trees.ts#L108-L109
fn append(allocator: Allocator, node: *Node, nodeToAppend: *const Node) !Node {
    var curNode = node;
    var parents = ArrayList(*ListNode).init(allocator);
    var _nodeToAppendOfCorrectHeight: ?*Node = null;
    while (true) {
        if (nodeToAppend.height() == curNode.height()) {
            _nodeToAppendOfCorrectHeight = nodeToAppend;
            break;
        }

        if (curNode.isLeaf()) {
            return error.UnexpectedLeafNode;
        }
        try parents.append(curNode);
        curNode = curNode.lastChild().?;
    }
    var i = parents.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const parent = parents.items[i];
        if (_nodeToAppendOfCorrectHeight) |nodeToAppendOfCorrectHeight| {
            // Can we take the element?
            if (parent.children.length >= 3) {
                // we need to split to maintain (2,3)-tree property.
                // Send the third element + the new element to the parent.
                const newList = ListNode.create(parent.unappendChild(), nodeToAppendOfCorrectHeight);
                _nodeToAppendOfCorrectHeight = .{ .list = newList };
            } else {
                parent.appendChild(nodeToAppendOfCorrectHeight);
                _nodeToAppendOfCorrectHeight = null;
            }
        }
    }
    if (_nodeToAppendOfCorrectHeight) |nodeToAppendOfCorrectHeight| {
        const newList = ListNode.init(allocator, nodeToAppendOfCorrectHeight.height() + 1);
        try newList.appendChild(node);
        try newList.appendChild(nodeToAppendOfCorrectHeight);
        return .{ .list = newList };
    } else {
        return node;
    }
}

fn prepend(allocator: Allocator, list: *Node, nodeToAppend: *const Node) !Node {
    var curNode = list;
    var parents = ArrayList(*ListNode).init(allocator);
    while (nodeToAppend.height() != curNode.height()) {
        if (curNode.isLeaf()) {
            return error.UnexpectedLeafNode;
        }
        try parents.append(curNode);
        // assert 2 <= curNode.childrenFast.length <= 3
        curNode = curNode.children()[0];
    }
    var _nodeToPrependOfCorrectHeight: ?*Node = nodeToAppend;
    // assert nodeToAppendOfCorrectHeight!.listHeight === curNode.listHeight
    var i = parents.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const parent = parents.items[i];
        if (_nodeToPrependOfCorrectHeight) |nodeToPrependOfCorrectHeight| {
            // Can we take the element?
            if (parent.children.length >= 3) {
                // we need to split to maintain (2,3)-tree property.
                // Send the third element + the new element to the parent.
                _nodeToPrependOfCorrectHeight = ListNode.create(nodeToPrependOfCorrectHeight, parent.unprependChild());
            } else {
                parent.prependChild(nodeToPrependOfCorrectHeight);
                _nodeToPrependOfCorrectHeight = null;
            }
        }
    }
    if (_nodeToPrependOfCorrectHeight) |nodeToPrependOfCorrectHeight| {
        return ListNode.create(nodeToPrependOfCorrectHeight, list);
    } else {
        return list;
    }
}

fn concat(allocator: Allocator, node1: *Node, node2: *const Node) !Node {
    if (node1.height() == node2.height()) {
        return .{ .list = ListNode.create(node1, node2) };
    } else if (node1.height() > node2.height()) {
        // node1 is the tree we want to insert into
        return append(allocator, node1, node2);
    } else {
        return prepend(allocator, node2, node1);
    }
}

pub const TokenStore = struct {
    allocator: Allocator,
    root: *Node,
    _textModel: *const TextModel,

    pub fn init(allocator: Allocator, textModel: *const TextModel) TokenStore {
        var self = TokenStore{
            .allocator = allocator,
            .root = undefined,
            ._textModel = textModel,
        };
        self.root = self.createEmptyRoot();
        return self;
    }

    fn createEmptyRoot(self: *TokenStore) Node {
        return .{
            .leaf = .{
                .length = self._textModel.getValueLength(null, false),
                .token = 0,
                .tokenQuality = .none,
            },
        };
    }

    // @param update all the tokens for the document in sequence
    fn buildStore(self: *TokenStore, tokens: []const TokenUpdate, tokenQuality: TokenQuality) void {
        self._root = self.createFromUpdates(tokens, tokenQuality);
    }

    fn createFromUpdates(self: *TokenStore, tokens: []const TokenUpdate, tokenQuality: TokenQuality) Node {
        if (tokens.len == 0) {
            return self.createEmptyRoot();
        }
        var newRoot: Node = .{
            .leaf = .{
                .length = tokens[0].length,
                .token = tokens[0].token,
                .tokenQuality = tokenQuality,
            },
        };
        for (1..tokens.len) |j| {
            newRoot = append(newRoot, .{
                .length = tokens[j].length,
                .token = tokens[j].token,
                .height = 0,
                .tokenQuality = tokenQuality,
            });
        }
        return newRoot;
    }

    // @param tokens tokens are in sequence in the document.
    fn update(self: *TokenStore, length: usize, tokens: []const TokenUpdate, tokenQuality: TokenQuality) void {
        if (tokens.len == 0) {
            return;
        }
        self.replace(length, tokens[0].startOffsetInclusive, tokens, tokenQuality);
    }

    fn delete(self: *TokenStore, length: usize, startOffset: usize) void {
        self.replace(length, startOffset, &[_]TokenUpdate{}, TokenQuality.EditGuess);
    }

    const NodeOffset = struct {
        node: *Node,
        offset: usize,
    };

    // @param tokens tokens are in sequence in the document.
    fn replace(self: *TokenStore, length: usize, updateOffsetStart: usize, tokens: []const TokenUpdate, tokenQuality: TokenQuality) !void {
        const allocator = self.allocator;
        const firstUnchangedOffsetAfterUpdate = updateOffsetStart + length;
        // Find the last unchanged node preceding the update
        var precedingNodes = ArrayList(Node).init(self.allocator);
        // Find the first unchanged node after the update
        var postcedingNodes = ArrayList(Node).init(self.allocator);
        var stack = ArrayList(NodeOffset).init(self.allocator);
        try stack.append(.{ .node = self.root, .offset = 0 });

        while (stack.len > 0) {
            const node = stack.pop().?;
            const currentOffset = node.offset;

            if (currentOffset < updateOffsetStart and currentOffset + node.node.length() <= updateOffsetStart) {
                if (!node.node.isLeaf()) {
                    node.node.setParent(null);
                }
                precedingNodes.push(node.node);
                continue;
            } else if (node.node.isLeaf() and (currentOffset < updateOffsetStart)) {
                // We have a partial preceding node
                try precedingNodes.append(
                    .{ .node = node.node, .length = updateOffsetStart - currentOffset, .token = node.node.token, .height = 0, .tokenQuality = node.node.tokenQuality },
                );
                // Node could also be postceeding, so don't continue
            }

            if ((updateOffsetStart <= currentOffset) and (currentOffset + node.node.length() <= firstUnchangedOffsetAfterUpdate)) {
                continue;
            }

            if (currentOffset >= firstUnchangedOffsetAfterUpdate) {
                if (!node.node.isLeaf()) {
                    node.node.setParent(null);
                }
                postcedingNodes.push(node.node);
                continue;
            } else if (node.node.isLeaf() and (currentOffset + node.node.length() > firstUnchangedOffsetAfterUpdate)) {
                // we have a partial postceeding node
                try postcedingNodes.append(
                    .{ .node = node.node, .length = currentOffset + node.node.length() - firstUnchangedOffsetAfterUpdate, .token = node.node.token, .height = 0, .tokenQuality = node.node.tokenQuality },
                );
                continue;
            }

            if (!node.node.isLeaf()) {
                // Push children in reverse order to process them left-to-right when popping
                var childOffset = currentOffset + node.node.length();
                var i = node.node.children().len - 1;
                while (i >= 0) : (i -= 1) {
                    childOffset -= node.node.children()[i].length();
                    try stack.append(.{ .node = node.node.children()[i], .offset = childOffset });
                }
            }
        }

        var allNodes = ArrayList(Node).init(allocator);
        if (tokens.length > 0) {
            allNodes = precedingNodes.concat(self.createFromUpdates(tokens, tokenQuality), postcedingNodes);
        } else {
            allNodes = precedingNodes.concat(postcedingNodes);
        }
        var newRoot: Node = allNodes[0];
        for (1..allNodes.len) |i| {
            newRoot = concat(newRoot, allNodes[i]);
        }

        self.root = &newRoot orelse &self.createEmptyRoot();
    }
    // @param startOffsetInclusive
    // @param endOffsetExclusive
    // @param visitor Return true from visitor to exit early
    // @returns
    fn traverseInOrderInRange(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize, ctx: anytype, visitor: fn (
        ctx: @TypeOf(ctx),
        node: *Node,
        offset: usize,
    ) bool) void {
        const allocator = self.allocator;
        var stack = ArrayList(NodeOffset).init(allocator);
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

            if (visitor(ctx, node, offset)) {
                return;
            }

            if (!node.isLeaf()) {
                // Push children in reverse order to process them left-to-right when popping
                var childOffset = offset + node.length();
                var i = node.children().len - 1;
                while (i >= 0) : (i -= 1) {
                    childOffset -= node.children()[i].length();
                    try stack.append(.{ .node = node.children()[i], .offset = childOffset });
                }
            }
        }
    }

    fn getTokenAt(self: *TokenStore, offset: usize) ?TokenUpdate {
        var result: ?TokenUpdate = null;
        self.traverseInOrderInRange(offset, self.root.length(), &result, struct {
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
        var result = ArrayList(TokenUpdate).init(self.allocator);
        defer result.deinit();

        self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, &result, struct {
            fn cb(ctx: *ArrayList(TokenUpdate), node: *Node, offset: usize) bool {
                if (node.isLeaf()) {
                    var clippedLength = node.length();
                    var clippedOffset = offset;
                    if ((offset < startOffsetInclusive) and (offset + node.length > endOffsetExclusive)) {
                        clippedOffset = startOffsetInclusive;
                        clippedLength = endOffsetExclusive - startOffsetInclusive;
                    } else if (offset < startOffsetInclusive) {
                        clippedLength -= (startOffsetInclusive - offset);
                        clippedOffset = startOffsetInclusive;
                    } else if (offset + node.length > endOffsetExclusive) {
                        clippedLength -= (offset + node.length - endOffsetExclusive);
                    }
                    try ctx.append(.{ .token = node.token, .startOffsetInclusive = clippedOffset, .length = clippedLength });
                }
                return false;
            }
        }.cb);
        return try result.toOwnedSlice();
    }

    pub fn markForRefresh(self: *TokenStore, startOffsetInclusive: usize, endOffsetExclusive: usize) void {
        self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, {}, struct {
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
        self.traverseInOrderInRange(startOffsetInclusive, endOffsetExclusive, &needsRefresh, struct {
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
        var result = ArrayList(struct { startOffset: usize, endOffset: usize }).init(self.allocator);
        defer result.deinit();

        self.traverseInOrderInRange(0, self._textModel.getValueLength(), struct {
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
        const newStore = try TokenStore.init(self.allocator, self._textModel);
        newStore.root = try self._copyNodeIterative(self.root);
        return newStore;
    }

    fn _copyNodeIterative(self: *TokenStore, root: *const Node) !Node {
        const newRoot = if (root.isLeaf())
            .{
                .leaf = .{
                    .length = root.length(),
                    .token = root.token(),
                    .tokenQuality = root.tokenQuality(),
                },
            }
        else
            .{ .list = ListNode.init(self.allocator, root.height()) };

        var stack = ArrayList([2]*Node).init(self.allocator);
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
                        .{ .list = ListNode.init(self.allocator, child.height()) };

                    clonedNode.list.appendChild(childCopy);
                    try stack.append([2]*Node{ child, childCopy });
                }
            }
        }

        return newRoot;
    }

    const NodeNumber = struct { *Node, usize };

    // Returns a string representation of the token tree using an iterative approach
    pub fn printTree(self: *const TokenStore, _root: ?*const Node) ArrayList(u8) {
        const root = _root orelse self.rootk;
        var result = ArrayList(u8).init(self.allocator);
        var stack = ArrayList(NodeNumber).init(self.allocator);
        try stack.append(.{ root, 0 });

        while (stack.length > 0) {
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
                var i = node.children().len - 1;
                while (i >= 0) : (i -= 1) {
                    try stack.append(.{ node.children()[i], depth + 1 });
                }
            }
        }

        return result;
    }

    pub fn dispose(self: *TokenStore) void {
        var stack = ArrayList(struct { *Node, bool }).init(self.allocator);
        try stack.append(.{ self.root, false });
        while (stack.length > 0) {
            const tmp = stack.pop().?;
            const node = tmp.@"0";
            const visited = tmp.@"1";
            if (node.isLeaf()) {
                // leaf node does not need to be disposed
            } else if (!visited) {
                try stack.append(.{ node, true });
                for (node.children()) |child| {
                    try stack.append(.{ child, false });
                }
            } else {
                node.setParent(null);
            }
        }
        self.root = undefined;
    }
};
