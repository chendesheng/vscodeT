// Port of `../vscode-textmate/src/plist.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// Adaptation: dates are preserved as their raw text (`Value.date`) and
// `<data>` as `Value.data`, because this port has no JavaScript `Date` type.
// Both are only meaningful to grammar/theme readers as opaque values, which is
// how vscode-textmate treats them.
const std = @import("std");
const rawGrammar = @import("rawGrammar.zig");
const Allocator = std.mem.Allocator;
const Value = rawGrammar.Value;
const Object = rawGrammar.Object;
const Location = rawGrammar.Location;

pub const ParseError = error{ InvalidPlist, OutOfMemory, InvalidUtf8 };

pub fn parsePLIST(allocator: Allocator, content: []const u8) ParseError!Value {
    return parseWithLocation(allocator, content, null, null);
}

pub fn parseWithLocation(
    allocator: Allocator,
    content: []const u8,
    filename: ?[]const u8,
    location_key_name: ?[]const u8,
) ParseError!Value {
    var parser = Parser{
        .allocator = allocator,
        .content = content,
        .filename = filename,
        .with_location = filename != null or location_key_name != null,
    };
    return parser.parseDocument();
}

const Parser = struct {
    allocator: Allocator,
    content: []const u8,
    filename: ?[]const u8,
    with_location: bool,
    pos: usize = 0,
    line: u32 = 1,
    char: u32 = 0,
    tag_name_buffer: [128]u8 = undefined,

    fn parseDocument(self: *Parser) ParseError!Value {
        if (self.content.len >= 3 and std.mem.eql(u8, self.content[0..3], "\xEF\xBB\xBF")) {
            self.pos = 3;
        }

        var result: Value = .null;
        var saw_value = false;

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.content.len) break;
            if (self.content[self.pos] != '<') return error.InvalidPlist;
            self.advanceOne();

            if (self.pos >= self.content.len) return error.InvalidPlist;
            switch (self.content[self.pos]) {
                '?' => {
                    self.advanceOne();
                    self.advanceUntil("?>");
                    continue;
                },
                '!' => {
                    self.advanceOne();
                    if (self.startsWith("--")) {
                        self.advanceUntil("-->");
                    } else {
                        self.advanceUntil(">");
                    }
                    continue;
                },
                '/' => {
                    self.advanceOne();
                    self.skipWhitespace();
                    if (self.advanceIfStartsWith("plist")) {
                        self.advanceUntil(">");
                        continue;
                    }
                    return error.InvalidPlist;
                },
                else => {},
            }

            const tag = try self.parseOpenTag();
            if (std.mem.eql(u8, tag.name, "plist")) {
                if (!tag.is_closed) {
                    const value = try self.parseElement();
                    result = value;
                    saw_value = true;
                    self.skipWhitespace();
                    if (!self.advanceIfStartsWith("</plist")) return error.InvalidPlist;
                    self.advanceUntil(">");
                }
                continue;
            }

            result = try self.parseElementFromTag(tag);
            saw_value = true;
        }

        if (!saw_value) return .null;
        return result;
    }

    fn parseElement(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        if (self.pos >= self.content.len or self.content[self.pos] != '<') return error.InvalidPlist;
        self.advanceOne();
        if (self.pos >= self.content.len) return error.InvalidPlist;
        if (self.content[self.pos] == '/') return error.InvalidPlist;
        if (self.content[self.pos] == '?') {
            self.advanceOne();
            self.advanceUntil("?>");
            return self.parseElement();
        }
        if (self.content[self.pos] == '!') {
            self.advanceOne();
            if (self.startsWith("--")) {
                self.advanceUntil("-->");
            } else {
                self.advanceUntil(">");
            }
            return self.parseElement();
        }
        const tag = try self.parseOpenTag();
        return self.parseElementFromTag(tag);
    }

    fn parseElementFromTag(self: *Parser, tag: Tag) ParseError!Value {
        if (std.mem.eql(u8, tag.name, "dict")) return self.parseDict(tag);
        if (std.mem.eql(u8, tag.name, "array")) return self.parseArray(tag);
        if (std.mem.eql(u8, tag.name, "key")) return error.InvalidPlist;

        if (std.mem.eql(u8, tag.name, "string")) {
            return .{ .string = try self.parseTagValue(tag) };
        }
        if (std.mem.eql(u8, tag.name, "real")) {
            const text = try self.parseTagValue(tag);
            defer self.allocator.free(text);
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t\r\n")) catch
                return error.InvalidPlist;
            return .{ .number = value };
        }
        if (std.mem.eql(u8, tag.name, "integer")) {
            const text = try self.parseTagValue(tag);
            defer self.allocator.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            var end: usize = 0;
            if (end < trimmed.len and (trimmed[end] == '-' or trimmed[end] == '+')) end += 1;
            while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) end += 1;
            if (end == 0) return error.InvalidPlist;
            const value: f64 = if (std.fmt.parseInt(i64, trimmed[0..end], 10)) |integer| blk: {
                break :blk @floatFromInt(integer);
            } else |_| blk: {
                break :blk std.fmt.parseFloat(f64, trimmed[0..end]) catch return error.InvalidPlist;
            };
            return .{ .number = value };
        }
        if (std.mem.eql(u8, tag.name, "date")) {
            return .{ .date = try self.parseTagValue(tag) };
        }
        if (std.mem.eql(u8, tag.name, "data")) {
            return .{ .data = try self.parseTagValue(tag) };
        }
        if (std.mem.eql(u8, tag.name, "true")) {
            const text = try self.parseTagValue(tag);
            self.allocator.free(text);
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, tag.name, "false")) {
            const text = try self.parseTagValue(tag);
            self.allocator.free(text);
            return .{ .boolean = false };
        }
        return error.InvalidPlist;
    }

    fn parseDict(self: *Parser, tag: Tag) ParseError!Value {
        const location = Location{ .filename = self.filename, .line = self.line, .char = self.char };
        const object = try self.allocator.create(Object);
        object.* = .{ .location = if (self.with_location) location else null };

        if (tag.is_closed) return .{ .object = object };

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.content.len) return error.InvalidPlist;

            if (self.startsWith("</dict")) {
                self.advanceUntil(">");
                return .{ .object = object };
            }

            if (!self.startsWith("<key")) return error.InvalidPlist;
            self.advanceOne(); // <
            const key_tag = try self.parseOpenTag();
            if (!std.mem.eql(u8, key_tag.name, "key")) return error.InvalidPlist;
            const key = try self.parseTagValue(key_tag);
            defer self.allocator.free(key);

            const value = try self.parseElement();
            try object.put(self.allocator, key, value);
        }
    }

    fn parseArray(self: *Parser, tag: Tag) ParseError!Value {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);

        if (tag.is_closed) return .{ .array = try items.toOwnedSlice(self.allocator) };

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.content.len) return error.InvalidPlist;
            if (self.startsWith("</array")) {
                self.advanceUntil(">");
                return .{ .array = try items.toOwnedSlice(self.allocator) };
            }
            try items.append(self.allocator, try self.parseElement());
        }
    }

    const Tag = struct {
        name: []const u8,
        is_closed: bool,
    };

    fn parseOpenTag(self: *Parser) ParseError!Tag {
        const raw = try self.captureUntil(">");
        defer self.allocator.free(raw);
        var name = std.mem.trim(u8, raw, " \t\r\n");
        var is_closed = false;
        if (name.len > 0 and name[name.len - 1] == '/') {
            is_closed = true;
            name = std.mem.trimEnd(u8, name[0 .. name.len - 1], " \t\r\n");
        }
        const whitespace = std.mem.indexOfAny(u8, name, " \t\r\n") orelse name.len;
        const short_name = name[0..whitespace];
        if (short_name.len > self.tag_name_buffer.len) return error.InvalidPlist;
        @memcpy(self.tag_name_buffer[0..short_name.len], short_name);
        return .{ .name = self.tag_name_buffer[0..short_name.len], .is_closed = is_closed };
    }

    fn parseTagValue(self: *Parser, tag: Tag) ParseError![]u8 {
        if (tag.is_closed) return self.allocator.dupe(u8, "");
        const raw = try self.captureUntil("</");
        defer self.allocator.free(raw);
        self.advanceUntil(">");
        return decodeEntities(self.allocator, raw);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r', '\n' => self.advanceOne(),
                else => return,
            }
        }
    }

    fn startsWith(self: *const Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.content[self.pos..], text);
    }

    fn advanceIfStartsWith(self: *Parser, text: []const u8) bool {
        if (!self.startsWith(text)) return false;
        self.advanceTo(self.pos + text.len);
        return true;
    }

    fn advanceUntil(self: *Parser, needle: []const u8) void {
        if (std.mem.indexOfPos(u8, self.content, self.pos, needle)) |found| {
            self.advanceTo(found + needle.len);
        } else {
            self.advanceTo(self.content.len);
        }
    }

    fn captureUntil(self: *Parser, needle: []const u8) ParseError![]u8 {
        const end = std.mem.indexOfPos(u8, self.content, self.pos, needle) orelse self.content.len;
        const result = try self.allocator.dupe(u8, self.content[self.pos..end]);
        self.advanceTo(if (end < self.content.len) end + needle.len else end);
        return result;
    }

    fn advanceTo(self: *Parser, target: usize) void {
        while (self.pos < target and self.pos < self.content.len) self.advanceOne();
    }

    fn advanceOne(self: *Parser) void {
        if (self.pos >= self.content.len) return;
        const byte = self.content[self.pos];
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
        const end = @min(self.pos + length, self.content.len);
        const codepoint = std.unicode.utf8Decode(self.content[self.pos..end]) catch 0xFFFD;
        self.pos = end;
        self.char += if (codepoint > 0xFFFF) 2 else 1;
    }
};

fn decodeEntities(allocator: Allocator, text: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '&') {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            const end = @min(index + length, text.len);
            try out.appendSlice(allocator, text[index..end]);
            index = end;
            continue;
        }

        if (std.mem.startsWith(u8, text[index..], "&#x") or std.mem.startsWith(u8, text[index..], "&#X")) {
            var cursor = index + 3;
            const digits_start = cursor;
            while (cursor < text.len and std.ascii.isHex(text[cursor])) cursor += 1;
            if (cursor > digits_start and cursor < text.len and text[cursor] == ';') {
                const value = std.fmt.parseInt(u21, text[digits_start..cursor], 16) catch 0xFFFD;
                try appendCodepoint(allocator, &out, if (value == 0) 0xFFFD else value);
                index = cursor + 1;
                continue;
            }
        } else if (std.mem.startsWith(u8, text[index..], "&#")) {
            var cursor = index + 2;
            const digits_start = cursor;
            while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
            if (cursor > digits_start and cursor < text.len and text[cursor] == ';') {
                const value = std.fmt.parseInt(u21, text[digits_start..cursor], 10) catch 0xFFFD;
                try appendCodepoint(allocator, &out, if (value == 0) 0xFFFD else value);
                index = cursor + 1;
                continue;
            }
        } else {
            const entities = [_]struct { needle: []const u8, replacement: u8 }{
                .{ .needle = "&amp;", .replacement = '&' },
                .{ .needle = "&lt;", .replacement = '<' },
                .{ .needle = "&gt;", .replacement = '>' },
                .{ .needle = "&quot;", .replacement = '"' },
                .{ .needle = "&apos;", .replacement = '\'' },
            };
            var matched = false;
            for (entities) |entity| {
                if (std.mem.startsWith(u8, text[index..], entity.needle)) {
                    try out.append(allocator, entity.replacement);
                    index += entity.needle.len;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }

        try out.append(allocator, '&');
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn appendCodepoint(allocator: Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch blk: {
        break :blk std.unicode.utf8Encode(0xFFFD, &buffer) catch 1;
    };
    try out.appendSlice(allocator, buffer[0..length]);
}

test "plist parses a grammar dictionary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>scopeName</key>
        \\  <string>source.test</string>
        \\  <key>patterns</key>
        \\  <array>
        \\    <dict>
        \\      <key>match</key>
        \\      <string>\bfoo\b</string>
        \\      <key>name</key>
        \\      <string>keyword.control.test</string>
        \\    </dict>
        \\  </array>
        \\</dict>
        \\</plist>
    ;
    const value = try parsePLIST(arena.allocator(), source);
    const root = value.object;
    try std.testing.expectEqualStrings("source.test", root.getString("scopeName").?);
    const patterns = root.getArray("patterns").?;
    try std.testing.expectEqual(@as(usize, 1), patterns.len);
    try std.testing.expectEqualStrings("keyword.control.test", patterns[0].object.getString("name").?);
}

test "plist decodes entities and booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parsePLIST(arena.allocator(),
        \\<dict><key>a</key><string>&lt;&amp;&gt;&#65;&#x42;</string>
        \\<key>b</key><true/><key>c</key><false/></dict>
    );
    try std.testing.expectEqualStrings("<&>AB", value.object.getString("a").?);
    try std.testing.expect(value.object.getBool("b").?);
    try std.testing.expect(!value.object.getBool("c").?);
}
