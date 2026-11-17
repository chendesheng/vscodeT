const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

/// UTF-8 string builder. Upstream uses UTF-16 buffers; this port builds UTF-8
/// directly because Zig strings and editor buffers are UTF-8.
/// Decodes UTF-16LE code units to UTF-8. A leading BOM is preserved (upstream
/// avoids the platform decoder for this reason). `offset` is a byte offset and
/// `len` a count of 16-bit code units.
pub fn decodeUTF16LE(allocator: Allocator, source: []const u8, offset: usize, len: usize) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const byte_index = offset + index * 2;
        const unit = std.mem.readInt(u16, source[byte_index..][0..2], .little);
        var codepoint: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF and index + 1 < len) {
            const next_index = byte_index + 2;
            const next_unit = std.mem.readInt(u16, source[next_index..][0..2], .little);
            if (next_unit >= 0xDC00 and next_unit <= 0xDFFF) {
                codepoint = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (next_unit - 0xDC00);
                index += 1;
            }
        }
        var buffer: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(codepoint, &buffer) catch {
            try result.append(0xEF);
            try result.append(0xBF);
            try result.append(0xBD);
            continue;
        };
        try result.appendSlice(buffer[0..encoded_len]);
    }
    return result.toOwnedSlice();
}

pub const StringBuilder = struct {
    allocator: Allocator,
    buffer: ArrayList(u8),

    pub fn init(allocator: Allocator, capacity: usize) !StringBuilder {
        var buffer = ArrayList(u8).init(allocator);
        try buffer.ensureTotalCapacity(capacity);
        return .{ .allocator = allocator, .buffer = buffer };
    }

    pub fn deinit(self: *StringBuilder) void {
        self.buffer.deinit();
    }

    pub fn reset(self: *StringBuilder) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn build(self: *const StringBuilder) []const u8 {
        return self.buffer.items;
    }

    pub fn appendCharCode(self: *StringBuilder, char_code: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &bytes) catch return error.InvalidCodePoint;
        try self.buffer.appendSlice(bytes[0..len]);
    }

    pub fn appendASCIICharCode(self: *StringBuilder, char_code: u8) !void {
        try self.buffer.append(char_code);
    }

    pub fn appendString(self: *StringBuilder, text: []const u8) !void {
        try self.buffer.appendSlice(text);
    }
};

test "stringBuilder: append and build" {
    const allocator = std.testing.allocator;
    var builder = try StringBuilder.init(allocator, 8);
    defer builder.deinit();
    try builder.appendString("ab");
    try builder.appendASCIICharCode('c');
    try builder.appendCharCode('é');
    try std.testing.expectEqualStrings("abcé", builder.build());
    builder.reset();
    try std.testing.expectEqualStrings("", builder.build());
}
