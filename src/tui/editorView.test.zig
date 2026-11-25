// Terminal editor integration tests. These six cases were previously inline
// in CodeEditorWidgetTerminal and StandaloneThemeService; they exercise the
// terminal View, ANSI output and cell geometry rather than upstream-only APIs.
// Test names and assertions are unchanged.
const std = @import("std");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const SyntaxTheme = @import("../vs/editor/standalone/browser/standaloneThemeService.zig").SyntaxTheme;
const View = @import("editorView.zig").View;

test "Editor: create, edit, undo, and render" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "hello world\nsecond line", "test.txt", 24, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try std.testing.expectEqual(@as(usize, 2), editor.model.getLineCount());
    try std.testing.expect(editor.viewLineCount() >= 2);

    try editor.insertText("X");
    const edited = try editor.model.getLineContent(1);
    defer edited.deinit();
    try std.testing.expectEqualStrings("Xhello world", edited.items);

    try editor.undo();
    const undone = try editor.model.getLineContent(1);
    defer undone.deinit();
    try std.testing.expectEqualStrings("hello world", undone.items);
    try std.testing.expectEqual(Position.init(1, 1), editor.modelCursorPosition());

    try editor.redo();
    const redone = try editor.model.getLineContent(1);
    defer redone.deinit();
    try std.testing.expectEqualStrings("Xhello world", redone.items);
    try std.testing.expectEqual(Position.init(1, 2), editor.modelCursorPosition());

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "Editor: tokenized Zig lines render through the wrapped view" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(allocator, io, "// hi\nconst x = 1;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.ensureTokensVisible();
    const line = try editor.viewLineData(1);
    try std.testing.expect(line.tokens.getCount() > 0);
    try std.testing.expectEqual(@as(u9, 5), line.tokens.getForeground(0));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "Editor: syntax stays visible after inserting blank lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(
        allocator,
        io,
        "const a = 1;\n\n/// comment\npub fn f() void {}\n",
        "test.zig",
        80,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(false);
    try editor.newline();
    try editor.newline();

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;197;134;192m") != null);
}

test "Editor: typing a function keeps following comments highlighted" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var editor = try Editor.createFromText(
        allocator,
        io,
        "const a = 1;\n\n/// comment\npub fn f() void {}\n",
        "test.zig",
        80,
        12,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveDown(false);
    try editor.insertText("pub fn hell() void {");
    try editor.newline();
    try editor.insertText("}");

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;197;134;192m") != null);
}

test "Editor: reserving the scrollbar avoids a second wrapping pass" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromTextWithOptions(
        allocator,
        io,
        "abcdefgh",
        "test.txt",
        15,
        5,
        .{ .reserve_scrollbar = true },
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expectEqual(@as(usize, 2), editor.scrollbar_width);
    try std.testing.expectEqual(@as(usize, 7), editor.textAreaWidth());
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 1), editor.view_lines.rebuildAllCount());

    const view = try View.init(allocator, editor);
    defer view.deinit();
    // View.init still sets the same width; it must not trigger another wrap.
    try std.testing.expectEqual(@as(usize, 1), editor.view_lines.rebuildAllCount());
}

test "syntax theme: editor paints the dark+ colors" {
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "// hi\nconst x = 1;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.ensureTokensVisible();
    var view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;86;156;214m") != null);
}
