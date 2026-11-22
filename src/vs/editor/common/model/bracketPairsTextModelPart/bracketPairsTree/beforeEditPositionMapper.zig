// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const tree = @import("./bracketPairsTree.zig");
const Length = tree.Length;

pub const TextEditInfo = struct {
    startOffset: Length,
    endOffset: Length,
    newLength: Length,

    pub fn init(startOffset: Length, endOffset: Length, newLength: Length) TextEditInfo {
        return .{ .startOffset = startOffset, .endOffset = endOffset, .newLength = newLength };
    }
};

const TL = struct { line: usize, column: usize };

fn toTL(length: Length) TL {
    return .{ .line = tree.lengthLineCount(length), .column = tree.lengthColumnCount(length) };
}

fn fromTL(value: TL) Length {
    return tree.toLength(value.line, value.column);
}

const EditCache = struct {
    offset: TL,
    endOffsetBefore: TL,
    endOffsetAfter: TL,
};

pub const BeforeEditPositionMapper = struct {
    edits: ArrayList(EditCache),
    nextEditIdx: usize = 0,
    deltaOldToNewLineCount: isize = 0,
    deltaOldToNewColumnCount: isize = 0,
    deltaLineIdxInOld: isize = -1,

    /// Edits must be sorted by offset in ascending order.
    pub fn init(allocator: Allocator, edits: []const TextEditInfo) !BeforeEditPositionMapper {
        var cache = ArrayList(EditCache).init(allocator);
        errdefer cache.deinit();
        for (edits) |edit| {
            try cache.append(.{
                .offset = toTL(edit.startOffset),
                .endOffsetBefore = toTL(edit.endOffset),
                .endOffsetAfter = toTL(tree.lengthAdd(edit.startOffset, edit.newLength)),
            });
        }
        return .{ .edits = cache };
    }

    pub fn deinit(self: *BeforeEditPositionMapper) void {
        self.edits.deinit();
    }

    pub fn getOffsetBeforeChange(self: *BeforeEditPositionMapper, offset: Length) Length {
        self.adjustNextEdit(offset);
        return self.translateCurToOld(offset);
    }

    pub fn getDistanceToNextChange(self: *BeforeEditPositionMapper, offset: Length) ?Length {
        self.adjustNextEdit(offset);
        if (self.nextEditIdx >= self.edits.items.len) return null;
        const nextEdit = self.edits.items[self.nextEditIdx];
        const nextChangeOffset = self.translateOldToCur(nextEdit.offset);
        return tree.lengthDiffNonNegative(offset, nextChangeOffset);
    }

    fn translateOldToCur(self: *BeforeEditPositionMapper, old: TL) Length {
        if (@as(isize, @intCast(old.line)) == self.deltaLineIdxInOld) {
            return fromTL(.{
                .line = @intCast(@as(isize, @intCast(old.line)) + self.deltaOldToNewLineCount),
                .column = @intCast(@as(isize, @intCast(old.column)) + self.deltaOldToNewColumnCount),
            });
        }
        return fromTL(.{
            .line = @intCast(@as(isize, @intCast(old.line)) + self.deltaOldToNewLineCount),
            .column = old.column,
        });
    }

    fn translateCurToOld(self: *BeforeEditPositionMapper, offset: Length) Length {
        const cur = toTL(offset);
        if (@as(isize, @intCast(cur.line)) - self.deltaOldToNewLineCount == self.deltaLineIdxInOld) {
            return fromTL(.{
                .line = @intCast(@as(isize, @intCast(cur.line)) - self.deltaOldToNewLineCount),
                .column = @intCast(@as(isize, @intCast(cur.column)) - self.deltaOldToNewColumnCount),
            });
        }
        return fromTL(.{
            .line = @intCast(@as(isize, @intCast(cur.line)) - self.deltaOldToNewLineCount),
            .column = cur.column,
        });
    }

    fn adjustNextEdit(self: *BeforeEditPositionMapper, offset: Length) void {
        while (self.nextEditIdx < self.edits.items.len) {
            const nextEdit = self.edits.items[self.nextEditIdx];
            const nextEditEndOffsetInCur = self.translateOldToCur(nextEdit.endOffsetAfter);
            if (tree.lengthLessThanEqual(nextEditEndOffsetInCur, offset)) {
                self.nextEditIdx += 1;
                const endInCur = toTL(nextEditEndOffsetInCur);
                const endBeforeInCur = toTL(self.translateOldToCur(nextEdit.endOffsetBefore));
                const lineDelta: isize = @as(isize, @intCast(endInCur.line)) - @as(isize, @intCast(endBeforeInCur.line));
                self.deltaOldToNewLineCount += lineDelta;
                const previousColumnDelta: isize = if (self.deltaLineIdxInOld == @as(isize, @intCast(nextEdit.endOffsetBefore.line))) self.deltaOldToNewColumnCount else 0;
                const columnDelta: isize = @as(isize, @intCast(endInCur.column)) - @as(isize, @intCast(endBeforeInCur.column));
                self.deltaOldToNewColumnCount = previousColumnDelta + columnDelta;
                self.deltaLineIdxInOld = @intCast(nextEdit.endOffsetBefore.line);
            } else break;
        }
    }
};
