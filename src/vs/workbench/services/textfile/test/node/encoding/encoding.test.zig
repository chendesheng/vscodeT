// Port of the BOM/decode/encode subset of
// `src/vs/workbench/services/textfile/test/node/encoding/encoding.test.ts`.
//
// The upstream heuristic `detectEncodingFromBuffer`/ANSI/ShiftJIS cases need
// jschardet/ICU and are a documented terminal omission; the BOM detection and
// UTF-8/UTF-16 round-trips are ported.
const std = @import("std");
const testing = std.testing;
const encoding = @import("../../../common/encoding.zig");

fn utf16Bytes(allocator: std.mem.Allocator, text: []const u8, endian: std.builtin.Endian, bom: bool) ![]u8 {
    var units = std.array_list.Managed(u16).init(allocator);
    defer units.deinit();
    if (bom) try units.append(0xFEFF);
    for (text) |byte| try units.append(byte);
    const result = try allocator.alloc(u8, units.items.len * 2);
    for (units.items, 0..) |unit, index| {
        std.mem.writeInt(u16, result[index * 2 ..][0..2], unit, endian);
    }
    return result;
}

test "encoding: detectBOM UTF-8, UTF-16 LE and UTF-16 BE" {
    const utf8 = "\xEF\xBB\xBFHello";
    const result = encoding.detectBOM(utf8).?;
    try testing.expectEqual(encoding.Encoding.utf8_with_bom, result.encoding);
    try testing.expectEqual(@as(usize, 3), result.length);

    const le = try utf16Bytes(testing.allocator, "Hello", .little, true);
    defer testing.allocator.free(le);
    const le_result = encoding.detectBOM(le).?;
    try testing.expectEqual(encoding.Encoding.utf16le_with_bom, le_result.encoding);
    try testing.expectEqual(@as(usize, 2), le_result.length);

    const be = try utf16Bytes(testing.allocator, "Hello", .big, true);
    defer testing.allocator.free(be);
    const be_result = encoding.detectBOM(be).?;
    try testing.expectEqual(encoding.Encoding.utf16be_with_bom, be_result.encoding);
    try testing.expectEqual(@as(usize, 2), be_result.length);

    try testing.expect(encoding.detectBOM("Hello") == null);
    try testing.expect(encoding.detectBOM("") == null);
}

test "encoding: decode strips BOMs and handles UTF-16" {
    const utf8 = "\xEF\xBB\xBFHello";
    const decoded_utf8 = try encoding.decode(testing.allocator, utf8, .utf8_with_bom);
    defer testing.allocator.free(decoded_utf8);
    try testing.expectEqualStrings("Hello", decoded_utf8);

    const le = try utf16Bytes(testing.allocator, "Hello", .little, true);
    defer testing.allocator.free(le);
    const decoded_le = try encoding.decode(testing.allocator, le, .utf16le_with_bom);
    defer testing.allocator.free(decoded_le);
    try testing.expectEqualStrings("Hello", decoded_le);

    const be = try utf16Bytes(testing.allocator, "Hello", .big, true);
    defer testing.allocator.free(be);
    const decoded_be = try encoding.decode(testing.allocator, be, .utf16be_with_bom);
    defer testing.allocator.free(decoded_be);
    try testing.expectEqualStrings("Hello", decoded_be);
}

test "encoding: encode/decode round-trips every encoding" {
    const encodings = [_]encoding.Encoding{
        .utf8,
        .utf8_with_bom,
        .utf16le,
        .utf16be,
        .utf16le_with_bom,
        .utf16be_with_bom,
    };
    for (encodings) |value| {
        const encoded = try encoding.encode(testing.allocator, "Hello \u{1F600}", value);
        defer testing.allocator.free(encoded);
        const decoded = try encoding.decode(testing.allocator, encoded, value);
        defer testing.allocator.free(decoded);
        try testing.expectEqualStrings("Hello \u{1F600}", decoded);
        try testing.expectEqual(encoding.hasBOM(value), encoding.detectBOM(encoded) != null);
        if (encoding.detectBOM(encoded)) |bom| {
            try testing.expectEqual(encoding.isUTF16(value), bom.length == 2);
        }
    }
}
