// Port of `src/vs/editor/common/core/stringBuilder.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

/// UTF-8 string builder. Upstream uses UTF-16 buffers; this port builds UTF-8
/// directly because Zig strings, editor buffers and editor offsets are UTF-8.
// UTF-16 decoding/encoding is intentionally not provided here: editor core is
// UTF-8, and the only UTF-16 boundary in the port is the TextMate adapter.
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
