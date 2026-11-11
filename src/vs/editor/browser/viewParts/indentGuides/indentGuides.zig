// Port of `src/vs/editor/browser/viewParts/indentGuides/indentGuides.ts`.
//
// Terminal adaptation: computes the vertical bracket-pair guides. The browser
// view also renders horizontal guides from an opening/closing bracket to the
// guide column; terminal cells use the same vertical line for now and the
// horizontal part is not painted. Indentation guides themselves are computed
// by `common/model/guidesTextModelPart.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;

pub const Guide = struct {
    /// 0-based visible column of the vertical line.
    column: usize,
    /// Bracket nesting level, used for the guide color.
    level: usize,
    active: bool,
};

pub const LineGuides = std.array_list.Managed(Guide);

/// Vertical bracket-pair guides for the requested model lines. The returned
/// slice is indexed by `lineNumber - startLineNumber`; each list is owned by
/// the caller.
pub fn getBracketGuides(
    allocator: Allocator,
    model: *TextModel,
    start_line_number: usize,
    end_line_number: usize,
    active_position: ?Position,
) ![]LineGuides {
    const line_count = model.getLineCount();
    if (start_line_number < 1 or start_line_number > line_count or
        end_line_number < 1 or end_line_number > line_count or
        end_line_number < start_line_number)
    {
        return error.InvalidLineRange;
    }

    const result = try allocator.alloc(LineGuides, end_line_number - start_line_number + 1);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*guides| guides.deinit();
        allocator.free(result);
    }
    for (result) |*guides| {
        guides.* = LineGuides.init(allocator);
        initialized += 1;
    }

    const line_max = model.getLineMaxColumn(end_line_number);
    var pairs = try model.getBracketPairsInRange(Range.init(
        start_line_number,
        1,
        end_line_number,
        line_max,
    ));
    defer pairs.deinit();

    var active_range: ?Range = null;
    if (active_position) |position| {
        if (position.lineNumber >= start_line_number and position.lineNumber <= end_line_number) {
            for (pairs.items) |pair| {
                if (pair.range.containsPosition(&position)) active_range = pair.range;
            }
        }
    }

    const tab_size = @max(model.getOptions().tabSize, 1);
    for (pairs.items) |pair| {
        const closing = pair.closingBracketRange orelse continue;
        if (pair.range.startLineNumber == pair.range.endLineNumber) continue;

        const is_active = if (active_range) |range| Range.equalsRange(range, pair.range) else false;

        const start = pair.openingBracketRange.getStartPosition();
        const end = closing.getStartPosition();
        const start_visible = try visibleColumn(model, start, tab_size);
        const end_visible = try visibleColumn(model, end, tab_size);
        const min_indent = try minVisibleIndent(
            model,
            pair.range.startLineNumber,
            pair.range.endLineNumber,
            tab_size,
        );
        const guide_column = @min(@min(start_visible, end_visible), min_indent + 1);
        if (guide_column == 0) continue;

        const first_line = @max(start.lineNumber, start_line_number);
        const last_line = @min(end.lineNumber, end_line_number);
        var line_number = first_line;
        while (line_number <= last_line) : (line_number += 1) {
            try result[line_number - start_line_number].append(.{
                .column = guide_column - 1,
                .level = pair.nestingLevel,
                .active = is_active,
            });
        }
    }

    for (result) |*guides| {
        std.mem.sort(Guide, guides.items, {}, struct {
            fn lessThan(_: void, a: Guide, b: Guide) bool {
                if (a.column != b.column) return a.column < b.column;
                return a.level < b.level;
            }
        }.lessThan);
    }

    return result;
}

fn visibleColumn(model: *TextModel, position: Position, tab_size: usize) !usize {
    var content = try model.getLineContent(position.lineNumber);
    defer content.deinit();
    return CursorColumns.visibleColumnFromColumn(content.items, position.column, tab_size) + 1;
}

fn minVisibleIndent(model: *TextModel, start_line: usize, end_line: usize, tab_size: usize) !usize {
    var result: usize = std.math.maxInt(usize);
    var line_number = start_line;
    while (line_number <= end_line) : (line_number += 1) {
        const first_non_ws = try model.getLineFirstNonWhitespaceColumn(line_number);
        if (first_non_ws == 0) continue;
        var content = try model.getLineContent(line_number);
        defer content.deinit();
        const visible = CursorColumns.visibleColumnFromColumn(content.items, first_non_ws, tab_size);
        result = @min(result, visible);
    }
    return if (result == std.math.maxInt(usize)) 0 else result;
}
