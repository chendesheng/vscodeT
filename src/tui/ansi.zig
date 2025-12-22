const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

// esc_sequence = "\x1b", intermediates, final
// intermediates = {0x20..0x2F}
// final = 0x30..0x7E

// csi_sequence  = "\x1b", "[", parameters, intermediates, final
// parameters     = { 0x30..0x3F }   ; '0'-'9', ';', ':', '<', '=', '>', '?'
// intermediates  = { 0x20..0x2F }   ; optional
// final         = 0x40..0x7E      ; mandatory

pub const AnsiTokenType = enum(u2) {
    string,
    csi,
};

pub const AnsiToken = union(AnsiTokenType) {
    pub const Csi = struct {
        parameters: []const u8,
        intermediate: []const u8,
        final: u8,
    };

    string: []const u8,
    csi: Csi,

    pub fn isCsi(self: *const AnsiToken, csi: Csi) bool {
        return switch (self.*) {
            .string => false,
            .csi => std.mem.eql(u8, self.csi.parameters, csi.parameters) and std.mem.eql(u8, self.csi.intermediate, csi.intermediate) and self.csi.final == csi.final,
        };
    }

    pub fn isEscSequence(self: *const AnsiToken, intermediate: []const u8, final: u8) bool {
        return self.isCsi(.{ .parameters = "", .intermediate = intermediate, .final = final });
    }

    pub fn isBracketedPasteStart(self: *const AnsiToken) bool {
        return self.isCsi(.{ .parameters = "200", .intermediate = "", .final = '~' });
    }

    pub fn isBracketedPasteEnd(self: *const AnsiToken) bool {
        return self.isCsi(.{ .parameters = "201", .intermediate = "", .final = '~' });
    }
};

const ESC = 0x1b;

fn isIntermediateChar(chr: u8) bool {
    return 0x20 <= chr and chr <= 0x2F;
}

fn isParameterChar(chr: u8) bool {
    return 0x30 <= chr and chr <= 0x3F;
}

fn isFinalChar(chr: u8) bool {
    return 0x40 <= chr and chr <= 0x7E;
}

fn isFinalCharForEscSequence(chr: u8) bool {
    return 0x30 <= chr and chr <= 0x7E;
}

const AnsiTokenizerState = enum {
    normal,
    esc,
    escParameter,
    escParameterIntermediate,
    escIntermediate,
    bracketedPaste,
};

pub fn tokenize(allocator: Allocator, input: []const u8) !ArrayList(AnsiToken) {
    var state: AnsiTokenizerState = .normal;
    var result = ArrayList(AnsiToken).init(allocator);
    var lastpos: usize = 0;
    var pos: usize = 0;
    var currentData = AnsiToken{ .csi = .{ .parameters = "", .intermediate = "", .final = 0 } };
    while (pos < input.len) {
        const chr = input[pos];
        switch (state) {
            .normal => {
                if (chr == ESC) {
                    if (lastpos < pos) {
                        try result.append(AnsiToken{ .string = input[lastpos..pos] });
                    }
                    state = .esc;
                }
            },
            .esc => {
                if (chr == '[') {
                    state = .escParameter;
                    lastpos = pos + 1;
                } else if (isIntermediateChar(chr)) {
                    state = .escIntermediate;
                    lastpos = pos;
                } else if (isFinalCharForEscSequence(chr)) {
                    currentData.csi.parameters = "";
                    currentData.csi.intermediate = "";
                    currentData.csi.final = chr;
                    try result.append(currentData);
                    state = .normal;
                    lastpos = pos + 1;
                } else {
                    state = .normal;
                }
            },
            .escParameter => {
                if (isIntermediateChar(chr)) {
                    currentData.csi.parameters = input[lastpos..pos];
                    state = .escParameterIntermediate;
                    lastpos = pos;
                } else if (isFinalChar(chr)) {
                    currentData.csi.parameters = input[lastpos..pos];
                    currentData.csi.intermediate = "";
                    currentData.csi.final = chr;
                    try result.append(currentData);
                    if (currentData.isBracketedPasteStart()) {
                        state = .bracketedPaste;
                    } else {
                        state = .normal;
                    }
                    lastpos = pos + 1;
                }
            },
            .escParameterIntermediate => {
                if (isFinalChar(chr)) {
                    currentData.csi.intermediate = input[lastpos..pos];
                    currentData.csi.final = chr;
                    try result.append(currentData);
                    state = .normal;
                }
            },
            .escIntermediate => {
                if (isFinalCharForEscSequence(chr)) {
                    currentData.csi.parameters = "";
                    currentData.csi.intermediate = input[lastpos..pos];
                    currentData.csi.final = chr;
                    try result.append(currentData);
                    state = .normal;
                }
            },
            .bracketedPaste => {
                if (std.mem.eql(u8, input[pos .. pos + 6], "\x1b[201~")) {
                    if (lastpos < pos) {
                        try result.append(AnsiToken{ .string = input[lastpos..pos] });
                    }
                    try result.append(AnsiToken{ .csi = .{ .parameters = "201", .intermediate = "", .final = '~' } });
                    state = .normal;
                    pos += 5;
                    lastpos = pos + 1;
                }
            },
        }
        pos += 1;
    }

    if (lastpos < pos) {
        try result.append(AnsiToken{ .string = input[lastpos..pos] });
    }
    return result;
}

test "tokenize multiple" {
    const allocator = std.testing.allocator;

    const result = try tokenize(allocator, "Hello\x1b[31mWorld\x1b[0m");
    defer result.deinit();

    try std.testing.expectEqual(4, result.items.len);

    try std.testing.expectEqualStrings("Hello", result.items[0].string);
    try std.testing.expect(result.items[1].isCsi(.{ .parameters = "31", .intermediate = "", .final = 'm' }));
    try std.testing.expectEqualStrings("World", result.items[2].string);
    try std.testing.expect(result.items[3].isCsi(.{ .parameters = "0", .intermediate = "", .final = 'm' }));
}

test "readAndTokenize single" {
    const allocator = std.testing.allocator;

    const Case = struct {
        input: []const u8,
        expected: AnsiToken.Csi,
    };
    const cases = [_]Case{
        .{ .input = "\x1b[1;2m", .expected = .{ .parameters = "1;2", .intermediate = "", .final = 'm' } },
        .{ .input = "\x1bD", .expected = .{ .parameters = "", .intermediate = "", .final = 'D' } },
    };

    for (cases) |c| {
        const result = try tokenize(allocator, c.input);
        defer result.deinit();

        try std.testing.expectEqual(1, result.items.len);
        try std.testing.expectEqualDeep(c.expected, result.items[0].csi);
    }
}

test "readAndTokenize empty" {
    const allocator = std.testing.allocator;

    const result = try tokenize(allocator, "");
    defer result.deinit();

    try std.testing.expectEqual(0, result.items.len);
}

test "readAndTokenize escape" {
    const allocator = std.testing.allocator;

    const result = try tokenize(allocator, "\x1b");
    defer result.deinit();

    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings("\x1b", result.items[0].string);
}

test "readAndTokenize bracketed paste" {
    const allocator = std.testing.allocator;

    const result = try tokenize(allocator, "\x1b[200~hello\x1b[201~");
    defer result.deinit();

    try std.testing.expectEqual(3, result.items.len);

    try std.testing.expect(result.items[0].isBracketedPasteStart());
    try std.testing.expectEqualStrings("hello", result.items[1].string);
    try std.testing.expect(result.items[2].isBracketedPasteEnd());
}
