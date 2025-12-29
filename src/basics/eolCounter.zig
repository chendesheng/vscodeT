const std = @import("std");
const ArrayList = std.array_list.Managed;

pub const EOL = enum(u8) {
    CRLF,
    LF,

    pub fn length(self: EOL) usize {
        return switch (self) {
            .CRLF => 2,
            .LF => 1,
        };
    }
};

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

pub fn countEOLFixed(text: []const u8) CountEOLResult {
    var r = std.Io.Reader.fixed(text);
    return countEOL(&r);
}

pub fn countEOL(text: *std.Io.Reader) CountEOLResult {
    var eolCount: usize = 0;
    var firstLineLength: usize = 0;
    var lastLineStart: usize = 0;
    var eol: u2 = Unknown;

    while (true) {
        const chr = text.peekByte() catch break;
        if (chr == '\r') {
            if (eolCount == 0) {
                firstLineLength = text.seek;
            }
            text.toss(1);
            eolCount += 1;
            const next = text.peekByte() catch ' ';
            if (next == '\n') {
                // \r\n... case
                eol |= CRLF;
                text.toss(1);
            } else {
                // \r... case
                eol |= Invalid;
            }
            lastLineStart = text.seek;
        } else if (chr == '\n') {
            // \n... case
            eol |= LF;
            if (eolCount == 0) {
                firstLineLength = text.seek;
            }
            text.toss(1);
            eolCount += 1;
            lastLineStart = text.seek;
        } else {
            text.toss(1);
        }
    }

    if (eolCount == 0) {
        firstLineLength = text.seek;
    }

    return CountEOLResult{
        .eolCount = eolCount,
        .firstLineLength = firstLineLength,
        .lastLineLength = text.seek - lastLineStart,
        .eol = @enumFromInt(eol),
    };
}

test "countEOL" {
    const result = countEOLFixed("Hello\nWorld\n");
    try std.testing.expectEqual(2, result.eolCount);
    try std.testing.expectEqual(5, result.firstLineLength);
    try std.testing.expectEqual(0, result.lastLineLength);
    try std.testing.expectEqual(.LF, result.eol);
}

pub fn eolToString(eol: EOL) []const u8 {
    if (eol == .CRLF) {
        return "\r\n";
    } else {
        return "\n";
    }
}

pub fn replaceEOL(target: *ArrayList(u8), eol: EOL) !void {
    if (target.items.len == 0) return;

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
