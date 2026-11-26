// Port of the line-change editing helpers in `vscode/extensions/git/src/staging.ts`.
// Model coordinates are one-based internally; the upstream staging algorithm
// works in zero-based TextDocument coordinates and preserves each source EOL.
const std = @import("std");
const TextModel = @import("../../../vs/editor/common/model/textModel.zig").TextModel;
const Range = @import("../../../vs/editor/common/core/range.zig").Range;
pub const LineChange = @import("../../../vs/editor/common/diff/linesDiffComputer.zig").IChange;

fn appendRange(result: *std.ArrayList(u8), allocator: std.mem.Allocator, model: *TextModel, start_line: usize, start_character: usize, end_line: usize, end_character: usize) !void {
    var text = try model.getValueInRange(Range.init(start_line + 1, start_character + 1, end_line + 1, end_character + 1), null);
    defer text.deinit();
    try result.appendSlice(allocator, text.items);
}

pub fn applyLineChanges(allocator: std.mem.Allocator, original: *TextModel, modified: *TextModel, diffs: []const LineChange) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var current_line: usize = 0;
    for (diffs) |diff| {
        const is_insertion = diff.originalEndLineNumber == 0;
        const is_deletion = diff.modifiedEndLineNumber == 0;
        var end_line = if (is_insertion) diff.originalStartLineNumber else diff.originalStartLineNumber -| 1;
        var end_character: usize = 0;
        if (is_deletion and diff.originalEndLineNumber == original.getLineCount() and end_line > 0) {
            end_line -= 1;
            end_character = original.getLineMaxColumn(end_line + 1);
            end_character -|= 1;
        }
        try appendRange(&result, allocator, original, current_line, 0, end_line, end_character);
        if (!is_deletion) {
            var from_line = diff.modifiedStartLineNumber -| 1;
            var from_character: usize = 0;
            if (is_insertion and diff.originalStartLineNumber == original.getLineCount() and from_line > 0) {
                from_line -= 1;
                from_character = modified.getLineMaxColumn(from_line + 1) -| 1;
            }
            try appendRange(&result, allocator, modified, from_line, from_character, diff.modifiedEndLineNumber, 0);
        }
        current_line = if (is_insertion) diff.originalStartLineNumber else diff.originalEndLineNumber;
    }
    try appendRange(&result, allocator, original, current_line, 0, original.getLineCount(), 0);
    return result.toOwnedSlice(allocator);
}

pub fn invertLineChange(change: LineChange) LineChange {
    return .{ .originalStartLineNumber = change.modifiedStartLineNumber, .originalEndLineNumber = change.modifiedEndLineNumber, .modifiedStartLineNumber = change.originalStartLineNumber, .modifiedEndLineNumber = change.originalEndLineNumber };
}

pub fn compareLineChanges(_: void, a: LineChange, b: LineChange) bool {
    return @import("../../../vs/workbench/contrib/scm/common/quickDiff.zig").compareChanges(a, b) < 0;
}
