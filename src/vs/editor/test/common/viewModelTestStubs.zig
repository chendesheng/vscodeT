// Test helper: an identity `ICoordinatesConverter` for the ported view-model
// stubs.
//
// Upstream view tests construct a real view model (and therefore a real
// converter). The ported view scaffolding tests never convert coordinates, so
// a round-tripping converter is enough to satisfy the interface. There is no
// upstream file counterpart; this only exists to keep the stubs small.
const coordinates = @import("../../common/coordinatesConverter.zig");
const Position = @import("../../common/core/position.zig").Position;
const Range = @import("../../common/core/range.zig").Range;
const PositionAffinity = @import("../../common/model.zig").PositionAffinity;

pub const TestCoordinatesConverter = struct {
    pub fn interface() coordinates.ICoordinatesConverter {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .convertViewPositionToModelPosition = convertViewPositionToModelPosition,
            .convertViewRangeToModelRange = convertViewRangeToModelRange,
            .validateViewPosition = validateViewPosition,
            .validateViewRange = validateViewRange,
            .convertModelPositionToViewPosition = convertModelPositionToViewPosition,
            .convertModelRangeToViewRange = convertModelRangeToViewRange,
            .modelPositionIsVisible = modelPositionIsVisible,
            .getModelLineViewLineCount = getModelLineViewLineCount,
            .getViewLineNumberOfModelPosition = getViewLineNumberOfModelPosition,
        };
    }

    fn convertViewPositionToModelPosition(_: *anyopaque, view_position: Position) Position {
        return view_position;
    }
    fn convertViewRangeToModelRange(_: *anyopaque, view_range: Range) Range {
        return view_range;
    }
    fn validateViewPosition(_: *anyopaque, view_position: Position, _: Position) Position {
        return view_position;
    }
    fn validateViewRange(_: *anyopaque, view_range: Range, _: Range) Range {
        return view_range;
    }
    fn convertModelPositionToViewPosition(_: *anyopaque, model_position: Position, _: PositionAffinity, _: bool, _: bool) Position {
        return model_position;
    }
    fn convertModelRangeToViewRange(_: *anyopaque, model_range: Range, _: PositionAffinity) Range {
        return model_range;
    }
    fn modelPositionIsVisible(_: *anyopaque, _: Position) bool {
        return true;
    }
    fn getModelLineViewLineCount(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getViewLineNumberOfModelPosition(_: *anyopaque, model_line_number: usize, _: usize) usize {
        return model_line_number;
    }
};
