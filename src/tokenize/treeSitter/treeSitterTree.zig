const std = @import("std");
const ArrayList = std.array_list.Managed;
const TextLength = @import("../../basics/textLength.zig").TextLength;
const ModelContentChangedEvent = @import("../../textModel/textModelEvents.zig").ModelContentChangedEvent;
const ModelContentChange = @import("../../textModel/textModelEvents.zig").ModelContentChange;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const gotoParent = @import("./cursorUtils.zig").gotoParent;
const getClosestPreviousNodes = @import("./cursorUtils.zig").getClosestPreviousNodes;
const nextSiblingOrParentSibling = @import("./cursorUtils.zig").nextSiblingOrParentSibling;
const gotoNthChild = @import("./cursorUtils.zig").gotoNthChild;
const Range = @import("../../basics/range.zig").Range;
const ts = @import("tree-sitter");

pub const TreeSitterTree = struct {
    _tree: ?*ts.Tree = null,
    _treeLastParsedVersion: i32 = -1,

    _lastFullyParsed: ?*ts.Tree = null,
    _lastFullyParsedWithEdits: ?*ts.Tree = null,

    // private _onDidChangeContentQueue: TaskQueue = new TaskQueue();

    _parser: *ts.Parser,
    _injectionQuery: *ts.Query,
    textModel: *TextModel,

    pub fn init(
        languageId: []const u8,
        _ranges: []const ts.Range,
        // readonly treeSitterLanguage: Language,
        // /** Must have the language set! */
        // private readonly _injectionQuery: TreeSitter.Query,
        textModel: *TextModel,
    ) !void {
        _ = languageId;
        _ = _ranges;
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
            ._tree = undefined,
            ._parser = undefined,
            ._injectionQuery = undefined,
            .textModel = textModel,
        };
        self._tree = try ts.Tree.new();
        self._parser = try ts.Parser.new();
        self._injectionQuery = try ts.Query.new();
        return self;
    }

    pub fn handleContentChange(self: *TreeSitterTree, e: ?ModelContentChangedEvent, _ranges: ?[]const ts.Range) !void {
        const version = self.textModel.getVersionId();
        var newRanges: []const ts.Range = undefined;
        if (_ranges) |rgs| {
            newRanges = try self._setRanges(rgs);
        }
        if (e != null) {
            try self._applyEdits(e.?.changes.items);
        }

        const oldTree = self._lastFullyParsed;
        var changedNodes: ?[]const ts.Range = undefined;
        if (self._lastFullyParsedWithEdits and self._lastFullyParsed) {
            changedNodes = try self._findChangedNodes(self._lastFullyParsedWithEdits, self._lastFullyParsed);
        }

        const completed_tree = try self._parseAndUpdateTree(version);
        var rgs = ArrayList(RangeChange).init(self.textModel.getAllocator());
        defer rgs.deinit();
        if (!changedNodes) {
            if (self._ranges) {
                // ranges = this._ranges.map(r => ({ newRange: new Range(r.startPosition.row + 1, r.startPosition.column + 1, r.endPosition.row + 1, r.endPosition.column + 1), oldRangeLength: r.endIndex - r.startIndex, newRangeStartOffset: r.startIndex, newRangeEndOffset: r.endIndex }));
            }
        } else if (oldTree and changedNodes) {
            rgs = self._findTreeChanges(completed_tree, changedNodes, newRanges);
        }
        if (rgs.items.len == 0) {
            // rgs = [{ newRange: this.textModel.getFullModelRange(), newRangeStartOffset: 0, newRangeEndOffset: this.textModel.getValueLength() }];
        }

        const previousTree = self._tree;
        self._tree = completed_tree;
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
            const originalTextLength = TextLength.ofRange(Range.lift(change.range));
            const newTextLength = TextLength.ofText(change.text);
            const summedTextLengths = if (change.text.isEmpty()) newTextLength else originalTextLength.add(newTextLength);
            const edit = ts.InputEdit{
                .start_byte = change.rangeOffset,
                .old_end_byte = @intCast(change.rangeOffset + change.rangeLength),
                .new_end_byte = @intCast(change.rangeOffset + change.text.length),
                .start_point = .{ .row = @intCast(change.range.startLineNumber - 1), .column = @intCast(change.range.startColumn - 1) },
                .old_end_point = .{ .row = @intCast(change.range.endLineNumber - 1), .column = @intCast(change.range.endColumn - 1) },
                .new_end_point = .{
                    .row = @intCast(change.range.startLineNumber + summedTextLengths.lineCount - 1),
                    .column = if (summedTextLengths.lineCount > 0) @intCast(summedTextLengths.columnCount) else @intCast(change.range.endColumn + summedTextLengths.columnCount),
                },
            };
            self._tree.?.edit(edit);
            if (self._lastFullyParsedWithEdits) |lastFullyParsedWithEdits| {
                lastFullyParsedWithEdits.edit(edit);
            }
        }
    }

    fn _findChangedNodes(self: *TreeSitterTree, newTree: *ts.Tree, oldTree: *ts.Tree) ![]const ts.Range {
        // if ((self._ranges && self._ranges.every(range => range.startPosition.row != newTree.rootNode.startPosition.row)) || newTree.rootNode.startPosition.row != 0) {
        // return [];
        // }
        const allocator = self.textModel.getAllocator();
        const newCursor = try newTree.walk();
        const oldCursor = try oldTree.walk();

        var nodes: []const ts.Range = undefined;
        var next = true;

        while (true) {
            if (newCursor.node().hasChanges) {
                // Check if only one of the children has changes.
                // If it's only one, then we go to that child.
                // If it's more then, we need to go to each child
                // If it's none, then we've found one of our ranges
                const newChildren = newCursor.node().children;
                var indexChangedChildren: []const usize = undefined;
                const changedChildren = ArrayList(*ts.Node).init(allocator);
                for (newChildren, 0..) |c, index| {
                    if (c.hasChanges || (oldCursor.node().children.len <= index)) {
                        try indexChangedChildren.append(index);
                        try changedChildren.append(c);
                    }
                }
                // If we have changes and we *had* an error, the whole node should be refreshed.
                if ((changedChildren.length == 0) || (newCursor.node().hasError != oldCursor.node().hasError)) {
                    // walk up again until we get to the first one that's named as unnamed nodes can be too granular
                    while (newCursor.node().parent and next and !newCursor.node().isNamed) {
                        next = gotoParent(newCursor, oldCursor);
                    }
                    // Use the end position of the previous node and the start position of the current node
                    const newNode = newCursor.node();
                    const closestPreviousNode = getClosestPreviousNodes(newCursor, newTree) orelse newNode;
                    nodes.push(.{ .startIndex = closestPreviousNode.startIndex, .endIndex = newNode.endIndex, .startPosition = closestPreviousNode.startPosition, .endPosition = newNode.endPosition });
                    next = nextSiblingOrParentSibling(newCursor, oldCursor);
                } else if (changedChildren.length >= 1) {
                    next = gotoNthChild(newCursor, oldCursor, indexChangedChildren[0]);
                }
            } else {
                next = nextSiblingOrParentSibling(newCursor, oldCursor);
            }
            if (!next) break;
        }

        newCursor.delete();
        oldCursor.delete();
        return nodes.items;
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

            while (cursor.startIndex < node.startIndex and cursor.endIndex > node.endIndex) {
                // See if we can go to a child
                const child = cursor.gotoFirstChild();
                var foundChild = false;
                while (child) {
                    if (cursor.startIndex < node.startIndex and cursor.endIndex > node.endIndex and cursor.node().isNamed) {
                        foundChild = true;
                        break;
                    } else {
                        child = cursor.gotoNextSibling();
                    }
                }
                if (!foundChild) {
                    cursor.gotoParent();
                    break;
                }
                if (cursor.node().childCount == 0) {
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
                if (newRanges[newRangeIndex].startIndex < newChange.newRangeStartOffset) {
                    newChange.newRange = newChange.newRange.setStartPosition(newRanges[newRangeIndex].startPosition.row + 1, newRanges[newRangeIndex].startPosition.column + 1);
                    newChange.newRangeStartOffset = newRanges[newRangeIndex].startIndex;
                }
                if (newRanges[newRangeIndex].endIndex > newChange.newRangeEndOffset) {
                    newChange.newRange = newChange.newRange.setEndPosition(newRanges[newRangeIndex].endPosition.row + 1, newRanges[newRangeIndex].endPosition.column + 1);
                    newChange.newRangeEndOffset = newRanges[newRangeIndex].endIndex;
                }
                newRangeIndex += 1;
            } else if (newRangeIndex < newRanges.len and newRanges[newRangeIndex].endIndex < newChange.newRangeStartOffset) {
                // add the full range to the merged changes
                mergedChanges.append(.{ .newRange = Range.init(newRanges[newRangeIndex].startPosition.row + 1, newRanges[newRangeIndex].startPosition.column + 1, newRanges[newRangeIndex].endPosition.row + 1, newRanges[newRangeIndex].endPosition.column + 1), .newRangeStartOffset = newRanges[newRangeIndex].startIndex, .newRangeEndOffset = newRanges[newRangeIndex].endIndex });
            }

            if ((mergedChanges.len > 0) and (mergedChanges.getLast().newRangeEndOffset >= newChange.newRangeStartOffset)) {
                // Merge the changes
                mergedChanges.getLast().newRange = Range.fromPositions(mergedChanges.getLast().newRange.getStartPosition(), newChange.newRange.getEndPosition());
                mergedChanges.getLast().newRangeEndOffset = newChange.newRangeEndOffset;
            } else {
                mergedChanges.append(newChange);
            }
        }
        return try self._constrainRanges(mergedChanges.items);
    }

    fn _constrainRanges(self: *TreeSitterTree, changes: []const RangeChange) ![]const RangeChange {
        if (!self._ranges) {
            return changes;
        }

        var constrainedChanges = ArrayList(RangeChange).init(self.textModel.getAllocator());
        defer constrainedChanges.deinit();
        var changesIndex: usize = 0;
        var rangesIndex: usize = 0;
        while (changesIndex < changes.len and rangesIndex < self._ranges.len) {
            const change = changes[changesIndex];
            const range = self._ranges[rangesIndex];
            if (change.newRangeEndOffset < range.startIndex) {
                // Change is before the range, move to the next change
                changesIndex += 1;
            } else if (change.newRangeStartOffset > range.endIndex) {
                // Change is after the range, move to the next range
                rangesIndex += 1;
            } else {
                // Change is within the range, constrain it
                const newRangeStartOffset = @max(change.newRangeStartOffset, range.startIndex);
                const newRangeEndOffset = @min(change.newRangeEndOffset, range.endIndex);
                const newRange = change.newRange.intersectRanges(Range.init(range.startPosition.row + 1, range.startPosition.column + 1, range.endPosition.row + 1, range.endPosition.column + 1)).?;
                try constrainedChanges.append(.{
                    .newRange = newRange,
                    .newRangeEndOffset = newRangeEndOffset,
                    .newRangeStartOffset = newRangeStartOffset,
                });
                // Remove the intersected range from the current change
                if (newRangeEndOffset < change.newRangeEndOffset) {
                    change.newRange = Range.init(newRange.getEndPosition().row + 1, newRange.getEndPosition().column + 1, change.newRange.getEndPosition().row + 1, change.newRange.getEndPosition().column + 1);
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
        if (try self._parse()) |tree| {
            if (self._lastFullyParsed) |lastFullyParsed| {
                lastFullyParsed.destroy();
            }
            self._lastFullyParsed = tree.copy();
            if (self._lastFullyParsedWithEdits) |lastFullyParsedWithEdits| {
                lastFullyParsedWithEdits.destroy();
            }
            self._lastFullyParsedWithEdits = tree.dupe();

            return tree;
        } else if (self._tree == null) {
            // No tree means this is the initial parse and there were edits
            // parse function doesn't handle this well and we can end up with an incorrect tree, so we reset
            self._parser.reset();
        }
        return null;
    }

    fn _parse(self: *TreeSitterTree) !?*ts.Tree {
        _ = self;
        return null;
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
};

// pub const TelemetryParseType = struct {
//     const Full = "fullParse";
//     const Incremental = "incrementalParse";
// };

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
