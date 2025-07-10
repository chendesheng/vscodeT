const Range = @import("textModel.zig").Range;

pub const IntervalTree = struct {
    pub fn init() IntervalTree {
        return IntervalTree{};
    }
};

pub const IntervalNode = struct {
    left: *IntervalNode,
    right: *IntervalNode,
    parent: *IntervalNode,

    start: usize,
    end: usize,
    delta: usize,
    maxEnd: usize,

    id: []const u8,
    ownerId: usize,

    cachedVersionId: usize,
    cachedAbsoluteStart: usize,
    cachedAbsoluteEnd: usize,
    range: ?Range,

    pub fn init() IntervalNode {
        return IntervalNode{};
    }
};

fn computeMaxEnd(node: *const IntervalNode) usize {
    var maxEnd = node.maxEnd;
    if (node.left != null) {
        const leftMaxEnd = node.left.?.maxEnd;
        if (leftMaxEnd > maxEnd) {
            maxEnd = leftMaxEnd;
        }
    }
    if (node.right != null) {
        const rightMaxEnd = node.right.maxEnd + node.delta;
        if (rightMaxEnd > maxEnd) {
            maxEnd = rightMaxEnd;
        }
    }
    return maxEnd;
}

pub fn recomputeMaxEnd(node: *IntervalNode) void {
    node.maxEnd = computeMaxEnd(node);
}
