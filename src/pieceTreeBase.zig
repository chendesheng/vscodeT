const std = @import("std");
const rbt = @import("rbTreeBase.zig");
const SENTINEL = rbt.SENTINEL;
const TreeNode = rbt.TreeNode;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const StringBuffer = struct {
    buffer: [1 << 16]u8, // 64KB
    length: usize,
    lineStarts: ?ArrayList(usize),

    fn create(allocator: Allocator, str: []u8) !*StringBuffer {
        var buffer = try allocator.create(StringBuffer);
        std.mem.copyForwards(u8, buffer.buffer, str);
        buffer.length = str.len;
        buffer.lineStarts = createLineStartsFast(allocator, str);
        return buffer;
    }
};

const EMPTY_STRING = []u8{};
const AverageBufferSize = 65535;

fn createLineStartsFast(allocator: Allocator, str: []u8) ArrayList(usize) {
    var r = ArrayList(usize).init(allocator);
    for (0.., str) |i, c| {
        if (c == '\r') {
            if (i + 1 < str.len and str[i + 1] == '\n') {
                r.append(i + 2);
            } else {
                r.append(i + 1);
            }
        } else if (c == '\n' and (i == 0 or str[i - 1] != '\r')) {
            r.append(i + 1);
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
    lineFeedCnt: u32,
};

const LineFeed = enum {
    CRLF,
    LF,
    CR,
};

const CacheEntry = struct {
    node: *TreeNode,
    nodeStartOffset: usize,
    nodeStartLineNumber: ?usize,
};

const PieceTreeSearchCache = struct {
    _limit: usize,
    _cache: ArrayList(CacheEntry),

    fn create(allocator: Allocator, limit: usize) PieceTreeSearchCache {
        return .{
            ._limit = limit,
            ._cache = ArrayList(CacheEntry).init(allocator),
        };
    }

    fn validate(self: *PieceTreeSearchCache, offset: usize) void {
        const tmp = self._cache;

        var i: usize = tmp.items.len;
        while (i > 0) {
            i -= 1;

            const nodePos = tmp.items[i];
            if (nodePos.node.parent == null or nodePos.nodeStartOffset >= offset) {
                tmp.orderedRemove(i);
            }
        }
    }

    fn reset(self: *PieceTreeSearchCache) void {
        self._limit = 0;
        self._cache.resize(0);
    }
};

pub const PieceTreeBase = struct {
    allocator: Allocator,
    root: *TreeNode,
    _buffers: ArrayList(*StringBuffer),
    _lineCnt: usize,
    _length: usize,
    _EOL: LineFeed,
    _EOLNormalized: bool,
    _lastChangeBufferPos: BufferCursor,
    _searchCache: PieceTreeSearchCache,
    _lastVisitedLine: ?struct { lineNumber: usize, value: []u8 },

    pub fn create(allocator: Allocator, chunks: []*StringBuffer, eol: LineFeed) !*PieceTreeBase {
        const tree = try allocator.create(PieceTreeBase);
        tree.* = PieceTreeBase{
            .allocator = allocator,
            .root = SENTINEL,
            ._buffers = ArrayList(*StringBuffer).init(allocator),
            ._lineCnt = 1,
            ._EOL = eol,
            ._EOLNormalized = false,
            ._searchCache = PieceTreeSearchCache.create(allocator, 1),
            ._lastVisitedLine = null,
        };

        tree.resetBuffers(chunks);
        return tree;
    }

    fn resetBuffers(self: *PieceTreeBase, chunks: []*StringBuffer) void {
        var lastNode: *TreeNode = null;
        for (0.., chunks) |i, chunk| {
            if (chunk.length > 0) {
                if (chunk.lineStarts == null) {
                    chunk.lineStarts = createLineStartsFast(self.allocator, chunk.buffer[0..chunk.length]);
                }

                const piece = Piece{
                    .bufferIndex = i + 1,
                    .start = .{ .line = 0, .column = 0 },
                    .end = .{ .line = chunk.lineStarts.items.len - 1, .column = chunk.length - chunk.lineStarts[chunk.lineStarts.items.len - 1] },
                    .lineFeedCnt = chunk.lineStarts.items.len - 1,
                    .length = chunk.length,
                };
                self._buffers.append(chunk);
                lastNode = self.rbInsertRight(lastNode, piece);
            }
        }

        if (self._buffers.items.len == 0) {
            const emptyString = try self.allocator.create(StringBuffer);
            self._buffers.append(emptyString);
        }

        self.computeBufferMetadata();
    }

    fn normalizeEOL(self: *PieceTreeBase, eol: LineFeed) !void {
        var tempChunk = ArrayList(u8).init(self.allocator);
        defer tempChunk.deinit();

        var chunks = ArrayList(*StringBuffer).init(self.allocator);
        defer chunks.deinit();

        const iter = self.root.iterator();
        while (iter.next()) |node| {
            const averageBufferSize = AverageBufferSize;
            const min = averageBufferSize - @divFloor(averageBufferSize, 3);
            const max = min * 2;

            const str = self.getNodeContent(node);

            if (tempChunk.items.len <= min or tempChunk.items.len + str.len < max) {
                tempChunk.appendSlice(str);
            } else {
                // flush anyways
                replaceEOL(&tempChunk, self.getEOL());
                chunks.append(try StringBuffer.create(self.allocator, tempChunk.items));
                tempChunk.replaceRange(0, tempChunk.items.len, str);
            }
        }

        if (tempChunk.items.len > 0) {
            replaceEOL(&tempChunk, eol);
            chunks.append(try StringBuffer.create(self.allocator, tempChunk.items));
        }

        rbt.freeTree(self.allocator, self.root);
        self.root = SENTINEL;
        self._buffers.resize(0);
        self._lineCnt = 1;
        self._EOL = eol;
        self._EOLNormalized = true;
        self._searchCache.reset();
        self._lastVisitedLine = null;
        self.resetBuffers(chunks);
    }

    fn getNodeContent(self: *PieceTreeBase, node: *TreeNode) []u8 {
        if (node == SENTINEL) {
            return EMPTY_STRING;
        }

        return self.getPieceContent(node.piece.?);
    }

    fn getPieceContent(self: *PieceTreeBase, piece: *Piece) []u8 {
        const buffer = self._buffers.items[piece.bufferIndex];
        const startOffset = self.offsetInBuffer(piece.bufferIndex, piece.start);
        const endOffset = self.offsetInBuffer(piece.bufferIndex, piece.end);
        return buffer.buffer[startOffset..endOffset];
    }

    fn offsetInBuffer(self: *PieceTreeBase, bufferIndex: usize, cursor: BufferCursor) usize {
        const lineStarts = self._buffers.items[bufferIndex].lineStarts;
        return lineStarts[cursor.line] + cursor.column;
    }

    fn computeBufferMetadata(self: *PieceTreeBase) void {
        var x = self.root;

        var lfCnt = 1;
        var len = 0;

        while (x != SENTINEL) {
            lfCnt += x.lf_left + x.piece.lineFeedCnt;
            len += x.size_left + x.piece.length;
            x = x.right;
        }

        self._lineCnt = lfCnt;
        self._length = len;
        self._searchCache.validate(len);
    }

    fn rbInsertRight(self: *PieceTreeBase, node: ?*TreeNode, p: Piece) *TreeNode {
        const z = rbt.TreeNode.create(self.allocator, p);
        self.root = rbt.insertRight(self.root, node, z);
        return z;
    }

    fn rbInsertLeft(self: *PieceTreeBase, node: ?*TreeNode, p: Piece) *TreeNode {
        const z = rbt.TreeNode.create(self.allocator, p);
        self.root = rbt.insertLeft(self.root, node, z);
        return z;
    }

    fn getEOL(self: *PieceTreeBase) []u8 {
        if (self._EOL == .CRLF) {
            return "\r\n";
        } else {
            return "\n";
        }
    }

    fn getOffsetAt(self: *PieceTreeBase, lineNumber: usize, column: usize) usize {
        var leftLen = 0; // inorder

        var x = self.root;

        while (x != SENTINEL) {
            if (x.left != SENTINEL and x.lf_left + 1 >= lineNumber) {
                x = x.left;
            } else if (x.lf_left + x.piece.lineFeedCnt + 1 >= lineNumber) {
                leftLen += x.size_left;
                // lineNumber >= 2
                const accumualtedValInCurrentIndex = self.getAccumulatedValue(x, lineNumber - x.lf_left - 2);
                leftLen += accumualtedValInCurrentIndex + column - 1;
                return leftLen;
            } else {
                lineNumber -= x.lf_left + x.piece.lineFeedCnt;
                leftLen += x.size_left + x.piece.length;
                x = x.right;
            }
        }

        return leftLen;
    }

    fn getIndexOf(self: *PieceTreeBase, node: *TreeNode, accumulatedValue: usize) struct { index: usize, remainder: usize } {
        const piece = node.piece.?;
        const pos = self.positionInBuffer(node, accumulatedValue).?;
        const lineCnt = pos.line - piece.start.line;

        if (self.offsetInBuffer(piece.bufferIndex, piece.end) - self.positionInBuffer(piece.bufferIndex, piece.start) == accumulatedValue) {
            // we are checking the end of this node, so a CRLF check is necessary.
            const realLineCnt = self.getLineFeedCnt(piece.bufferIndex, piece.start, pos);
            if (realLineCnt != lineCnt) {
                // aha yes, CRLF
                return .{ .index = realLineCnt, .remainder = 0 };
            }
        }

        return .{ .index = lineCnt, .remainder = pos.column };
    }

    fn positionInBuffer(self: *PieceTreeBase, node: *TreeNode, accumulatedValue: usize) ?BufferCursor {
        _ = self;
        _ = node;
        _ = accumulatedValue;
        return null;
    }

    fn getAccumulatedValue(self: *PieceTreeBase, node: *TreeNode, index: usize) void {
        if (index < 0) return 0;
        const piece = node.piece;
        const lineStarts = self._buffers.items[piece.bufferIndex].lineStarts;
        const expectedLineStartIndex = piece.start.line + index + 1;
        if (expectedLineStartIndex > piece.end.line) {
            return lineStarts[piece.end.line] + piece.end.column - lineStarts[piece.start.line] + piece.start.column;
        } else {
            return lineStarts[expectedLineStartIndex] - lineStarts[piece.start.line] - piece.start.column;
        }
    }

    fn getLineFeedCnt(self: *PieceTreeBase, bufferIndex: usize, start: BufferCursor, end: BufferCursor) usize {
        // we don't need to worry about start: abc\r|\n, or abc|\r, or abc|\n, or abc|\r\n doesn't change the fact that, there is one line break after start.
        // now let's take care of end: abc\r|\n, if end is in between \r and \n, we need to add line feed count by 1
        if (end.column == 0) {
            return end.line - start.line;
        }

        const lineStarts = self._buffers.items[bufferIndex].lineStarts;
        if (end.line == lineStarts.length - 1) { // it means, there is no \n after end, otherwise, there will be one more lineStart.
            return end.line - start.line;
        }

        const nextLineStartOffset = lineStarts[end.line + 1];
        const endOffset = lineStarts[end.line] + end.column;
        if (nextLineStartOffset > endOffset + 1) { // there are more than 1 character after end, which means it can't be \n
            return end.line - start.line;
        }
        // endOffset + 1 === nextLineStartOffset
        // character at endOffset is \n, so we check the character before first
        // if character at endOffset is \r, end.column is 0 and we can't get here.
        const previousCharOffset = endOffset - 1; // end.column > 0 so it's okay.
        const buffer = self._buffers.items[bufferIndex].buffer;

        if (buffer[previousCharOffset] == 13) {
            return end.line - start.line + 1;
        } else {
            return end.line - start.line;
        }
    }

    fn deleteNodes(self: *PieceTreeBase, nodes: []const *TreeNode) void {
        for (nodes) |node| {
            self.root = rbt.rbDelete(self.root, node);
        }
    }

    fn createNewPieces(self: *PieceTreeBase, text: []u8) ArrayList(Piece) {
        if (text.len > AverageBufferSize) {
            // the content is large, operations like substring, charCode becomes slow
            // so here we split it into smaller chunks, just like what we did for CR/LF normalization
            const newPieces = ArrayList(Piece).init(self.allocator);
            while (text.len > AverageBufferSize) {
                const lastChar = text[text.len - 1];
                var splitText: []u8 = undefined;
                if (lastChar == '\r' or (lastChar >= 0xD800 and lastChar <= 0xDBFF)) {
                    // last character is \r or a high surrogate => keep it back
                    splitText = text[0 .. AverageBufferSize - 1];
                    text = text[(AverageBufferSize - 1)..];
                } else {
                    splitText = text[0..AverageBufferSize];
                    text = text[AverageBufferSize..];
                }

                const lineStarts = createLineStartsFast(self.allocator, splitText);
                newPieces.append(.{
                    .bufferIndex = self._buffers.items.len,
                    .start = .{ .line = 0, .column = 0 },
                    .end = .{ .line = lineStarts.items.len - 1, .column = text.len - lineStarts[lineStarts.items.len - 1] },
                    .lineFeedCnt = lineStarts.items.len - 1,
                    .length = text.len,
                });
                self._buffers.append(try StringBuffer.create(self.allocator, text, lineStarts));
                return newPieces;
            }
        }

        const startOffset = self._buffers.items[0].buffer.len;
        const lineStarts = createLineStartsFast(self.allocator, text);
        _ = lineStarts;

        // var start = self._lastChangeBufferPos;
        if (self._buffers.items[0].lineStarts.items[self._buffers.items[0].lineStarts.len - 1] == startOffset and startOffset != 0 and self.startWithLF(text) and self.endWithCR(self._buffers.items[0].buffer)) {
            self._lastChangeBufferPos = .{ .line = self._lastChangeBufferPos, .column = self._lastChangeBufferPos.column + 1 };
        }
    }

    fn strEndWithCR(self: *PieceTreeBase, val: []u8) bool {
        _ = self;
        return val[val.len - 1] == 13;
    }

    fn endWithCR(self: *PieceTreeBase, val: *TreeNode) bool {
        if (val == SENTINEL or val.piece.lineFeedCnt == 0) {
            return false;
        }

        return self.nodeCharCodeAt(val, val.piece.length - 1) == 13;
    }

    fn getContentOfSubTree(self: *PieceTreeBase, root: *TreeNode) ArrayList(u8) {
        const str = ArrayList(u8).init(self.allocator);
        const iter = root.iterator();
        while (iter.next()) |node| {
            str.append(self.getNodeContent(node));
        }
        return str;
    }

    fn nodeCharCodeAt(self: *PieceTreeBase, node: *TreeNode, offset: usize) u8 {
        const piece = node.piece.?;
        if (piece.lineFeedCnt < 1) {
            return -1;
        }

        const buffer = self._buffers.items[piece.bufferIndex].buffer;
        const newOffset = self.offsetInBuffer(piece.bufferIndex, piece.start) + offset;
        return buffer[newOffset];
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
        return self._EOLNormalized and self._EOL == '\n';
    }
};

fn toLineFeed(eol: []const u8) LineFeed {
    if (eol.len == 2 and eol[0] == '\r' and eol[1] == '\n') {
        return .CRLF;
    } else if (eol.len == 1 and eol[0] == '\r') {
        return .CR;
    } else {
        return .LF;
    }
}

fn lineFeedLen(lineFeed: LineFeed) usize {
    switch (lineFeed) {
        .CRLF => return 2,
        .CR => return 1,
        .LF => return 1,
    }
}

fn replaceEOL(target: *ArrayList(u8), eol: []const u8) !void {
    var i = target.items.len - 1;

    const lineFeed = toLineFeed(eol);

    while (true) {
        const ch = target.items[i];
        const ch_prev = if (i > 0) target.items[i - 1] else 0;

        var targetLineFeed: ?LineFeed = null;
        if (ch == '\r') {
            targetLineFeed = .CR;
        } else if (ch_prev == '\r' and ch == '\n') {
            targetLineFeed = .CRLF;
            i -= 1;
        } else if (ch == '\n') {
            targetLineFeed = .LF;
        }

        if (targetLineFeed != null and lineFeed != targetLineFeed.?) {
            try target.replaceRange(i, lineFeedLen(targetLineFeed.?), eol);
        }

        if (i == 0) break;
        i -= 1;
    }
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
    const eols = [_][]const u8{ "\n", "\r\n", "\r", "\n", "\n" };
    const afterReplaces = [_][]const u8{
        "Hello\nWorld\n",
        "Hello\r\nWorld\r\n",
        "Hello\rWorld\r",
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

pub fn main() !void {
    std.debug.print("Hello", .{});
}
