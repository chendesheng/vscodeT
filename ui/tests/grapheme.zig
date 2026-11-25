const std = @import("std");
const Table = @import("ui").grapheme.Table;

test "grapheme table interns, compares and remaps" {
    const allocator = std.testing.allocator;
    var a = try Table.init(allocator);
    defer a.deinit();
    var b = try Table.init(allocator);
    defer b.deinit();

    const id = try a.intern("e\u{301}");
    try std.testing.expect(id != 0);
    try std.testing.expectEqual(id, try a.intern("e\u{301}"));
    try std.testing.expectEqualStrings("e\u{301}", a.get(id));

    const other = try b.intern("e\u{301}");
    try std.testing.expect(Table.eql(&a, &b, id, other));
    const remapped = try b.remap(&a, id);
    try std.testing.expectEqual(other, remapped);
}
