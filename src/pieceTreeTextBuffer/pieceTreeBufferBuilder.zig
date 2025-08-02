const std = @import("std");

const strings = @import("../basics/strings.zig");
const StringBuffer = @import("pieceTreeBase.zig").StringBuffer;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const createLineStarts = @import("pieceTreeBase.zig").createLineStarts;
const createLineStartsFast = @import("pieceTreeBase.zig").createLineStartsFast;
const EOL = @import("../basics/eolCounter.zig").EOL;
const PieceTreeTextBuffer = @import("pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const replaceEOL = @import("../basics/eolCounter.zig").replaceEOL;
const safeUtf8Prefix = @import("../tui/utf8Helper.zig").safeUtf8Prefix;

pub const PieceTreeTextBufferFactory = struct {
    _allocator: Allocator,
    _chunks: ArrayList(StringBuffer),
    _BOM: []const u8,
    _cr: usize,
    _lf: usize,
    _crlf: usize,
    _containsRTL: bool,
    _containsUnusualLineTerminators: bool,
    _isBasicASCII: bool,
    _normalizeEOL: bool,

    fn _getEOL(self: *const PieceTreeTextBufferFactory, defaultEOL: EOL) EOL {
        const totalEOLCount = self._cr + self._lf + self._crlf;
        const totalCRCount = self._cr + self._crlf;
        if (totalEOLCount == 0) {
            // This is an empty file or a file with precisely one line
            return if (defaultEOL == .LF) .LF else .CRLF;
        }
        if (totalCRCount > totalEOLCount / 2) {
            // More than half of the file contains \r\n ending lines
            return .CRLF;
        }
        // At least one line more ends in \n
        return .LF;
    }

    pub fn create(self: *const PieceTreeTextBufferFactory, defaultEOL: EOL) !PieceTreeTextBuffer {
        const eol = self._getEOL(defaultEOL);
        const chunks = self._chunks;

        if (self._normalizeEOL and ((eol == .CRLF and (self._cr > 0 or self._lf > 0)) or (eol == .LF and (self._cr > 0 or self._crlf > 0)))) {
            // Normalize Pieces
            for (chunks.items) |*chunk| {
                try replaceEOL(&chunk.buffer, eol);
                chunk.lineStarts = try createLineStartsFast(self._allocator, chunk.buffer.items);
            }
        }

        return PieceTreeTextBuffer
            .init(self._allocator, chunks.items, self._BOM, eol, self._containsRTL, self._containsUnusualLineTerminators, self._isBasicASCII, self._normalizeEOL);
    }

    pub fn getFirstLineText(self: *const PieceTreeTextBufferFactory, lengthLimit: usize) ![]const u8 {
        // TODO: handle \r\n
        return std.mem.sliceTo(self._chunks.items[0].buffer.items[0..lengthLimit], '\n');
    }

    pub fn deinit(self: *const PieceTreeTextBufferFactory) void {
        self._chunks.deinit();
    }
};

pub const PieceTreeBufferBuilder = struct {
    chunks: ArrayList(StringBuffer),
    BOM: []const u8,
    // previousChar can be '\r' or a partial UTF-8 sequence
    // since UTF-8 has at most 4 bytes, 3 is enough for a partial sequence
    _previousCharLen: u2,
    _previousChar: [3]u8,
    // _tmpLineStarts: ArrayList(usize),  -- this is not needed anymore, because the createLineStarts no needs to have UintArray

    cr: usize,
    lf: usize,
    crlf: usize,
    containsRTL: bool,
    containsUnusualLineTerminators: bool,
    isBasicASCII: bool,

    pub fn init(allocator: Allocator) PieceTreeBufferBuilder {
        return PieceTreeBufferBuilder{
            .chunks = ArrayList(StringBuffer).init(allocator),
            .BOM = "",

            ._previousCharLen = 0,
            ._previousChar = undefined,

            .cr = 0,
            .lf = 0,
            .crlf = 0,
            .containsRTL = false,
            .containsUnusualLineTerminators = false,
            .isBasicASCII = true,
        };
    }

    pub fn acceptChunk(self: *PieceTreeBufferBuilder, chunk: []const u8) !void {
        if (chunk.len == 0) {
            return;
        }

        if (self.chunks.items.len == 0) {
            if (strings.startsWithUTF8BOM(chunk)) {
                self.BOM = strings.UTF8_BOM_CHARACTER;
            } else {
                self.BOM = "";
            }
        }

        const lastChar = chunk[chunk.len - 1];
        if (lastChar == '\r') {
            try self._acceptChunk1(chunk[0 .. chunk.len - 1], false);
            self._previousCharLen = 1;
            self._previousChar[0] = lastChar;
        } else {
            const chunk2 = safeUtf8Prefix(chunk, chunk.len);
            try self._acceptChunk1(chunk2, false);
            if (chunk2.len < chunk.len) {
                std.debug.assert(chunk.len - chunk2.len < 4);

                self._previousCharLen = @intCast(chunk.len - chunk2.len);

                for (chunk2.len..chunk.len) |i| {
                    self._previousChar[i - chunk2.len] = chunk[i];
                }
            } else {
                self._previousCharLen = 0;
            }
        }
    }

    fn _acceptChunk1(self: *PieceTreeBufferBuilder, chunk: []const u8, allowEmptyString: bool) !void {
        if (!allowEmptyString and chunk.len == 0) {
            // Nothing to do
            return;
        }

        try self._acceptChunk2(chunk);
    }

    fn _acceptChunk2(self: *PieceTreeBufferBuilder, chunk: []const u8) !void {
        var buffer = ArrayList(u8).init(self.chunks.allocator);
        if (self._getPreviousChar()) |previousChar| {
            try buffer.appendSlice(previousChar);
        }
        try buffer.appendSlice(chunk);

        var stringBuffer = StringBuffer{
            .buffer = buffer,
            .lineStarts = undefined,
        };
        const lineStarts = try createLineStarts(self.chunks.allocator, buffer.items);
        stringBuffer.lineStarts = lineStarts.lineStarts;

        try self.chunks.append(stringBuffer);
        self.cr += lineStarts.cr;
        self.lf += lineStarts.lf;
        self.crlf += lineStarts.crlf;

        if (!lineStarts.isBasicASCII) {
            self.isBasicASCII = false;
            if (!self.containsRTL) {
                self.containsRTL = strings.containsRTL(chunk);
            }
            if (!self.containsUnusualLineTerminators) {
                self.containsUnusualLineTerminators = strings.containsUnusualLineTerminators(chunk);
            }
        }
    }

    pub fn finish(self: *PieceTreeBufferBuilder, normalizeEOL: bool) !PieceTreeTextBufferFactory {
        try self._finish();
        return PieceTreeTextBufferFactory{
            ._chunks = self.chunks,
            ._allocator = self.chunks.allocator,
            ._BOM = self.BOM,
            ._cr = self.cr,
            ._lf = self.lf,
            ._crlf = self.crlf,
            ._containsRTL = self.containsRTL,
            ._containsUnusualLineTerminators = self.containsUnusualLineTerminators,
            ._isBasicASCII = self.isBasicASCII,
            ._normalizeEOL = normalizeEOL,
        };
    }

    fn _getPreviousChar(self: *PieceTreeBufferBuilder) ?[]const u8 {
        if (self._previousCharLen == 0) {
            return null;
        }
        return self._previousChar[0..self._previousCharLen];
    }

    fn _finish(self: *PieceTreeBufferBuilder) !void {
        if (self.chunks.items.len == 0) {
            try self._acceptChunk1("", true);
        }

        if (self._getPreviousChar()) |previousChar| {
            // recreate last chunk
            var lastChunk = self.chunks.items[self.chunks.items.len - 1];
            try lastChunk.buffer.appendSlice(previousChar);

            const newLineStarts = try createLineStartsFast(self.chunks.allocator, lastChunk.buffer.items);
            lastChunk.lineStarts.deinit();
            lastChunk.lineStarts = newLineStarts;
            if (previousChar[0] == '\r') {
                self.cr += 1;
            }
        }
    }
};

test "PieceTreeBufferBuilder" {
    const allocator = std.testing.allocator;
    var builder = PieceTreeBufferBuilder.init(allocator);

    try builder.acceptChunk("Hello");
    try builder.acceptChunk("World");

    var factory = try builder.finish(false);
    defer factory.deinit();

    var buffer = try factory.create(.LF);
    defer buffer.deinit();

    const lineContent = try buffer.getLineContent(1);
    defer lineContent.deinit();
    try std.testing.expectEqualStrings("HelloWorld", lineContent.items);
}

test "PieceTreeBufferBuilder unicode" {
    const allocator = std.testing.allocator;
    var builder = PieceTreeBufferBuilder.init(allocator);

    const str = "你好世界";
    try builder.acceptChunk(str[0..5]);
    try builder.acceptChunk(str[5..]);

    var factory = try builder.finish(false);
    defer factory.deinit();

    var buffer = try factory.create(.LF);
    defer buffer.deinit();

    const lineContent = try buffer.getLineContent(1);
    defer lineContent.deinit();

    try std.testing.expectEqualStrings("你好世界", lineContent.items);
}
