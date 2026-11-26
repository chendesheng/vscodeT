// Port of the full-range MoreMinimal cases in `src/vs/editor/test/common/services/editorWebWorker.test.ts`.
const std = @import("std");
const worker = @import("../../../common/services/editorWebWorker.zig");
const DiffChange = @import("../../../../base/common/diff/diffChange.zig").DiffChange;
const a = std.testing.allocator;

fn assertApplied(original: []const u8, result: worker.MinimalEdits, expected: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var offset: usize = 0;
    for (result.changes) |change| {
        const start: usize = @intCast(change.originalStart);
        const end: usize = @intCast(change.getOriginalEnd());
        try text.appendSlice(a, original[offset..start]);
        try text.appendSlice(a, result.text[@intCast(change.modifiedStart)..@intCast(change.getModifiedEnd())]);
        offset = end;
    }
    try text.appendSlice(a, original[offset..]);
    try std.testing.expectEqualStrings(expected, text.items);
}

test "EditorWebWorker MoreMinimal" {
    const original = "This is line one";
    const result = try worker.computeMoreMinimalEdits(a, original, "This is line One", .LF, false);
    defer result.deinit(a);
    try std.testing.expectEqualSlices(DiffChange, &.{DiffChange.init(13, 1, 13, 1)}, result.changes);
    try assertApplied(original, result, "This is line One");
}

test "EditorWebWorker MoreMinimal issue #15385 newline changes only and other" {
    const original = "{\n\t\"a\":1\n}";
    const unchanged = try worker.computeMoreMinimalEdits(a, original, "{\r\n\t\"a\":1\r\n}", .LF, false);
    defer unchanged.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), unchanged.changes.len);
    const changed = try worker.computeMoreMinimalEdits(a, original, "{\r\n\t\"b\":1\r\n}", .LF, false);
    defer changed.deinit(a);
    try std.testing.expectEqualSlices(DiffChange, &.{DiffChange.init(4, 1, 4, 1)}, changed.changes);
    try assertApplied(original, changed, "{\n\t\"b\":1\n}");
}

test "EditorWebWorker MoreMinimal preserves surrogate pairs" {
    const original = "𫚭齅5龯蝌䶱aＺr灋㊣珸琱璳AbD龪龫藏㒱㓥㓹3UxヅЁЖa偓兘㎜𫟹";
    const modified = "㈢鿃2磷𬸚﹢㘥怐ND䶮ёㄆホ鿃龬鿍a6纷冬督㊣㈱㔾㖏㕽內冚7畫皗Э𫔍";
    const result = try worker.computeMoreMinimalEdits(a, original, modified, .LF, false);
    defer result.deinit(a);
    try assertApplied(original, result, modified);
}

test "EditorWebWorker MoreMinimal CRLF boundaries and large edit fallback" {
    const original = "a\r\nb\r\nc";
    const result = try worker.computeMoreMinimalEdits(a, original, "a\nc\nb", .CRLF, false);
    defer result.deinit(a);
    try assertApplied(original, result, "a\r\nc\r\nb");
    const large = try a.alloc(u8, 100_001);
    defer a.free(large);
    @memset(large, 'x');
    const bigger = try worker.computeMoreMinimalEdits(a, large, "x", .LF, false);
    defer bigger.deinit(a);
    try std.testing.expectEqualSlices(DiffChange, &.{DiffChange.init(0, 100_001, 0, 1)}, bigger.changes);
}
