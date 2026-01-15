const std = @import("std");
const ArrayList = std.array_list.Managed;
const Emitter = @import("../../basics/event.zig").Emitter;
const ModelContentChangedEvent = @import("../../textModel/textModelEvents.zig").ModelContentChangedEvent;
const ModelContentChange = @import("../../textModel/textModelEvents.zig").ModelContentChange;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const gotoParent = @import("./cursorUtils.zig").gotoParent;
const getClosestPreviousNodes = @import("./cursorUtils.zig").getClosestPreviousNodes;
const nextSiblingOrParentSibling = @import("./cursorUtils.zig").nextSiblingOrParentSibling;
const gotoNthChild = @import("./cursorUtils.zig").gotoNthChild;
const Range = @import("../../basics/range.zig").Range;
const ts = @import("tree-sitter");
const TextLength = @import("../../basics/text/textLength.zig");
const PieceTreeTextBuffer = @import("../../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;

const TreeSitterTree = @This();

_tree: ?*ts.Tree = null,
onTreeParseUpdate: Emitter(TreeParseUpdateEvent),

_treeLastParsedVersion: i32 = -1,

_lastFullyParsed: ?*ts.Tree = null,
_lastFullyParsedWithEdits: ?*ts.Tree = null,

_parser: *ts.Parser,
// _injectionQuery: *ts.Query,
textModel: *TextModel,
_ranges: ?[]const ts.Range,
languageId: []const u8,

pub fn init(
    languageId: []const u8,
    _ranges: ?[]const ts.Range,
    _parser: *ts.Parser,
    // readonly treeSitterLanguage: Language,
    // /** Must have the language set! */
    // private readonly _injectionQuery: TreeSitter.Query,
    textModel: *TextModel,
) !void {
    // this._tree = observableValue(this, undefined);
    // this.tree = this._tree;

    // this._register(toDisposable(() => {
    // this._tree.get()?.delete();
    // this._lastFullyParsed?.delete();
    // this._lastFullyParsedWithEdits?.delete();
    // this._parser.delete();
    // }));
    // this.handleContentChange(undefined, this._ranges);
    var self = TreeSitterTree{
        ._tree = null,
        ._parser = _parser,
        ._ranges = _ranges,
        .textModel = textModel,
        .languageId = languageId,
    };
    try self.handleContentChange(null, _ranges);
    return self;
}

pub fn deinit(self: *TreeSitterTree) void {
    if (self._tree) |tree| {
        tree.destroy();
    }
    if (self._lastFullyParsed) |lastFullyParsed| {
        lastFullyParsed.destroy();
    }
    if (self._lastFullyParsedWithEdits) |lastFullyParsedWithEdits| {
        lastFullyParsedWithEdits.destroy();
    }
    // FIXME: is parser owned by the tree?
    self._parser.destroy();
}

pub fn handleContentChange(self: *TreeSitterTree, e: ?ModelContentChangedEvent, _ranges: ?[]const ts.Range) !void {
    const allocator = self.textModel.getAllocator();
    const version = self.textModel.getVersionId();
    var newRanges: []const ts.Range = undefined;
    if (_ranges) |rgs| {
        newRanges = try self._setRanges(rgs);
    }
    if (e != null) {
        try self._applyEdits(e.?.changes.items);
    }

    const oldTree = self._lastFullyParsed;
    var changedNodes: ?[]const ts.Range = null;
    defer if (changedNodes) |cn| {
        allocator.free(cn);
    };
    if (self._lastFullyParsedWithEdits != null and self._lastFullyParsed != null) {
        changedNodes = try self._findChangedNodes(self._lastFullyParsedWithEdits, self._lastFullyParsed);
    }

    const completed_tree = try self._parseAndUpdateTree(version);
    var rgs = ArrayList(RangeChange).init(self.textModel.getAllocator());
    defer rgs.deinit();
    if (changedNodes == null) {
        if (self._ranges) |seflRanges| {
            for (seflRanges) |r| {
                try rgs.append(.{
                    .newRange = Range.init(r.startPosition.row + 1, r.startPosition.column + 1, r.endPosition.row + 1, r.endPosition.column + 1),
                    // .oldRangeLength = r.endIndex - r.startIndex,
                    .newRangeStartOffset = r.startIndex,
                    .newRangeEndOffset = r.endIndex,
                });
            }
        }
    } else if (oldTree != null and changedNodes != null) {
        rgs = self._findTreeChanges(completed_tree, changedNodes, newRanges);
    }
    if (rgs.items.len == 0) {
        try rgs.append(.{
            .newRange = self.textModel.getFullModelRange(),
            .newRangeStartOffset = 0,
            .newRangeEndOffset = self.textModel.getValueLength(null, false),
        });
    }

    const previousTree = self._tree;
    self._tree = completed_tree;
    self.onTreeParseUpdate.fire(.{ .ranges = rgs.items, .versionId = version });
    self._treeLastParsedVersion = version;
    if (previousTree) |prevT| {
        prevT.destroy();
    }
}

fn ranges(self: *TreeSitterTree) ![]const ts.Range {
    return self._ranges;
}

fn getInjectionTrees(self: *TreeSitterTree, startIndex: usize, languageId: []const u8) !?*ts.Tree {
    _ = self;
    _ = startIndex;
    _ = languageId;
    // TODO
    return null;
}

fn _applyEdits(self: *TreeSitterTree, changes: []const ModelContentChange) !void {
    for (changes) |*change| {
        const originalTextLength = TextLength.ofRange(change.range);
        const newTextLength = change.text.toTextLength();
        const summedTextLengths = if (change.text.isEmpty()) newTextLength else originalTextLength.add(newTextLength);
        const edit = ts.InputEdit{
            .start_byte = change.rangeOffset,
            .old_end_byte = @intCast(change.rangeOffset + change.rangeLength),
            .new_end_byte = @intCast(change.rangeOffset + change.text.len()),
            .start_point = rangeStartToTSPoint(change.range),
            .old_end_point = rangeEndToTSPoint(change.range),
            .new_end_point = .{
                .row = @intCast(change.range.startLineNumber + summedTextLengths.lineCount - 1),
                .column = if (summedTextLengths.lineCount > 0)
                    @intCast(summedTextLengths.columnCount)
                else
                    @intCast(change.range.endColumn + summedTextLengths.columnCount),
            },
        };
        if (self._tree) |tree| {
            tree.edit(edit);
        }
        if (self._lastFullyParsedWithEdits) |lastFullyParsedWithEdits| {
            lastFullyParsedWithEdits.edit(edit);
        }
    }
}

fn _findChangedNodes(self: *TreeSitterTree, newTree: *ts.Tree, oldTree: *ts.Tree) ![]const ts.Range {
    if (self._ranges) |rgs| {
        const empty = &[_]ts.Range{};

        if (newTree.rootNode().startPoint().row != 0) {
            return empty;
        }

        var b = false;
        for (rgs) |r| {
            if (r.start_point.row != newTree.rootNode().startPoint().row) {
                b = true;
                break;
            }
        }

        if (b) {
            return empty;
        }
    }
    const allocator = self.textModel.getAllocator();
    const newCursor = newTree.walk();
    const oldCursor = oldTree.walk();

    var nodes: ArrayList(ts.Range) = ArrayList(ts.Range).init(allocator);
    defer nodes.deinit();
    var next = true;

    while (true) {
        if (newCursor.node().hasChanges()) {
            // Check if only one of the children has changes.
            // If it's only one, then we go to that child.
            // If it's more then, we need to go to each child
            // If it's none, then we've found one of our ranges
            const newChildren = try newCursor.node().children(newCursor, allocator);
            var indexChangedChildren = ArrayList(usize).init(allocator);
            defer indexChangedChildren.deinit();
            const changedChildren = ArrayList(*ts.Node).init(allocator);
            for (newChildren, 0..) |c, index| {
                if (c.hasChanges || (oldCursor.node().childCount() <= @as(u32, @intCast(index)))) {
                    try indexChangedChildren.append(index);
                    try changedChildren.append(c);
                }
            }
            // If we have changes and we *had* an error, the whole node should be refreshed.
            if ((changedChildren.items.len == 0) || (newCursor.node().hasError() != oldCursor.node().hasError())) {
                // walk up again until we get to the first one that's named as unnamed nodes can be too granular
                while (newCursor.node().parent and next and !newCursor.node().isNamed) {
                    next = gotoParent(newCursor, oldCursor);
                }
                // Use the end position of the previous node and the start position of the current node
                const newNode = newCursor.node();
                const closestPreviousNode = getClosestPreviousNodes(newCursor, newTree) orelse newNode;
                try nodes.append(.{
                    .start_byte = closestPreviousNode.startByte(),
                    .end_byte = newNode.endByte(),
                    .start_point = closestPreviousNode.startPoint(),
                    .end_point = newNode.endPoint(),
                });
                next = nextSiblingOrParentSibling(newCursor, oldCursor);
            } else if (changedChildren.length >= 1) {
                next = gotoNthChild(newCursor, oldCursor, indexChangedChildren.items[0]);
            }
        } else {
            next = nextSiblingOrParentSibling(newCursor, oldCursor);
        }
        if (!next) break;
    }

    newCursor.destroy();
    oldCursor.destroy();
    return try nodes.toOwnedSlice();
}

fn _findTreeChanges(self: *TreeSitterTree, newTree: *ts.Tree, changedNodes: []const ts.Range, newRanges: []const ts.Range) ![]const RangeChange {
    const allocator = self.textModel.getAllocator();
    var newRangeIndex: usize = 0;
    var mergedChanges = ArrayList(RangeChange).init(allocator);
    defer mergedChanges.deinit();

    // Find the parent in the new tree of the changed node
    for (0..changedNodes.len) |nodeIndex| {
        const node = changedNodes[nodeIndex];

        if (mergedChanges.len > 0) {
            if ((node.startIndex >= mergedChanges.getLast().newRangeStartOffset) and (node.endIndex <= mergedChanges.getLast().newRangeEndOffset)) {
                // This node is within the previous range, skip it
                continue;
            }
        }

        const cursor = newTree.walk();

        while (cursor.node().startByte() < node.start_byte and cursor.node().endByte() > node.end_byte) {
            // See if we can go to a child
            const child = cursor.gotoFirstChild();
            var foundChild = false;
            while (child) {
                if (cursor.node().startByte() < node.start_byte and cursor.node().endByte() > node.end_byte and cursor.node().isNamed()) {
                    foundChild = true;
                    break;
                } else {
                    child = cursor.gotoNextSibling();
                }
            }
            if (!foundChild) {
                _ = cursor.gotoParent();
                break;
            }
            if (cursor.node().childCount() == 0) {
                break;
            }
        }

        const startPosition = cursor.node().startPoint();
        const endPosition = cursor.node().endPoint();
        const startIndex = cursor.node().startByte();
        const endIndex = cursor.node().endByte();

        const newChange = RangeChange{
            .newRange = Range.init(
                @intCast(startPosition.row + 1),
                @intCast(startPosition.column + 1),
                @intCast(endPosition.row + 1),
                @intCast(endPosition.column + 1),
            ),
            .newRangeStartOffset = @intCast(startIndex),
            .newRangeEndOffset = @intCast(endIndex),
        };
        if ((newRangeIndex < newRanges.len) and rangesIntersect(newRanges[newRangeIndex], ts.Range{
            .start_byte = startIndex,
            .end_byte = endIndex,
            .start_point = startPosition,
            .end_point = endPosition,
        })) {
            // combine the new change with the range
            if (newRanges[newRangeIndex].start_byte < newChange.newRangeStartOffset) {
                newChange.newRange = newChange.newRange.setStartPosition(newRanges[newRangeIndex].start_point.row + 1, newRanges[newRangeIndex].start_point.column + 1);
                newChange.newRangeStartOffset = newRanges[newRangeIndex].start_byte;
            }
            if (newRanges[newRangeIndex].end_byte > newChange.newRangeEndOffset) {
                newChange.newRange = newChange.newRange.setEndPosition(newRanges[newRangeIndex].endPosition.row + 1, newRanges[newRangeIndex].endPosition.column + 1);
                newChange.newRangeEndOffset = newRanges[newRangeIndex].end_byte;
            }
            newRangeIndex += 1;
        } else if (newRangeIndex < newRanges.len and newRanges[newRangeIndex].end_byte < newChange.newRangeStartOffset) {
            // add the full range to the merged changes
            mergedChanges.append(.{
                .newRange = tsRangeToRange(newRanges[newRangeIndex]),
                .newRangeStartOffset = newRanges[newRangeIndex].start_byte,
                .newRangeEndOffset = newRanges[newRangeIndex].end_byte,
            });
        }

        if ((mergedChanges.len > 0) and (mergedChanges.getLast().newRangeEndOffset >= newChange.newRangeStartOffset)) {
            // Merge the changes
            mergedChanges.getLast().newRange = Range.fromPositions(mergedChanges.getLast().newRange.getStartPosition(), newChange.newRange.getEndPosition());
            mergedChanges.getLast().newRangeEndOffset = newChange.newRangeEndOffset;
        } else {
            try mergedChanges.append(newChange);
        }
    }
    return try self._constrainRanges(mergedChanges.items);
}

fn _constrainRanges(self: *TreeSitterTree, changes: []const RangeChange) ![]const RangeChange {
    if (self._ranges == null) {
        return changes;
    }

    const _rgs = self._ranges.?;

    var constrainedChanges = ArrayList(RangeChange).init(self.textModel.getAllocator());
    defer constrainedChanges.deinit();
    var changesIndex: usize = 0;
    var rangesIndex: usize = 0;
    while (changesIndex < changes.len and rangesIndex < _rgs.len) {
        const change = changes[changesIndex];
        const range = _rgs[rangesIndex];
        if (change.newRangeEndOffset < range.start_byte) {
            // Change is before the range, move to the next change
            changesIndex += 1;
        } else if (change.newRangeStartOffset > range.end_byte) {
            // Change is after the range, move to the next range
            rangesIndex += 1;
        } else {
            // Change is within the range, constrain it
            const newRangeStartOffset: usize = @max(change.newRangeStartOffset, @as(usize, @intCast(range.start_byte)));
            const newRangeEndOffset: usize = @min(change.newRangeEndOffset, @as(usize, @intCast(range.end_byte)));
            const newRange = change.newRange.intersectRanges(tsRangeToRange(range)).?;
            try constrainedChanges.append(.{
                .newRange = newRange,
                .newRangeEndOffset = newRangeEndOffset,
                .newRangeStartOffset = newRangeStartOffset,
            });
            // Remove the intersected range from the current change
            if (newRangeEndOffset < change.newRangeEndOffset) {
                change.newRange = Range.fromPositions(newRange.getEndPosition(), change.newRange.getEndPosition());
                change.newRangeStartOffset = newRangeEndOffset + 1;
            } else {
                // Move to the next change
                changesIndex += 1;
            }
        }
    }

    return try constrainedChanges.toOwnedSlice();
}

fn _parseAndUpdateTree(self: *TreeSitterTree, version: i32) !?*ts.Tree {
    _ = version;
    const tree = try self._parse();
    if (self._lastFullyParsed) |lastFullyParsed| {
        lastFullyParsed.destroy();
    }
    self._lastFullyParsed = tree.dupe();
    if (self._lastFullyParsedWithEdits) |lastFullyParsedWithEdits| {
        lastFullyParsedWithEdits.destroy();
    }
    self._lastFullyParsedWithEdits = tree.dupe();

    return tree;
}

fn _parse(self: *TreeSitterTree) *ts.Tree {
    return self._parser.parse(ts.Input{
        .payload = &self.textModel.getTextBuffer(),
        .read = struct {
            fn read(payload: *anyopaque, byte_index: u32, position: ts.Point, bytes_read: *u32) [*c]const u8 {
                _ = position;

                const textBuffer: *PieceTreeTextBuffer = @ptrCast(payload);
                const chunk = textBuffer.getNearestChunk(@intCast(byte_index));
                bytes_read.* = @intCast(chunk.len);
                return @ptrCast(chunk.ptr);
            }
        }.read,
    }, self._tree);
}

fn _setRanges(self: *TreeSitterTree, newRanges: []const ts.Range) ![]const ts.Range {
    const allocator = self.textModel.getAllocator();
    var unKnownRanges = ArrayList(ts.Range).init(allocator);
    defer unKnownRanges.deinit();
    // If we have existing ranges, find the parts of the new ranges that are not included in the existing ones
    if (self._ranges) {
        for (newRanges) |newRange| {
            var isFullyIncluded = false;

            for (0..self._ranges.len) |i| {
                const existingRange = self._ranges[i];

                if (rangesEqual(existingRange, newRange) or rangesIntersect(existingRange, newRange)) {
                    isFullyIncluded = true;
                    break;
                }
            }

            if (!isFullyIncluded) {
                try unKnownRanges.append(newRange);
            }
        }
    } else {
        // No existing ranges, all new ranges are unknown
        try unKnownRanges.appendSlice(newRanges);
    }

    self._ranges = newRanges;
    return try unKnownRanges.toOwnedSlice();
}

// pub fn createParsedTreeSync(self: *TreeSitterTree, src: []const u8) !?*ts.Tree {
//     const parser = try ts.Parser.new();
//     parser.setLanguage(try self._parser.language());
//     const tree = try parser.parse(src);
//     parser.delete();
//     return tree;
// }

pub const TreeParseUpdateEvent = struct {
    ranges: []const RangeChange,
    versionId: i32,
};

pub const RangeWithOffsets = struct {
    range: Range,
    startOffset: usize,
    endOffset: usize,
};

pub const RangeChange = struct {
    newRange: Range,
    newRangeStartOffset: usize,
    newRangeEndOffset: usize,
};

pub fn rangesEqual(a: ts.Range, b: ts.Range) bool {
    return (a.startPosition.row == b.startPosition.row) and (a.startPosition.column == b.startPosition.column) and (a.endPosition.row == b.endPosition.row) and (a.endPosition.column == b.endPosition.column) and (a.startIndex == b.startIndex) and (a.endIndex == b.endIndex);
}

pub fn rangesIntersect(a: ts.Range, b: ts.Range) bool {
    return (a.startIndex <= b.startIndex and a.endIndex >= b.startIndex) or
        (b.startIndex <= a.startIndex and b.endIndex >= a.startIndex);
}

fn rangeStartToTSPoint(range: ts.Range) ts.Point {
    return .{ .row = @intCast(range.startPosition.row - 1), .column = @intCast(range.startPosition.column - 1) };
}

fn rangeEndToTSPoint(range: ts.Range) ts.Point {
    return .{ .row = @intCast(range.endPosition.row - 1), .column = @intCast(range.endPosition.column - 1) };
}

fn tsRangeToRange(range: ts.Range) Range {
    return Range.init(
        range.start_point.row + 1,
        range.start_point.column + 1,
        range.end_point.row + 1,
        range.end_point.column + 1,
    );
}
