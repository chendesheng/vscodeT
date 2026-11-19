// Port of selected cases from
// `src/vs/editor/contrib/suggest/test/browser/suggestOvertypingCapturer.test.ts`.

const std = @import("std");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const OvertypingCapturer = @import("../../browser/suggestOvertypingCapturer.zig").OvertypingCapturer;

test "OvertypingCapturer: records selected text before typing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello\nworld", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 6),
        Selection.init(2, 1, 2, 6),
    });

    var capturer = OvertypingCapturer.init(allocator);
    defer capturer.deinit();
    capturer.capture(editor);

    const first = capturer.getLastOvertypedInfo(0).?;
    try std.testing.expectEqualStrings("hello", first.value);
    const second = capturer.getLastOvertypedInfo(1).?;
    try std.testing.expectEqualStrings("world", second.value);
    try std.testing.expect(capturer.getLastOvertypedInfo(2) == null);
}

test "OvertypingCapturer: locked capture and empty selection clear" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelection(Range.init(1, 1, 1, 6));

    var capturer = OvertypingCapturer.init(allocator);
    defer capturer.deinit();
    capturer.capture(editor);
    try std.testing.expectEqualStrings("hello", capturer.getLastOvertypedInfo(0).?.value);

    capturer.lock();
    try editor.setSelection(Range.init(1, 1, 1, 2));
    capturer.capture(editor);
    try std.testing.expectEqualStrings("hello", capturer.getLastOvertypedInfo(0).?.value);
    capturer.unlock();

    try editor.setCursorPosition(.{ .lineNumber = 1, .column = 2 });
    capturer.capture(editor);
    try std.testing.expect(capturer.getLastOvertypedInfo(0) == null);
}
