// Port of `src/vs/editor/common/core/selection.ts`.
const std = @import("std");
const Io = std.Io;
const Position = @import("./position.zig").Position;
const Range = @import("./range.zig").Range;

pub const SelectionDirection = enum {
    // The selection starts above where it ends.
    LTR,
    // The selection starts below where it ends.
    RTL,
};

// A selection in the editor.
// The selection is a range that has an orientation.
pub const Selection = struct {
    //  Line number on which the range starts (starts at 1).
    startLineNumber: usize,
    // Column on which the range starts in line `startLineNumber` (starts at 1).
    startColumn: usize,
    // Line number on which the range ends.
    endLineNumber: usize,
    // Column on which the range ends in line `endLineNumber`.
    endColumn: usize,

    // The line number on which the selection has started.
    selectionStartLineNumber: usize,
    // The column on `selectionStartLineNumber` where the selection has started.
    selectionStartColumn: usize,
    // The line number on which the selection has ended.
    positionLineNumber: usize,
    // The column on `positionLineNumber` where the selection has ended.
    positionColumn: usize,

    pub fn fromPositions(start: Position, end: ?Position) Selection {
        if (end) |endPosition| {
            return init(start.lineNumber, start.column, endPosition.lineNumber, endPosition.column);
        } else {
            return init(start.lineNumber, start.column, start.lineNumber, start.column);
        }
    }

    pub fn init(selectionStartLineNumber: usize, selectionStartColumn: usize, positionLineNumber: usize, positionColumn: usize) Selection {
        const reversed = (selectionStartLineNumber > positionLineNumber) or
            (selectionStartLineNumber == positionLineNumber and selectionStartColumn > positionColumn);

        return Selection{
            .startLineNumber = if (reversed) positionLineNumber else selectionStartLineNumber,
            .startColumn = if (reversed) positionColumn else selectionStartColumn,
            .endLineNumber = if (reversed) selectionStartLineNumber else positionLineNumber,
            .endColumn = if (reversed) selectionStartColumn else positionColumn,
            .selectionStartLineNumber = selectionStartLineNumber,
            .selectionStartColumn = selectionStartColumn,
            .positionLineNumber = positionLineNumber,
            .positionColumn = positionColumn,
        };
    }

    // Transform to a human-readable representation.
    pub fn toString(self: *const Selection, writer: *Io.Writer) !void {
        try writer.print("[{d},{d} -> {d},{d}]", .{ self.selectionStartLineNumber, self.selectionStartColumn, self.positionLineNumber, self.positionColumn });
    }

    // Test if equals other selection.
    pub fn equalsSelection(a: *const Selection, b: *const Selection) bool {
        return selectionsEqual(a, b);
    }

    // Test if the two selections are equal.
    pub fn selectionsEqual(a: *const Selection, b: *const Selection) bool {
        return a.selectionStartLineNumber == b.selectionStartLineNumber and
            a.selectionStartColumn == b.selectionStartColumn and
            a.positionLineNumber == b.positionLineNumber and
            a.positionColumn == b.positionColumn;
    }

    // Create a new selection with the same fields.
    pub fn liftSelection(sel: Selection) Selection {
        return sel;
    }

    // Get directions (LTR or RTL).
    pub fn getDirection(self: *const Selection) SelectionDirection {
        if (self.selectionStartLineNumber == self.startLineNumber and self.selectionStartColumn == self.startColumn) {
            return .LTR;
        }
        return .RTL;
    }

    // Create a new selection with a different `positionLineNumber` and `positionColumn`.
    pub fn setEndPosition(self: *const Selection, endLineNumber: usize, endColumn: usize) Selection {
        if (self.getDirection() == .LTR) {
            return Selection.init(self.startLineNumber, self.startColumn, endLineNumber, endColumn);
        } else {
            return Selection.init(endLineNumber, endColumn, self.startLineNumber, self.startColumn);
        }
    }

    // Get the position at `positionLineNumber` and `positionColumn`.
    pub fn getPosition(self: *const Selection) Position {
        return Position{
            .lineNumber = self.positionLineNumber,
            .column = self.positionColumn,
        };
    }

    pub fn isEmpty(self: *const Selection) bool {
        return self.startLineNumber == self.endLineNumber and self.startColumn == self.endColumn;
    }

    pub fn getStartPosition(self: *const Selection) Position {
        return Position{ .lineNumber = self.startLineNumber, .column = self.startColumn };
    }

    pub fn getEndPosition(self: *const Selection) Position {
        return Position{ .lineNumber = self.endLineNumber, .column = self.endColumn };
    }

    pub fn plusRange(self: *const Selection, other: *const Selection) Range {
        const a = Range.init(self.startLineNumber, self.startColumn, self.endLineNumber, self.endColumn);
        const b = Range.init(other.startLineNumber, other.startColumn, other.endLineNumber, other.endColumn);
        return a.plusRange(&b);
    }

    // Get the position at the start of the selection.
    pub fn getSelectionStart(self: *const Selection) Position {
        return Position{
            .lineNumber = self.selectionStartLineNumber,
            .column = self.selectionStartColumn,
        };
    }

    // Create a new selection with a different `selectionStartLineNumber` and `selectionStartColumn`.
    pub fn setSelectionStart(self: *const Selection, startLineNumber: usize, startColumn: usize) Selection {
        if (self.getDirection() == .LTR) {
            return Selection.init(startLineNumber, startColumn, self.endLineNumber, self.endColumn);
        } else {
            return Selection.init(self.endLineNumber, self.endColumn, startLineNumber, startColumn);
        }
    }
};

test "Selection: setters, toString, equality" {
    const ltr = Selection.init(1, 1, 3, 3);
    const moved_end = ltr.setEndPosition(4, 5);
    try std.testing.expectEqual(Position{ .lineNumber = 1, .column = 1 }, moved_end.getSelectionStart());
    try std.testing.expectEqual(Position{ .lineNumber = 4, .column = 5 }, moved_end.getPosition());

    const rtl = Selection.init(3, 3, 1, 1);
    const moved_end_rtl = rtl.setEndPosition(2, 2);
    try std.testing.expectEqual(Position{ .lineNumber = 2, .column = 2 }, moved_end_rtl.getSelectionStart());
    try std.testing.expectEqual(Position{ .lineNumber = 1, .column = 1 }, moved_end_rtl.getPosition());

    const moved_start = ltr.setSelectionStart(2, 2);
    try std.testing.expectEqual(Position{ .lineNumber = 2, .column = 2 }, moved_start.getSelectionStart());
    try std.testing.expectEqual(Position{ .lineNumber = 3, .column = 3 }, moved_start.getPosition());

    try std.testing.expect(ltr.equalsSelection(&Selection.init(1, 1, 3, 3)));
    try std.testing.expect(Selection.selectionsEqual(&ltr, &Selection.init(1, 1, 3, 3)));
    try std.testing.expect(!ltr.equalsSelection(&moved_end));

    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try ltr.toString(&writer);
    try std.testing.expectEqualStrings("[1,1 -> 3,3]", writer.buffered());
}

// Create a `Selection` from one or two positions
pub fn fromPositions(start: Position, end: ?Position) Selection {
    if (end) |endPosition| {
        return Selection.init(start.lineNumber, start.column, endPosition.lineNumber, endPosition.column);
    } else {
        return Selection.init(start.lineNumber, start.column, start.lineNumber, start.column);
    }
}

// Creates a `Selection` from a range, given a direction.
pub fn fromRange(range: Range, direction: SelectionDirection) Selection {
    if (direction == .LTR) {
        return Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn);
    } else {
        return Selection.init(range.endLineNumber, range.endColumn, range.startLineNumber, range.startColumn);
    }
}

// `a` equals `b`.
pub fn selectionsArrEqual(a: []const Selection, b: []const Selection) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |itemA, itemB| {
        if (!Selection.selectionsEqual(&itemA, &itemB)) {
            return false;
        }
    }
    return true;
}

// Create with a direction.
pub fn createWithDirection(startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, direction: SelectionDirection) Selection {
    if (direction == .LTR) {
        return Selection.init(startLineNumber, startColumn, endLineNumber, endColumn);
    } else {
        return Selection.init(endLineNumber, endColumn, startLineNumber, startColumn);
    }
}
