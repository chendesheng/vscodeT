const std = @import("std");

pub const ScrollType = enum(u8) {
    Smooth = 0,
    Immediate = 1,
};

/// Built-in commands.
pub const Handler = enum(u8) {
    compositionStart,
    compositionEnd,
    type,
    replacePreviousChar,
    compositionType,
    paste,
    cut,
};

pub const TypePayload = struct {
    text: []const u8,
};

pub const ReplacePreviousCharPayload = struct {
    text: []const u8,
    replaceCharCnt: usize,
};

pub const CompositionTypePayload = struct {
    text: []const u8,
    replacePrevCharCnt: usize,
    replaceNextCharCnt: usize,
    positionDelta: i32,
};

// --- view

pub const IScrollEvent = struct {
    scrollTop: f64,
    scrollLeft: f64,
    scrollWidth: f64,
    scrollHeight: f64,

    scrollTopChanged: bool,
    scrollLeftChanged: bool,
    scrollWidthChanged: bool,
    scrollHeightChanged: bool,
};

pub const IContentSizeChangedEvent = struct {
    contentWidth: f64,
    contentHeight: f64,

    contentWidthChanged: bool,
    contentHeightChanged: bool,
};

pub const ITriggerEditorOperationEvent = struct {
    source: ?[]const u8,
    handlerId: []const u8,
    payload: ?*anyopaque,
};

pub const INewScrollPosition = struct {
    scrollLeft: ?f64 = null,
    scrollTop: ?f64 = null,
};

test "editorCommon: handler names" {
    try std.testing.expectEqualStrings("compositionStart", @tagName(Handler.compositionStart));
    try std.testing.expectEqualStrings("compositionEnd", @tagName(Handler.compositionEnd));
    try std.testing.expectEqualStrings("type", @tagName(Handler.type));
    try std.testing.expectEqualStrings("replacePreviousChar", @tagName(Handler.replacePreviousChar));
    try std.testing.expectEqualStrings("compositionType", @tagName(Handler.compositionType));
    try std.testing.expectEqualStrings("paste", @tagName(Handler.paste));
    try std.testing.expectEqualStrings("cut", @tagName(Handler.cut));
}

test "editorCommon: payloads" {
    const type_payload = TypePayload{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", type_payload.text);

    const replace_payload = ReplacePreviousCharPayload{ .text = "x", .replaceCharCnt = 2 };
    try std.testing.expectEqual(@as(usize, 2), replace_payload.replaceCharCnt);

    const composition_payload = CompositionTypePayload{
        .text = "abc",
        .replacePrevCharCnt = 1,
        .replaceNextCharCnt = 2,
        .positionDelta = -1,
    };
    try std.testing.expectEqual(@as(i32, -1), composition_payload.positionDelta);
}

test "editorCommon: scroll event shape" {
    const event = IScrollEvent{
        .scrollTop = 10,
        .scrollLeft = 20,
        .scrollWidth = 100,
        .scrollHeight = 200,
        .scrollTopChanged = true,
        .scrollLeftChanged = false,
        .scrollWidthChanged = true,
        .scrollHeightChanged = false,
    };
    try std.testing.expect(event.scrollTopChanged);
    try std.testing.expect(!event.scrollHeightChanged);

    const new_position = INewScrollPosition{ .scrollTop = 5 };
    try std.testing.expectEqual(@as(?f64, 5), new_position.scrollTop);
    try std.testing.expectEqual(@as(?f64, null), new_position.scrollLeft);
}
