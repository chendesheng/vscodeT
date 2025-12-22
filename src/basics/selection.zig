const std = @import("std");
const fmt = std.fmt;
const Position = @import("position.zig").Position;
const Range = @import("range.zig").Range;

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

    pub fn init(selectionStartLineNumber: usize, selectionStartColumn: usize, positionLineNumber: usize, positionColumn: usize) Selection {
        var startLineNumber = selectionStartLineNumber;
        var startColumn = selectionStartColumn;
        var endLineNumber = positionLineNumber;
        var endColumn = positionColumn;

        if ((startLineNumber > endLineNumber) or (startLineNumber == endLineNumber and startColumn > endColumn)) {
            startLineNumber = endLineNumber;
            startColumn = endColumn;
            endLineNumber = startLineNumber;
            endColumn = startColumn;
        }

        return Selection{
            .startLineNumber = startLineNumber,
            .startColumn = startColumn,
            .endLineNumber = endLineNumber,
            .endColumn = endColumn,
            .selectionStartLineNumber = selectionStartLineNumber,
            .selectionStartColumn = selectionStartColumn,
            .positionLineNumber = positionLineNumber,
            .positionColumn = positionColumn,
        };
    }

    // Transform to a human-readable representation.
    pub fn toString(self: *const Selection) []const u8 {
        var buf: [1024]u8 = undefined;
        return fmt.bufPrint(&buf, "[{d},{d} -> {d},{d}]", .{ self.selectionStartLineNumber, self.selectionStartColumn, self.positionLineNumber, self.positionColumn });
    }

    // Test if equals other selection.
    pub fn equalsSelection(a: *const Selection, b: *const Selection) bool {
        return selectionsEqual(a, b);
    }

    // Get directions (LTR or RTL).
    pub fn getDirection(self: *const Selection) SelectionDirection {
        if (self.selectionStartLineNumber == self.startLineNumber and self.selectionStartColumn == self.startColumn) {
            return .LTR;
        }
        return .RTL;
    }

    // Create a new selection with a different `positionLineNumber` and `positionColumn`.
    pub fn setEndPosition(self: *Selection, endLineNumber: usize, endColumn: usize) void {
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

    // Get the position at the start of the selection.
    pub fn getSelectionStart(self: *const Selection) Position {
        return Position{
            .lineNumber = self.selectionStartLineNumber,
            .column = self.selectionStartColumn,
        };
    }

    // Create a new selection with a different `selectionStartLineNumber` and `selectionStartColumn`.
    pub fn setSelectionStart(self: *Selection, startLineNumber: usize, startColumn: usize) void {
        if (self.getDirection() == .LTR) {
            return Selection.init(startLineNumber, startColumn, self.endLineNumber, self.endColumn);
        } else {
            return Selection.init(self.endLineNumber, self.endColumn, startLineNumber, startColumn);
        }
    }
};

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
        if (!selectionsEqual(&itemA, &itemB)) {
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

// Test if the two selections are equal.
fn selectionsEqual(a: *const Selection, b: *const Selection) bool {
    return a.selectionStartLineNumber == b.selectionStartLineNumber and a.selectionStartColumn == b.selectionStartColumn and a.positionLineNumber == b.positionLineNumber and a.positionColumn == b.positionColumn;
}
