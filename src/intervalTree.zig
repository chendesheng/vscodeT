const std = @import("std");
const ModelDecoration = @import("model.zig").ModelDecoration;
const ModelDecorationOptions = @import("model.zig").ModelDecorationOptions;
const Range = @import("range.zig").Range;
const TrackedRangeStickiness = @import("model.zig").TrackedRangeStickiness;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const usizeSub = @import("utils.zig").usizeSub;
const usizeAdd = @import("utils.zig").usizeAdd;

pub const ClassName = enum {
    EditorHintDecoration,
    EditorInfoDecoration,
    EditorWarningDecoration,
    EditorErrorDecoration,
    EditorUnnecessaryDecoration,
    EditorUnnecessaryInlineDecoration,
    EditorDeprecatedInlineDecoration,
};

pub const NodeColor = enum(u1) {
    Black,
    Red,
};

const Metadata = packed struct {
    color: NodeColor,
    isVisited: bool,
    isForValidation: bool,
    isInGlyphMargin: bool,
    stickiness: TrackedRangeStickiness,
    collapseOnReplaceEdit: bool,
    isMargin: bool,
};

test "metadata" {
    const metadata: Metadata = .{
        .color = .Red,
        .isVisited = false,
        .isForValidation = false,
        .isInGlyphMargin = false,
        .stickiness = .NeverGrowsWhenTypingAtEdges,
        .collapseOnReplaceEdit = false,
        .isMargin = false,
    };
    try std.testing.expectEqual(metadata.color, .Red);
    try std.testing.expectEqual(metadata.isVisited, false);
    try std.testing.expectEqual(metadata.isForValidation, false);
    try std.testing.expectEqual(metadata.isInGlyphMargin, false);
    try std.testing.expectEqual(metadata.stickiness, .NeverGrowsWhenTypingAtEdges);
    try std.testing.expectEqual(metadata.collapseOnReplaceEdit, false);
    try std.testing.expectEqual(metadata.isMargin, false);
}

// Due to how deletion works (in order to avoid always walking the right subtree of the deleted node),
// the deltas for nodes can grow and shrink dramatically. It has been observed, in practice, that unless
// the deltas are corrected, integer overflow will occur.
//
// The integer overflow occurs when 53 bits are used in the numbers, but we will try to avoid it as
// a node's delta gets below a negative 30 bits number.
//
// MIN SMI (SMall Integer) as defined in v8.
// one bit is lost for boxing/unboxing flag.
// one bit is lost for sign flag.
// See https://thibaultlaurens.github.io/javascript/2013/04/29/how-the-v8-engine-works/#tagged-values
const MIN_SAFE_DELTA = -(1 << 30);
// MAX SMI (SMall Integer) as defined in v8.
// one bit is lost for boxing/unboxing flag.
// one bit is lost for sign flag.
// See https://thibaultlaurens.github.io/javascript/2013/04/29/how-the-v8-engine-works/#tagged-values
const MAX_SAFE_DELTA = 1 << 30;

pub fn getNodeColor(node: *const IntervalNode) NodeColor {
    return node.metadata.color;
}
fn setNodeColor(node: *IntervalNode, color: NodeColor) void {
    node.metadata.color = color;
}
fn getNodeIsVisited(node: *const IntervalNode) bool {
    return node.metadata.isVisited;
}
fn setNodeIsVisited(node: *IntervalNode, value: bool) void {
    node.metadata.isVisited = value;
}
fn getNodeIsForValidation(node: *const IntervalNode) bool {
    return node.metadata.isForValidation;
}
fn setNodeIsForValidation(node: *IntervalNode, value: bool) void {
    node.metadata.isForValidation = value;
}
fn getNodeIsInGlyphMargin(node: *const IntervalNode) bool {
    return node.metadata.isInGlyphMargin;
}
fn setNodeIsInGlyphMargin(node: *IntervalNode, value: bool) void {
    node.metadata.isInGlyphMargin = value;
}
fn getNodeStickiness(node: *const IntervalNode) TrackedRangeStickiness {
    return node.metadata.stickiness;
}
fn setNodeStickiness(node: *IntervalNode, stickiness: TrackedRangeStickiness) void {
    node.metadata.stickiness = stickiness;
}
fn getCollapseOnReplaceEdit(node: *const IntervalNode) bool {
    return node.metadata.collapseOnReplaceEdit;
}
fn setCollapseOnReplaceEdit(node: *IntervalNode, value: bool) void {
    node.metadata.collapseOnReplaceEdit = value;
}

pub const IntervalNode = struct {
    // contains binary encoded information for color, visited, isForValidation and stickiness.
    metadata: Metadata,

    left: *IntervalNode,
    right: *IntervalNode,
    parent: *IntervalNode,

    start: usize,
    end: usize,
    delta: isize,
    maxEnd: usize,

    id: u64,
    ownerId: usize,
    options: *ModelDecorationOptions,

    cachedVersionId: u32,
    cachedAbsoluteStart: usize,
    cachedAbsoluteEnd: usize,
    range: ?Range,

    pub fn init(allocator: Allocator, id: u64, start: usize, end: usize) !*IntervalNode {
        const node: *IntervalNode = try allocator.create(IntervalNode);
        node.* = IntervalNode{
            .metadata = .{
                .color = .Red,
                .isVisited = false,
                .isForValidation = false,
                .isInGlyphMargin = false,
                .stickiness = .NeverGrowsWhenTypingAtEdges,
                .collapseOnReplaceEdit = false,
                .isMargin = false,
            },
            .parent = node,
            .left = node,
            .right = node,
            .start = start,
            .end = end,
            .delta = 0,
            .maxEnd = end,
            .id = id,
            .ownerId = 0,
            .cachedVersionId = 0,
            .cachedAbsoluteStart = start,
            .cachedAbsoluteEnd = end,
            .range = null,
            .options = undefined,
        };
        return node;
    }

    pub fn deinit(self: *IntervalNode, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn reset(self: *IntervalNode, versionId: u32, start: usize, end: usize, range: ?Range) void {
        self.start = start;
        self.end = end;
        self.maxEnd = end;
        self.cachedVersionId = versionId;
        self.cachedAbsoluteStart = start;
        self.cachedAbsoluteEnd = end;
        self.range = range;
    }

    pub fn setOptions(self: *IntervalNode, options: *ModelDecorationOptions) void {
        self.options = options;
        const className = self.options.className;
        setNodeIsForValidation(self, (className == ClassName.EditorErrorDecoration or
            className == ClassName.EditorWarningDecoration or
            className == ClassName.EditorInfoDecoration));
        setNodeIsInGlyphMargin(self, self.options.glyphMarginClassName != null);
        if (self.options.stickiness) |stickiness| {
            setNodeStickiness(self, stickiness);
        }
        setCollapseOnReplaceEdit(self, self.options.collapseOnReplaceEdit orelse false);
    }

    pub fn setCachedOffsets(self: *IntervalNode, absoluteStart: usize, absoluteEnd: usize, cachedVersionId: u32) void {
        if (self.cachedVersionId != cachedVersionId) {
            self.range = null;
        }
        self.cachedVersionId = cachedVersionId;
        self.cachedAbsoluteStart = absoluteStart;
        self.cachedAbsoluteEnd = absoluteEnd;
    }

    pub fn detach(self: *IntervalNode) void {
        self.parent = undefined;
        self.left = undefined;
        self.right = undefined;
    }

    pub fn toModelDecoration(self: *IntervalNode) ModelDecoration {
        return ModelDecoration{
            .id = self.id,
            .ownerId = self.ownerId,
            .range = self.range.?,
            .options = self.options,
        };
    }
};

test "IntervalNode.init" {
    const allocator = std.testing.allocator;
    const node = try IntervalNode.init(allocator, 42, 0, 10);
    defer allocator.destroy(node);
    try std.testing.expectEqual(0, node.start);
    try std.testing.expectEqual(10, node.end);
    try std.testing.expectEqual(NodeColor.Red, node.metadata.color);
    try std.testing.expectEqual(TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges, node.metadata.stickiness);
}

pub const IntervalTree = struct {
    root: *IntervalNode,
    requestNormalizeDelta: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) IntervalTree {
        return IntervalTree{
            .root = SENTINEL,
            .requestNormalizeDelta = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IntervalTree) void {
        const nodes = self.getAllInOrder() catch return;
        defer nodes.deinit();
        for (nodes.items) |node| {
            if (node != SENTINEL) {
                node.deinit(self.allocator);
            }
        }
    }

    pub fn intervalSearch(self: *IntervalTree, start: usize, end: usize, filterOwnerId: usize, filterOutValidation: bool, cachedVersionId: u32, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
        if (self.root == SENTINEL) {
            return ArrayList(*IntervalNode).init(self.allocator);
        }
        return try _intervalSearch(self, start, end, filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
    }

    pub fn search(self: *IntervalTree, filterOwnerId: usize, filterOutValidation: bool, cachedVersionId: u32, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
        if (self.root == SENTINEL) {
            return ArrayList(*IntervalNode).init(self.allocator);
        }
        return try _search(self, filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
    }

    // Will not set `cachedAbsoluteStart` nor `cachedAbsoluteEnd` on the returned nodes!
    pub fn collectNodesFromOwner(self: *IntervalTree, ownerId: usize) !ArrayList(*IntervalNode) {
        return try _collectNodesFromOwner(self, ownerId);
    }

    // Will not set `cachedAbsoluteStart` nor `cachedAbsoluteEnd` on the returned nodes!
    pub fn collectNodesPostOrder(self: *IntervalTree) !ArrayList(*IntervalNode) {
        return try _collectNodesPostOrder(self);
    }

    pub fn insert(self: *IntervalTree, node: *IntervalNode) void {
        _ = rbTreeInsert(self, node);
        self._normalizeDeltaIfNecessary();
    }

    pub fn delete(self: *IntervalTree, node: *IntervalNode) void {
        rbTreeDelete(self, node);
        node.deinit(self.allocator);
        self._normalizeDeltaIfNecessary();
    }

    pub fn resolveNode(self: *IntervalTree, node: *IntervalNode, cachedVersionId: u32) void {
        var initialNode = node;
        var delta: isize = 0;
        var current = node;
        while (current != self.root) {
            if (current == current.parent.right) {
                delta += current.parent.delta;
            }
            current = current.parent;
        }

        const nodeStart = usizeAdd(initialNode.start, delta);
        const nodeEnd = usizeAdd(initialNode.end, delta);
        initialNode.setCachedOffsets(nodeStart, nodeEnd, cachedVersionId);
    }

    pub fn acceptReplace(self: *IntervalTree, offset: usize, length: usize, textLength: usize, forceMoveMarkers: bool) !void {
        // Our strategy is to remove all directly impacted nodes, and then add them back to the tree.

        // (1) collect all nodes that are intersecting this edit as nodes of interest
        const nodesOfInterest = try searchForEditing(self, offset, offset + length);
        defer nodesOfInterest.deinit();

        // (2) remove all nodes that are intersecting this edit
        for (nodesOfInterest.items) |node| {
            rbTreeDelete(self, node);
        }
        self._normalizeDeltaIfNecessary();

        // (3) edit all tree nodes except the nodes of interest
        noOverlapReplace(self, offset, offset + length, textLength);
        self._normalizeDeltaIfNecessary();

        // (4) edit the nodes of interest and insert them back in the tree
        for (nodesOfInterest.items) |node| {
            node.start = node.cachedAbsoluteStart;
            node.end = node.cachedAbsoluteEnd;
            nodeAcceptEdit(node, offset, (offset + length), textLength, forceMoveMarkers);
            node.maxEnd = node.end;
            _ = rbTreeInsert(self, node);
        }
        self._normalizeDeltaIfNecessary();
    }

    pub fn getAllInOrder(self: *IntervalTree) !ArrayList(*IntervalNode) {
        return try _search(self, 0, false, 0, false);
    }

    fn _normalizeDeltaIfNecessary(self: *IntervalTree) void {
        if (!self.requestNormalizeDelta) {
            return;
        }
        self.requestNormalizeDelta = false;
        normalizeDelta(self);
    }
};

test "IntervalTree.init" {
    const allocator = std.testing.allocator;
    var tree = IntervalTree.init(allocator);
    defer tree.deinit();
    try std.testing.expectEqual(SENTINEL, tree.root);
    try std.testing.expectEqual(false, tree.requestNormalizeDelta);
}

test "IntervalTree.insert" {
    const allocator = std.testing.allocator;
    var tree = IntervalTree.init(allocator);
    defer tree.deinit();
    const node = try IntervalNode.init(allocator, 42, 0, 10);
    tree.insert(node);
    tree.delete(node);
    try std.testing.expectEqual(SENTINEL, tree.root);
}

test "acceptReplace single" {
    const allocator = std.testing.allocator;
    var tree = IntervalTree.init(allocator);
    defer tree.deinit();
    const node = try IntervalNode.init(allocator, 42, 0, 100);
    tree.insert(node);
    try tree.acceptReplace(10, 10, 20, false);
    try std.testing.expectEqual(0, tree.root.start);
    try std.testing.expectEqual(110, tree.root.end);
}

test "acceptReplace multiple" {
    const allocator = std.testing.allocator;
    var tree = IntervalTree.init(allocator);
    defer tree.deinit();
    const node1 = try IntervalNode.init(allocator, 42, 0, 100);
    const node2 = try IntervalNode.init(allocator, 43, 150, 200);
    tree.insert(node1);
    tree.insert(node2);
    try tree.acceptReplace(80, 50, 10, false);
    const nodes = tree.getAllInOrder() catch return;
    defer nodes.deinit();
    try std.testing.expectEqual(nodes.items.len, 2);
    try std.testing.expectEqual(nodes.items[0].start, 0);
    try std.testing.expectEqual(nodes.items[0].end, 90);
    try std.testing.expectEqual(nodes.items[1].start, 110);
    try std.testing.expectEqual(nodes.items[1].end, 160);
}

var sentinelValue: IntervalNode = .{
    .metadata = .{
        .color = .Black,
        .isVisited = false,
        .isForValidation = false,
        .isInGlyphMargin = false,
        .stickiness = .NeverGrowsWhenTypingAtEdges,
        .collapseOnReplaceEdit = false,
        .isMargin = false,
    },
    .left = &sentinelValue,
    .right = &sentinelValue,
    .parent = &sentinelValue,
    .start = 0,
    .end = 0,
    .delta = 0,
    .maxEnd = 0,
    .id = undefined,
    .ownerId = 0,
    .cachedVersionId = 0,
    .cachedAbsoluteStart = 0,
    .cachedAbsoluteEnd = 0,
    .range = null,
    .options = undefined,
};
pub var SENTINEL: *IntervalNode = &sentinelValue;

//#region Delta Normalization
fn normalizeDelta(T: *IntervalTree) void {
    var node = T.root;
    var delta: isize = 0;
    while (node != SENTINEL) {
        if (node.left != SENTINEL and !getNodeIsVisited(node.left)) {
            // go left
            node = node.left;
            continue;
        }

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            delta += node.delta;
            node = node.right;
            continue;
        }

        // handle current node
        node.start = usizeAdd(node.start, delta);
        node.end = usizeAdd(node.end, delta);
        node.delta = 0;
        recomputeMaxEnd(node);

        setNodeIsVisited(node, true);

        // going up from this node
        setNodeIsVisited(node.left, false);
        setNodeIsVisited(node.right, false);
        if (node == node.parent.right) {
            delta -= node.parent.delta;
        }
        node = node.parent;
    }

    setNodeIsVisited(T.root, false);
}
//#endregion

//#region Editing

const MarkerMoveSemantics = enum(u2) { MarkerDefined = 0, ForceMove = 1, ForceStay = 2 };

fn adjustMarkerBeforeColumn(markerOffset: usize, markerStickToPreviousCharacter: bool, checkOffset: usize, moveSemantics: MarkerMoveSemantics) bool {
    if (markerOffset < checkOffset) {
        return true;
    }
    if (markerOffset > checkOffset) {
        return false;
    }
    if (moveSemantics == MarkerMoveSemantics.ForceMove) {
        return false;
    }
    if (moveSemantics == MarkerMoveSemantics.ForceStay) {
        return true;
    }
    return markerStickToPreviousCharacter;
}

// This is a lot more complicated than strictly necessary to maintain the same behaviour
// as when decorations were implemented using two markers.
fn nodeAcceptEdit(node: *IntervalNode, start: usize, end: usize, textLength: usize, forceMoveMarkers: bool) void {
    const nodeStickiness = getNodeStickiness(node);
    const startStickToPreviousCharacter = (nodeStickiness == TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges or nodeStickiness == TrackedRangeStickiness.GrowsOnlyWhenTypingBefore);
    const endStickToPreviousCharacter = (nodeStickiness == TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges or nodeStickiness == TrackedRangeStickiness.GrowsOnlyWhenTypingBefore);

    const deletingCnt = (end - start);
    const insertingCnt = textLength;
    const commonLength = @min(deletingCnt, insertingCnt);

    const nodeStart = node.start;
    var startDone = false;

    const nodeEnd = node.end;
    var endDone = false;

    if (start <= nodeStart and nodeEnd <= end and getCollapseOnReplaceEdit(node)) {
        // This edit encompasses the entire decoration range
        // and the decoration has asked to become collapsed
        node.start = start;
        startDone = true;
        node.end = start;
        endDone = true;
    }

    {
        const moveSemantics = if (forceMoveMarkers) MarkerMoveSemantics.ForceMove else if (deletingCnt > 0) MarkerMoveSemantics.ForceStay else MarkerMoveSemantics.MarkerDefined;
        if (!startDone and adjustMarkerBeforeColumn(nodeStart, startStickToPreviousCharacter, start, moveSemantics)) {
            startDone = true;
        }
        if (!endDone and adjustMarkerBeforeColumn(nodeEnd, endStickToPreviousCharacter, start, moveSemantics)) {
            endDone = true;
        }
    }

    if (commonLength > 0 and !forceMoveMarkers) {
        const moveSemantics = if (deletingCnt > insertingCnt) MarkerMoveSemantics.ForceStay else MarkerMoveSemantics.MarkerDefined;
        if (!startDone and adjustMarkerBeforeColumn(nodeStart, startStickToPreviousCharacter, start + commonLength, moveSemantics)) {
            startDone = true;
        }
        if (!endDone and adjustMarkerBeforeColumn(nodeEnd, endStickToPreviousCharacter, start + commonLength, moveSemantics)) {
            endDone = true;
        }
    }

    {
        const moveSemantics = if (forceMoveMarkers) MarkerMoveSemantics.ForceMove else MarkerMoveSemantics.MarkerDefined;
        if (!startDone and adjustMarkerBeforeColumn(nodeStart, startStickToPreviousCharacter, end, moveSemantics)) {
            node.start = start + insertingCnt;
            startDone = true;
        }
        if (!endDone and adjustMarkerBeforeColumn(nodeEnd, endStickToPreviousCharacter, end, moveSemantics)) {
            node.end = start + insertingCnt;
            endDone = true;
        }
    }

    // Finish
    const deltaColumn = usizeSub(insertingCnt, deletingCnt);
    if (!startDone) {
        node.start = @max(0, @as(isize, @intCast(nodeStart)) + deltaColumn);
    }
    if (!endDone) {
        node.end = @max(0, @as(isize, @intCast(nodeEnd)) + deltaColumn);
    }

    if (node.start > node.end) {
        node.end = node.start;
    }
}

fn searchForEditing(T: *IntervalTree, start: usize, end: usize) !ArrayList(*IntervalNode) {
    // https://en.wikipedia.org/wiki/Interval_tree#Augmented_tree
    // Now, it is known that two intervals A and B overlap only when both
    // A.low <= B.high and A.high >= B.low. When searching the trees for
    // nodes overlapping with a given interval, you can immediately skip:
    //  a) all nodes to the right of nodes whose low value is past the end of the given interval.
    //  b) all nodes that have their maximum 'high' value below the start of the given interval.
    var node = T.root;
    var delta: isize = 0;
    var nodeMaxEnd: usize = 0;
    var nodeStart: usize = 0;
    var nodeEnd: usize = 0;
    var result = ArrayList(*IntervalNode).init(T.allocator);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            if (node == node.parent.right) {
                delta -= node.parent.delta;
            }
            node = node.parent;
            continue;
        }

        if (!getNodeIsVisited(node.left)) {
            // first time seeing this node
            nodeMaxEnd = usizeAdd(node.maxEnd, delta);
            if (nodeMaxEnd < start) {
                // cover case b) from above
                // there is no need to search this node or its children
                setNodeIsVisited(node, true);
                continue;
            }

            if (node.left != SENTINEL) {
                // go left
                node = node.left;
                continue;
            }
        }

        // handle current node
        nodeStart = usizeAdd(node.start, delta);
        if (nodeStart > end) {
            // cover case a) from above
            // there is no need to search this node or its right subtree
            setNodeIsVisited(node, true);
            continue;
        }

        nodeEnd = usizeAdd(node.end, delta);
        if (nodeEnd >= start) {
            node.setCachedOffsets(nodeStart, nodeEnd, 0);
            try result.append(node);
        }
        setNodeIsVisited(node, true);

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            delta += node.delta;
            node = node.right;
            continue;
        }
    }

    setNodeIsVisited(T.root, false);

    return result;
}

fn noOverlapReplace(T: *IntervalTree, start: usize, end: usize, textLength: usize) void {
    // https://en.wikipedia.org/wiki/Interval_tree#Augmented_tree
    // Now, it is known that two intervals A and B overlap only when both
    // A.low <= B.high and A.high >= B.low. When searching the trees for
    // nodes overlapping with a given interval, you can immediately skip:
    //  a) all nodes to the right of nodes whose low value is past the end of the given interval.
    //  b) all nodes that have their maximum 'high' value below the start of the given interval.
    var node = T.root;
    var delta: isize = 0;
    var nodeMaxEnd: usize = 0;
    var nodeStart: usize = 0;
    const editDelta = usizeSub(textLength, end - start);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            if (node == node.parent.right) {
                delta -= node.parent.delta;
            }
            recomputeMaxEnd(node);
            node = node.parent;
            continue;
        }

        if (!getNodeIsVisited(node.left)) {
            // first time seeing this node
            nodeMaxEnd = usizeAdd(node.maxEnd, delta);
            if (nodeMaxEnd < start) {
                // cover case b) from above
                // there is no need to search this node or its children
                setNodeIsVisited(node, true);
                continue;
            }

            if (node.left != SENTINEL) {
                // go left
                node = node.left;
                continue;
            }
        }

        // handle current node
        nodeStart = usizeAdd(node.start, delta);
        if (nodeStart > end) {
            node.start = usizeAdd(node.start, editDelta);
            node.end = usizeAdd(node.end, editDelta);
            node.delta += editDelta;
            if (node.delta < MIN_SAFE_DELTA or node.delta > MAX_SAFE_DELTA) {
                T.requestNormalizeDelta = true;
            }
            // cover case a) from above
            // there is no need to search this node or its right subtree
            setNodeIsVisited(node, true);
            continue;
        }

        setNodeIsVisited(node, true);

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            delta += node.delta;
            node = node.right;
            continue;
        }
    }

    setNodeIsVisited(T.root, false);
}

//#endregion

//#region Searching

fn _collectNodesFromOwner(T: *IntervalTree, ownerId: usize) !ArrayList(*IntervalNode) {
    var node = T.root;
    var result = ArrayList(*IntervalNode).init(T.allocator);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            node = node.parent;
            continue;
        }

        if (node.left != SENTINEL and !getNodeIsVisited(node.left)) {
            // go left
            node = node.left;
            continue;
        }

        // handle current node
        if (node.ownerId == ownerId) {
            try result.append(node);
        }

        setNodeIsVisited(node, true);

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            node = node.right;
            continue;
        }
    }

    setNodeIsVisited(T.root, false);

    return result;
}

fn _collectNodesPostOrder(T: *IntervalTree) !ArrayList(*IntervalNode) {
    var node = T.root;
    var result = ArrayList(*IntervalNode).init(T.allocator);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            node = node.parent;
            continue;
        }

        if (node.left != SENTINEL and !getNodeIsVisited(node.left)) {
            // go left
            node = node.left;
            continue;
        }

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            node = node.right;
            continue;
        }

        // handle current node
        try result.append(node);
        setNodeIsVisited(node, true);
    }

    setNodeIsVisited(T.root, false);

    return result;
}

fn _search(T: *IntervalTree, filterOwnerId: usize, filterOutValidation: bool, cachedVersionId: u32, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
    var node = T.root;
    var delta: isize = 0;
    var nodeStart: usize = 0;
    var nodeEnd: usize = 0;
    var result = ArrayList(*IntervalNode).init(T.allocator);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            if (node == node.parent.right) {
                delta -= node.parent.delta;
            }
            node = node.parent;
            continue;
        }

        if (node.left != SENTINEL and !getNodeIsVisited(node.left)) {
            // go left
            node = node.left;
            continue;
        }

        // handle current node
        nodeStart = usizeAdd(node.start, delta);
        nodeEnd = usizeAdd(node.end, delta);

        node.setCachedOffsets(nodeStart, nodeEnd, cachedVersionId);

        var include = true;
        if (filterOwnerId != 0 and node.ownerId != 0 and node.ownerId != filterOwnerId) {
            include = false;
        }
        if (filterOutValidation and getNodeIsForValidation(node)) {
            include = false;
        }
        if (onlyMarginDecorations and !getNodeIsInGlyphMargin(node)) {
            include = false;
        }

        if (include) {
            try result.append(node);
        }

        setNodeIsVisited(node, true);

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            delta += node.delta;
            node = node.right;
            continue;
        }
    }

    setNodeIsVisited(T.root, false);

    return result;
}

fn _intervalSearch(T: *IntervalTree, intervalStart: usize, intervalEnd: usize, filterOwnerId: usize, filterOutValidation: bool, cachedVersionId: u32, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
    // https://en.wikipedia.org/wiki/Interval_tree#Augmented_tree
    // Now, it is known that two intervals A and B overlap only when both
    // A.low <= B.high and A.high >= B.low. When searching the trees for
    // nodes overlapping with a given interval, you can immediately skip:
    //  a) all nodes to the right of nodes whose low value is past the end of the given interval.
    //  b) all nodes that have their maximum 'high' value below the start of the given interval.

    var node = T.root;
    var delta: isize = 0;
    var nodeMaxEnd: usize = 0;
    var nodeStart: usize = 0;
    var nodeEnd: usize = 0;
    var result = ArrayList(*IntervalNode).init(T.allocator);
    while (node != SENTINEL) {
        if (getNodeIsVisited(node)) {
            // going up from this node
            setNodeIsVisited(node.left, false);
            setNodeIsVisited(node.right, false);
            if (node == node.parent.right) {
                delta -= node.parent.delta;
            }
            node = node.parent;
            continue;
        }

        if (!getNodeIsVisited(node.left)) {
            // first time seeing this node
            nodeMaxEnd = usizeAdd(node.maxEnd, delta);
            if (nodeMaxEnd < intervalStart) {
                // cover case b) from above
                // there is no need to search this node or its children
                setNodeIsVisited(node, true);
                continue;
            }

            if (node.left != SENTINEL) {
                // go left
                node = node.left;
                continue;
            }
        }

        // handle current node
        nodeStart = usizeAdd(node.start, delta);
        if (nodeStart > intervalEnd) {
            // cover case a) from above
            // there is no need to search this node or its right subtree
            setNodeIsVisited(node, true);
            continue;
        }

        nodeEnd = usizeAdd(node.end, delta);

        if (nodeEnd >= intervalStart) {
            // There is overlap
            node.setCachedOffsets(nodeStart, nodeEnd, cachedVersionId);

            var include = true;
            if (filterOwnerId > 0 and node.ownerId > 0 and node.ownerId != filterOwnerId) {
                include = false;
            }
            if (filterOutValidation and getNodeIsForValidation(node)) {
                include = false;
            }
            if (onlyMarginDecorations and !getNodeIsInGlyphMargin(node)) {
                include = false;
            }

            if (include) {
                try result.append(node);
            }
        }

        setNodeIsVisited(node, true);

        if (node.right != SENTINEL and !getNodeIsVisited(node.right)) {
            // go right
            delta += node.delta;
            node = node.right;
            continue;
        }
    }

    setNodeIsVisited(T.root, false);

    return result;
}

//#endregion

//#region Insertion
fn rbTreeInsert(T: *IntervalTree, newNode: *IntervalNode) *IntervalNode {
    if (T.root == SENTINEL) {
        newNode.parent = SENTINEL;
        newNode.left = SENTINEL;
        newNode.right = SENTINEL;
        setNodeColor(newNode, NodeColor.Black);
        T.root = newNode;
        return T.root;
    }

    treeInsert(T, newNode);

    recomputeMaxEndWalkToRoot(newNode.parent);

    // repair tree
    var x = newNode;
    while (x != T.root and getNodeColor(x.parent) == NodeColor.Red) {
        if (x.parent == x.parent.parent.left) {
            const y = x.parent.parent.right;

            if (getNodeColor(y) == NodeColor.Red) {
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(y, NodeColor.Black);
                setNodeColor(x.parent.parent, NodeColor.Red);
                x = x.parent.parent;
            } else {
                if (x == x.parent.right) {
                    x = x.parent;
                    leftRotate(T, x);
                }
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(x.parent.parent, NodeColor.Red);
                rightRotate(T, x.parent.parent);
            }
        } else {
            const y = x.parent.parent.left;

            if (getNodeColor(y) == NodeColor.Red) {
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(y, NodeColor.Black);
                setNodeColor(x.parent.parent, NodeColor.Red);
                x = x.parent.parent;
            } else {
                if (x == x.parent.left) {
                    x = x.parent;
                    rightRotate(T, x);
                }
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(x.parent.parent, NodeColor.Red);
                leftRotate(T, x.parent.parent);
            }
        }
    }

    setNodeColor(T.root, NodeColor.Black);

    return newNode;
}

fn treeInsert(T: *IntervalTree, z: *IntervalNode) void {
    var delta: isize = 0;
    var x = T.root;
    const zAbsoluteStart = z.start;
    const zAbsoluteEnd = z.end;
    while (true) {
        const cmp = intervalCompare(zAbsoluteStart, zAbsoluteEnd, usizeAdd(x.start, delta), usizeAdd(x.end, delta));
        if (cmp < 0) {
            // this node should be inserted to the left
            // => it is not affected by the node's delta
            if (x.left == SENTINEL) {
                z.start = usizeAdd(z.start, -delta);
                z.end = usizeAdd(z.end, -delta);
                z.maxEnd = usizeAdd(z.maxEnd, -delta);
                x.left = z;
                break;
            } else {
                x = x.left;
            }
        } else {
            // this node should be inserted to the right
            // => it is not affected by the node's delta
            if (x.right == SENTINEL) {
                z.start = usizeAdd(z.start, -(delta + x.delta));
                z.end = usizeAdd(z.end, -(delta + x.delta));
                z.maxEnd = usizeAdd(z.maxEnd, -(delta + x.delta));
                x.right = z;
                break;
            } else {
                delta += x.delta;
                x = x.right;
            }
        }
    }

    z.parent = x;
    z.left = SENTINEL;
    z.right = SENTINEL;
    setNodeColor(z, NodeColor.Red);
}
//#endregion

//#region Deletion
fn rbTreeDelete(T: *IntervalTree, z: *IntervalNode) void {
    var x: *IntervalNode = undefined;
    var y: *IntervalNode = undefined;

    // RB-DELETE except we don't swap z and y in case c)
    // i.e. we always delete what's pointed at by z.

    if (z.left == SENTINEL) {
        x = z.right;
        y = z;

        // x's delta is no longer influenced by z's delta
        x.delta += z.delta;
        if (x.delta < MIN_SAFE_DELTA or x.delta > MAX_SAFE_DELTA) {
            T.requestNormalizeDelta = true;
        }
        x.start = usizeAdd(x.start, z.delta);
        x.end = usizeAdd(x.end, z.delta);
    } else if (z.right == SENTINEL) {
        x = z.left;
        y = z;
    } else {
        y = leftest(z.right);
        x = y.right;

        // y's delta is no longer influenced by z's delta,
        // but we don't want to walk the entire right-hand-side subtree of x.
        // we therefore maintain z's delta in y, and adjust only x
        x.start = usizeAdd(x.start, y.delta);
        x.end = usizeAdd(x.end, y.delta);
        x.delta += y.delta;
        if (x.delta < MIN_SAFE_DELTA or x.delta > MAX_SAFE_DELTA) {
            T.requestNormalizeDelta = true;
        }

        y.start = usizeAdd(y.start, z.delta);
        y.end = usizeAdd(y.end, z.delta);
        y.delta = z.delta;
        if (y.delta < MIN_SAFE_DELTA or y.delta > MAX_SAFE_DELTA) {
            T.requestNormalizeDelta = true;
        }
    }

    if (y == T.root) {
        T.root = x;
        setNodeColor(x, NodeColor.Black);

        z.detach();
        resetSentinel();
        recomputeMaxEnd(x);
        T.root.parent = SENTINEL;
        return;
    }

    const yWasRed = (getNodeColor(y) == NodeColor.Red);

    if (y == y.parent.left) {
        y.parent.left = x;
    } else {
        y.parent.right = x;
    }

    if (y == z) {
        x.parent = y.parent;
    } else {
        if (y.parent == z) {
            x.parent = y;
        } else {
            x.parent = y.parent;
        }

        y.left = z.left;
        y.right = z.right;
        y.parent = z.parent;
        setNodeColor(y, getNodeColor(z));

        if (z == T.root) {
            T.root = y;
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
    }

    z.detach();

    if (yWasRed) {
        recomputeMaxEndWalkToRoot(x.parent);
        if (y != z) {
            recomputeMaxEndWalkToRoot(y);
            recomputeMaxEndWalkToRoot(y.parent);
        }
        resetSentinel();
        return;
    }

    recomputeMaxEndWalkToRoot(x);
    recomputeMaxEndWalkToRoot(x.parent);
    if (y != z) {
        recomputeMaxEndWalkToRoot(y);
        recomputeMaxEndWalkToRoot(y.parent);
    }

    // RB-DELETE-FIXUP
    var w: *IntervalNode = undefined;
    while (x != T.root and getNodeColor(x) == NodeColor.Black) {
        if (x == x.parent.left) {
            w = x.parent.right;

            if (getNodeColor(w) == NodeColor.Red) {
                setNodeColor(w, NodeColor.Black);
                setNodeColor(x.parent, NodeColor.Red);
                leftRotate(T, x.parent);
                w = x.parent.right;
            }

            if (getNodeColor(w.left) == NodeColor.Black and getNodeColor(w.right) == NodeColor.Black) {
                setNodeColor(w, NodeColor.Red);
                x = x.parent;
            } else {
                if (getNodeColor(w.right) == NodeColor.Black) {
                    setNodeColor(w.left, NodeColor.Black);
                    setNodeColor(w, NodeColor.Red);
                    rightRotate(T, w);
                    w = x.parent.right;
                }

                setNodeColor(w, getNodeColor(x.parent));
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(w.right, NodeColor.Black);
                leftRotate(T, x.parent);
                x = T.root;
            }
        } else {
            w = x.parent.left;

            if (getNodeColor(w) == NodeColor.Red) {
                setNodeColor(w, NodeColor.Black);
                setNodeColor(x.parent, NodeColor.Red);
                rightRotate(T, x.parent);
                w = x.parent.left;
            }

            if (getNodeColor(w.left) == NodeColor.Black and getNodeColor(w.right) == NodeColor.Black) {
                setNodeColor(w, NodeColor.Red);
                x = x.parent;
            } else {
                if (getNodeColor(w.left) == NodeColor.Black) {
                    setNodeColor(w.right, NodeColor.Black);
                    setNodeColor(w, NodeColor.Red);
                    leftRotate(T, w);
                    w = x.parent.left;
                }

                setNodeColor(w, getNodeColor(x.parent));
                setNodeColor(x.parent, NodeColor.Black);
                setNodeColor(w.left, NodeColor.Black);
                rightRotate(T, x.parent);
                x = T.root;
            }
        }
    }

    setNodeColor(x, NodeColor.Black);
    resetSentinel();
}

fn leftest(node: *IntervalNode) *IntervalNode {
    var current = node;
    while (current.left != SENTINEL) {
        current = current.left;
    }
    return current;
}

fn resetSentinel() void {
    SENTINEL.parent = SENTINEL;
    SENTINEL.delta = 0; // optional
    SENTINEL.start = 0; // optional
    SENTINEL.end = 0; // optional
}
//#endregion

//#region Rotations
fn leftRotate(T: *IntervalTree, x: *IntervalNode) void {
    const y = x.right; // set y.

    y.delta += x.delta; // y's delta is no longer influenced by x's delta
    if (y.delta < MIN_SAFE_DELTA or y.delta > MAX_SAFE_DELTA) {
        T.requestNormalizeDelta = true;
    }
    y.start = usizeAdd(y.start, x.delta);
    y.end = usizeAdd(y.end, x.delta);

    x.right = y.left; // turn y's left subtree into x's right subtree.
    if (y.left != SENTINEL) {
        y.left.parent = x;
    }
    y.parent = x.parent; // link x's parent to y.
    if (x.parent == SENTINEL) {
        T.root = y;
    } else if (x == x.parent.left) {
        x.parent.left = y;
    } else {
        x.parent.right = y;
    }

    y.left = x; // put x on y's left.
    x.parent = y;

    recomputeMaxEnd(x);
    recomputeMaxEnd(y);
}

fn rightRotate(T: *IntervalTree, y: *IntervalNode) void {
    var x = y.left;

    y.delta -= x.delta;
    if (y.delta < MIN_SAFE_DELTA or y.delta > MAX_SAFE_DELTA) {
        T.requestNormalizeDelta = true;
    }
    y.start = usizeAdd(y.start, -(x.delta));
    y.end = usizeAdd(y.end, -(x.delta));

    y.left = x.right;
    if (x.right != SENTINEL) {
        x.right.parent = y;
    }
    x.parent = y.parent;
    if (y.parent == SENTINEL) {
        T.root = x;
    } else if (y == y.parent.right) {
        y.parent.right = x;
    } else {
        y.parent.left = x;
    }

    x.right = y;
    y.parent = x;

    recomputeMaxEnd(y);
    recomputeMaxEnd(x);
}

fn computeMaxEnd(node: *const IntervalNode) usize {
    var maxEnd = node.maxEnd;
    if (node.left != SENTINEL) {
        const leftMaxEnd = node.left.maxEnd;
        if (leftMaxEnd > maxEnd) {
            maxEnd = leftMaxEnd;
        }
    }
    if (node.right != SENTINEL) {
        const rightMaxEnd = usizeAdd(node.right.maxEnd, node.delta);
        if (rightMaxEnd > maxEnd) {
            maxEnd = rightMaxEnd;
        }
    }
    return maxEnd;
}

pub fn recomputeMaxEnd(node: *IntervalNode) void {
    node.maxEnd = computeMaxEnd(node);
}

fn recomputeMaxEndWalkToRoot(node: *IntervalNode) void {
    var current = node;
    while (current != SENTINEL) {
        const maxEnd = computeMaxEnd(current);

        if (current.maxEnd == maxEnd) {
            // no need to go further
            return;
        }

        current.maxEnd = maxEnd;
        current = current.parent;
    }
}

pub fn intervalCompare(aStart: usize, aEnd: usize, bStart: usize, bEnd: usize) isize {
    if (aStart == bStart) {
        return usizeSub(aEnd, bEnd);
    }
    return usizeSub(aStart, bStart);
}
