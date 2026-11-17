// Port of the core `VSBuffer` byte-buffer subset of
// `src/vs/base/common/buffer.ts`. The terminal port owns a plain byte slice;
// slices/concat copy rather than sharing reference-counted storage.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const VSBuffer = struct {
    bytes: []u8,

    pub fn alloc(allocator: Allocator, size: usize) !VSBuffer {
        return .{ .bytes = try allocator.alloc(u8, size) };
    }

    pub fn fromString(allocator: Allocator, text: []const u8) !VSBuffer {
        return .{ .bytes = try allocator.dupe(u8, text) };
    }

    pub fn deinit(self: *VSBuffer, allocator: Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
    }

    pub fn byteLength(self: *const VSBuffer) usize {
        return self.bytes.len;
    }

    pub fn toString(self: *const VSBuffer, allocator: Allocator) ![]u8 {
        return allocator.dupe(u8, self.bytes);
    }

    pub fn slice(self: *const VSBuffer, allocator: Allocator, start: usize, end: usize) !VSBuffer {
        if (start > end or end > self.bytes.len) return error.InvalidSlice;
        return .{ .bytes = try allocator.dupe(u8, self.bytes[start..end]) };
    }

    pub fn concat(allocator: Allocator, buffers: []const VSBuffer) !VSBuffer {
        var total: usize = 0;
        for (buffers) |buffer| total += buffer.bytes.len;
        const result = try allocator.alloc(u8, total);
        var offset: usize = 0;
        for (buffers) |buffer| {
            @memcpy(result[offset .. offset + buffer.bytes.len], buffer.bytes);
            offset += buffer.bytes.len;
        }
        return .{ .bytes = result };
    }

    pub fn toHexString(self: *const VSBuffer, allocator: Allocator) ![]u8 {
        const digits = "0123456789abcdef";
        const result = try allocator.alloc(u8, self.bytes.len * 2);
        for (self.bytes, 0..) |byte, index| {
            result[index * 2] = digits[byte >> 4];
            result[index * 2 + 1] = digits[byte & 0xF];
        }
        return result;
    }

    pub fn fromHexString(allocator: Allocator, text: []const u8) !VSBuffer {
        if (text.len % 2 != 0) return error.InvalidHexString;
        const result = try allocator.alloc(u8, text.len / 2);
        errdefer allocator.free(result);
        var index: usize = 0;
        while (index < result.len) : (index += 1) {
            const high = std.fmt.charToDigit(text[index * 2], 16) catch return error.InvalidHexString;
            const low = std.fmt.charToDigit(text[index * 2 + 1], 16) catch return error.InvalidHexString;
            result[index] = high * 16 + low;
        }
        return .{ .bytes = result };
    }

    pub fn toBase64(self: *const VSBuffer, allocator: Allocator) ![]u8 {
        const encoder = std.base64.standard.Encoder;
        const result = try allocator.alloc(u8, encoder.calcSize(self.bytes.len));
        const encoded = encoder.encode(result, self.bytes);
        return result[0..encoded.len];
    }

    pub fn fromBase64(allocator: Allocator, text: []const u8) !VSBuffer {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(text) catch return error.InvalidBase64;
        const result = try allocator.alloc(u8, size);
        errdefer allocator.free(result);
        decoder.decode(result, text) catch return error.InvalidBase64;
        return .{ .bytes = result };
    }

    pub fn equals(self: *const VSBuffer, other: *const VSBuffer) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn indexOf(self: *const VSBuffer, byte: u8, from: usize) ?usize {
        if (from >= self.bytes.len) return null;
        const offset = std.mem.indexOfScalar(u8, self.bytes[from..], byte) orelse return null;
        return from + offset;
    }

    pub fn readUInt8(self: *const VSBuffer, offset: usize) ?u8 {
        if (offset >= self.bytes.len) return null;
        return self.bytes[offset];
    }

    pub fn readUInt32BE(self: *const VSBuffer, offset: usize) ?u32 {
        if (offset + 4 > self.bytes.len) return null;
        return std.mem.readInt(u32, self.bytes[offset..][0..4], .big);
    }

    pub fn writeUInt32BE(self: *VSBuffer, value: u32, offset: usize) void {
        std.mem.writeInt(u32, self.bytes[offset..][0..4], value, .big);
    }
};

test "VSBuffer string, slice, concat and equality" {
    const allocator = std.testing.allocator;
    var hello = try VSBuffer.fromString(allocator, "hello");
    defer hello.deinit(allocator);
    const text = try hello.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectEqual(@as(usize, 5), hello.byteLength());

    var slice = try hello.slice(allocator, 1, 4);
    defer slice.deinit(allocator);
    const slice_text = try slice.toString(allocator);
    defer allocator.free(slice_text);
    try std.testing.expectEqualStrings("ell", slice_text);

    var world = try VSBuffer.fromString(allocator, " world");
    defer world.deinit(allocator);
    var joined = try VSBuffer.concat(allocator, &.{ hello, world });
    defer joined.deinit(allocator);
    const joined_text = try joined.toString(allocator);
    defer allocator.free(joined_text);
    try std.testing.expectEqualStrings("hello world", joined_text);

    var copy = try VSBuffer.fromString(allocator, "hello");
    defer copy.deinit(allocator);
    try std.testing.expect(hello.equals(&copy));
    try std.testing.expectEqual(@as(?usize, 1), hello.indexOf('e', 0));
    try std.testing.expect(hello.indexOf('z', 0) == null);
}

test "VSBuffer integer access" {
    const allocator = std.testing.allocator;
    var buffer = try VSBuffer.alloc(allocator, 8);
    defer buffer.deinit(allocator);
    buffer.writeUInt32BE(0xA1B2C3D4, 0);
    try std.testing.expectEqual(@as(?u32, 0xA1B2C3D4), buffer.readUInt32BE(0));
    try std.testing.expectEqual(@as(?u8, 0xA1), buffer.readUInt8(0));
    try std.testing.expect(buffer.readUInt32BE(6) == null);
}

test "VSBuffer hex round-trip" {
    const allocator = std.testing.allocator;
    var buffer = try VSBuffer.fromHexString(allocator, "00abff");
    defer buffer.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), buffer.byteLength());
    const hex = try buffer.toHexString(allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("00abff", hex);
    try std.testing.expectError(error.InvalidHexString, VSBuffer.fromHexString(allocator, "0g"));
    try std.testing.expectError(error.InvalidHexString, VSBuffer.fromHexString(allocator, "abc"));
}

test "VSBuffer base64 round-trip" {
    const allocator = std.testing.allocator;
    var buffer = try VSBuffer.fromString(allocator, "hello world");
    defer buffer.deinit(allocator);
    const encoded = try buffer.toBase64(allocator);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8gd29ybGQ=", encoded);
    var decoded = try VSBuffer.fromBase64(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expect(buffer.equals(&decoded));
}
