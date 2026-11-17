// Port of the core of `src/vs/workbench/services/themes/common/plistParser.ts`.
//
// Terminal adaptation: XML is parsed with a small purpose-built reader into
// `std.json.Value` (dicts/arrays/strings/integers/reals/booleans). Data and
// date values are returned as their text; comments/doctypes are skipped.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    InvalidPlist,
    UnexpectedEnd,
    UnknownElement,
} || Allocator.Error;

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    index: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
    }

    fn skipMisc(self: *Parser) void {
        while (true) {
            self.skipSpace();
            if (self.index >= self.input.len) return;
            if (std.mem.startsWith(u8, self.input[self.index..], "<?") or std.mem.startsWith(u8, self.input[self.index..], "<!")) {
                const end = std.mem.indexOfScalarPos(u8, self.input, self.index, '>') orelse {
                    self.index = self.input.len;
                    return;
                };
                self.index = end + 1;
                continue;
            }
            return;
        }
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.index..], text);
    }

    fn expect(self: *Parser, text: []const u8) ParseError!void {
        if (!self.startsWith(text)) return error.InvalidPlist;
        self.index += text.len;
    }

    fn readTag(self: *Parser) ParseError![]const u8 {
        if (self.index >= self.input.len or self.input[self.index] != '<') return error.InvalidPlist;
        const end = std.mem.indexOfScalarPos(u8, self.input, self.index, '>') orelse return error.UnexpectedEnd;
        var raw = self.input[self.index + 1 .. end];
        self.index = end + 1;
        raw = std.mem.trim(u8, raw, " \t\r\n");
        if (raw.len > 0 and raw[raw.len - 1] == '/') raw = raw[0 .. raw.len - 1];
        const space = std.mem.indexOfAny(u8, raw, " \t\r\n") orelse raw.len;
        return raw[0..space];
    }

    fn readTextUntil(self: *Parser, closing: []const u8) ParseError![]const u8 {
        const end = std.mem.indexOfPos(u8, self.input, self.index, closing) orelse return error.UnexpectedEnd;
        const text = self.input[self.index..end];
        self.index = end + closing.len;
        return text;
    }

    fn unescape(self: *Parser, text: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '&') {
                if (std.mem.startsWith(u8, text[index..], "&lt;")) {
                    try out.append('<');
                    index += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, text[index..], "&gt;")) {
                    try out.append('>');
                    index += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, text[index..], "&amp;")) {
                    try out.append('&');
                    index += 5;
                    continue;
                }
                if (std.mem.startsWith(u8, text[index..], "&quot;")) {
                    try out.append('"');
                    index += 6;
                    continue;
                }
                if (std.mem.startsWith(u8, text[index..], "&apos;")) {
                    try out.append('\'');
                    index += 6;
                    continue;
                }
            }
            try out.append(text[index]);
            index += 1;
        }
        return out.toOwnedSlice();
    }

    fn parseValue(self: *Parser) ParseError!std.json.Value {
        self.skipMisc();
        if (self.index >= self.input.len) return error.UnexpectedEnd;
        const tag = try self.readTag();
        if (std.mem.eql(u8, tag, "dict")) return self.parseDict();
        if (std.mem.eql(u8, tag, "array")) return self.parseArray();
        if (std.mem.eql(u8, tag, "string")) {
            const text = try self.readTextUntil("</string>");
            return .{ .string = try self.unescape(text) };
        }
        if (std.mem.eql(u8, tag, "key")) {
            const text = try self.readTextUntil("</key>");
            return .{ .string = try self.unescape(text) };
        }
        if (std.mem.eql(u8, tag, "integer")) {
            const text = std.mem.trim(u8, try self.readTextUntil("</integer>"), " \t\r\n");
            return .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidPlist };
        }
        if (std.mem.eql(u8, tag, "real")) {
            const text = std.mem.trim(u8, try self.readTextUntil("</real>"), " \t\r\n");
            return .{ .float = std.fmt.parseFloat(f64, text) catch return error.InvalidPlist };
        }
        if (std.mem.eql(u8, tag, "true") or std.mem.eql(u8, tag, "false")) {
            self.skipSpace();
            if (std.mem.eql(u8, tag, "true") and self.startsWith("</true>")) {
                self.index += "</true>".len;
            } else if (std.mem.eql(u8, tag, "false") and self.startsWith("</false>")) {
                self.index += "</false>".len;
            }
            return .{ .bool = std.mem.eql(u8, tag, "true") };
        }
        if (std.mem.eql(u8, tag, "data")) {
            return .{ .string = try self.readTextUntil("</data>") };
        }
        if (std.mem.eql(u8, tag, "date")) {
            return .{ .string = try self.readTextUntil("</date>") };
        }
        return error.UnknownElement;
    }

    fn parseDict(self: *Parser) ParseError!std.json.Value {
        var object = std.json.ObjectMap{};
        while (true) {
            self.skipMisc();
            if (self.startsWith("</dict>")) {
                self.index += "</dict>".len;
                return .{ .object = object };
            }
            const tag = try self.readTag();
            if (!std.mem.eql(u8, tag, "key")) return error.InvalidPlist;
            const key_text = try self.readTextUntil("</key>");
            const key = try self.unescape(key_text);
            const value = try self.parseValue();
            try object.put(self.allocator, key, value);
        }
    }

    fn parseArray(self: *Parser) ParseError!std.json.Value {
        var array = std.array_list.Managed(std.json.Value).init(self.allocator);
        while (true) {
            self.skipMisc();
            if (self.startsWith("</array>")) {
                self.index += "</array>".len;
                return .{ .array = array };
            }
            try array.append(try self.parseValue());
        }
    }
};

pub fn parse(allocator: Allocator, content: []const u8) ParseError!std.json.Value {
    var parser = Parser{ .allocator = allocator, .input = content };
    parser.skipMisc();
    if (parser.startsWith("<plist")) {
        _ = try parser.readTag();
        parser.skipMisc();
    }
    return parser.parseValue();
}

test "parses dictionary values and preserves non-array settings" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(), "<plist><dict><key>settings</key><string>invalid</string></dict></plist>");
    try std.testing.expect(value == .object);
    const settings = value.object.get("settings").?;
    try std.testing.expect(settings == .string);
    try std.testing.expectEqualStrings("invalid", settings.string);
}

test "parses arrays, numbers and booleans" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(), "<plist><dict><key>array</key><array><integer>3</integer><real>1.5</real><true/></array></dict></plist>");
    const array = value.object.get("array").?.array;
    try std.testing.expectEqual(@as(usize, 3), array.items.len);
    try std.testing.expectEqual(@as(i64, 3), array.items[0].integer);
    try std.testing.expectEqual(@as(f64, 1.5), array.items[1].float);
    try std.testing.expect(array.items[2].bool);
}
