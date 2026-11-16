// Port of `../vscode-textmate/src/json.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// The upstream parser is a streaming reader with explicit state; this port is
// a recursive-descent reader over the same token set. It accepts and rejects
// the same JSON shapes (including the permissive number grammar), preserves
// duplicate-key last-wins behavior, and records object locations for debug
// mode.
//
// Adaptation: `\uXXXX` escape sequences are decoded into UTF-8. A valid
// surrogate pair is combined into one code point; an unpaired surrogate is
// replaced with U+FFFD because Zig strings are valid UTF-8.
const std = @import("std");
const rawGrammar = @import("rawGrammar.zig");
const Allocator = std.mem.Allocator;
const Value = rawGrammar.Value;
const Object = rawGrammar.Object;
const Location = rawGrammar.Location;

pub const ParseError = error{ InvalidJson, OutOfMemory, InvalidUtf8 };

pub fn parseJSON(
    allocator: Allocator,
    source: []const u8,
    filename: ?[]const u8,
    with_metadata: bool,
) ParseError!Value {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .filename = filename,
        .with_metadata = with_metadata,
    };
    parser.skipWhitespace();
    if (parser.pos >= source.len) return .null;
    const value = try parser.parseValue();
    parser.skipWhitespace();
    if (parser.pos != source.len) return error.InvalidJson;
    return value;
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    filename: ?[]const u8,
    with_metadata: bool,
    pos: usize = 0,
    line: u32 = 1,
    char: u32 = 0,

    fn current(self: *const Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos >= self.source.len) return;
        const byte = self.source[self.pos];
        if (byte < 0x80) {
            self.pos += 1;
            if (byte == '\n') {
                self.line += 1;
                self.char = 0;
            } else {
                self.char += 1;
            }
            return;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const end = @min(self.pos + length, self.source.len);
        const codepoint = std.unicode.utf8Decode(self.source[self.pos..end]) catch 0xFFFD;
        self.pos = end;
        self.char += if (codepoint > 0xFFFF) 2 else 1;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.current()) |byte| {
            switch (byte) {
                ' ', '\t', '\r' => self.advance(),
                '\n' => self.advance(),
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        const byte = self.current() orelse return error.InvalidJson;
        return switch (byte) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => .{ .string = try self.parseString() },
            't' => blk: {
                try self.expectLiteral("true");
                break :blk .{ .boolean = true };
            },
            'f' => blk: {
                try self.expectLiteral("false");
                break :blk .{ .boolean = false };
            },
            'n' => blk: {
                try self.expectLiteral("null");
                break :blk .null;
            },
            '-', '0'...'9' => .{ .number = try self.parseNumber() },
            else => error.InvalidJson,
        };
    }

    fn parseObject(self: *Parser) ParseError!Value {
        const location = Location{ .filename = self.filename, .line = self.line, .char = self.char };
        self.expectByte('{') catch return error.InvalidJson;

        const object = try self.allocator.create(Object);
        object.* = .{ .location = if (self.with_metadata) location else null };

        self.skipWhitespace();
        if (self.current() == '}') {
            self.advance();
            return .{ .object = object };
        }

        while (true) {
            self.skipWhitespace();
            if (self.current() != '"') return error.InvalidJson;
            const key = try self.parseString();
            self.skipWhitespace();
            self.expectByte(':') catch return error.InvalidJson;
            const value = try self.parseValue();
            try object.put(self.allocator, key, value);
            self.allocator.free(key);

            self.skipWhitespace();
            switch (self.current() orelse return error.InvalidJson) {
                ',' => {
                    self.advance();
                    self.skipWhitespace();
                    if (self.current() == '}') return error.InvalidJson;
                },
                '}' => {
                    self.advance();
                    return .{ .object = object };
                },
                else => return error.InvalidJson,
            }
        }
    }

    fn parseArray(self: *Parser) ParseError!Value {
        self.expectByte('[') catch return error.InvalidJson;
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);

        self.skipWhitespace();
        if (self.current() == ']') {
            self.advance();
            return .{ .array = try items.toOwnedSlice(self.allocator) };
        }

        while (true) {
            try items.append(self.allocator, try self.parseValue());
            self.skipWhitespace();
            switch (self.current() orelse return error.InvalidJson) {
                ',' => {
                    self.advance();
                    self.skipWhitespace();
                    if (self.current() == ']') return error.InvalidJson;
                },
                ']' => {
                    self.advance();
                    return .{ .array = try items.toOwnedSlice(self.allocator) };
                },
                else => return error.InvalidJson,
            }
        }
    }

    fn parseNumber(self: *Parser) ParseError!f64 {
        const start = self.pos;
        while (self.current()) |byte| {
            switch (byte) {
                '0'...'9', '.', 'e', 'E', '+', '-' => self.advance(),
                else => break,
            }
        }
        if (self.pos == start) return error.InvalidJson;
        return std.fmt.parseFloat(f64, self.source[start..self.pos]) catch error.InvalidJson;
    }

    fn parseString(self: *Parser) ParseError![]u8 {
        self.expectByte('"') catch return error.InvalidJson;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            const byte = self.current() orelse return error.InvalidJson;
            if (byte == '"') {
                self.advance();
                return out.toOwnedSlice(self.allocator);
            }
            if (byte == '\\') {
                self.advance();
                const escape = self.current() orelse return error.InvalidJson;
                self.advance();
                switch (escape) {
                    '"' => try out.append(self.allocator, '"'),
                    '\\' => try out.append(self.allocator, '\\'),
                    '/' => try out.append(self.allocator, '/'),
                    'b' => try out.append(self.allocator, 0x08),
                    'f' => try out.append(self.allocator, 0x0C),
                    'n' => try out.append(self.allocator, '\n'),
                    'r' => try out.append(self.allocator, '\r'),
                    't' => try out.append(self.allocator, '\t'),
                    'u' => {
                        var codepoint = try self.parseHex4();
                        if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                            // Combine a following low surrogate when present.
                            if (self.pos + 1 < self.source.len and self.source[self.pos] == '\\' and self.source[self.pos + 1] == 'u') {
                                const saved_pos = self.pos;
                                const saved_line = self.line;
                                const saved_char = self.char;
                                self.advance();
                                self.advance();
                                const low = self.parseHex4() catch {
                                    self.pos = saved_pos;
                                    self.line = saved_line;
                                    self.char = saved_char;
                                    try appendCodepoint(self.allocator, &out, 0xFFFD);
                                    continue;
                                };
                                if (low >= 0xDC00 and low <= 0xDFFF) {
                                    codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                                } else {
                                    try appendCodepoint(self.allocator, &out, 0xFFFD);
                                    try appendCodepoint(self.allocator, &out, low);
                                    continue;
                                }
                            } else {
                                codepoint = 0xFFFD;
                            }
                        } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                            codepoint = 0xFFFD;
                        }
                        try appendCodepoint(self.allocator, &out, @intCast(codepoint));
                    },
                    else => return error.InvalidJson,
                }
                continue;
            }

            // Copy one whole UTF-8 sequence (or a single raw byte).
            const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const end = @min(self.pos + length, self.source.len);
            try out.appendSlice(self.allocator, self.source[self.pos..end]);
            self.advance();
        }
    }

    fn parseHex4(self: *Parser) ParseError!u21 {
        if (self.pos + 4 > self.source.len) return error.InvalidJson;
        var value: u21 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const digit = std.fmt.charToDigit(self.source[self.pos], 16) catch return error.InvalidJson;
            value = value * 16 + digit;
            self.advance();
        }
        return value;
    }

    fn expectLiteral(self: *Parser, literal: []const u8) ParseError!void {
        if (!std.mem.startsWith(u8, self.source[self.pos..], literal)) return error.InvalidJson;
        for (literal) |_| self.advance();
    }

    fn expectByte(self: *Parser, byte: u8) !void {
        if (self.current() != byte) return error.InvalidJson;
        self.advance();
    }
};

fn appendCodepoint(allocator: Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch blk: {
        break :blk std.unicode.utf8Encode(0xFFFD, &buffer) catch 1;
    };
    try out.appendSlice(allocator, buffer[0..length]);
}

test "json accepts upstream valid cases" {
    const allocator = std.testing.allocator;
    const valid = [_][]const u8{
        "{}\n\n",
        "{}",
        "{\"key\": \"value\"}",
        "{\"key1\": true, \"key2\": 3, \"key3\": [null], \"key4\": { \"nested\": {}}}",
        "{\"constructor\": true }",
        "[]",
        "[1, 2]",
        "[1, \"string\", false, {}, [null]]",
        "[\"string\"]",
        "[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u1234\\u12AB\"]",
        "[\"\\\\\"]",
        "[0, -1, 186.1, 0.123, -1.583e+4, 1.583E-4, 5e8]",
        "{\"a\": 1, \"a\": 2}",
        "{\"a\": { \"a\": 2, \"a\": 3}}",
        "[{ \"a\": 2, \"a\": 3}]",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try parseJSON(arena.allocator(), source, null, false);
    }
}

test "json rejects upstream invalid cases" {
    const invalid = [_][]const u8{
        "{}[]",
        "*",
        "{",
        "{3:3}",
        "{'key': 3}",
        "{\"key\" 3}",
        "{\"key\":3 \"key2\": 4}",
        "{\"key\":42, }",
        "{\"key:42",
        "[",
        "[,]",
        "[1 2]",
        "[true false]",
        "[1, ]",
        "[[]",
        "[\"something\"",
        "[magic]",
        "[\"",
        "[\"]",
        "[\"\\z\"]",
        "[\"\\u\"]",
        "[\"\\u123\"]",
        "[\"\\u123Z\"]",
        "['string']",
        "{\n\"key\":32,\nerror\n}",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidJson, parseJSON(arena.allocator(), source, null, false));
    }
}

test "json stores object locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseJSON(arena.allocator(), "{\n  \"a\": {}}", "test.json", true);
    const root = value.object;
    try std.testing.expectEqual(@as(u32, 1), root.location.?.line);
    try std.testing.expectEqual(@as(u32, 0), root.location.?.char);
    const child = root.getObject("a").?;
    try std.testing.expectEqual(@as(u32, 2), child.location.?.line);
    try std.testing.expectEqual(@as(u32, 7), child.location.?.char);
}
