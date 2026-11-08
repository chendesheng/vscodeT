const TextModel = @import("../textModel.zig").TextModel;
const ICoordinatesConverter = @import("../coordinatesConverter.zig").ICoordinatesConverter;
const cursorCommon = @import("cursorCommon.zig");

pub const CursorContext = struct {
    model: *TextModel,
    viewModel: cursorCommon.ICursorSimpleModel,
    coordinatesConverter: ICoordinatesConverter,
    cursorConfig: *const cursorCommon.CursorConfiguration,

    pub fn init(
        model: *TextModel,
        viewModel: cursorCommon.ICursorSimpleModel,
        coordinatesConverter: ICoordinatesConverter,
        cursorConfig: *const cursorCommon.CursorConfiguration,
    ) CursorContext {
        return .{
            .model = model,
            .viewModel = viewModel,
            .coordinatesConverter = coordinatesConverter,
            .cursorConfig = cursorConfig,
        };
    }
};
