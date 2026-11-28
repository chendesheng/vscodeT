//! Port of
//! `vscode/extensions/markdown-language-features/src/preview/scrolling.ts`.
//!
//! Upstream calls `editor.revealRange(..., AtTop)`. The terminal editor maps a
//! fractional model line to the containing view line and sets it as the first
//! visible view line.

const std = @import("std");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../../editor/common/core/position.zig").Position;

pub const StartingScrollLine = struct { line: f64 };
pub const StartingScrollFragment = struct { fragment: []const u8 };
pub const StartingScrollLocation = union(enum) {
    line: StartingScrollLine,
    fragment: StartingScrollFragment,
};

/// Changes the top-most visible line of `editor` to `line` (0-based and
/// fractional).
pub fn scrollEditorToLine(line: f64, editor: *Editor) void {
    if (std.math.isNan(line)) return;
    const clamped = @max(line, 0);
    const source_line_float = @floor(clamped);
    const source_line: usize = @intFromFloat(source_line_float);
    const line_count = editor.model.getLineCount();
    if (source_line >= line_count) {
        const position = editor.viewPositionOfModelPosition(Position.init(line_count, 1));
        _ = editor.setTopViewLine(position.lineNumber);
        return;
    }

    const fraction = clamped - source_line_float;
    const text_length = editor.model.getLineLength(source_line + 1);
    const offset: usize = @intFromFloat(@floor(fraction * @as(f64, @floatFromInt(text_length))));
    const max_column = editor.model.getLineMaxColumn(source_line + 1);
    const column = @min(offset + 1, max_column);
    const position = editor.viewPositionOfModelPosition(Position.init(source_line + 1, column));
    _ = editor.setTopViewLine(position.lineNumber);
}

test "scrolling: fractional lines map to the containing view line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var line: usize = 0;
    while (line < 40) : (line += 1) {
        try text.writer.print("line {d}\n", .{line});
    }
    const editor = try Editor.createFromText(allocator, io, text.written(), "test.md", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    scrollEditorToLine(0, editor);
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());
    scrollEditorToLine(12, editor);
    try std.testing.expectEqual(@as(usize, 13), editor.topViewLine());
    scrollEditorToLine(-4, editor);
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());
}

test "scrolling: StartingScrollLocation carries a line or fragment" {
    const line: StartingScrollLocation = .{ .line = .{ .line = 12.5 } };
    try std.testing.expectEqual(@as(f64, 12.5), line.line.line);
    const fragment: StartingScrollLocation = .{ .fragment = .{ .fragment = "usage" } };
    try std.testing.expectEqualStrings("usage", fragment.fragment.fragment);
}
