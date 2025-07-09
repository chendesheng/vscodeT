const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const AnsiDataKind = enum(u2) {
    string,
    csi,
};

pub const AnsiData = union(AnsiDataKind) {
    string: []u8,
    csi: struct {
        parameters: []const u8,
        intermediate: []const u8,
        final: u8,
    },

    pub fn free(self: *const AnsiData, allocator: Allocator) void {
        switch (self.*) {
            .string => allocator.free(self.string),
            .csi => {
                allocator.free(self.csi.parameters);
                allocator.free(self.csi.intermediate);
            },
        }
    }
};

// proc parseAnsi*(input: string): seq[AnsiData] =
//   ## This procedure will take a string and parse it into a sequence of AnsiData
//   ## elements that split the string in string parts and ANSI escape code parts.
//   var
//     lastpos = 0
//     pos = 0
//   while pos < input.len:
//     if input[pos] == 0x1b.char and pos+1 < input.len:
//       if input[pos+1] == '[':
//         if lastpos != pos:
//           result.add AnsiData(kind: String, str: input[lastpos..<pos])
//         pos += 2
//         lastpos = pos
//         result.add AnsiData(kind: CSI)
//         while input.len > pos and input[pos] in {0x30.char..0x3F.char}:
//           pos += 1
//         if pos >= input.len:
//           var err = newException(InsufficientInputError, "ANSI sequence didn't properly terminate before end of input")
//           err.position = pos
//           raise err
//         result[^1].parameters = input[lastpos..<pos]
//         lastpos = pos
//         while input.len > pos and input[pos] in {0x20.char..0x2F.char}:
//           pos += 1
//         if pos >= input.len:
//           var err = newException(InsufficientInputError, "ANSI sequence didn't properly terminate before end of input")
//           err.position = pos
//           raise err
//         result[^1].intermediate = input[lastpos..<pos]
//         if input[pos] notin {0x40.char..0x7E.char}:
//           var err = newException(FinalByteError, "Final byte of sequence at position " & $pos & " not in range 0x40-0x7E is " & $input[pos].byte)
//           err.position = pos
//           raise err
//         result[^1].final = input[pos]
//         lastpos = pos + 1
//       else:
//         var err = newException(UnknownEscapeError, "Unknown escape sequence at position " & $pos & ", currently only CSI sequences are recognised")
//         err.position = pos
//         raise err
//     pos += 1
//
//   if lastpos != input.len:
//     result.add AnsiData(kind: String, str: input[lastpos..^1])

const ESC = 0x1b;

fn isIntermediateChar(chr: u8) bool {
    return 0x20 <= chr and chr <= 0x2F;
}

fn isParameterChar(chr: u8) bool {
    return ('0' <= chr and chr <= '9') or chr == ';' or chr == ':';
}

fn isFinalChar(chr: u8) bool {
    return 0x40 <= chr and chr <= 0x7E;
}

fn isFinalCharForEscSequence(chr: u8) bool {
    return 0x30 <= chr and chr <= 0x7E;
}

fn zeroOrMoreIntermediateChars(input: []const u8, pos: usize) []const u8 {
    var i = pos;
    while (i < input.len and isIntermediateChar(input[i])) {
        i += 1;
    }

    if (i == pos) {
        return "";
    }

    return input[pos..i];
}

fn oneOrMoreParameterChars(input: []const u8, pos: usize) ![]const u8 {
    var i = pos;
    while (i < input.len and isParameterChar(input[i])) {
        i += 1;
    }

    if (i == pos) {
        return error.ExpectedParameterChar;
    }
    return input[pos..i];
}

fn mustFinalChar(input: []const u8, pos: usize) !u8 {
    if (pos >= input.len) {
        return error.InsufficientInput;
    }

    const chr = input[pos];
    if (isFinalChar(chr)) {
        return chr;
    } else {
        return error.InsufficientInput;
    }
}
fn mustFinalCharForEscSequence(input: []const u8, pos: usize) !u8 {
    if (pos >= input.len) {
        return error.InsufficientInput;
    }

    const chr = input[pos];
    if (isFinalCharForEscSequence(chr)) {
        return chr;
    } else {
        return error.InsufficientInput;
    }
}

const Iterator = struct {
    reader: io.AnyReader,
    allocator: Allocator,
    buffer: ArrayList(u8),

    pub fn init(allocator: Allocator, reader: io.AnyReader) Iterator {
        return Iterator{
            .reader = reader,
            .allocator = allocator,
            .buffer = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Iterator) void {
        self.buffer.deinit();
    }

    fn read(self: *Iterator) !ArrayList(u8) {
        var tmp: [32]u8 = undefined;
        self.buffer.clearRetainingCapacity();
        while (true) {
            const n = try self.reader.readAll(&tmp);
            if (n > 0) {
                try self.buffer.appendSlice(tmp[0..n]);
            }
            if (n < tmp.len) {
                break;
            }
        }
        return self.buffer;
    }

    pub fn readAndParse(self: *Iterator) !ArrayList(AnsiData) {
        const buffer = try self.read();
        return try self.parse(buffer.items);
    }

    pub fn parse(self: *Iterator, input: []u8) !ArrayList(AnsiData) {
        var result = ArrayList(AnsiData).init(self.allocator);
        var lastpos: usize = 0;
        var pos: usize = 0;
        while (pos < input.len) {
            if (input[pos] == ESC and pos + 1 < input.len) {
                if (lastpos != pos) {
                    try result.append(AnsiData{
                        .string = input[lastpos..pos],
                    });
                }

                if (input[pos + 1] == '[') {
                    pos += 2;
                    const parameters = oneOrMoreParameterChars(input, pos) catch {
                        return result;
                    };
                    pos += parameters.len;
                    const intermediate = zeroOrMoreIntermediateChars(input, pos);
                    pos += intermediate.len;
                    const final = mustFinalChar(input, pos) catch {
                        return result;
                    };
                    pos += 1;
                    try result.append(AnsiData{
                        .csi = .{
                            .parameters = parameters,
                            .intermediate = intermediate,
                            .final = final,
                        },
                    });
                    lastpos = pos;
                } else {
                    pos += 1;
                    const intermediate = zeroOrMoreIntermediateChars(input, pos);
                    pos += intermediate.len;
                    const final = mustFinalCharForEscSequence(input, pos) catch {
                        return result;
                    };
                    pos += 1;
                    try result.append(AnsiData{
                        .csi = .{
                            .intermediate = intermediate,
                            .parameters = "",
                            .final = final,
                        },
                    });
                    lastpos = pos;
                }
            }
            pos += 1;
        }
        if (lastpos < input.len) {
            try result.append(AnsiData{ .string = input[lastpos..] });
        }
        return result;
    }
};

test "readAndParse multiple" {
    const allocator = std.testing.allocator;
    var stream = io.fixedBufferStream("Hello\x1b[31mWorld\x1b[0m");
    var iterator = Iterator.init(allocator, stream.reader().any());
    defer iterator.deinit();

    const result = try iterator.readAndParse();
    defer result.deinit();

    try std.testing.expectEqual(result.items.len, 4);

    try std.testing.expectEqual(std.meta.activeTag(result.items[0]), AnsiDataKind.string);
    try std.testing.expectEqualStrings(result.items[0].string, "Hello");

    try std.testing.expectEqual(std.meta.activeTag(result.items[1]), AnsiDataKind.csi);
    try std.testing.expectEqualStrings(result.items[1].csi.parameters, "31");
    try std.testing.expectEqualStrings(result.items[1].csi.intermediate, "");
    try std.testing.expectEqual(result.items[1].csi.final, 'm');

    try std.testing.expectEqual(std.meta.activeTag(result.items[2]), AnsiDataKind.string);
    try std.testing.expectEqualStrings(result.items[2].string, "World");

    try std.testing.expectEqual(std.meta.activeTag(result.items[3]), AnsiDataKind.csi);
    try std.testing.expectEqualStrings(result.items[3].csi.parameters, "0");
    try std.testing.expectEqualStrings(result.items[3].csi.intermediate, "");
    try std.testing.expectEqual(result.items[3].csi.final, 'm');
}

test "readAndParse single" {
    const allocator = std.testing.allocator;
    var stream = io.fixedBufferStream("\x1b[1;2m");
    var iterator = Iterator.init(allocator, stream.reader().any());
    defer iterator.deinit();

    const result = try iterator.readAndParse();
    defer result.deinit();

    try std.testing.expectEqual(result.items.len, 1);
    try std.testing.expectEqual(std.meta.activeTag(result.items[0]), AnsiDataKind.csi);
    try std.testing.expectEqualStrings(result.items[0].csi.parameters, "1;2");
    try std.testing.expectEqualStrings(result.items[0].csi.intermediate, "");
    try std.testing.expectEqual(result.items[0].csi.final, 'm');
}

test "readAndParse empty" {
    const allocator = std.testing.allocator;
    var stream = io.fixedBufferStream("");
    var iterator = Iterator.init(allocator, stream.reader().any());
    defer iterator.deinit();

    const result = try iterator.readAndParse();
    defer result.deinit();

    try std.testing.expectEqual(result.items.len, 0);
}

test "readAndParse escape" {
    const allocator = std.testing.allocator;
    var stream = io.fixedBufferStream("\x1b");
    var iterator = Iterator.init(allocator, stream.reader().any());
    defer iterator.deinit();

    const result = try iterator.readAndParse();
    defer result.deinit();

    try std.testing.expectEqual(result.items.len, 1);
    try std.testing.expectEqual(std.meta.activeTag(result.items[0]), AnsiDataKind.string);
    try std.testing.expectEqualStrings(result.items[0].string, "\x1b");
}
