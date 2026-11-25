const std = @import("std");
const ui = @import("ui");
const Segment = ui.cell_border.Segment;
const Joint = ui.cell_border.Joint;
const Stroke = ui.cell_border.Stroke;
const Set = ui.cell_border.Set;
const Table = ui.cell_border.Table;
const query = ui.cell_border.query;
const appendPen = ui.cell_border.appendPen;
const appendPenDiff = ui.cell_border.appendPenDiff;
const parseReply = ui.cell_border.parseReply;
const containsDa1 = ui.cell_border.containsDa1;

test "cell border: query and pen encoding" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expectEqualStrings("\x1bP1+bcell-border;q\x1b\\", query);

    var set = Set.empty();
    set = set.with(Segment.top, .{
        .width = 32,
        .color = .{ .rgb = .{ .r = 0x12, .g = 0x34, .b = 0xab } },
        .placement = .centered,
        .priority = 2,
    });
    set = set.with(Segment.left, .{ .width = 64, .color = .default_fg });
    try appendPen(&out, allocator, set);
    try std.testing.expectEqualStrings(
        "\x1bP1+bcell-border;pen;3;32;1234ab;1;0;priority=2\x1b\\" ++
            "\x1bP1+bcell-border;pen;192;64;fg;1;0\x1b\\",
        out.items,
    );
}

test "cell border: grouping is order independent and merges equal strokes" {
    const stroke = Stroke{ .width = 64, .color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } };
    var left = Set.empty();
    left = left.with(Segment.top, stroke);
    left = left.with(Segment.left, stroke);
    left = left.with(Segment.right, .{ .width = 16, .color = .default_fg });

    var right = Set.empty();
    right = right.with(Segment.right, .{ .width = 16, .color = .default_fg });
    right = right.with(Segment.left, stroke);
    right = right.with(Segment.top, stroke);

    try std.testing.expect(left.eql(right));
    try std.testing.expectEqual(@as(u3, 2), left.count);
    try std.testing.expectEqual(Segment.right, left.groups[0].mask);
    try std.testing.expectEqual(Segment.top | Segment.left, left.groups[1].mask);
}

test "cell border: intern probes past hash collisions" {
    var table = Table{};
    const stroke = Stroke{ .width = 32, .color = .{ .palette = 7 } };

    // 4095 distinct masks into 1024 cache slots must collide in the low bits.
    var seen: [table.ids.len]u12 = @splat(0);
    var used: [table.ids.len]bool = @splat(false);
    var collision_a: u12 = 0;
    var collision_b: u12 = 0;
    var mask: usize = 1;
    while (mask <= 4095) : (mask += 1) {
        const bits: u12 = @intCast(mask);
        const set = Set.empty().with(bits, stroke);
        var sample = Table{};
        const id = sample.intern(set);
        const slot = std.mem.indexOfScalar(u16, &sample.ids, id).?;
        if (used[slot]) {
            collision_a = seen[slot];
            collision_b = bits;
            break;
        }
        used[slot] = true;
        seen[slot] = bits;
    }
    try std.testing.expect(collision_a != 0);

    const first = Set.empty().with(collision_a, stroke);
    const second = Set.empty().with(collision_b, stroke);
    try std.testing.expect(!first.eql(second));
    const first_id = table.intern(first);
    const second_id = table.intern(second);
    try std.testing.expectEqual(@as(u16, 1), first_id);
    try std.testing.expectEqual(@as(u16, 2), second_id);
    // The full `Set.eql` confirmation finds each side of the collision again.
    try std.testing.expectEqual(first_id, table.intern(first));
    try std.testing.expectEqual(second_id, table.intern(second));
    try std.testing.expect(table.get(first_id).eql(first));
    try std.testing.expect(table.get(second_id).eql(second));
}

test "cell border: intern handles joints-only sets and ignores round style without joints" {
    var table = Table{};
    const joint = Joint;

    var a = Set.empty();
    a.joints = joint.top_left;
    var b = Set.empty();
    b.joints = joint.top_right;
    try std.testing.expect(a.count == 0 and b.count == 0);

    const id_a = table.intern(a);
    const id_b = table.intern(b);
    try std.testing.expectEqual(@as(u16, 1), id_a);
    try std.testing.expectEqual(@as(u16, 2), id_b);

    // With joints present the round style is part of the equality, so it must
    // be part of the hash and each variant interns separately.
    var rounded = a;
    rounded.round_style = .{ .radius = 128, .outside = .terminal_background };
    const id_rounded = table.intern(rounded);
    try std.testing.expectEqual(@as(u16, 3), id_rounded);
    try std.testing.expectEqual(id_a, table.intern(a));
    try std.testing.expectEqual(id_rounded, table.intern(rounded));

    // Without joints `Set.eql` ignores the round style; the hash has to ignore
    // it too or two equal sets would get different ids.
    const stroke = Stroke{ .width = 16, .color = .default_fg };
    const plain = Set.empty().with(Segment.top, stroke);
    var styled = plain;
    styled.round_style = .{ .radius = 64 };
    try std.testing.expect(plain.eql(styled));
    const id_plain = table.intern(plain);
    try std.testing.expectEqual(id_plain, table.intern(styled));

    try std.testing.expectEqual(@as(u16, 0), table.intern(Set.empty()));

    // A full table drops new sets instead of growing or aliasing.
    var full = Table{};
    var index: usize = 1;
    while (index <= Table.max_sets) : (index += 1) {
        const set = Set.empty().with(@intCast(index), stroke);
        try std.testing.expectEqual(@as(u16, @intCast(index)), full.intern(set));
    }
    try std.testing.expectEqual(@as(u16, 0), full.intern(Set.empty().with(Segment.all, stroke)));
}

test "cell border: a newer stroke replaces segments" {
    const red = Stroke{ .color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const blue = Stroke{ .color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    var set = Set.empty();
    set = set.with(Segment.top, red);
    set = set.with(Segment.top_left, blue);
    try std.testing.expectEqual(@as(u3, 2), set.count);
    try std.testing.expectEqual(Segment.top_left, set.groups[0].mask);
    try std.testing.expectEqual(Segment.top_right, set.groups[1].mask);
}

test "cell border: the pen transitions only changed segments" {
    const allocator = std.testing.allocator;
    const red = Stroke{ .color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const blue = Stroke{ .color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    var current = Set.empty();
    current = current.with(Segment.top, red);
    var wanted = Set.empty();
    wanted = wanted.with(Segment.right, blue);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendPenDiff(&out, allocator, current, wanted);
    try std.testing.expectEqualStrings(
        "\x1bP1+bcell-border;pen-clear;3\x1b\\" ++
            "\x1bP1+bcell-border;pen;12;64;0000ff;1;0\x1b\\",
        out.items,
    );

    // A segment with the same stroke is left alone; only the missing one is set.
    var same = Set.empty();
    same = same.with(Segment.top, red);
    out.clearRetainingCapacity();
    try appendPenDiff(&out, allocator, current, same);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "cell border: parse a capability reply" {
    const reply = "\x1bP1+bcell-border;ok;1;pen,rect,half,center,palette,priority\x1b\\";
    const capabilities = parseReply(reply) orelse return error.MissingReply;
    try std.testing.expectEqual(@as(u8, 1), capabilities.version);
    try std.testing.expect(capabilities.has(.pen));
    try std.testing.expect(capabilities.has(.priority));
    try std.testing.expect(!capabilities.has(.round));
    try std.testing.expect(containsDa1("\x1b[?62;22c"));
    try std.testing.expect(!containsDa1("plain"));
}
