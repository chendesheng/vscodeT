const std = @import("std");
const rbt = @import("rbTreeBase.zig");
const Position = @import("position.zig").Position;
const Range = @import("range.zig").Range;
const SENTINEL = rbt.SENTINEL;
const TreeNode = rbt.TreeNode;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const AverageBufferSize = 65535;

fn createLineStartsFast(allocator: Allocator, str: []const u8) !ArrayList(usize) {
    var r = ArrayList(usize).init(allocator);
    try r.append(0);

    for (0.., str) |i, chr| {
        if (chr == '\r') {
            if (i + 1 < str.len and str[i + 1] == '\n') {
                try r.append(i + 2);
            } else {
                try r.append(i + 1);
            }
        } else if (chr == '\n') {
            if (i == 0 or str[i - 1] != '\r') {
                try r.append(i + 1);
            }
        }
    }
    return r;
}

const NodePosition = struct {
    // Piece Index
    node: *TreeNode,
    // remainder in current piece.
    remainder: usize,
    // node start offset in document
    nodeStartOffset: usize,
};

const BufferCursor = struct {
    // Line number in current buffer
    line: usize,
    // Column number in current buffer
    column: usize,
};

pub const Piece = struct {
    bufferIndex: usize,
    start: BufferCursor,
    end: BufferCursor,
    length: usize,
    lineFeedCnt: usize,
};

const EOL = enum {
    CRLF,
    LF,
};

const StringBuffer = struct {
    buffer: ArrayList(u8),
    lineStarts: ArrayList(usize),

    fn init(allocator: Allocator, str: []const u8) !StringBuffer {
        var buffer = ArrayList(u8).init(allocator);
        try buffer.appendSlice(str);
        return .{
            .buffer = buffer,
            .lineStarts = try createLineStartsFast(allocator, str),
        };
    }

    fn deinit(self: *const StringBuffer) void {
        self.buffer.deinit();
        self.lineStarts.deinit();
    }

    fn length(self: *const StringBuffer) usize {
        return self.buffer.items.len;
    }

    fn charCodeAt(self: *const StringBuffer, i: usize) u8 {
        return self.buffer.items[i];
    }

    fn substring(self: *const StringBuffer, start: usize, end: usize) []const u8 {
        return self.buffer.items[start..end];
    }

    fn substr(self: *const StringBuffer, start: usize, len: usize) []const u8 {
        return self.buffer.items[start .. start + len];
    }

    fn append(self: *StringBuffer, value: []const u8) !void {
        try self.buffer.appendSlice(value);
    }
};

// Readonly snapshot for piece tree.
// In a real multiple thread environment, to make snapshot reading always work correctly, we need to
// 1. Make TreeNode.piece immutable, then reading and writing can run in parallel.
// 2. TreeNode/Buffers normalization should not happen during snapshot reading.
const PieceTreeSnapshot = struct {
    _pieces: ArrayList(*const Piece),
    _index: ?usize, // null is for BOM
    _tree: *const PieceTreeBase,
    _BOM: []const u8,

    fn init(tree: *const PieceTreeBase, BOM: []const u8) !PieceTreeSnapshot {
        var pieces = ArrayList(*const Piece).init(tree.allocator);

        var iter = tree.root.iterator();
        while (iter.next()) |node| {
            if (node.piece) |*piece| {
                try pieces.append(piece);
            }
        }

        return .{
            ._pieces = pieces,
            ._index = if (BOM.len > 0) null else 0,
            ._tree = tree,
            ._BOM = BOM,
        };
    }

    fn deinit(self: *const PieceTreeSnapshot) void {
        self._pieces.deinit();
    }

    fn read(self: *PieceTreeSnapshot) ?[]const u8 {
        if (self._index == null) {
            self._index = 0;
            return self._BOM;
        }

        const i = self._index.?;

        if (i >= self._pieces.items.len) {
            return null;
        }

        const ret = self._tree.getPieceContent(self._pieces.items[i]);
        self._index = i + 1;
        return ret;
    }
};

const CacheEntry = struct {
    node: *TreeNode,
    nodeStartOffset: usize,
    nodeStartLineNumber: ?usize,
};

const PieceTreeSearchCache = struct {
    _limit: usize,
    _cache: ArrayList(CacheEntry),

    fn init(allocator: Allocator, limit: usize) PieceTreeSearchCache {
        return .{
            ._limit = limit,
            ._cache = ArrayList(CacheEntry).init(allocator),
        };
    }

    fn deinit(self: *const PieceTreeSearchCache) void {
        self._cache.deinit();
    }

    fn get(self: *const PieceTreeSearchCache, offset: usize) ?CacheEntry {
        const len = self._cache.items.len;
        if (len == 0) {
            return null;
        }

        var i: usize = len - 1;
        while (i >= 0) : (i -= 1) {
            const nodePos = self._cache.items[i];
            if (nodePos.nodeStartOffset <= offset and nodePos.nodeStartOffset + nodePos.node.piece.?.length >= offset) {
                return nodePos;
            }
        }
        return null;
    }

    fn get2(self: *const PieceTreeSearchCache, lineNumber: usize) ?CacheEntry {
        const len = self._cache.items.len;
        if (len == 0) {
            return null;
        }

        var i: usize = len - 1;
        while (i >= 0) : (i -= 1) {
            const nodePos = self._cache.items[i];
            if (nodePos.nodeStartLineNumber != null and nodePos.nodeStartLineNumber.? < lineNumber and nodePos.nodeStartLineNumber.? + nodePos.node.piece.?.lineFeedCnt >= lineNumber) {
                return nodePos;
            }
        }
        return null;
    }

    fn set(self: *PieceTreeSearchCache, nodePosition: CacheEntry) !void {
        if (self._cache.items.len >= self._limit) {
            _ = self._cache.orderedRemove(0);
        }
        try self._cache.append(nodePosition);
    }

    fn validate(self: *PieceTreeSearchCache, offset: usize) void {
        var tmp = self._cache;

        var i: usize = tmp.items.len;
        while (i > 0) {
            i -= 1;

            const nodePos = tmp.items[i];
            if (nodePos.node == SENTINEL or nodePos.nodeStartOffset >= offset) {
                _ = tmp.orderedRemove(i);
            }
        }
    }

    fn reset(self: *PieceTreeSearchCache) !void {
        self._limit = 0;
        try self._cache.resize(0);
    }
};

const LastVisitedLine = struct {
    lineNumber: usize,
    value: ArrayList(u8),

    fn init(allocator: Allocator) LastVisitedLine {
        return .{
            .lineNumber = 0,
            .value = ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *const LastVisitedLine) void {
        self.value.deinit();
    }

    fn reset(self: *LastVisitedLine) !void {
        self.lineNumber = 0;
        try self.value.resize(0);
    }
};

pub const PieceTreeBase = struct {
    allocator: Allocator,
    root: *TreeNode,
    _buffers: ArrayList(StringBuffer),
    _lineCnt: usize,
    _length: usize,
    _EOL: EOL,
    _EOLNormalized: bool,
    _EOLLength: usize,
    _lastChangeBufferPos: BufferCursor,
    _searchCache: PieceTreeSearchCache,
    _lastVisitedLine: LastVisitedLine,

    pub fn init(allocator: Allocator, chunks: []StringBuffer, eol: EOL) !PieceTreeBase {
        var tree = PieceTreeBase{
            .allocator = allocator,
            .root = SENTINEL,
            ._buffers = ArrayList(StringBuffer).init(allocator),
            ._lineCnt = 1,
            ._length = 0,
            ._EOL = eol,
            ._EOLNormalized = false,
            ._EOLLength = if (eol == .CRLF) 2 else 1,
            ._lastChangeBufferPos = .{ .line = 0, .column = 0 },
            ._searchCache = PieceTreeSearchCache.init(allocator, 1),
            ._lastVisitedLine = LastVisitedLine.init(allocator),
        };

        try tree.resetBuffers(chunks);
        return tree;
    }

    pub fn deinit(self: *const PieceTreeBase) void {
        rbt.freeTree(self.allocator, self.root);
        for (self._buffers.items) |buffer| {
            buffer.deinit();
        }
        self._buffers.deinit();
        self._searchCache.deinit();
        self._lastVisitedLine.deinit();
    }

    fn resetBuffers(self: *PieceTreeBase, chunks: []StringBuffer) !void {
        if (self._buffers.items.len > 0) {
            for (self._buffers.items) |buffer| {
                buffer.deinit();
            }
            try self._buffers.resize(0);
        }

        try self._buffers.append(try StringBuffer.init(self.allocator, ""));

        var lastNode: ?*TreeNode = null;
        for (1.., chunks) |i, chunk| {
            if (chunk.length() > 0) {
                const piece = Piece{
                    .bufferIndex = i,
                    .start = .{ .line = 0, .column = 0 },
                    .end = .{ .line = chunk.lineStarts.items.len - 1, .column = chunk.length() - chunk.lineStarts.items[chunk.lineStarts.items.len - 1] },
                    .lineFeedCnt = chunk.lineStarts.items.len - 1,
                    .length = chunk.length(),
                };
                try self._buffers.append(chunk);
                lastNode = try self.rbInsertRight(lastNode, piece);
            }
        }

        self.computeBufferMetadata();
    }

    fn normalizeEOL(self: *PieceTreeBase, eol: EOL) !void {
        var tempChunk = ArrayList(u8).init(self.allocator);
        defer tempChunk.deinit();

        var chunks = ArrayList(StringBuffer).init(self.allocator);
        defer chunks.deinit();

        var iter = self.root.iterator();
        while (iter.next()) |node| {
            const averageBufferSize = AverageBufferSize;
            const min = averageBufferSize - @divFloor(averageBufferSize, 3);
            const max = min * 2;

            const str = self.getNodeContent(node);

            if (tempChunk.items.len <= min or tempChunk.items.len + str.len < max) {
                try tempChunk.appendSlice(str);
            } else {
                // flush anyways
                try replaceEOL(&tempChunk, self._EOL);
                try chunks.append(try StringBuffer.init(self.allocator, tempChunk.items));
                try tempChunk.replaceRange(0, tempChunk.items.len, str);
            }
        }

        if (tempChunk.items.len > 0) {
            try replaceEOL(&tempChunk, eol);
            try chunks.append(try StringBuffer.init(self.allocator, tempChunk.items));
        }

        rbt.freeTree(self.allocator, self.root);
        self.root = SENTINEL;
        self._lineCnt = 1;
        self._EOL = eol;
        self._EOLNormalized = true;
        self._EOLLength = if (eol == .CRLF) 2 else 1;
        try self._searchCache.reset();
        try self._lastVisitedLine.reset();
        try self.resetBuffers(chunks.items);
    }

    fn rbDelete(self: *PieceTreeBase, node: *TreeNode) void {
        self.root = rbt.rbDelete(self.root, node);
    }

    pub fn getEOL(self: *PieceTreeBase) []const u8 {
        return eolToString(self._EOL);
    }

    pub fn setEOL(self: *PieceTreeBase, eol: EOL) void {
        self._EOL = eol;
        self.normalizeEOL(self._EOL);
    }

    pub fn createSnapshot(self: *PieceTreeBase, BOM: []u8) !PieceTreeSnapshot {
        return try PieceTreeSnapshot.init(self, BOM);
    }

    pub fn equal(self: *const PieceTreeBase, other: *const PieceTreeBase) !bool {
        if (self.getLength() != other.getLength()) {
            return false;
        }
        if (self.getLineCount() != other.getLineCount()) {
            return false;
        }

        var offset: usize = 0;
        var ret = true;

        var iter = self.root.iterator();
        while (iter.next()) |node| {
            if (node == SENTINEL) {
                continue;
            }

            const str = self.getNodeContent(node);
            const startPosition = other.nodeAt(offset);
            const endPosition = other.nodeAt(offset + str.len);
            const val = try other.getValueInRange2(startPosition, endPosition);
            defer val.deinit();

            offset += str.len;
            if (!std.mem.eql(u8, str, val.items)) {
                ret = false;
                break;
            }
        }

        return ret;
    }

    pub fn getOffsetAt(self: *const PieceTreeBase, lineNumber: usize, column: usize) usize {
        var leftLen: usize = 0; // inorder

        var x = self.root;
        var line = lineNumber;

        while (x != SENTINEL) {
            const piece = x.piece.?;
            if (x.left != SENTINEL and x.lf_left + 1 >= line) {
                x = x.left;
            } else if (x.lf_left + piece.lineFeedCnt + 1 >= line) {
                leftLen += x.size_left;
                // lineNumber >= 2
                const accumualtedValInCurrentIndex = if (line < x.lf_left + 2)
                    0
                else
                    self.getAccumulatedValue(x, line - x.lf_left - 2);
                leftLen += accumualtedValInCurrentIndex + column - 1;
                break;
            } else {
                line -= x.lf_left + piece.lineFeedCnt;
                leftLen += x.size_left + piece.length;
                x = x.right;
            }
        }

        return leftLen;
    }

    pub fn getPositionAt(self: *PieceTreeBase, off: usize) Position {
        var offset = @floor(off);
        offset = @max(0, offset);

        var x = self.root;
        var lfCnt = 0;
        const originalOffset = offset;

        while (x != SENTINEL) {
            if (x.size_left != 0 and x.size_left >= offset) {
                x = x.left;
            } else if (x.size_left + x.piece.length >= offset) {
                const out = self.getIndexOf(x, offset - x.size_left);

                lfCnt += x.lf_left + out.index;

                if (out.index == 0) {
                    const lineStartOffset = self.getOffsetAt(lfCnt + 1, 1);
                    const column = originalOffset - lineStartOffset;
                    return Position.create(lfCnt + 1, column + 1);
                }

                return Position.create(lfCnt + 1, out.remainder + 1);
            } else {
                offset -= x.size_left + x.piece.length;
                lfCnt += x.lf_left + x.piece.lineFeedCnt;

                if (x.right == SENTINEL) {
                    // last node
                    const lineStartOffset = self.getOffsetAt(lfCnt + 1, 1);
                    const column = originalOffset - offset - lineStartOffset;
                    return Position.create(lfCnt + 1, column + 1);
                } else {
                    x = x.right;
                }
            }
        }

        return Position.create(1, 1);
    }

    pub fn getValueInRange(self: *PieceTreeBase, range: Range, eol_: ?EOL) ArrayList(u8) {
        if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) {
            return ArrayList(u8).init(self.allocator);
        }

        const startPosition = self.nodeAt2(range.startLineNumber, range.startColumn);
        const endPosition = self.nodeAt2(range.endLineNumber, range.endColumn);

        const value = self.getValueInRange2(startPosition, endPosition);
        if (eol_) |eol| {
            if (eol != self._EOL || !self._EOLNormalized) {
                replaceEOL(&value, eol);
                return value;
            }

            if (eol == self._EOL and self._EOLNormalized) {
                // if (sts.mem.eql(eol, "\r\n")) {}
                return value;
            }
            replaceEOL(&value, eol);
            return value;
        }
        return value;
    }

    pub fn getValueInRange2(self: *const PieceTreeBase, startPosition: NodePosition, endPosition: NodePosition) !ArrayList(u8) {
        if (startPosition.node == endPosition.node) {
            const node = startPosition.node;
            const buffer = self._buffers.items[node.piece.?.bufferIndex];
            const startOffset = self.offsetInBuffer(node.piece.?.bufferIndex, node.piece.?.start);
            var ret = ArrayList(u8).init(self.allocator);
            try ret.appendSlice(buffer.substring(startOffset + startPosition.remainder, startOffset + endPosition.remainder));
            return ret;
        }

        var x = startPosition.node;
        var piece = x.piece.?;
        const buffer = self._buffers.items[piece.bufferIndex];
        const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
        var ret = ArrayList(u8).init(self.allocator);
        try ret.appendSlice(buffer.substring(startOffset + startPosition.remainder, startOffset + piece.length));

        x = x.next();
        while (x != SENTINEL) {
            piece = x.piece.?;
            const buf = self._buffers.items[piece.bufferIndex];
            const stOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);

            if (x == endPosition.node) {
                try ret.appendSlice(buf.substring(stOffset, stOffset + endPosition.remainder));
                break;
            } else {
                try ret.appendSlice(buf.substr(stOffset, piece.length));
            }

            x = x.next();
        }

        return ret;
    }

    pub fn getLinesContent(self: *PieceTreeBase) !ArrayList(ArrayList(u8)) {
        var lines = ArrayList(ArrayList(u8)).init(self.allocator);

        var currentLine = ArrayList(u8).init(self.allocator);

        var danglingCR = false;

        var iter = self.root.iterator();
        while (iter.next()) |node| {
            if (node == SENTINEL) {
                continue;
            }

            const piece = node.piece.?;
            var pieceLength = piece.length;
            if (pieceLength == 0) {
                continue;
            }

            const buffer = self._buffers.items[piece.bufferIndex];
            const lineStarts = buffer.lineStarts.items;

            const pieceStartLine = piece.start.line;
            const pieceEndLine = piece.end.line;
            var pieceStartOffset = lineStarts[pieceStartLine] + piece.start.column;

            if (danglingCR) {
                if (buffer.charCodeAt(pieceStartOffset) == '\n') {
                    // pretend the \n was in the previous piece.
                    pieceStartOffset += 1;
                    pieceLength -= 1;
                }
                try lines.append(currentLine);
                currentLine = ArrayList(u8).init(self.allocator);
                danglingCR = false;
                if (pieceLength == 0) {
                    continue;
                }
            }

            if (pieceStartLine == pieceEndLine) {
                // self piece has no new lines
                if (!self._EOLNormalized and buffer.charCodeAt(pieceStartOffset + pieceLength - 1) == '\r') {
                    danglingCR = true;
                    try currentLine.appendSlice(buffer.substr(pieceStartOffset, pieceLength - 1));
                } else {
                    try currentLine.appendSlice(buffer.substr(pieceStartOffset, pieceLength));
                }
                continue;
            }

            // add the text before the first line start in this piece
            try currentLine.appendSlice(if (self._EOLNormalized) buffer.substring(pieceStartOffset, @max(pieceStartOffset, lineStarts[pieceStartLine + 1] - self._EOLLength)) else sliceLineFeeds(buffer.substring(pieceStartOffset, lineStarts[pieceStartLine + 1])));
            try lines.append(currentLine);

            for (pieceStartLine + 1..pieceEndLine) |line| {
                currentLine = ArrayList(u8).init(self.allocator);
                try currentLine.appendSlice(if (self._EOLNormalized) buffer.substring(lineStarts[line], lineStarts[line + 1] - self._EOLLength) else sliceLineFeeds(buffer.substring(lineStarts[line], lineStarts[line + 1])));

                try lines.append(currentLine);
            }

            if (!self._EOLNormalized and buffer.charCodeAt(lineStarts[pieceEndLine] + piece.end.column - 1) == '\r') {
                danglingCR = true;
                if (piece.end.column == 0) {
                    // The last line ended with a \r, let's undo the push, it will be pushed by next iteration
                    if (lines.pop()) |last| {
                        last.deinit();
                    }
                } else {
                    currentLine = ArrayList(u8).init(self.allocator);
                    try currentLine.appendSlice(buffer.substr(lineStarts[pieceEndLine], piece.end.column - 1));
                }
            } else {
                currentLine = ArrayList(u8).init(self.allocator);
                try currentLine.appendSlice(buffer.substr(lineStarts[pieceEndLine], piece.end.column));
            }
        }

        if (danglingCR) {
            try lines.append(currentLine);
            currentLine = ArrayList(u8).init(self.allocator);
        }

        try lines.append(currentLine);
        return lines;
    }

    pub fn getLength(self: *const PieceTreeBase) usize {
        return self._length;
    }

    pub fn getLineCount(self: *const PieceTreeBase) usize {
        return self._lineCnt;
    }

    pub fn getLineContent(self: *PieceTreeBase, lineNumber: usize) ![]u8 {
        if (self._lastVisitedLine.lineNumber == lineNumber) {
            return self._lastVisitedLine.value.items;
        }

        const oldValue = self._lastVisitedLine.value;
        defer oldValue.deinit();

        self._lastVisitedLine.lineNumber = lineNumber;

        if (lineNumber == self._lineCnt) {
            self._lastVisitedLine.value = try self.getLineRawContent(lineNumber, 0);
        } else if (self._EOLNormalized) {
            self._lastVisitedLine.value = try self.getLineRawContent(lineNumber, self._EOLLength);
        } else {
            var ret = try self.getLineRawContent(lineNumber, 0);
            for (0..getEOLLength(ret.items)) |_| {
                _ = ret.pop();
            }
            self._lastVisitedLine.value = ret;
        }

        return self._lastVisitedLine.value.items;
    }

    fn _getCharCode(self: *PieceTreeBase, nodePos: NodePosition) u8 {
        if (nodePos.remainder == nodePos.node.piece.?.length) {
            // the char we want to fetch is at the head of next node.
            const matchingNode = nodePos.node.next();
            if (!matchingNode) {
                return 0;
            }

            const buffer = self._buffers.items[matchingNode.piece.?.bufferIndex];
            const startOffset = self.offsetInBuffer(matchingNode.piece.?.bufferIndex, matchingNode.piece.?.start);
            return buffer.charCodeAt(startOffset);
        } else {
            const buffer = self._buffers.items[nodePos.node.piece.?.bufferIndex];
            const startOffset = self.offsetInBuffer(nodePos.node.piece.?.bufferIndex, nodePos.node.piece.?.start);
            const targetOffset = startOffset + nodePos.remainder;

            return buffer.charCodeAt(targetOffset);
        }
    }

    pub fn getLineCharCode(self: *const PieceTreeBase, lineNumber: usize, index: usize) u8 {
        const nodePos = self.nodeAt2(lineNumber, index + 1);
        return self._getCharCode(nodePos);
    }

    pub fn getLineLength(self: *const PieceTreeBase, lineNumber: usize) usize {
        if (lineNumber == self.getLineCount()) {
            const startOffset = self.getOffsetAt(lineNumber, 1);
            return self.getLength() - startOffset;
        }
        return self.getOffsetAt(lineNumber + 1, 1) - self.getOffsetAt(lineNumber, 1) - self._EOLLength;
    }

    pub fn getCharCode(self: *const PieceTreeBase, offset: usize) usize {
        const nodePos = self.nodeAt(offset);
        return self._getCharCode(nodePos);
    }

    pub fn getNearestChunk(self: *const PieceTreeBase, offset: usize) []const u8 {
        const nodePos = self.nodeAt(offset);
        if (nodePos.remainder == nodePos.node.piece.?.length) {
            // the offset is at the head of next node.
            const matchingNode = nodePos.node.next();
            if (matchingNode == SENTINEL) {
                return "";
            }

            const buffer = self._buffers.items[matchingNode.piece.?.bufferIndex];
            const startOffset = self.offsetInBuffer(matchingNode.piece.?.bufferIndex, matchingNode.piece.?.start);
            return buffer.substring(startOffset, startOffset + matchingNode.piece.?.length);
        } else {
            const buffer = self._buffers.items[nodePos.node.piece.?.bufferIndex];
            const startOffset = self.offsetInBuffer(nodePos.node.piece.?.bufferIndex, nodePos.node.piece.?.start);
            const targetOffset = startOffset + nodePos.remainder;
            const targetEnd = startOffset + nodePos.node.piece.?.length;
            return buffer.substring(targetOffset, targetEnd);
        }
    }

    // #region Piece Table
    pub fn insert(self: *PieceTreeBase, offset: usize, value: []const u8, eolNormalized: bool) !void {
        self._EOLNormalized = self._EOLNormalized and eolNormalized;
        try self._lastVisitedLine.reset();

        if (self.root != SENTINEL) {
            const n = self.nodeAt(offset);
            const node = n.node;
            const remainder = n.remainder;
            const nodeStartOffset = n.nodeStartOffset;
            const piece = node.piece.?;
            const bufferIndex = piece.bufferIndex;
            const insertPosInBuffer = self.positionInBuffer(node, remainder, null).?;
            if (piece.bufferIndex == 0 and
                piece.end.line == self._lastChangeBufferPos.line and
                piece.end.column == self._lastChangeBufferPos.column and
                (nodeStartOffset + piece.length == offset) and
                value.len < AverageBufferSize)
            {
                // changed buffer
                try self.appendToNode(node, value);
                self.computeBufferMetadata();
                return;
            }

            if (nodeStartOffset == offset) {
                try self.insertContentToNodeLeft(value, node);
                self._searchCache.validate(offset);
            } else if (nodeStartOffset + node.piece.?.length > offset) {
                var appendLF = false;
                var prependCR = false;

                // we are inserting into the middle of a node.
                var nodesToDel = ArrayList(*TreeNode).init(self.allocator);
                defer nodesToDel.deinit();

                var newRightPiece: Piece = .{
                    .bufferIndex = piece.bufferIndex,
                    .start = insertPosInBuffer,
                    .end = piece.end,
                    .lineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, insertPosInBuffer, piece.end),
                    .length = self.offsetInBuffer(bufferIndex, piece.end) - self.offsetInBuffer(bufferIndex, insertPosInBuffer),
                };

                if (self.shouldCheckCRLF() and strEndWithCR(value)) {
                    const headOfRight = self.nodeCharCodeAt(node, remainder);

                    if (headOfRight == '\n') { // \n
                        const newStart: BufferCursor = .{ .line = newRightPiece.start.line + 1, .column = 0 };
                        newRightPiece = .{
                            .bufferIndex = newRightPiece.bufferIndex,
                            .start = newStart,
                            .end = newRightPiece.end,
                            .lineFeedCnt = self.getLineFeedCnt(newRightPiece.bufferIndex, newStart, newRightPiece.end),
                            .length = newRightPiece.length - 1,
                        };

                        appendLF = true;
                    }
                }

                // reuse node for content before insertion point.
                if (self.shouldCheckCRLF() and strStartWithLF(value)) {
                    const tailOfLeft = self.nodeCharCodeAt(node, remainder - 1);
                    if (tailOfLeft == '\r') { // \r
                        const previousPos = self.positionInBuffer(node, remainder - 1, null).?;
                        self.deleteNodeTail(node, previousPos);

                        prependCR = true;

                        if (node.piece.?.length == 0) {
                            try nodesToDel.append(node);
                        }
                    } else {
                        self.deleteNodeTail(node, insertPosInBuffer);
                    }
                } else {
                    self.deleteNodeTail(node, insertPosInBuffer);
                }

                var newPieces: ArrayList(Piece) = undefined;
                if (appendLF or prependCR) {
                    const newVal = try std.mem.join(self.allocator, "", &[_][]const u8{
                        if (prependCR) "\r" else "",
                        value,
                        if (appendLF) "\n" else "",
                    });
                    defer self.allocator.free(newVal);
                    newPieces = try self.createNewPieces(newVal);
                } else {
                    newPieces = try self.createNewPieces(value);
                }
                defer newPieces.deinit();

                if (newRightPiece.length > 0) {
                    _ = try self.rbInsertRight(node, newRightPiece);
                }

                var tmpNode = node;
                for (0..newPieces.items.len) |k| {
                    tmpNode = try self.rbInsertRight(tmpNode, newPieces.items[k]);
                }
                self.deleteNodes(nodesToDel.items);
            } else {
                try self.insertContentToNodeRight(value, node);
            }
        } else {
            // insert new node
            const pieces = try self.createNewPieces(value);
            var node = try self.rbInsertLeft(null, pieces.items[0]);

            for (1..pieces.items.len) |k| {
                node = try self.rbInsertRight(node, pieces.items[k]);
            }
        }

        // todo, this is too brutal. Total line feed count should be updated the same way as lf_left.
        self.computeBufferMetadata();
    }

    pub fn delete(self: *PieceTreeBase, offset: usize, cnt: usize) !void {
        try self._lastVisitedLine.reset();

        if (cnt <= 0 or self.root == SENTINEL) {
            return;
        }

        const startPosition = self.nodeAt(offset);
        const endPosition = self.nodeAt(offset + cnt);
        const startNode = startPosition.node;
        const endNode = endPosition.node;

        if (startNode == endNode) {
            const startSplitPosInBuffer = self.positionInBuffer(startNode, startPosition.remainder, null).?;
            const endSplitPosInBuffer = self.positionInBuffer(startNode, endPosition.remainder, null).?;

            if (startPosition.nodeStartOffset == offset) {
                if (cnt == startNode.piece.?.length) { // delete node
                    const next = startNode.next();
                    self.rbDelete(startNode);
                    try self.validateCRLFWithPrevNode(next);
                    self.computeBufferMetadata();
                    return;
                }
                self.deleteNodeHead(startNode, endSplitPosInBuffer);
                self._searchCache.validate(offset);
                try self.validateCRLFWithPrevNode(startNode);
                self.computeBufferMetadata();
                return;
            }

            if (startPosition.nodeStartOffset + startNode.piece.?.length == offset + cnt) {
                self.deleteNodeTail(startNode, startSplitPosInBuffer);
                try self.validateCRLFWithNextNode(startNode);
                self.computeBufferMetadata();
                return;
            }

            // delete content in the middle, self node will be splitted to nodes
            try self.shrinkNode(startNode, startSplitPosInBuffer, endSplitPosInBuffer);
            self.computeBufferMetadata();
            return;
        }

        var nodesToDel = ArrayList(*TreeNode).init(self.allocator);
        defer nodesToDel.deinit();

        const startSplitPosInBuffer = self.positionInBuffer(startNode, startPosition.remainder, null).?;
        self.deleteNodeTail(startNode, startSplitPosInBuffer);
        self._searchCache.validate(offset);
        if (startNode.piece.?.length == 0) {
            try nodesToDel.append(startNode);
        }

        // update last touched node
        const endSplitPosInBuffer = self.positionInBuffer(endNode, endPosition.remainder, null).?;
        self.deleteNodeHead(endNode, endSplitPosInBuffer);
        if (endNode.piece.?.length == 0) {
            try nodesToDel.append(endNode);
        }

        // delete nodes in between
        var node = startNode.next();
        while (node != SENTINEL and node != endNode) {
            try nodesToDel.append(node);
            node = node.next();
        }

        const prev = if (startNode.piece.?.length == 0) startNode.prev() else startNode;
        self.deleteNodes(nodesToDel.items);
        try self.validateCRLFWithNextNode(prev);
        self.computeBufferMetadata();
    }

    fn insertContentToNodeLeft(self: *PieceTreeBase, value: []const u8, node: *TreeNode) !void {
        // we are inserting content to the beginning of node
        var nodesToDel = ArrayList(*TreeNode).init(self.allocator);
        defer nodesToDel.deinit();

        var val = ArrayList(u8).init(self.allocator);
        defer val.deinit();
        try val.appendSlice(value);

        if (self.shouldCheckCRLF() and strEndWithCR(val.items) and self.startWithLF(node)) {
            // move `\n` to new node.

            const piece = node.piece.?;
            const newStart: BufferCursor = .{ .line = piece.start.line + 1, .column = 0 };
            const nPiece: Piece = .{
                .bufferIndex = piece.bufferIndex,
                .start = newStart,
                .end = piece.end,
                .lineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, newStart, piece.end),
                .length = piece.length - 1,
            };

            node.piece = nPiece;

            try val.append('\n');
            self.updateTreeMetadata(node, -1, -1);

            if (node.piece.?.length == 0) {
                try nodesToDel.append(node);
            }
        }

        const newPieces = try self.createNewPieces(val.items);
        defer newPieces.deinit();

        var newNode = try self.rbInsertLeft(node, newPieces.items[newPieces.items.len - 1]);
        if (newPieces.items.len >= 2) {
            for (0..newPieces.items.len - 1) |i| {
                const k = newPieces.items.len - 1 - i - 1;
                newNode = try self.rbInsertLeft(newNode, newPieces.items[k]);
            }
        }
        try self.validateCRLFWithPrevNode(newNode);
        self.deleteNodes(nodesToDel.items);
    }

    fn insertContentToNodeRight(self: *PieceTreeBase, value: []const u8, node: *TreeNode) !void {
        var val = ArrayList(u8).init(self.allocator);
        defer val.deinit();
        try val.appendSlice(value);

        // we are inserting to the right of this node.
        if (self.adjustCarriageReturnFromNext(val.items, node)) {
            // move \n to the new node.
            try val.append('\n');
        }

        const newPieces = try self.createNewPieces(val.items);
        defer newPieces.deinit();

        const newNode = try self.rbInsertRight(node, newPieces.items[0]);
        var tmpNode = newNode;

        for (1..newPieces.items.len) |k| {
            tmpNode = try self.rbInsertRight(tmpNode, newPieces.items[k]);
        }

        try self.validateCRLFWithPrevNode(newNode);
    }

    fn positionInBuffer(self: *PieceTreeBase, node: *TreeNode, remainder: usize, ret: ?BufferCursor) ?BufferCursor {
        var res = ret;
        const piece = node.piece.?;
        const bufferIndex = piece.bufferIndex;
        const lineStarts = self._buffers.items[bufferIndex].lineStarts.items;

        const startOffset = lineStarts[piece.start.line] + piece.start.column;

        const offset = startOffset + remainder;

        // binary search offset between startOffset and endOffset
        var low = piece.start.line;
        var high = piece.end.line;

        var mid: usize = 0;
        var midStop: usize = 0;
        var midStart: usize = 0;

        while (low <= high) {
            mid = low + ((high - low) / 2) | 0;
            midStart = lineStarts[mid];

            if (mid == high) {
                break;
            }

            midStop = lineStarts[mid + 1];

            if (offset < midStart) {
                high = mid - 1;
            } else if (offset >= midStop) {
                low = mid + 1;
            } else {
                break;
            }
        }

        if (res != null) {
            res.?.line = mid;
            res.?.column = offset - midStart;
            return null;
        }

        return .{
            .line = mid,
            .column = offset - midStart,
        };
    }

    fn getLineFeedCnt(self: *PieceTreeBase, bufferIndex: usize, start: BufferCursor, end: BufferCursor) usize {
        // we don't need to worry about start: abc\r|\n, or abc|\r, or abc|\n, or abc|\r\n doesn't change the fact that, there is one line break after start.
        // now let's take care of end: abc\r|\n, if end is in between \r and \n, we need to add line feed count by 1
        if (end.column == 0) {
            return end.line - start.line;
        }

        const lineStarts = self._buffers.items[bufferIndex].lineStarts.items;
        if (end.line == lineStarts.len - 1) { // it means, there is no \n after end, otherwise, there will be one more lineStart.
            return end.line - start.line;
        }

        const nextLineStartOffset = lineStarts[end.line + 1];
        const endOffset = lineStarts[end.line] + end.column;
        if (nextLineStartOffset > endOffset + 1) { // there are more than 1 character after end, which means it can't be \n
            return end.line - start.line;
        }
        // endOffset + 1 == nextLineStartOffset
        // character at endOffset is \n, so we check the character before first
        // if character at endOffset is \r, end.column is 0 and we can't get here.
        const previousCharOffset = endOffset - 1; // end.column > 0 so it's okay.
        const buffer = self._buffers.items[bufferIndex].buffer;

        if (buffer.items[previousCharOffset] == '\r') {
            return end.line - start.line + 1;
        } else {
            return end.line - start.line;
        }
    }

    fn offsetInBuffer(self: *const PieceTreeBase, bufferIndex: usize, cursor: BufferCursor) usize {
        const lineStarts = self._buffers.items[bufferIndex].lineStarts.items;
        return lineStarts[cursor.line] + cursor.column;
    }

    fn deleteNodes(self: *PieceTreeBase, nodes: []const *TreeNode) void {
        for (nodes) |node| {
            self.rbDelete(node);
        }
    }

    fn createNewPieces(self: *PieceTreeBase, text: []const u8) !ArrayList(Piece) {
        if (text.len > AverageBufferSize) {
            // the content is large, operations like substring, charCode becomes slow
            // so here we split it into smaller chunks, just like what we did for CR/LF normalization
            var newPieces = ArrayList(Piece).init(self.allocator);
            var txt = text;
            while (txt.len > AverageBufferSize) {
                const lastChar = txt[txt.len - 1];
                var splitText: []const u8 = undefined;

                // FIXME: this is not correct as the text is not js string.
                if (lastChar == '\r' or (lastChar >= 0xD800 and lastChar <= 0xDBFF)) {
                    // last character is \r or a high surrogate => keep it back
                    splitText = txt[0 .. AverageBufferSize - 1];
                    txt = txt[(AverageBufferSize - 1)..];
                } else {
                    splitText = txt[0..AverageBufferSize];
                    txt = txt[AverageBufferSize..];
                }

                const buf = try StringBuffer.init(self.allocator, splitText);
                const lineStarts = buf.lineStarts.items;
                try newPieces.append(.{
                    .bufferIndex = self._buffers.items.len,
                    .start = .{ .line = 0, .column = 0 },
                    .end = .{ .line = lineStarts.len - 1, .column = splitText.len - lineStarts[lineStarts.len - 1] },
                    .lineFeedCnt = lineStarts.len - 1,
                    .length = splitText.len,
                });
                try self._buffers.append(buf);
            }

            const buf = try StringBuffer.init(self.allocator, txt);
            const lineStarts = buf.lineStarts.items;
            try newPieces.append(.{
                .bufferIndex = self._buffers.items.len,
                .start = .{ .line = 0, .column = 0 },
                .end = .{ .line = lineStarts.len - 1, .column = txt.len - lineStarts[lineStarts.len - 1] },
                .lineFeedCnt = lineStarts.len - 1,
                .length = txt.len,
            });
            try self._buffers.append(buf);
            return newPieces;
        }

        var startOffset = self._buffers.items[0].length();
        const lineStarts = try createLineStartsFast(self.allocator, text);
        defer lineStarts.deinit();

        var start = self._lastChangeBufferPos;
        if (self._buffers.items[0].lineStarts.items[self._buffers.items[0].lineStarts.items.len - 1] == startOffset and startOffset != 0 and strStartWithLF(text) and strEndWithCR(self._buffers.items[0].buffer.items)) {
            self._lastChangeBufferPos = .{ .line = self._lastChangeBufferPos.line, .column = self._lastChangeBufferPos.column + 1 };
            start = self._lastChangeBufferPos;

            for (0.., lineStarts.items) |i, lineStart| {
                lineStarts.items[i] = lineStart + startOffset + 1;
            }

            try self._buffers.items[0].lineStarts.appendSlice(lineStarts.items[1..]);
            try self._buffers.items[0].append("_");
            try self._buffers.items[0].append(text);
            startOffset += 1;
        } else {
            if (startOffset != 0) {
                for (0..lineStarts.items.len) |i| {
                    lineStarts.items[i] += startOffset;
                }
            }
            try self._buffers.items[0].lineStarts.appendSlice(lineStarts.items[1..]);
            try self._buffers.items[0].append(text);
        }

        const endOffset = self._buffers.items[0].length();
        const endIndex = self._buffers.items[0].lineStarts.items.len - 1;
        const endColumn = endOffset - self._buffers.items[0].lineStarts.items[endIndex];
        const endPos: BufferCursor = .{ .line = endIndex, .column = endColumn };
        const newPiece: Piece = .{
            .bufferIndex = 0, // TODO
            .start = start,
            .end = endPos,
            .lineFeedCnt = self.getLineFeedCnt(0, start, endPos),
            .length = endOffset - startOffset,
        };
        self._lastChangeBufferPos = endPos;

        var newPieces = ArrayList(Piece).init(self.allocator);
        try newPieces.append(newPiece);
        return newPieces;
    }

    fn getLinesRawContent(self: *PieceTreeBase) !ArrayList(u8) {
        return try self.getContentOfSubTree(self.root);
    }

    pub fn getLineRawContent(self: *PieceTreeBase, lineNumber: usize, endOffset: usize) !ArrayList(u8) {
        var x = self.root;

        var ret = ArrayList(u8).init(self.allocator);
        const cache_ = self._searchCache.get2(lineNumber);
        if (cache_ != null) {
            const cache = cache_.?;
            x = cache.node;
            const piece = x.piece.?;
            const prevAccumulatedValue = self.getAccumulatedValue(x, lineNumber -% cache.nodeStartLineNumber.? -% 1);
            const buffer = self._buffers.items[piece.bufferIndex];
            const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
            if (cache.nodeStartLineNumber.? + piece.lineFeedCnt == lineNumber) {
                try ret.appendSlice(buffer.substring(startOffset + prevAccumulatedValue, startOffset + piece.length));
            } else {
                const accumulatedValue = self.getAccumulatedValue(x, lineNumber -% cache.nodeStartLineNumber.?);
                try ret.resize(0);
                try ret.appendSlice(buffer.substring(startOffset + prevAccumulatedValue, startOffset + accumulatedValue - endOffset));
                return ret;
            }
        } else {
            var nodeStartOffset: usize = 0;
            const originalLineNumber = lineNumber;
            var line = lineNumber;
            while (x != SENTINEL) {
                const piece = x.piece.?;
                if (x.left != SENTINEL and x.lf_left >= line - 1) {
                    x = x.left;
                } else if (x.lf_left + piece.lineFeedCnt > line - 1) {
                    const prevAccumulatedValue = if (line < x.lf_left + 2) 0 else self.getAccumulatedValue(x, line - x.lf_left - 2);
                    const accumulatedValue = if (line < x.lf_left + 1) 0 else self.getAccumulatedValue(x, line - x.lf_left - 1);
                    const buffer = self._buffers.items[piece.bufferIndex];
                    const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
                    nodeStartOffset += x.size_left;
                    try self._searchCache.set(.{
                        .node = x,
                        .nodeStartOffset = nodeStartOffset,
                        .nodeStartLineNumber = originalLineNumber - (line - 1 - x.lf_left),
                    });

                    try ret.resize(0);
                    try ret.appendSlice(buffer.substring(startOffset + prevAccumulatedValue, startOffset + accumulatedValue - endOffset));
                    return ret;
                } else if (x.lf_left + piece.lineFeedCnt == line - 1) {
                    const prevAccumulatedValue = if (line < x.lf_left + 2) 0 else self.getAccumulatedValue(x, line - x.lf_left - 2);
                    const buffer = self._buffers.items[piece.bufferIndex];
                    const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);

                    try ret.resize(0);
                    try ret.appendSlice(buffer.substring(startOffset + prevAccumulatedValue, startOffset + piece.length));
                    break;
                } else {
                    line = line + piece.lineFeedCnt - x.lf_left;
                    nodeStartOffset += x.size_left + piece.length;
                    x = x.right;
                }
            }
        }

        // search in order, to find the node contains end column
        x = x.next();
        while (x != SENTINEL) {
            const piece = x.piece.?;
            const buffer = self._buffers.items[piece.bufferIndex];

            if (piece.lineFeedCnt > 0) {
                const accumulatedValue = self.getAccumulatedValue(x, 0);
                const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);

                try ret.appendSlice(buffer.substring(startOffset, startOffset + accumulatedValue - endOffset));
                return ret;
            } else {
                const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
                try ret.appendSlice(buffer.substring(startOffset, startOffset + piece.length));
            }

            x = x.next();
        }

        return ret;
    }

    fn computeBufferMetadata(self: *PieceTreeBase) void {
        var x = self.root;

        var lfCnt: usize = 1;
        var len: usize = 0;

        while (x != SENTINEL) {
            lfCnt += x.lf_left + x.piece.?.lineFeedCnt;
            len += x.size_left + x.piece.?.length;
            x = x.right;
        }

        self._lineCnt = lfCnt;
        self._length = len;
        self._searchCache.validate(len);
    }

    fn getIndexOf(self: *PieceTreeBase, node: *TreeNode, accumulatedValue: usize) struct { index: usize, remainder: usize } {
        const piece = node.piece.?;
        const pos = self.positionInBuffer(node, accumulatedValue, null).?;
        const lineCnt = pos.line - piece.start.line;

        if (self.offsetInBuffer(piece.bufferIndex, piece.end) - self.positionInBuffer(piece.bufferIndex, piece.start, null) == accumulatedValue) {
            // we are checking the end of this node, so a CRLF check is necessary.
            const realLineCnt = self.getLineFeedCnt(piece.bufferIndex, piece.start, pos);
            if (realLineCnt != lineCnt) {
                // aha yes, CRLF
                return .{ .index = realLineCnt, .remainder = 0 };
            }
        }

        return .{ .index = lineCnt, .remainder = pos.column };
    }

    fn getAccumulatedValue(self: *const PieceTreeBase, node: *const TreeNode, index: usize) usize {
        const piece = node.piece.?;
        const lineStarts = self._buffers.items[piece.bufferIndex].lineStarts.items;
        const expectedLineStartIndex = piece.start.line + index + 1;
        if (expectedLineStartIndex > piece.end.line) {
            return lineStarts[piece.end.line] + piece.end.column - lineStarts[piece.start.line] - piece.start.column;
        } else {
            return lineStarts[expectedLineStartIndex] - lineStarts[piece.start.line] - piece.start.column;
        }
    }

    fn deleteNodeTail(self: *PieceTreeBase, node: *TreeNode, pos: BufferCursor) void {
        const piece = node.piece.?;
        const originalLFCnt = piece.lineFeedCnt;
        const originalEndOffset = self.offsetInBuffer(piece.bufferIndex, piece.end);

        const newEnd = pos;
        const newEndOffset = self.offsetInBuffer(piece.bufferIndex, newEnd);
        const newLineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, piece.start, newEnd);

        const lf_delta = usizeDiff(newLineFeedCnt, originalLFCnt);
        const size_delta = usizeDiff(newEndOffset, originalEndOffset);
        const newLength: usize = @intCast(@as(isize, @intCast(piece.length)) + size_delta);

        node.piece = .{
            .bufferIndex = piece.bufferIndex,
            .start = piece.start,
            .end = newEnd,
            .lineFeedCnt = newLineFeedCnt,
            .length = newLength,
        };

        self.updateTreeMetadata(node, size_delta, lf_delta);
    }

    fn deleteNodeHead(self: *PieceTreeBase, node: *TreeNode, pos: BufferCursor) void {
        const piece = node.piece.?;
        const originalLFCnt = piece.lineFeedCnt;
        const originalStartOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);

        const newStart = pos;
        const newLineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, newStart, piece.end);
        const newStartOffset = self.offsetInBuffer(piece.bufferIndex, newStart);
        const lf_delta = usizeDiff(newLineFeedCnt, originalLFCnt);
        const size_delta = usizeDiff(originalStartOffset, newStartOffset);
        const newLength: usize = @intCast(@as(isize, @intCast(piece.length)) + size_delta);
        node.piece = .{
            .bufferIndex = piece.bufferIndex,
            .start = newStart,
            .end = piece.end,
            .lineFeedCnt = newLineFeedCnt,
            .length = newLength,
        };

        self.updateTreeMetadata(node, size_delta, lf_delta);
    }

    fn shrinkNode(self: *PieceTreeBase, node: *TreeNode, start: BufferCursor, end: BufferCursor) !void {
        const piece = node.piece.?;
        const originalStartPos = piece.start;
        const originalEndPos = piece.end;

        // old piece, originalStartPos, start
        const oldLength = piece.length;
        const oldLFCnt = piece.lineFeedCnt;
        const newEnd = start;
        const newLineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, piece.start, newEnd);
        const newLength = self.offsetInBuffer(piece.bufferIndex, start) - self.offsetInBuffer(piece.bufferIndex, originalStartPos);

        node.piece = .{
            .bufferIndex = piece.bufferIndex,
            .start = piece.start,
            .end = newEnd,
            .lineFeedCnt = newLineFeedCnt,
            .length = newLength,
        };

        self.updateTreeMetadata(node, @intCast(@as(isize, @intCast(newLength)) - @as(isize, @intCast(oldLength))), @intCast(@as(isize, @intCast(newLineFeedCnt)) - @as(isize, @intCast(oldLFCnt))));

        // new right piece, end, originalEndPos
        const newPiece: Piece = .{
            .bufferIndex = piece.bufferIndex,
            .start = end,
            .end = originalEndPos,
            .lineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, end, originalEndPos),
            .length = self.offsetInBuffer(piece.bufferIndex, originalEndPos) - self.offsetInBuffer(piece.bufferIndex, end),
        };

        const newNode: *TreeNode = try self.rbInsertLeft(node, newPiece);
        try self.validateCRLFWithPrevNode(newNode);
    }

    fn appendToNode(self: *PieceTreeBase, node: *TreeNode, value: []const u8) !void {
        var val = value;
        defer if (val.ptr != value.ptr) self.allocator.free(val);

        if (self.adjustCarriageReturnFromNext(val, node)) {
            val = try std.mem.join(self.allocator, "", &[_][]const u8{ val, "\n" });
        }

        const hitCRLF = self.shouldCheckCRLF() and strStartWithLF(val) and self.endWithCR(node);
        const startOffset = self._buffers.items[0].length();
        try self._buffers.items[0].append(val);
        const lineStarts = try createLineStartsFast(self.allocator, val);
        defer lineStarts.deinit();
        for (0.., lineStarts.items) |i, lineStart| {
            lineStarts.items[i] = lineStart + startOffset;
        }
        if (hitCRLF) {
            const prevStartOffset = self._buffers.items[0].lineStarts.items[self._buffers.items[0].lineStarts.items.len - 2];
            _ = self._buffers.items[0].lineStarts.pop();
            self._lastChangeBufferPos = .{ .line = self._lastChangeBufferPos.line - 1, .column = startOffset - prevStartOffset };
        }

        try self._buffers.items[0].lineStarts.appendSlice(lineStarts.items[1..]);
        const endIndex = self._buffers.items[0].lineStarts.items.len - 1;
        const endColumn = self._buffers.items[0].length() - self._buffers.items[0].lineStarts.items[endIndex];
        const newEnd: BufferCursor = .{ .line = endIndex, .column = endColumn };
        const newLength = node.piece.?.length + val.len;
        const oldLineFeedCnt = node.piece.?.lineFeedCnt;
        const newLineFeedCnt = self.getLineFeedCnt(0, node.piece.?.start, newEnd);
        const lf_delta = usizeDiff(newLineFeedCnt, oldLineFeedCnt);

        node.piece = .{
            .bufferIndex = node.piece.?.bufferIndex,
            .start = node.piece.?.start,
            .end = newEnd,
            .lineFeedCnt = newLineFeedCnt,
            .length = newLength,
        };

        self._lastChangeBufferPos = newEnd;
        self.updateTreeMetadata(node, @intCast(val.len), lf_delta);
    }

    fn nodeAt(self: *const PieceTreeBase, offset: usize) NodePosition {
        var offs = offset;
        var x = self.root;
        if (self._searchCache.get(offs)) |cache| {
            return .{
                .node = cache.node,
                .nodeStartOffset = cache.nodeStartOffset,
                .remainder = offs - cache.nodeStartOffset,
            };
        }

        var nodeStartOffset: usize = 0;

        while (x != SENTINEL) {
            if (x.size_left > offs) {
                x = x.left;
            } else if (x.size_left + x.piece.?.length >= offs) {
                nodeStartOffset += x.size_left;
                const ret: NodePosition = .{
                    .node = x,
                    .remainder = offs - x.size_left,
                    .nodeStartOffset = nodeStartOffset,
                };
                // self._searchCache.set(ret) catch {};
                return ret;
            } else {
                offs -= x.size_left + x.piece.?.length;
                nodeStartOffset += x.size_left + x.piece.?.length;
                x = x.right;
            }
        }

        return undefined;
    }

    fn nodeAt2(self: *PieceTreeBase, lineNumber: usize, column: usize) NodePosition {
        var x = self.root;
        var nodeStartOffset = 0;

        while (x != SENTINEL) {
            if (x.left != SENTINEL and x.lf_left >= lineNumber - 1) {
                x = x.left;
            } else if (x.lf_left + x.piece.?.lineFeedCnt > lineNumber - 1) {
                const prevAccumualtedValue =
                    if (lineNumber < x.lf_left + 2) 0 else self.getAccumulatedValue(x, lineNumber - x.lf_left - 2);
                const accumulatedValue =
                    if (lineNumber < x.lf_left + 1) 0 else self.getAccumulatedValue(x, lineNumber - x.lf_left - 1);
                nodeStartOffset += x.size_left;

                return .{
                    .node = x,
                    .reminder = std.math.minInt(prevAccumualtedValue + column - 1, accumulatedValue),
                    .nodeStartOffset = nodeStartOffset,
                };
            } else if (x.lf_left + x.piece.?.lineFeedCnt == lineNumber - 1) {
                const prevAccumualtedValue = self.getAccumulatedValue(x, lineNumber - x.lf_left - 2);
                if (prevAccumualtedValue + column - 1 <= x.piece.?.length) {
                    return .{
                        .node = x,
                        .remainder = prevAccumualtedValue + column - 1,
                        .nodeStartOffset = nodeStartOffset,
                    };
                } else {
                    column -= x.piece.?.length - prevAccumualtedValue;
                    break;
                }
            } else {
                lineNumber -= x.lf_left + x.piece.?.lineFeedCnt;
                nodeStartOffset += x.size_left + x.piece.?.length;
                x = x.right;
            }
        }

        // search in order, to find the node contains position.column
        x = x.next();
        while (x != SENTINEL) {
            if (x.piece.?.lineFeedCnt > 0) {
                const accumualtedValue = self.getAccumulatedValue(x, 0);
                return .{
                    .node = x,
                    .remainder = std.math.minInt(column - 1, accumualtedValue),
                    .nodeStartOffset = self.offsetOfNode(x),
                };
            } else {
                column -= x.piece.?.length;
            }

            x = x.next();
        }

        return undefined;
    }

    fn nodeCharCodeAt(self: *PieceTreeBase, node: *TreeNode, offset: usize) u8 {
        const piece = node.piece.?;
        if (piece.lineFeedCnt < 1) {
            return 0;
        }

        const buffer = self._buffers.items[piece.bufferIndex];
        const newOffset = self.offsetInBuffer(piece.bufferIndex, piece.start) + offset;
        return buffer.charCodeAt(newOffset);
    }

    fn offsetOfNode(self: *PieceTreeBase, node: *TreeNode) usize {
        if (node == SENTINEL) {
            return 0;
        }
        var pos = node.size_left;
        while (node != self.root) {
            if (node.parent.right == node) {
                pos += node.parent.size_left + node.parent.piece.length;
            }

            node = node.parent;
        }

        return pos;
    }

    fn shouldCheckCRLF(self: *PieceTreeBase) bool {
        return !(self._EOLNormalized and self._EOL == .LF);
    }

    fn startWithLF(self: *PieceTreeBase, val: *TreeNode) bool {
        if (val == SENTINEL or val.piece.?.lineFeedCnt == 0) {
            return false;
        }

        const piece = val.piece.?;
        const lineStarts = self._buffers.items[piece.bufferIndex].lineStarts.items;
        const line = piece.start.line;
        const startOffset = lineStarts[line] + piece.start.column;
        if (line == lineStarts.len - 1) {
            // last line, so there is no line feed at the end of this line
            return false;
        }
        const nextLineStartOffset = lineStarts[line + 1];
        if (nextLineStartOffset > startOffset + 1) {
            return false;
        }
        return self._buffers.items[piece.bufferIndex].charCodeAt(startOffset) == '\n';
    }

    fn endWithCR(self: *PieceTreeBase, val: *TreeNode) bool {
        if (val == SENTINEL or val.piece.?.lineFeedCnt == 0) {
            return false;
        }

        return self.nodeCharCodeAt(val, val.piece.?.length - 1) == '\r';
    }

    fn validateCRLFWithPrevNode(self: *PieceTreeBase, nextNode: *TreeNode) !void {
        if (self.shouldCheckCRLF() and self.startWithLF(nextNode)) {
            const node = nextNode.prev();
            if (self.endWithCR(node)) {
                try self.fixCRLF(node, nextNode);
            }
        }
    }

    fn validateCRLFWithNextNode(self: *PieceTreeBase, node: *TreeNode) !void {
        if (self.shouldCheckCRLF() and self.endWithCR(node)) {
            const nextNode = node.next();
            if (self.startWithLF(nextNode)) {
                try self.fixCRLF(node, nextNode);
            }
        }
    }

    fn fixCRLF(self: *PieceTreeBase, prev: *TreeNode, next: *TreeNode) !void {
        // update node
        const prevPiece = prev.piece.?;
        const prevPieceEnd = prevPiece.end;
        const lineStarts = self._buffers.items[prevPiece.bufferIndex].lineStarts.items;

        prev.piece = .{
            .bufferIndex = prevPiece.bufferIndex,
            .start = prevPiece.start,
            .end = if (prevPieceEnd.column == 0)
                // it means, last line ends with \r, not \r\n
                .{ .line = prevPieceEnd.line - 1, .column = lineStarts[prevPieceEnd.line] - lineStarts[prevPieceEnd.line - 1] }
            else
                .{ .line = prevPieceEnd.line, .column = prevPieceEnd.column - 1 },
            .lineFeedCnt = prevPiece.lineFeedCnt - 1,
            .length = prevPiece.length - 1,
        };

        self.updateTreeMetadata(prev, -1, -1);

        // update nextNode
        const nextPiece = next.piece.?;
        const newStart = BufferCursor{ .line = nextPiece.start.line + 1, .column = 0 };
        next.piece = .{
            .bufferIndex = nextPiece.bufferIndex,
            .start = newStart,
            .end = nextPiece.end,
            .lineFeedCnt = self.getLineFeedCnt(nextPiece.bufferIndex, newStart, nextPiece.end),
            .length = nextPiece.length - 1,
        };

        self.updateTreeMetadata(next, -1, -1);

        // create new piece which contains \r\n
        const pieces = try self.createNewPieces("\r\n");
        defer pieces.deinit();

        _ = try self.rbInsertRight(prev, pieces.items[0]);

        // delete empty nodes
        if (prev.piece.?.length == 0) {
            self.rbDelete(prev);
        }
        if (next.piece.?.length == 0) {
            self.rbDelete(next);
        }
    }

    fn adjustCarriageReturnFromNext(self: *PieceTreeBase, value: []const u8, node: *TreeNode) bool {
        if (self.shouldCheckCRLF() and strEndWithCR(value)) {
            const nextNode = node.next();
            if (self.startWithLF(nextNode)) {
                // move '\n' forward
                // value += '\n';

                const piece = nextNode.piece.?;
                if (piece.length == 1) {
                    self.rbDelete(nextNode);
                } else {
                    const newStart = BufferCursor{ .line = piece.start.line + 1, .column = 0 };
                    nextNode.piece = .{
                        .bufferIndex = piece.bufferIndex,
                        .start = newStart,
                        .end = piece.end,
                        .lineFeedCnt = self.getLineFeedCnt(piece.bufferIndex, newStart, piece.end),
                        .length = piece.length - 1,
                    };

                    self.updateTreeMetadata(nextNode, -1, -1);
                }
                return true;
            }
        }
        return false;
    }

    fn getNodeContent(self: *const PieceTreeBase, node: *const TreeNode) []const u8 {
        if (node.piece) |*piece| {
            return self.getPieceContent(piece);
        }

        return "";
    }

    fn getPieceContent(self: *const PieceTreeBase, piece: *const Piece) []const u8 {
        const buffer = self._buffers.items[piece.bufferIndex];
        const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
        const endOffset = self.offsetInBuffer(piece.bufferIndex, piece.end);
        return buffer.substring(startOffset, endOffset);
    }

    fn updateTreeMetadata(self: *PieceTreeBase, node: *TreeNode, delta: isize, lineFeedCntDelta: isize) void {
        rbt.updateTreeMetadata(self.root, node, delta, lineFeedCntDelta);
    }

    fn rbInsertRight(self: *PieceTreeBase, node: ?*TreeNode, p: Piece) !*TreeNode {
        const z = try rbt.TreeNode.create(self.allocator, p);
        self.root = rbt.insertRight(self.root, node, z);
        return z;
    }

    fn rbInsertLeft(self: *PieceTreeBase, node: ?*TreeNode, p: Piece) !*TreeNode {
        const z = try rbt.TreeNode.create(self.allocator, p);
        self.root = rbt.insertLeft(self.root, node, z);
        return z;
    }

    fn getContentOfSubTree(self: *PieceTreeBase, root: *TreeNode) !ArrayList(u8) {
        var str = ArrayList(u8).init(self.allocator);
        var iter = root.iterator();
        while (iter.next()) |node| {
            try str.appendSlice(self.getNodeContent(node));
        }
        return str;
    }
};

fn strStartWithLF(val: []const u8) bool {
    return val[0] == '\n';
}

fn strEndWithCR(val: []const u8) bool {
    return val[val.len - 1] == '\r';
}

fn toEOL(eol: []const u8) EOL {
    if (eol.len == 2 and eol[0] == '\r' and eol[1] == '\n') {
        return .CRLF;
    } else if (eol.len == 1 and eol[0] == '\r') {
        return .CR;
    } else {
        return .LF;
    }
}

fn eolToString(eol: EOL) []const u8 {
    if (eol == .CRLF) {
        return "\r\n";
    } else {
        return "\n";
    }
}

fn lineFeedLen(lineFeed: EOL) usize {
    switch (lineFeed) {
        .CRLF => return 2,
        .LF => return 1,
    }
}

fn getEOLLength(str: []const u8) usize {
    if (str.len >= 2 and str[str.len - 2] == '\r' and str[str.len - 1] == '\n') {
        return 2;
    }

    if (str.len >= 1 and (str[str.len - 1] == '\r' or str[str.len - 1] == '\n')) {
        return 1;
    }

    return 0;
}

fn sliceLineFeeds(str: []const u8) []const u8 {
    const lineFeedLength = getEOLLength(str);
    if (lineFeedLength == 0) {
        return str;
    }

    return str[0 .. str.len - lineFeedLength];
}

fn replaceEOL(target: *ArrayList(u8), eol: EOL) !void {
    var i = target.items.len - 1;

    while (true) {
        const ch = target.items[i];
        const ch_prev = if (i > 0) target.items[i - 1] else 0;

        var replace: usize = 0;
        if (ch_prev == '\r' and ch == '\n') {
            i -= 1;
            replace = if (eol != .CRLF) 2 else 0;
        } else if (ch == '\r') {
            replace = 1;
        } else if (ch == '\n') {
            replace = if (eol != .LF) 1 else 0;
        }

        if (replace > 0) {
            try target.replaceRange(i, replace, eolToString(eol));
        }

        if (i == 0) break;
        i -= 1;
    }
}

fn usizeDiff(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

test "replace EOL" {
    const allocator = std.testing.allocator;
    var target = ArrayList(u8).init(allocator);
    defer target.deinit();

    const beforeReplaces = [_][]const u8{
        "Hello\r\nWorld\r\n",
        "Hello\r\nWorld\r\n",
        "Hello\r\nWorld\r\n",
        "Hello\r\r\nWorld\r\n",
        "\r\n",
    };
    const eols = [_]EOL{ .LF, .CRLF, .LF, .LF, .LF };
    const afterReplaces = [_][]const u8{
        "Hello\nWorld\n",
        "Hello\r\nWorld\r\n",
        "Hello\nWorld\n",
        "Hello\n\nWorld\n",
        "\n",
    };

    for (beforeReplaces, eols, afterReplaces) |before, eol, after| {
        try target.resize(0);
        try target.appendSlice(before);
        try replaceEOL(&target, eol);
        try std.testing.expectEqualSlices(u8, after, target.items);
    }
}

test "create empty" {
    const allocator = std.testing.allocator;
    var tree = try PieceTreeBase.init(allocator, &[_]StringBuffer{}, .LF);
    defer tree.deinit();
}

test "create from string" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try std.testing.expectEqual(tree.getLineCount(), 4);

    const line1 = try tree.getLineContent(1);
    try std.testing.expectEqualSlices(u8, "First", line1);
    const line2 = try tree.getLineContent(2);
    try std.testing.expectEqualSlices(u8, "Second", line2);
    const line3 = try tree.getLineContent(3);
    try std.testing.expectEqualSlices(u8, "Third", line3);
    const line4 = try tree.getLineContent(4);
    try std.testing.expectEqualSlices(u8, "", line4);
}

test "normalize EOL" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\r\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try tree.normalizeEOL(.LF);
    const content = try tree.getLinesRawContent();
    defer content.deinit();

    try std.testing.expect(tree._EOLNormalized);
    try std.testing.expectEqualSlices(u8, "First\nSecond\nThird\n", content.items);
}

test "getLinesContent" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\r\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    const lines = try tree.getLinesContent();
    defer lines.deinit();
    defer {
        for (lines.items) |line| {
            line.deinit();
        }
    }

    try std.testing.expectEqual(4, lines.items.len);
    try std.testing.expectEqualSlices(u8, "First", lines.items[0].items);
    try std.testing.expectEqualSlices(u8, "Second", lines.items[1].items);
    try std.testing.expectEqualSlices(u8, "Third", lines.items[2].items);
    try std.testing.expectEqualSlices(u8, "", lines.items[3].items);
}

test "insert" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try tree.insert(0, "Hi", false);
    const line = try tree.getLineContent(1);
    try std.testing.expectEqualSlices(u8, "HiFirst", line);
}

test "delete" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try tree.delete(0, 1);
    const line = try tree.getLineContent(1);
    try std.testing.expectEqualSlices(u8, "First"[1..], line);
}

test "equal" {
    const allocator = std.testing.allocator;
    var buffers1 = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    const tree1 = try PieceTreeBase.init(allocator, &buffers1, .LF);
    defer tree1.deinit();

    var buffers2 = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    const tree2 = try PieceTreeBase.init(allocator, &buffers2, .LF);
    defer tree2.deinit();

    try std.testing.expect(try tree1.equal(&tree2));
}

test "getOffsetAt" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try std.testing.expectEqual(0, tree.getOffsetAt(1, 1));
    try std.testing.expectEqual(6, tree.getOffsetAt(2, 1));
}

test "getLineLength" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    try std.testing.expectEqual(5, tree.getLineLength(1));
}

test "getNearestChunk" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
        try StringBuffer.init(allocator, "Fourth\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    const chunk = tree.getNearestChunk(buffers[0].length());
    try std.testing.expectEqualSlices(u8, "Fourth\n", chunk);
}

test "create snapshot" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "First\nSecond\nThird\n"),
        try StringBuffer.init(allocator, "Fourth\n"),
    };
    var tree = try PieceTreeBase.init(allocator, &buffers, .LF);
    defer tree.deinit();

    var snapshot = try tree.createSnapshot("");
    defer snapshot.deinit();

    try std.testing.expectEqualSlices(u8, "First\nSecond\nThird\n", snapshot.read().?);
    try std.testing.expectEqualSlices(u8, "Fourth\n", snapshot.read().?);
    try std.testing.expectEqual(null, snapshot.read());
}
