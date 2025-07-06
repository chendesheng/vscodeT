const std = @import("std");

const strings = @import("strings.zig");
const StringBuffer = @import("pieceTreeBase.zig").StringBuffer;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const createLineStarts = @import("pieceTreeBase.zig").createLineStarts;
const createLineStartsFast = @import("pieceTreeBase.zig").createLineStartsFast;
const EOL = @import("pieceTreeBase.zig").EOL;
const PieceTreeTextBuffer = @import("pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const replaceEOL = @import("pieceTreeBase.zig").replaceEOL;

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

    fn create(self: *const PieceTreeTextBufferFactory, defaultEOL: EOL) !PieceTreeTextBuffer {
        const eol = self._getEOL(defaultEOL);
        const chunks = self._chunks;

        if (self._normalizeEOL and ((eol == .CRLF and (self._cr > 0 or self._lf > 0)) or (eol == .LF and (self._cr > 0 or self._crlf > 0)))) {
            // Normalize Pieces
            for (chunks.items) |chunk| {
                try replaceEOL(chunk.buffer, eol);
                chunk.lineStarts = try createLineStartsFast(self._allocator, chunk.buffer.items);
            }
        }

        return PieceTreeTextBuffer
            .init(self._allocator, chunks, self._BOM, eol, self._containsRTL, self._containsUnusualLineTerminators, self._isBasicASCII, self._normalizeEOL);
    }

    pub fn getFirstLineText(self: *const PieceTreeTextBufferFactory, lengthLimit: usize) ![]const u8 {
        // TODO: handle \r\n
        return std.mem.sliceTo(self._chunks.items[0].buffer.items[0..lengthLimit], '\n');
    }
};

pub const PieceTreeBufferBuilder = struct {
    chunks: ArrayList(StringBuffer),
    BOM: []const u8,
    _hasPreviousChar: bool,
    _previousChar: u8,
    _tmpLineStarts: ArrayList(usize),

    cr: usize,
    lf: usize,
    crlf: usize,
    containsRTL: bool,
    containsUnusualLineTerminators: bool,
    isBasicASCII: bool,

    pub fn init(allocator: Allocator) !PieceTreeBufferBuilder {
        return PieceTreeBufferBuilder{
            .chunks = ArrayList(StringBuffer).init(allocator),
            .BOM = "",

            ._hasPreviousChar = false,
            ._previousChar = 0,
            ._tmpLineStarts = ArrayList(usize).init(allocator),

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
            if (strings.startsWithUTF8BOM(chunk.text)) {
                self.BOM = strings.UTF8_BOM_CHARACTER;
            } else {
                self.BOM = "";
            }
        }

        const lastChar = chunk[chunk.len - 1];
        if (lastChar == '\r' or (lastChar >= 0xD800 and lastChar <= 0xDFFF)) {
            self._acceptChunk1(chunk[0 .. chunk.len - 1], false);
            self._hasPreviousChar = true;
            self._previousChar = lastChar;
        } else {
            self._acceptChunk1(chunk, false);
            self._hasPreviousChar = false;
            self._previousChar = lastChar;
        }
    }

    fn _acceptChunk1(self: *PieceTreeBufferBuilder, chunk: []const u8, allowEmptyString: bool) !void {
        if (!allowEmptyString and chunk.len == 0) {
            // Nothing to do
            return;
        }

        if (self._hasPreviousChar) {
            self._accpetChunk2(self._previousChar + chunk);
        } else {
            self._acceptChunk2(chunk);
        }
    }

    fn _acceptChunk2(self: *PieceTreeBufferBuilder, chunk: []const u8) !void {
        const lineStarts = try createLineStarts(self.chunks.allocator, chunk);

        self.chunks.append(StringBuffer.initFromArrayList(self.chunks.allocator, lineStarts.lineStarts));
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
        self._finish();
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

    fn _finish(self: *PieceTreeBufferBuilder) void {
        if (self.chunks.items.len == 0) {
            self._acceptChunk1("", true);
        }

        if (self._hasPreviousChar) {
            self._hasPreviousChar = false;
            // recreate last chunk
            const lastChunk = self.chunks.items[self.chunks.items.len - 1];
            lastChunk.append(self._previousChar);
            const newLineStarts = try createLineStartsFast(self.chunks.allocator, lastChunk.buffer.items);
            lastChunk.lineStarts = newLineStarts;
            if (self._previousChar == '\r') {
                self.cr += 1;
            }
        }
    }
};
