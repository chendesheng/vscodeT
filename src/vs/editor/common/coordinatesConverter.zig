const Position = @import("./core/position.zig").Position;
const Range = @import("./core/range.zig").Range;
const TextModel = @import("./model/textModel.zig").TextModel;
const PositionAffinity = @import("./model.zig").PositionAffinity;

pub const ICoordinatesConverter = struct {
    context: *anyopaque,

    convertViewPositionToModelPosition: *const fn (context: *anyopaque, viewPosition: Position) Position,
    convertViewRangeToModelRange: *const fn (context: *anyopaque, viewRange: Range) Range,
    validateViewPosition: *const fn (context: *anyopaque, viewPosition: Position, expectedModelPosition: Position) Position,
    validateViewRange: *const fn (context: *anyopaque, viewRange: Range, expectedModelRange: Range) Range,

    convertModelPositionToViewPosition: *const fn (
        context: *anyopaque,
        modelPosition: Position,
        affinity: PositionAffinity,
        allowZeroLineNumber: bool,
        belowHiddenRanges: bool,
    ) Position,
    convertModelRangeToViewRange: *const fn (context: *anyopaque, modelRange: Range, affinity: PositionAffinity) Range,
    modelPositionIsVisible: *const fn (context: *anyopaque, modelPosition: Position) bool,
    getModelLineViewLineCount: *const fn (context: *anyopaque, modelLineNumber: usize) usize,
    getViewLineNumberOfModelPosition: *const fn (context: *anyopaque, modelLineNumber: usize, modelColumn: usize) usize,
};

pub const IdentityCoordinatesConverter = struct {
    model: *TextModel,

    pub fn init(model: *TextModel) IdentityCoordinatesConverter {
        return .{ .model = model };
    }

    pub fn interface(self: *IdentityCoordinatesConverter) ICoordinatesConverter {
        return .{
            .context = self,
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

    pub fn modelRangeIsVisible(self: *IdentityCoordinatesConverter, modelRange: Range) bool {
        const lineCount = self.model.getLineCount();
        if (modelRange.startLineNumber < 1 or modelRange.startLineNumber > lineCount) return false;
        if (modelRange.endLineNumber < 1 or modelRange.endLineNumber > lineCount) return false;
        return true;
    }

    fn fromContext(context: *anyopaque) *IdentityCoordinatesConverter {
        return @ptrCast(@alignCast(context));
    }

    fn convertViewPositionToModelPosition(context: *anyopaque, viewPosition: Position) Position {
        const self = fromContext(context);
        return self.model.validatePosition(viewPosition);
    }

    fn convertViewRangeToModelRange(context: *anyopaque, viewRange: Range) Range {
        const self = fromContext(context);
        return self.model.validateRange(viewRange);
    }

    fn validateViewPosition(context: *anyopaque, _: Position, expectedModelPosition: Position) Position {
        const self = fromContext(context);
        return self.model.validatePosition(expectedModelPosition);
    }

    fn validateViewRange(context: *anyopaque, _: Range, expectedModelRange: Range) Range {
        const self = fromContext(context);
        return self.model.validateRange(expectedModelRange);
    }

    fn convertModelPositionToViewPosition(context: *anyopaque, modelPosition: Position, _: PositionAffinity, _: bool, _: bool) Position {
        const self = fromContext(context);
        return self.model.validatePosition(modelPosition);
    }

    fn convertModelRangeToViewRange(context: *anyopaque, modelRange: Range, _: PositionAffinity) Range {
        const self = fromContext(context);
        return self.model.validateRange(modelRange);
    }

    fn modelPositionIsVisible(context: *anyopaque, modelPosition: Position) bool {
        const self = fromContext(context);
        const lineCount = self.model.getLineCount();
        if (modelPosition.lineNumber < 1 or modelPosition.lineNumber > lineCount) {
            return false;
        }
        return true;
    }

    fn getModelLineViewLineCount(_: *anyopaque, _: usize) usize {
        return 1;
    }

    fn getViewLineNumberOfModelPosition(_: *anyopaque, modelLineNumber: usize, _: usize) usize {
        return modelLineNumber;
    }
};
