// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/nodeReader.ts`.
const std = @import("std");
const ArrayList = std.array_list.Managed;
const tree = @import("./bracketPairsTree.zig");

/// Finds the longest reusable child at monotonically increasing offsets.
pub const NodeReader = struct {
    nextNodes: ArrayList(*tree.AstNode),
    offsets: ArrayList(tree.Length),
    idxs: ArrayList(usize),
    lastOffset: tree.Length = 0,

    pub fn init(allocator: std.mem.Allocator, root: *tree.AstNode) NodeReader {
        var nextNodes = ArrayList(*tree.AstNode).init(allocator);
        nextNodes.append(root) catch unreachable;
        var offsets = ArrayList(tree.Length).init(allocator);
        offsets.append(0) catch unreachable;
        return .{
            .nextNodes = nextNodes,
            .offsets = offsets,
            .idxs = ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *NodeReader) void {
        self.nextNodes.deinit();
        self.offsets.deinit();
        self.idxs.deinit();
    }

    pub fn readLongestNodeAt(self: *NodeReader, offset: tree.Length, opened: tree.SmallImmutableSet, maxCacheableLength: ?tree.Length) ?*tree.AstNode {
        self.lastOffset = offset;
        while (true) {
            const curNode = last(self.nextNodes) orelse return null;
            const curNodeOffset = last(self.offsets).?;
            if (tree.lengthLessThan(offset, curNodeOffset)) return null;
            if (tree.lengthLessThan(curNodeOffset, offset)) {
                if (tree.lengthLessThanEqual(tree.lengthAdd(curNodeOffset, curNode.length), offset)) {
                    self.nextNodeAfterCurrent();
                } else if (getNextChildIdx(curNode, null)) |childIdx| {
                    self.nextNodes.append(curNode.child(childIdx).?) catch unreachable;
                    self.offsets.append(curNodeOffset) catch unreachable;
                    self.idxs.append(childIdx) catch unreachable;
                } else {
                    self.nextNodeAfterCurrent();
                }
            } else {
                const valid = if (maxCacheableLength) |maxLen| tree.lengthLessThan(curNode.length, maxLen) and curNode.canBeReused(opened) else curNode.canBeReused(opened);
                if (valid) {
                    self.nextNodeAfterCurrent();
                    return curNode;
                }
                if (getNextChildIdx(curNode, null)) |childIdx| {
                    self.nextNodes.append(curNode.child(childIdx).?) catch unreachable;
                    self.offsets.append(curNodeOffset) catch unreachable;
                    self.idxs.append(childIdx) catch unreachable;
                } else {
                    self.nextNodeAfterCurrent();
                    return null;
                }
            }
        }
    }

    fn nextNodeAfterCurrent(self: *NodeReader) void {
        while (true) {
            const currentOffset = last(self.offsets);
            const currentNode = last(self.nextNodes);
            _ = self.nextNodes.pop();
            _ = self.offsets.pop();
            if (self.idxs.items.len == 0) break;
            const parent = last(self.nextNodes).?;
            const currentIdx = self.idxs.items[self.idxs.items.len - 1];
            if (getNextChildIdx(parent, currentIdx)) |nextIdx| {
                self.nextNodes.append(parent.child(nextIdx).?) catch unreachable;
                self.offsets.append(tree.lengthAdd(currentOffset.?, currentNode.?.length)) catch unreachable;
                self.idxs.items[self.idxs.items.len - 1] = nextIdx;
                break;
            } else {
                _ = self.idxs.pop();
            }
        }
    }
};

fn last(list: anytype) ?@TypeOf(list.items[0]) {
    if (list.items.len == 0) return null;
    return list.items[list.items.len - 1];
}

fn getNextChildIdx(node: *tree.AstNode, curIdx: ?usize) ?usize {
    var index: usize = if (curIdx) |i| i + 1 else 0;
    while (index < node.childrenLength()) : (index += 1) {
        if (node.child(index) != null) return index;
    }
    return null;
}
