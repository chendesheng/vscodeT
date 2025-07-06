const usizeDiff = @import("pieceTreeBase.zig").usizeDiff;
const Position = @import("position.zig").Position;

pub const Range = struct {
    startLineNumber: usize,
    startColumn: usize,
    endLineNumber: usize,
    endColumn: usize,

    pub fn isEmpty(self: *const Range) bool {
        return self.startLineNumber == self.endLineNumber and self.startColumn == self.endColumn;
    }

    pub fn getEndPosition(self: *const Range) Position {
        return Position{
            .lineNumber = self.endLineNumber,
            .column = self.endColumn,
        };
    }

    pub fn getStartPosition(self: *const Range) Position {
        return Position{
            .lineNumber = self.startLineNumber,
            .column = self.startColumn,
        };
    }
};

// A function that compares ranges, useful for sorting ranges
// It will first compare ranges on the endPosition and then on the startPosition
pub fn compareRangesUsingEnds(a: *const Range, b: *const Range) isize {
    if (a.endLineNumber == b.endLineNumber) {
        if (a.endColumn == b.endColumn) {
            if (a.startLineNumber == b.startLineNumber) {
                return usizeDiff(a.startColumn, b.startColumn);
            }
            return usizeDiff(a.startLineNumber, b.startLineNumber);
        }
        return usizeDiff(a.endColumn, b.endColumn);
    }
    return usizeDiff(a.endLineNumber, b.endLineNumber);
}
