// Tests for the terminal image decoder in `common/mediaImage.zig`. The PNG,
// unsupported-format and size-limit cases exercise the same paths as the
// browser preview's `HTMLImageElement` decode checks.

const std = @import("std");
const mediaImage = @import("../../common/mediaImage.zig");
const decode = mediaImage.decode;
const pngSize = mediaImage.pngSize;
const unsupportedFormat = mediaImage.unsupportedFormat;

const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

fn writeU16(buffer: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buffer[offset..][0..2], value, .little);
}

fn writeU32(buffer: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
}

test "mediaImage: PNG dimensions are read from IHDR and the bytes pass through" {
    // A valid 1x1 RGB PNG.
    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
        0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    const size = pngSize(&png) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), size.width);
    try std.testing.expectEqual(@as(usize, 1), size.height);

    var decoded = try decode(std.testing.allocator, &png);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(decoded.payload == .png);
    try std.testing.expectEqualSlices(u8, &png, decoded.payload.bytes());
}

test "mediaImage: BMP is decoded and re-encoded as PNG" {
    // zigimg reads the Windows V4/V5 bitmap headers; 14-byte file header + a
    // 108-byte V4 info header + 16 bytes of bottom-up 24-bit pixels.
    var bmp: [138]u8 = @splat(0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    writeU32(&bmp, 2, @intCast(bmp.len));
    writeU32(&bmp, 10, 122);
    writeU32(&bmp, 14, 108);
    writeU32(&bmp, 18, 2);
    writeU32(&bmp, 22, 2);
    writeU16(&bmp, 26, 1);
    writeU16(&bmp, 28, 24);
    writeU32(&bmp, 34, 16);
    // Bottom-up rows: blue, green / red, white (BGR order).
    bmp[122..128].* = .{ 255, 0, 0, 0, 255, 0 };
    bmp[130..136].* = .{ 0, 0, 255, 255, 255, 255 };

    var decoded = try decode(std.testing.allocator, &bmp);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.width);
    try std.testing.expectEqual(@as(usize, 2), decoded.height);
    try std.testing.expect(decoded.payload == .png);
    const size = pngSize(decoded.payload.bytes()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), size.width);
}

test "mediaImage: unsupported formats are distinguished from corrupt data" {
    try std.testing.expect(unsupportedFormat("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));
    try std.testing.expect(unsupportedFormat("RIFF\x00\x00\x00\x00WEBPVP8 "));
    try std.testing.expect(unsupportedFormat("\x00\x00\x01\x00\x01\x00"));
    try std.testing.expectError(error.UnsupportedFormat, decode(std.testing.allocator, "<svg></svg>"));
    try std.testing.expectError(error.CorruptImage, decode(std.testing.allocator, "not an image at all"));
}

test "mediaImage: oversized dimensions are rejected before decoding pixels" {
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..8], &png_signature);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 20000, .big);
    std.mem.writeInt(u32, png[20..24], 20000, .big);
    try std.testing.expectError(error.ImageTooLarge, decode(std.testing.allocator, &png));
}

test "mediaImage: Windows 3.x top-down BMP is normalised" {
    var bmp: [70]u8 = @splat(0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    writeU32(&bmp, 2, @intCast(bmp.len));
    writeU32(&bmp, 10, 54);
    writeU32(&bmp, 14, 40);
    writeU32(&bmp, 18, 2);
    // Negative height: rows are stored top-down.
    std.mem.writeInt(i32, bmp[22..26], -2, .little);
    writeU16(&bmp, 26, 1);
    writeU16(&bmp, 28, 24);
    writeU32(&bmp, 34, 16);
    bmp[54..60].* = .{ 0, 0, 255, 255, 255, 255 };
    bmp[62..68].* = .{ 255, 0, 0, 0, 255, 0 };

    var decoded = try decode(std.testing.allocator, &bmp);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.width);
    try std.testing.expectEqual(@as(usize, 2), decoded.height);
    try std.testing.expect(decoded.payload == .png);
}
