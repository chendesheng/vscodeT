// Port of `src/vs/editor/test/common/core/stringBuilder.test.ts`.
const std = @import("std");
const string_builder = @import("../../../common/core/stringBuilder.zig");

fn writeUInt16LE(buffer: []u8, value: u16, offset: usize) void {
    std.mem.writeInt(u16, buffer[offset..][0..2], value, .little);
}

test "issue #118041: unicode character undo bug 1" {
    const allocator = std.testing.allocator;
    var buff: [2]u8 = @splat(0);
    writeUInt16LE(&buff, 0xFEFF, 0);
    const actual = try string_builder.decodeUTF16LE(allocator, &buff, 0, 1);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("\u{FEFF}", actual);
}

test "issue #118041: unicode character undo bug 2" {
    const allocator = std.testing.allocator;
    var buff: [4]u8 = @splat(0);
    writeUInt16LE(&buff, 'a', 0);
    writeUInt16LE(&buff, 0xFEFF, 2);
    const actual = try string_builder.decodeUTF16LE(allocator, &buff, 0, 2);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("a\u{FEFF}", actual);
}

test "issue #118041: unicode character undo bug 3" {
    const allocator = std.testing.allocator;
    var buff: [6]u8 = @splat(0);
    writeUInt16LE(&buff, 'a', 0);
    writeUInt16LE(&buff, 0xFEFF, 2);
    writeUInt16LE(&buff, 'b', 4);
    const actual = try string_builder.decodeUTF16LE(allocator, &buff, 0, 3);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("a\u{FEFF}b", actual);
}

test "basic" {
    const allocator = std.testing.allocator;
    var sb = try string_builder.StringBuilder.init(allocator, 100);
    defer sb.deinit();
    try sb.appendASCIICharCode('A');
    try sb.appendASCIICharCode(' ');
    try sb.appendString("😊");
    try std.testing.expectEqualStrings("A 😊", sb.build());
}
