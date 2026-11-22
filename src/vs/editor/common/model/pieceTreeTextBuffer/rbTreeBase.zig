// Port of `src/vs/editor/common/model/pieceTreeTextBuffer/rbTreeBase.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Piece = @import("./pieceTreeBase.zig").Piece;
const usizeSub = @import("../../../../base/common/utils.zig").usizeSub;
const usizeAdd = @import("../../../../base/common/utils.zig").usizeAdd;

pub const TreeNode = struct {
    parent: *TreeNode,
    left: *TreeNode,
    right: *TreeNode,
    color: NodeColor,

    // piece
    piece: ?Piece,
    size_left: usize,
    lf_left: usize,

    fn pieceSize(self: *const TreeNode) usize {
        return if (self.piece != null) self.piece.?.length else 0;
    }

    fn pieceLineFeedCnt(self: *const TreeNode) usize {
        return if (self.piece != null) self.piece.?.lineFeedCnt else 0;
    }

    fn isLeaf(self: *const TreeNode) bool {
        return self.left == SENTINEL and self.right == SENTINEL;
    }

    fn blackHeight(self: *const TreeNode) usize {
        if (self == SENTINEL) return 0; // FIXME: return error??

        var h: usize = 0;
        var current: ?*const TreeNode = self;
        while (current) |node| {
            if (node == SENTINEL) break;
            if (node.color == .black) {
                h += 1;
            }
            current = node.parent;
        }
        return h;
    }

    pub fn iterator(self: *TreeNode) Iterator {
        return Iterator.create(self);
    }

    pub fn next(self: *TreeNode) *TreeNode {
        if (self.right != SENTINEL) {
            return leftest(self.right);
        }

        var node = self;
        while (node.parent != SENTINEL) {
            if (node.parent.left == node) {
                break;
            }

            node = node.parent;
        }

        if (node.parent == SENTINEL) {
            return SENTINEL;
        } else {
            return node.parent;
        }
    }

    pub fn prev(self: *TreeNode) *TreeNode {
        if (self.left != SENTINEL) {
            return rightest(self.left);
        }

        var node = self;
        while (node.parent != SENTINEL) {
            if (node.parent.right == node) {
                break;
            }

            node = node.parent;
        }

        if (node.parent == SENTINEL) {
            return SENTINEL;
        } else {
            return node.parent;
        }
    }

    pub fn create(allocator: Allocator, p: ?Piece) !*TreeNode {
        const node = try allocator.create(TreeNode);
        node.* = TreeNode{
            .left = SENTINEL,
            .right = SENTINEL,
            .parent = SENTINEL,
            .size_left = 0,
            .lf_left = 0,
            .color = .red,
            .piece = p,
        };

        return node;
    }

    pub fn detach(self: *TreeNode) void {
        self.parent = undefined;
        self.left = undefined;
        self.right = undefined;
    }
};

pub const Iterator = struct {
    _root: *TreeNode,
    _next: ?*TreeNode,

    fn create(root: *TreeNode) Iterator {
        return .{
            ._root = root,
            ._next = leftest(root),
        };
    }

    pub fn next(self: *Iterator) ?*const TreeNode {
        const ret = self._next;

        if (self._next == null or self._next == SENTINEL) {
            self._next = null;
            return null;
        }

        self._next = self._next.?.next();
        return ret;
    }
};

const NodeColor = enum {
    black,
    red,
};

var sentinelValue: TreeNode = .{
    .parent = &sentinelValue,
    .left = &sentinelValue,
    .right = &sentinelValue,
    .color = .black,
    .piece = null,
    .lf_left = 0,
    .size_left = 0,
};
pub const SENTINEL: *TreeNode = &sentinelValue;

pub fn leftest(node: *TreeNode) *TreeNode {
    var current = node;
    while (current.left != SENTINEL) {
        current = current.left;
    }
    return current;
}

pub fn rightest(node: *TreeNode) *TreeNode {
    var current = node;
    while (current.right != SENTINEL) {
        current = current.right;
    }
    return current;
}

fn calculateSize(node: *TreeNode) usize {
    if (node == SENTINEL) {
        return 0;
    }

    return node.size_left + node.pieceSize() + calculateSize(node.right);
}

fn calculateLF(node: *TreeNode) usize {
    if (node == SENTINEL) {
        return 0;
    }

    return node.lf_left + node.pieceLineFeedCnt() + calculateLF(node.right);
}

fn resetSentinel() void {
    SENTINEL.parent = SENTINEL;
}

pub fn leftRotate(root: *TreeNode, x: *TreeNode) *TreeNode {
    var newRoot = root;

    var y = x.right;

    // fix size_left
    y.size_left += x.size_left + x.pieceSize();
    y.lf_left += x.lf_left + x.pieceLineFeedCnt();
    x.right = y.left;

    if (y.left != SENTINEL) {
        y.left.parent = x;
    }
    y.parent = x.parent;
    if (x.parent == SENTINEL) {
        newRoot = y;
    } else if (x.parent.left == x) {
        x.parent.left = y;
    } else {
        x.parent.right = y;
    }
    y.left = x;
    x.parent = y;

    return newRoot;
}

pub fn rightRotate(root: *TreeNode, y: *TreeNode) *TreeNode {
    var newRoot = root;

    var x = y.left;
    y.left = x.right;
    if (x.right != SENTINEL) {
        x.right.parent = y;
    }
    x.parent = y.parent;

    // fix size_left
    y.size_left -= x.size_left + x.pieceSize();
    y.lf_left -= x.lf_left + x.pieceLineFeedCnt();

    if (y.parent == SENTINEL) {
        newRoot = x;
    } else if (y == y.parent.right) {
        y.parent.right = x;
    } else {
        y.parent.left = x;
    }

    x.right = y;
    y.parent = x;

    return newRoot;
}

pub fn rbDelete(root: *TreeNode, z: *TreeNode) *TreeNode {
    var newRoot = root;
    var x: *TreeNode = undefined;
    var y: *TreeNode = undefined;

    if (z.left == SENTINEL) {
        y = z;
        x = y.right;
    } else if (z.right == SENTINEL) {
        y = z;
        x = y.left;
    } else {
        y = leftest(z.right);
        x = y.right;
    }

    if (y == newRoot) {
        newRoot = x;

        // if x is null, we are removing the only node
        x.color = .black;
        z.detach();
        resetSentinel();
        newRoot.parent = SENTINEL;

        return newRoot;
    }

    const yWasRed = y.color == .red;

    if (y == y.parent.left) {
        y.parent.left = x;
    } else {
        y.parent.right = x;
    }

    if (y == z) {
        x.parent = y.parent;
        recomputeTreeMetadata(newRoot, x);
    } else {
        if (y.parent == z) {
            x.parent = y;
        } else {
            x.parent = y.parent;
        }

        // as we make changes to x's hierarchy, update size_left of subtree first
        recomputeTreeMetadata(newRoot, x);

        y.left = z.left;
        y.right = z.right;
        y.parent = z.parent;
        y.color = z.color;

        if (z == newRoot) {
            newRoot = y;
        } else {
            if (z == z.parent.left) {
                z.parent.left = y;
            } else {
                z.parent.right = y;
            }
        }

        if (y.left != SENTINEL) {
            y.left.parent = y;
        }
        if (y.right != SENTINEL) {
            y.right.parent = y;
        }

        // update metadata
        // we replace z with y, so in this sub tree, the length change is z.item.length
        y.size_left = z.size_left;
        y.lf_left = z.lf_left;
        recomputeTreeMetadata(newRoot, y);
    }

    z.detach();

    if (x.parent.left == x) {
        const newSizeLeft = calculateSize(x);
        const newLFLeft = calculateLF(x);
        if (newSizeLeft != x.parent.size_left or newLFLeft != x.parent.lf_left) {
            const delta = usizeSub(newSizeLeft, x.parent.size_left);
            const lf_delta = usizeSub(newLFLeft, x.parent.lf_left);
            x.parent.size_left = newSizeLeft;
            x.parent.lf_left = newLFLeft;
            updateTreeMetadata(newRoot, x.parent, delta, lf_delta);
        }
    }

    recomputeTreeMetadata(newRoot, x.parent);

    if (yWasRed) {
        resetSentinel();
        return newRoot;
    }

    var w: *TreeNode = undefined;
    while (x != newRoot and x.color == .black) {
        if (x == x.parent.left) {
            w = x.parent.right;

            if (w.color == .red) {
                w.color = .black;
                x.parent.color = .red;
                newRoot = leftRotate(newRoot, x.parent);
                w = x.parent.right;
            }

            if (w.left.color == .black and w.right.color == .black) {
                w.color = .red;
                x = x.parent;
            } else {
                if (w.right.color == .black) {
                    w.left.color = .black;
                    w.color = .red;
                    newRoot = rightRotate(newRoot, w);
                    w = x.parent.right;
                }

                w.color = x.parent.color;
                x.parent.color = .black;
                w.right.color = .black;
                newRoot = leftRotate(newRoot, x.parent);
                x = newRoot;
            }
        } else {
            w = x.parent.left;

            if (w.color == .red) {
                w.color = .black;
                x.parent.color = .red;
                newRoot = rightRotate(newRoot, x.parent);
                w = x.parent.left;
            }

            if (w.left.color == .black and w.right.color == .black) {
                w.color = .red;
                x = x.parent;
            } else {
                if (w.left.color == .black) {
                    w.right.color = .black;
                    w.color = .red;
                    newRoot = leftRotate(newRoot, w);
                    w = x.parent.left;
                }

                w.color = x.parent.color;
                x.parent.color = .black;
                w.left.color = .black;
                newRoot = rightRotate(newRoot, x.parent);
                x = newRoot;
            }
        }
    }

    x.color = .black;
    resetSentinel();

    return newRoot;
}

//      node              node
//     /  \              /  \
//    a   b     ---->   a    b
//                       \
//                        z
//
pub fn insertLeft(root: *TreeNode, node: ?*TreeNode, z: *TreeNode) *TreeNode {
    var newRoot = root;
    const x = newRoot;
    if (x == SENTINEL) {
        newRoot = z;
        z.color = .black;
    } else if (node.?.left == SENTINEL) {
        node.?.left = z;
        z.parent = node.?;
    } else {
        var prevNode = rightest(node.?.left);
        prevNode.right = z;
        z.parent = prevNode;
    }

    return fixInsert(newRoot, z);
}

//
//     node              node
//    /  \              /  \
//   a   b    <----   a    b
//                        /
//                       z
//
pub fn insertRight(root: *TreeNode, node: ?*TreeNode, z: *TreeNode) *TreeNode {
    var newRoot = root;
    const x = newRoot;
    if (x == SENTINEL) {
        newRoot = z;
        z.color = .black;
    } else if (node.?.right == SENTINEL) {
        node.?.right = z;
        z.parent = node.?;
    } else {
        var nextNode = leftest(node.?.right);
        nextNode.left = z;
        z.parent = nextNode;
    }

    return fixInsert(newRoot, z);
}

fn fixInsert(root: *TreeNode, node: *TreeNode) *TreeNode {
    var x = node;
    var newRoot = root;
    recomputeTreeMetadata(newRoot, x);

    while (x != newRoot and x.parent.color == .red) {
        if (x.parent == x.parent.parent.left) {
            const y = x.parent.parent.right;

            if (y.color == .red) {
                x.parent.color = .black;
                y.color = .black;
                x.parent.parent.color = .red;
                x = x.parent.parent;
            } else {
                if (x == x.parent.right) {
                    x = x.parent;
                    newRoot = leftRotate(newRoot, x);
                }

                x.parent.color = .black;
                x.parent.parent.color = .red;
                newRoot = rightRotate(newRoot, x.parent.parent);
            }
        } else {
            const y = x.parent.parent.left;

            if (y.color == .red) {
                x.parent.color = .black;
                y.color = .black;
                x.parent.parent.color = .red;
                x = x.parent.parent;
            } else {
                if (x == x.parent.left) {
                    x = x.parent;
                    newRoot = rightRotate(newRoot, x);
                }
                x.parent.color = .black;
                x.parent.parent.color = .red;
                newRoot = leftRotate(newRoot, x.parent.parent);
            }
        }
    }

    newRoot.color = .black;
    return newRoot;
}

pub fn updateTreeMetadata(root: *TreeNode, node: *TreeNode, delta: isize, lineFeedCntDelta: isize) void {
    var x = node;
    // node length change or line feed count change
    while (x != root and x != SENTINEL) {
        if (x.parent.left == x) {
            x.parent.size_left = usizeAdd(x.parent.size_left, delta);
            x.parent.lf_left = usizeAdd(x.parent.lf_left, lineFeedCntDelta);
        }

        x = x.parent;
    }
}

fn recomputeTreeMetadata(root: *TreeNode, node: *TreeNode) void {
    var delta: isize = 0;
    var lf_delta: isize = 0;
    var x = node;

    // go upwards till the node whose left subtree is changed.
    while (x != root and x == x.parent.right) {
        x = x.parent;
    }

    if (x == root) {
        // well, it means we add a node to the end (inorder)
        return;
    }

    // x is the node whose right subtree is changed.
    x = x.parent;

    delta = usizeSub(calculateSize(x.left), x.size_left);
    lf_delta = usizeSub(calculateLF(x.left), x.lf_left);
    x.size_left = usizeAdd(x.size_left, delta);
    x.lf_left = usizeAdd(x.lf_left, lf_delta);

    // go upwards till root. O(logN)
    while (x != root and (delta != 0 or lf_delta != 0)) {
        if (x.parent.left == x) {
            x.parent.size_left = usizeAdd(x.parent.size_left, delta);
            x.parent.lf_left = usizeAdd(x.parent.lf_left, lf_delta);
        }

        x = x.parent;
    }
}

pub fn freeTree(allocator: Allocator, root: *TreeNode) void {
    if (root == SENTINEL) return;

    freeTree(allocator, root.left);
    freeTree(allocator, root.right);

    allocator.destroy(root);
}

fn mockPiece(length: usize, lineFeedCnt: usize) Piece {
    return .{
        .bufferIndex = 0,
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 0 },
        .length = length,
        .lineFeedCnt = lineFeedCnt,
    };
}

fn expectAllRedNodesChildrenAreBlack(root: *TreeNode) !void {
    var iter = root.iterator();
    while (iter.next()) |node| {
        if (node.color == .red) {
            try std.testing.expectEqual(node.left.color, .black);
            try std.testing.expectEqual(node.right.color, .black);
        }
    }
}

fn expectBlackHeightsAreEqual(root: *TreeNode) !void {
    var iter = root.iterator();
    var blackHeight: ?usize = null;
    while (iter.next()) |node| {
        if (node.isLeaf()) {
            if (blackHeight == null) {
                blackHeight = node.blackHeight();
            } else {
                try std.testing.expectEqual(blackHeight, node.blackHeight());
            }
        }
    }
}

test "total size" {
    const allocator = std.testing.allocator;
    const p = mockPiece(100, 10);
    var root = SENTINEL;
    defer freeTree(allocator, root);

    const n = 10;

    for (0..n) |_| {
        const node = try TreeNode.create(allocator, p);
        root = insertLeft(root, root, node);
    }

    const total: usize = calculateSize(root);

    try std.testing.expectEqual(n * p.length, total);
}

test "total lf" {
    const allocator = std.testing.allocator;
    const p = mockPiece(100, 10);
    var root = SENTINEL;
    defer freeTree(allocator, root);

    const n = 10;

    for (0..n) |_| {
        const node = try TreeNode.create(allocator, p);
        root = insertRight(root, root, node);
    }

    const total: usize = calculateLF(root);

    try std.testing.expectEqual(n * p.lineFeedCnt, total);
}

test "children of red nodes are black" {
    const allocator = std.testing.allocator;
    var root = SENTINEL;
    defer freeTree(allocator, root);

    const n = 100;

    for (0..n) |_| {
        const node = try TreeNode.create(allocator, null);
        root = insertLeft(root, root, node);
    }

    try expectAllRedNodesChildrenAreBlack(root);
}

test "black heights are equal" {
    const allocator = std.testing.allocator;
    var root = SENTINEL;
    defer freeTree(allocator, root);

    const n = 100;

    for (0..n) |_| {
        const node = try TreeNode.create(allocator, null);
        root = insertRight(root, root, node);
    }

    try expectBlackHeightsAreEqual(root);
}

test "delete node" {
    const allocator = std.testing.allocator;
    var root = SENTINEL;
    defer freeTree(allocator, root);

    const n = 10;
    const p = mockPiece(100, 10);

    for (0..n) |_| {
        const node = try TreeNode.create(allocator, p);
        root = insertRight(root, root, node);
    }

    const nodeToDelete = root.right;
    root = rbDelete(root, nodeToDelete);
    defer allocator.destroy(nodeToDelete);

    try std.testing.expectEqual((n - 1) * p.length, calculateSize(root));
    try std.testing.expectEqual((n - 1) * p.lineFeedCnt, calculateLF(root));
}
