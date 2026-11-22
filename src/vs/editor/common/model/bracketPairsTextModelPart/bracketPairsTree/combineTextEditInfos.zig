// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/combineTextEditInfos.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const length_mod = @import("./length.zig");
const TextEditInfo = @import("./beforeEditPositionMapper.zig").TextEditInfo;

const Mapping = struct {
    modified: bool,
    before: length_mod.Length,
    after: length_mod.Length,
    /// Upstream's trailing sentinel (`lengthBefore`/`lengthAfter` undefined)
    /// means "copy every remaining first-state mapping".
    copy_all: bool = false,

    fn splitAt(self: Mapping, lengthAfter: length_mod.Length) [2]?Mapping {
        const remainingAfter = length_mod.lengthDiffNonNegative(lengthAfter, self.after);
        if (length_mod.lengthEquals(remainingAfter, 0)) {
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
    var lastOffset: length_mod.Length = 0;
    for (edits) |edit| {
        const space = length_mod.lengthDiffNonNegative(lastOffset, edit.startOffset);
        if (!length_mod.lengthIsZero(space)) try result.append(.{ .modified = false, .before = space, .after = space });
        const before = length_mod.lengthDiffNonNegative(edit.startOffset, edit.endOffset);
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
    try secondMappings.append(.{ .modified = false, .before = 0, .after = 0, .copy_all = true });

    var result = ArrayList(TextEditInfo).init(allocator);
    errdefer result.deinit();

    var firstIdx: usize = 0;
    var curItem: ?Mapping = if (firstMappings.items.len > 0) firstMappings.items[0] else null;
    if (curItem != null) firstIdx = 1;

    var s0offset: length_mod.Length = 0;
    for (secondMappings.items) |s1ToS2| {
        var s0ToS1 = ArrayList(Mapping).init(allocator);
        defer s0ToS1.deinit();
        try takeFirstMappings(&firstMappings, &firstIdx, &curItem, s1ToS2.before, &s0ToS1, s1ToS2.copy_all);

        if (s1ToS2.modified) {
            var s0Length: length_mod.Length = 0;
            for (s0ToS1.items) |m| s0Length = length_mod.lengthAdd(s0Length, m.before);
            const s0End = length_mod.lengthAdd(s0offset, s0Length);
            try pushEdit(&result, s0offset, s0End, s1ToS2.after);
            s0offset = s0End;
        } else {
            for (s0ToS1.items) |s1| {
                const start = s0offset;
                s0offset = length_mod.lengthAdd(s0offset, s1.before);
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
    s1Length: length_mod.Length,
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
    while (cur.* != null and !length_mod.lengthIsZero(remaining)) {
        const item = cur.*.?;
        const split = item.splitAt(remaining);
        try out.append(split[0].?);
        remaining = length_mod.lengthDiffNonNegative(split[0].?.after, remaining);
        if (split[1]) |rest| {
            cur.* = rest;
        } else {
            cur.* = if (index.* < all.items.len) all.items[index.*] else null;
            if (cur.* != null) index.* += 1;
        }
    }
    if (!length_mod.lengthIsZero(remaining)) {
        try out.append(.{ .modified = false, .before = remaining, .after = remaining });
    }
}

fn pushEdit(result: *ArrayList(TextEditInfo), start: length_mod.Length, end: length_mod.Length, newLength: length_mod.Length) !void {
    if (result.items.len > 0 and length_mod.lengthEquals(result.items[result.items.len - 1].endOffset, start)) {
        const last = &result.items[result.items.len - 1];
        last.endOffset = end;
        last.newLength = length_mod.lengthAdd(last.newLength, newLength);
    } else {
        try result.append(.{ .startOffset = start, .endOffset = end, .newLength = newLength });
    }
}

test "combineTextEditInfos: keeps older edits that follow the newest edit" {
    const allocator = std.testing.allocator;
    const first = [_]TextEditInfo{
        .{ .startOffset = length_mod.toLength(0, 4), .endOffset = length_mod.toLength(0, 7), .newLength = length_mod.toLength(0, 2) },
    };
    const second = [_]TextEditInfo{
        .{ .startOffset = 0, .endOffset = length_mod.toLength(0, 2), .newLength = length_mod.toLength(0, 1) },
    };

    var combined = try combineTextEditInfos(allocator, &first, &second);
    defer combined.deinit();

    try std.testing.expectEqual(@as(usize, 2), combined.items.len);
    try std.testing.expectEqual(length_mod.toLength(0, 0), combined.items[0].startOffset);
    try std.testing.expectEqual(length_mod.toLength(0, 2), combined.items[0].endOffset);
    try std.testing.expectEqual(length_mod.toLength(0, 1), combined.items[0].newLength);
    try std.testing.expectEqual(length_mod.toLength(0, 4), combined.items[1].startOffset);
    try std.testing.expectEqual(length_mod.toLength(0, 7), combined.items[1].endOffset);
    try std.testing.expectEqual(length_mod.toLength(0, 2), combined.items[1].newLength);
}
