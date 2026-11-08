const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const tree = @import("./bracketPairsTree.zig");
const TextEditInfo = @import("./beforeEditPositionMapper.zig").TextEditInfo;

const Mapping = struct {
    modified: bool,
    before: tree.Length,
    after: tree.Length,

    fn splitAt(self: Mapping, lengthAfter: tree.Length) [2]?Mapping {
        const remainingAfter = tree.lengthDiffNonNegative(lengthAfter, self.after);
        if (tree.lengthEquals(remainingAfter, 0)) {
            return .{ self, null };
        }
        if (self.modified) {
            return .{
                .{ .modified = true, .before = self.before, .after = lengthAfter },
                .{ .modified = true, .before = 0, .after = remainingAfter },
            };
        }
        return .{
            .{ .modified = false, .before = lengthAfter, .after = lengthAfter },
            .{ .modified = false, .before = remainingAfter, .after = remainingAfter },
        };
    }
};

fn toMappings(allocator: Allocator, edits: []const TextEditInfo) !ArrayList(Mapping) {
    var result = ArrayList(Mapping).init(allocator);
    errdefer result.deinit();
    var lastOffset: tree.Length = 0;
    for (edits) |edit| {
        const space = tree.lengthDiffNonNegative(lastOffset, edit.startOffset);
        if (!tree.lengthIsZero(space)) try result.append(.{ .modified = false, .before = space, .after = space });
        const before = tree.lengthDiffNonNegative(edit.startOffset, edit.endOffset);
        try result.append(.{ .modified = true, .before = before, .after = edit.newLength });
        lastOffset = edit.endOffset;
    }
    return result;
}

/// Combines two sequential edit lists into one edit list that maps the state
/// before the first edit directly to the state after the second edit.
pub fn combineTextEditInfos(allocator: Allocator, first: []const TextEditInfo, second: []const TextEditInfo) !ArrayList(TextEditInfo) {
    if (first.len == 0) {
        var copy = ArrayList(TextEditInfo).init(allocator);
        try copy.appendSlice(second);
        return copy;
    }
    if (second.len == 0) {
        var copy = ArrayList(TextEditInfo).init(allocator);
        try copy.appendSlice(first);
        return copy;
    }

    var firstMappings = try toMappings(allocator, first);
    defer firstMappings.deinit();
    var secondMappings = try toMappings(allocator, second);
    defer secondMappings.deinit();
    try secondMappings.append(.{ .modified = false, .before = 0, .after = 0 });

    var result = ArrayList(TextEditInfo).init(allocator);
    errdefer result.deinit();

    var firstIdx: usize = 0;
    var curItem: ?Mapping = if (firstMappings.items.len > 0) firstMappings.items[0] else null;
    if (curItem != null) firstIdx = 1;

    var s0offset: tree.Length = 0;
    for (secondMappings.items) |s1ToS2| {
        var s0ToS1 = ArrayList(Mapping).init(allocator);
        defer s0ToS1.deinit();
        try takeFirstMappings(&firstMappings, &firstIdx, &curItem, s1ToS2.before, &s0ToS1, s1ToS2.modified and tree.lengthIsZero(s1ToS2.before) and tree.lengthIsZero(s1ToS2.after));

        if (s1ToS2.modified) {
            var s0Length: tree.Length = 0;
            for (s0ToS1.items) |m| s0Length = tree.lengthAdd(s0Length, m.before);
            const s0End = tree.lengthAdd(s0offset, s0Length);
            try pushEdit(&result, s0offset, s0End, s1ToS2.after);
            s0offset = s0End;
        } else {
            for (s0ToS1.items) |s1| {
                const start = s0offset;
                s0offset = tree.lengthAdd(s0offset, s1.before);
                if (s1.modified) try pushEdit(&result, start, s0offset, s1.after);
            }
        }
    }
    return result;
}

fn takeFirstMappings(
    all: *ArrayList(Mapping),
    index: *usize,
    cur: *?Mapping,
    s1Length: tree.Length,
    out: *ArrayList(Mapping),
    copyAll: bool,
) !void {
    if (copyAll) {
        // Consume everything (used for the sentinel copy-all mapping).
        if (cur.*) |item| try out.append(item);
        cur.* = null;
        while (index.* < all.items.len) : (index.* += 1) try out.append(all.items[index.*]);
        return;
    }

    var remaining = s1Length;
    while (cur.* != null and !tree.lengthIsZero(remaining)) {
        const item = cur.*.?;
        const split = item.splitAt(remaining);
        try out.append(split[0].?);
        remaining = tree.lengthDiffNonNegative(split[0].?.after, remaining);
        if (split[1]) |rest| {
            cur.* = rest;
        } else {
            cur.* = if (index.* < all.items.len) all.items[index.*] else null;
            if (cur.* != null) index.* += 1;
        }
    }
    if (!tree.lengthIsZero(remaining)) {
        try out.append(.{ .modified = false, .before = remaining, .after = remaining });
    }
}

fn pushEdit(result: *ArrayList(TextEditInfo), start: tree.Length, end: tree.Length, newLength: tree.Length) !void {
    if (result.items.len > 0 and tree.lengthEquals(result.items[result.items.len - 1].endOffset, start)) {
        const last = &result.items[result.items.len - 1];
        last.endOffset = end;
        last.newLength = tree.lengthAdd(last.newLength, newLength);
    } else {
        try result.append(.{ .startOffset = start, .endOffset = end, .newLength = newLength });
    }
}
