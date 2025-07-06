const std = @import("std");

const Unknown = 0;
const Invalid = 3;
const LF = 1;
const CRLF = 2;

pub const StringEOL = enum(u2) {
    Unknown = Unknown,
    Invalid = Invalid,
    LF = LF,
    CRLF = CRLF,
};

pub const CountEOLResult = struct {
    eolCount: usize,
    firstLineLength: usize,
    lastLineLength: usize,
    eol: StringEOL,
};

pub fn countEOL(text: []const u8) CountEOLResult {
    var eolCount: usize = 0;
    var firstLineLength: usize = 0;
    var lastLineStart: usize = 0;
    var eol: u2 = Unknown;

    var i: usize = 0;
    const len = text.len;
    while (i < len) : (i += 1) {
        const chr = text[i];

        if (chr == '\r') {
            if (eolCount == 0) {
                firstLineLength = i;
            }
            eolCount += 1;
            if (i + 1 < len and text[i + 1] == '\n') {
                // \r\n... case
                eol |= CRLF;
                i += 1; // skip \n
            } else {
                // \r... case
                eol |= Invalid;
            }
            lastLineStart = i + 1;
        } else if (chr == '\n') {
            // \n... case
            eol |= LF;
            if (eolCount == 0) {
                firstLineLength = i;
            }
            eolCount += 1;
            lastLineStart = i + 1;
        }
    }

    if (eolCount == 0) {
        firstLineLength = len;
    }

    return CountEOLResult{
        .eolCount = eolCount,
        .firstLineLength = firstLineLength,
        .lastLineLength = len - lastLineStart,
        .eol = @enumFromInt(eol),
    };
}

test "countEOL" {
    const result = countEOL("Hello\nWorld\n");
    try std.testing.expectEqual(2, result.eolCount);
    try std.testing.expectEqual(5, result.firstLineLength);
    try std.testing.expectEqual(0, result.lastLineLength);
    try std.testing.expectEqual(.LF, result.eol);
}
