// Port of `src/vs/editor/browser/view/viewUserInputEvents.ts`.
//
// Terminal adaptations: the raw browser event is an opaque pointer (only
// forwarded), the keyboard event reuses the platform keybinding event shape,
// and the wheel event is a plain delta struct.
const std = @import("std");
const editor_browser = @import("../editorBrowser.zig");
const coordinates = @import("../../common/coordinatesConverter.zig");
const keybinding_mod = @import("../../../platform/keybinding/common/keybinding.zig");

const MouseTarget = editor_browser.MouseTarget;
const MouseTargetDetail = editor_browser.MouseTargetDetail;
const MouseTargetType = editor_browser.MouseTargetType;
const ViewZoneTargetData = editor_browser.ViewZoneTargetData;
const ICoordinatesConverter = coordinates.ICoordinatesConverter;
const IKeyboardEvent = keybinding_mod.IKeyboardEvent;

pub fn Callback(comptime T: type) type {
    return struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, event: T) void,
    };
}

pub const IEditorMouseEvent = struct {
    event: ?*const anyopaque = null,
    target: ?MouseTarget = null,
};

pub const MouseWheelEvent = struct {
    delta_x: f64,
    delta_y: f64,
};

pub const ViewUserInputEvents = struct {
    coordinates_converter: ICoordinatesConverter,

    onKeyDown: ?Callback(IKeyboardEvent) = null,
    onKeyUp: ?Callback(IKeyboardEvent) = null,
    onContextMenu: ?Callback(IEditorMouseEvent) = null,
    onMouseMove: ?Callback(IEditorMouseEvent) = null,
    onMouseLeave: ?Callback(IEditorMouseEvent) = null,
    onMouseDown: ?Callback(IEditorMouseEvent) = null,
    onMouseUp: ?Callback(IEditorMouseEvent) = null,
    onMouseDrag: ?Callback(IEditorMouseEvent) = null,
    onMouseDrop: ?Callback(IEditorMouseEvent) = null,
    onMouseDropCanceled: ?Callback(void) = null,
    onMouseWheel: ?Callback(MouseWheelEvent) = null,

    pub fn init(converter: ICoordinatesConverter) ViewUserInputEvents {
        return .{ .coordinates_converter = converter };
    }

    pub fn emitKeyDown(self: *ViewUserInputEvents, event: IKeyboardEvent) void {
        if (self.onKeyDown) |callback| callback.call(callback.context, event);
    }

    pub fn emitKeyUp(self: *ViewUserInputEvents, event: IKeyboardEvent) void {
        if (self.onKeyUp) |callback| callback.call(callback.context, event);
    }

    pub fn emitContextMenu(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onContextMenu) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseMove(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseMove) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseLeave(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseLeave) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseDown(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseDown) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseUp(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseUp) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseDrag(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseDrag) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseDrop(self: *ViewUserInputEvents, event: IEditorMouseEvent) void {
        if (self.onMouseDrop) |callback| callback.call(callback.context, self.convertViewToModelMouseEvent(event));
    }

    pub fn emitMouseDropCanceled(self: *ViewUserInputEvents) void {
        if (self.onMouseDropCanceled) |callback| callback.call(callback.context, {});
    }

    pub fn emitMouseWheel(self: *ViewUserInputEvents, event: MouseWheelEvent) void {
        if (self.onMouseWheel) |callback| callback.call(callback.context, event);
    }

    fn convertViewToModelMouseEvent(self: *ViewUserInputEvents, event: IEditorMouseEvent) IEditorMouseEvent {
        if (event.target) |target| {
            return .{ .event = event.event, .target = convertViewToModelMouseTarget(target, self.coordinates_converter) };
        }
        return event;
    }

    pub fn convertViewToModelMouseTarget(target: MouseTarget, converter: ICoordinatesConverter) MouseTarget {
        var result = target;
        if (result.position) |position| result.position = converter.convertViewPositionToModelPosition(converter.context, position);
        if (result.range) |range| result.range = converter.convertViewRangeToModelRange(converter.context, range);
        if (result.type == .gutter_view_zone or result.type == .content_view_zone) {
            if (result.detail) |detail| {
                if (detail == .view_zone) {
                    result.detail = .{ .view_zone = convertViewToModelViewZoneData(detail.view_zone, converter) };
                }
            }
        }
        return result;
    }

    fn convertViewToModelViewZoneData(data: ViewZoneTargetData, converter: ICoordinatesConverter) ViewZoneTargetData {
        return .{
            .view_zone_id = data.view_zone_id,
            .position_before = if (data.position_before) |position| converter.convertViewPositionToModelPosition(converter.context, position) else null,
            .position_after = if (data.position_after) |position| converter.convertViewPositionToModelPosition(converter.context, position) else null,
            .position = converter.convertViewPositionToModelPosition(converter.context, data.position),
            .after_line_number = converter.convertViewPositionToModelPosition(converter.context, .{ .lineNumber = data.after_line_number, .column = 1 }).lineNumber,
        };
    }
};

test "mouse targets convert view positions and view-zone data" {
    const State = struct {
        fn toModel(_: *anyopaque, position: Position) Position {
            return .{ .lineNumber = position.lineNumber + 1, .column = position.column + 1 };
        }
        fn toModelRange(_: *anyopaque, range: @import("../../common/core/range.zig").Range) @import("../../common/core/range.zig").Range {
            return .{ .startLineNumber = range.startLineNumber + 1, .startColumn = range.startColumn + 1, .endLineNumber = range.endLineNumber + 1, .endColumn = range.endColumn + 1 };
        }
        fn remaining(comptime name: []const u8) usize {
            _ = name;
            return 0;
        }
    };
    var state: u8 = 0;
    const converter = ICoordinatesConverter{
        .context = &state,
        .convertViewPositionToModelPosition = State.toModel,
        .convertViewRangeToModelRange = State.toModelRange,
        .validateViewPosition = struct {
            fn f(_: *anyopaque, position: Position, _: Position) Position {
                return position;
            }
        }.f,
        .validateViewRange = struct {
            fn f(_: *anyopaque, range: @import("../../common/core/range.zig").Range, _: @import("../../common/core/range.zig").Range) @import("../../common/core/range.zig").Range {
                return range;
            }
        }.f,
        .convertModelPositionToViewPosition = struct {
            fn f(_: *anyopaque, position: Position, _: @import("../../common/model.zig").PositionAffinity, _: bool, _: bool) Position {
                return position;
            }
        }.f,
        .convertModelRangeToViewRange = struct {
            fn f(_: *anyopaque, range: @import("../../common/core/range.zig").Range, _: @import("../../common/model.zig").PositionAffinity) @import("../../common/core/range.zig").Range {
                return range;
            }
        }.f,
        .modelPositionIsVisible = struct {
            fn f(_: *anyopaque, _: Position) bool {
                return true;
            }
        }.f,
        .getModelLineViewLineCount = struct {
            fn f(_: *anyopaque, _: usize) usize {
                return 0;
            }
        }.f,
        .getViewLineNumberOfModelPosition = struct {
            fn f(_: *anyopaque, _: usize, _: usize) usize {
                return 0;
            }
        }.f,
    };

    const target = MouseTarget{
        .position = .{ .lineNumber = 2, .column = 3 },
        .type = .content_text,
    };
    const converted = ViewUserInputEvents.convertViewToModelMouseTarget(target, converter);
    try std.testing.expectEqual(@as(usize, 3), converted.position.?.lineNumber);
    try std.testing.expectEqual(@as(usize, 4), converted.position.?.column);

    const zone = MouseTarget{
        .type = .content_view_zone,
        .detail = .{ .view_zone = .{ .view_zone_id = "zone", .position = .{ .lineNumber = 1, .column = 1 }, .after_line_number = 4 } },
        .position = .{ .lineNumber = 1, .column = 1 },
    };
    const converted_zone = ViewUserInputEvents.convertViewToModelMouseTarget(zone, converter);
    try std.testing.expectEqual(@as(usize, 5), converted_zone.detail.?.view_zone.after_line_number);
}

const Position = @import("../../common/core/position.zig").Position;
