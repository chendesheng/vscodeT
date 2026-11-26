// Port of translatePosition and lengthBetweenPositions from
// src/vs/editor/browser/widget/diffEditor/utils.ts.
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const DiffMapping = @import("./diffEditorViewModel.zig").DiffMapping;

/// Translate a model position to a range on the other side. Flipping the
/// input/output ranges is equivalent to upstream's mapping.flip() array.
pub fn translatePosition(position: Position, mappings: []const DiffMapping, flip: bool) Range {
    var mapping_index = mappings.len;
    while (mapping_index > 0) {
        mapping_index -= 1;
        const mapping = mappings[mapping_index].line_range_mapping;
        const source = if (flip) mapping.modified else mapping.original;
        const destination = if (flip) mapping.original else mapping.modified;
        if (source.startLineNumber > position.lineNumber) continue;
        if (source.endLineNumberExclusive <= position.lineNumber) {
            const target = Position.init(position.lineNumber - source.endLineNumberExclusive + destination.endLineNumberExclusive, position.column);
            return Range.fromPositions(target, target);
        }
        const inner_changes = mapping.inner_changes orelse {
            const target = Position.init(destination.startLineNumber, 1);
            return Range.fromPositions(target, target);
        };
        var inner_index = inner_changes.len;
        while (inner_index > 0) {
            inner_index -= 1;
            const inner = inner_changes[inner_index];
            const a = if (flip) inner.modifiedRange else inner.originalRange;
            const b = if (flip) inner.originalRange else inner.modifiedRange;
            if (!a.getStartPosition().isBeforeOrEqual(position)) continue;
            if (a.containsPosition(&position)) return b;
            const end = a.getEndPosition();
            const target_end = b.getEndPosition();
            const target = if (end.lineNumber == position.lineNumber)
                Position.init(target_end.lineNumber, target_end.column + position.column - end.column)
            else
                Position.init(target_end.lineNumber + position.lineNumber - end.lineNumber, position.column);
            return Range.fromPositions(target, target);
        }
        const target = Position.init(position.lineNumber - source.startLineNumber + destination.startLineNumber, position.column);
        return Range.fromPositions(target, target);
    }
    return Range.fromPositions(position, position);
}
