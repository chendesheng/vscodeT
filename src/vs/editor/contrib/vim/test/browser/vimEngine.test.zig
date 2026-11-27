// Native Vim engine tests.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const extension_api = @import("../../../../../workbench/api/common/extensionApi.zig");
const builtin_host = @import("../../../../../workbench/api/browser/builtinExtensionHost.zig");
const VimEngine = @import("../../browser/vimEngine.zig").VimEngine;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");

const Harness = @import("./vimTestHarness.zig").Harness;

test "Vim: insert, escape, undo and redo use editor state" {
    const h = try Harness.init(std.testing.allocator, "hello");
    defer h.deinit();

    try h.sendChar('i');
    try h.sendText("abc");
    try h.send(.escape);

    try h.expectValue("abchello");

    try h.sendChar('u');
    try h.expectValue("hello");

    try h.sendCtrl('r');
    try h.expectValue("abchello");
}

test "Vim: j and k keep the editor's visible column" {
    const h = try Harness.init(std.testing.allocator, "abcdef\nab\nabcdef");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 6));

    try h.sendChar('j');
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 6), h.editor.modelCursorPosition());

    try h.sendChar('k');
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 6), h.editor.modelCursorPosition());
}

test "Vim: k on the first line keeps the desired column" {
    // Mirrors `.vscode/tasks.json`: a short first line, then long comments.
    const h = try Harness.init(std.testing.allocator, "{\n  // See https://go.microsoft.com/fwlink/?LinkId=733558\n  // for the documentation about the tasks.json format\n  \"version\": \"2.0.0\",");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(2, 10));

    // `k` enters the short first line; normal mode clamps the caret to `{`.
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());

    // A second `k` cannot move any further. Upstream returns the position
    // unchanged, so the desired column is still there for the next `j`.
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());

    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(2, 10), h.editor.modelCursorPosition());
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.editor.modelCursorPosition());
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(2, 10), h.editor.modelCursorPosition());
}

test "Vim: k on the first line does not move the caret" {
    const h = try Harness.init(std.testing.allocator, "0123456789abcdef\nab");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 10));

    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 10), h.editor.modelCursorPosition());
    try h.send(.up);
    try std.testing.expectEqual(Position.init(1, 10), h.editor.modelCursorPosition());

    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(2, 2), h.editor.modelCursorPosition());
}

test "Vim: j on the last line is a no-op and counts stop at the edge" {
    const h = try Harness.init(std.testing.allocator, "0123456789abcdef\nab\n0123456789abcdef");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 10));

    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(2, 2), h.editor.modelCursorPosition());
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.editor.modelCursorPosition());

    // The last line must not pull the caret to its end.
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.editor.modelCursorPosition());
    try h.send(.down);
    try std.testing.expectEqual(Position.init(3, 10), h.editor.modelCursorPosition());

    // A count clamps at the last line at the remembered column.
    try h.sendChar('k');
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 10), h.editor.modelCursorPosition());
    try h.sendChar('9');
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.editor.modelCursorPosition());

    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(2, 2), h.editor.modelCursorPosition());
}

test "Vim: dw and dd edit through the command engine" {
    const h = try Harness.init(std.testing.allocator, "hello world");
    defer h.deinit();

    try h.sendChar('d');
    try h.sendChar('w');
    try h.expectValue("world");

    try h.sendChar('u');
    try h.expectValue("hello world");

    try h.sendChar('d');
    try h.sendChar('d');
    try h.expectValue("");

    try h.sendChar('p');
    try h.expectValue("hello world");
}

test "Vim: visual mode and text objects" {
    const h = try Harness.init(std.testing.allocator, "hello world");
    defer h.deinit();

    try h.sendChar('v');
    try h.sendChar('l');
    try h.sendChar('d');
    try h.expectValue("llo world");

    try h.sendChar('u');
    try h.expectValue("hello world");

    try h.sendChar('d');
    try h.sendChar('i');
    try h.sendChar('w');
    try h.expectValue(" world");
}

test "Vim: search and ex command line" {
    const h = try Harness.init(std.testing.allocator, "alpha beta gamma");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("gamma");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 12), h.editor.modelCursorPosition().column);

    try h.sendChar(':');
    try h.sendText("w");
    try h.send(.enter);
    try std.testing.expect(h.commands.last != null);
    try std.testing.expectEqualStrings("workbench.action.files.save", h.commands.last.?);
}

test "Vim: x at end of line does not join the next line" {
    const h = try Harness.init(std.testing.allocator, "ab\ncd");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 2));
    try h.sendChar('x');
    try h.expectValue("a\ncd");
}

test "Vim: dj deletes through the target line" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo\nthree");
    defer h.deinit();
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());
    try h.sendChar('d');
    try h.sendChar('j');
    try h.expectValue("three");
}

test "Vim: Vd deletes only the selected line" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();
    try h.sendChar('V');
    try h.sendChar('d');
    try h.expectValue("two");
}

test "Vim: r replaces without changing registers" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('r');
    try h.sendChar('X');
    try h.expectValue("Xbc");
}

test "Vim: gt asks the window service to switch tabs" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('g');
    try h.sendChar('t');
    try std.testing.expectEqual(@as(isize, 1), h.window.tab_delta);
}

test "Vim: cw and cc are one undo step including insert" {
    const cw = try Harness.init(std.testing.allocator, "abc def");
    defer cw.deinit();
    try cw.sendChar('c');
    try cw.sendChar('w');
    try cw.sendText("X");
    try cw.send(.escape);
    try cw.expectValue("X def");
    try cw.sendChar('u');
    try cw.expectValue("abc def");

    const cc = try Harness.init(std.testing.allocator, "one\ntwo");
    defer cc.deinit();
    try cc.sendChar('c');
    try cc.sendChar('c');
    try cc.sendText("changed");
    try cc.send(.escape);
    try cc.expectValue("changed\ntwo");
    try cc.sendChar('u');
    try cc.expectValue("one\ntwo");
}

test "Vim: n advances through repeated search matches" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 5), h.editor.modelCursorPosition().column);
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 9), h.editor.modelCursorPosition().column);
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 1), h.editor.modelCursorPosition().column);
}

test "Vim: incremental search previews matches and Escape restores the cursor" {
    const h = try Harness.init(std.testing.allocator, "alpha beta alpha");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("alp");
    try std.testing.expectEqual(Position.init(1, 12), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 2), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 12, 1, 15), h.currentHighlight().?);

    // The preview searches from the prompt-start cursor, not from the
    // previewed match, so extending the pattern keeps the first match.
    try h.sendText("ha");
    try std.testing.expectEqual(Position.init(1, 12), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 2), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 12, 1, 17), h.currentHighlight().?);

    try h.send(.escape);
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
}

test "Vim: committed search highlights all matches and n moves the current match" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 3), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 5, 1, 8), h.currentHighlight().?);

    try h.sendChar('n');
    try std.testing.expectEqual(Range.init(1, 9, 1, 12), h.currentHighlight().?);

    try h.sendChar('N');
    try std.testing.expectEqual(Range.init(1, 5, 1, 8), h.currentHighlight().?);

    try h.sendChar(':');
    try h.sendText("noh");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
}

test "Vim: :noh keeps the search pattern and n re-enables the highlight" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 3), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 5, 1, 8), h.currentHighlight().?);

    try h.sendChar(':');
    try h.sendText("noh");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
    try std.testing.expectEqual(@as(?[]const u8, null), h.window.message);

    // Cancelling a prompt after `:noh` must not repaint the old matches.
    try h.sendChar('/');
    try h.send(.escape);
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());

    // Vim keeps the pattern: `n` searches again and turns the paint back on.
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 3), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 9, 1, 12), h.currentHighlight().?);
}

test "Vim: :nohl and :nohlsearch are accepted abbreviations" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 3), h.highlightCount());

    try h.sendChar(':');
    try h.sendText("nohl");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
    try std.testing.expectEqual(@as(?[]const u8, null), h.window.message);

    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 3), h.highlightCount());

    try h.sendChar(':');
    try h.sendText("nohlsearch");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
    try std.testing.expectEqual(@as(?[]const u8, null), h.window.message);

    // Anything that is not a prefix of `nohlsearch` stays unsupported.
    try h.sendChar(':');
    try h.sendText("nohlx");
    try h.send(.enter);
    try std.testing.expectEqualStrings("Vim: unsupported command", h.window.message.?);
}

test "Vim: incremental search backspace and no match" {
    const h = try Harness.init(std.testing.allocator, "abcabc");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("bc");
    try std.testing.expectEqual(Position.init(1, 2), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 2), h.highlightCount());

    try h.send(.backspace);
    try std.testing.expectEqual(Position.init(1, 2), h.editor.modelCursorPosition());

    try h.send(.backspace);
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());

    try h.sendText("zzz");
    try std.testing.expectEqual(Position.init(1, 1), h.editor.modelCursorPosition());
    try std.testing.expectEqual(@as(usize, 0), h.highlightCount());
}

test "Vim: starred search highlights every occurrence" {
    const h = try Harness.init(std.testing.allocator, "foo bar foo");
    defer h.deinit();

    try h.sendChar('*');
    try std.testing.expectEqual(@as(usize, 2), h.highlightCount());
    try std.testing.expectEqual(Range.init(1, 9, 1, 12), h.currentHighlight().?);
}

test "Vim: counted search commits to the counted match" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();

    try h.sendChar('2');
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(Position.init(1, 9), h.editor.modelCursorPosition());
    try std.testing.expectEqual(Range.init(1, 9, 1, 12), h.currentHighlight().?);
}

test "Vim: f and ; repeat a character search" {
    const h = try Harness.init(std.testing.allocator, "a.b.c.d");
    defer h.deinit();
    try h.sendChar('f');
    try h.sendChar('.');
    try std.testing.expectEqual(@as(usize, 2), h.editor.modelCursorPosition().column);
    try h.sendChar(';');
    try std.testing.expectEqual(@as(usize, 4), h.editor.modelCursorPosition().column);
    try h.sendChar(',');
    try std.testing.expectEqual(@as(usize, 2), h.editor.modelCursorPosition().column);
}

test "Vim: dd on the last line removes the preceding line break" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(2, 1));
    try h.sendChar('d');
    try h.sendChar('d');
    try h.expectValue("one");
    try h.sendChar('u');
    try h.expectValue("one\ntwo");
}

test "Vim: printable text runs are normal-mode keys" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendText("x");
    try h.expectValue("bc");
    try h.sendText("u");
    try h.expectValue("abc");
}

test "Vim: search uses regular expressions" {
    const h = try Harness.init(std.testing.allocator, "abc123def456");
    defer h.deinit();
    try h.sendChar('/');
    try h.sendText("[0-9]+");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 4), h.editor.modelCursorPosition().column);
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 10), h.editor.modelCursorPosition().column);
}

test "Vim: percent jumps between matching brackets" {
    const h = try Harness.init(std.testing.allocator, "(foo)");
    defer h.deinit();
    try h.sendChar('%');
    try std.testing.expectEqual(@as(usize, 5), h.editor.modelCursorPosition().column);
    try h.sendChar('%');
    try std.testing.expectEqual(@as(usize, 1), h.editor.modelCursorPosition().column);
}

test "Vim: shift operators indent and outdent lines" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();
    try h.sendChar('>');
    try h.sendChar('>');
    const indented = try h.value();
    defer h.allocator.free(indented);
    try std.testing.expect(std.mem.startsWith(u8, indented, "    one"));
    try h.sendChar('<');
    try h.sendChar('<');
    try h.expectValue("one\ntwo");
}

test "Vim: U restores the last changed line" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('x');
    try h.expectValue("bc");
    try h.sendChar('U');
    try h.expectValue("abc");
}

test "Vim: gv reselects and gi returns to the last insert" {
    const gv = try Harness.init(std.testing.allocator, "abc");
    defer gv.deinit();
    try gv.sendChar('v');
    try gv.sendChar('l');
    try gv.sendChar('d');
    try gv.expectValue("c");
    try gv.sendChar('u');
    try gv.expectValue("abc");
    try gv.sendChar('g');
    try gv.sendChar('v');
    try gv.sendChar('d');
    try gv.expectValue("c");

    const gi = try Harness.init(std.testing.allocator, "abc");
    defer gi.deinit();
    try gi.sendChar('i');
    try gi.sendText("X");
    try gi.send(.escape);
    try gi.expectValue("Xabc");
    try gi.sendChar('g');
    try gi.sendChar('i');
    try gi.sendText("Y");
    try gi.send(.escape);
    try gi.expectValue("XYabc");
}

test "Vim: R replaces text on the current line" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('R');
    try h.sendText("XY");
    try h.send(.escape);
    try h.expectValue("XYc");
    try h.sendChar('u');
    try h.expectValue("abc");
}

test "Vim: visual block deletes a rectangle" {
    const h = try Harness.init(std.testing.allocator, "ab\ncd\nef");
    defer h.deinit();
    try h.sendCtrl('v');
    try h.sendText("j");
    try h.sendText("d");
    try h.expectValue("b\nd\nef");
}

test "Vim: dot repeats the last change" {
    const x = try Harness.init(std.testing.allocator, "abc");
    defer x.deinit();
    try x.sendChar('x');
    try x.expectValue("bc");
    try x.sendChar('.');
    try x.expectValue("c");

    const insert = try Harness.init(std.testing.allocator, "abc");
    defer insert.deinit();
    try insert.sendChar('i');
    try insert.sendText("X");
    try insert.send(.escape);
    try insert.expectValue("Xabc");
    try insert.sendChar('.');
    try insert.expectValue("XXabc");

    const word = try Harness.init(std.testing.allocator, "one two three");
    defer word.deinit();
    try word.sendChar('d');
    try word.sendChar('w');
    try word.expectValue("two three");
    try word.sendChar('.');
    try word.expectValue("three");

    const count = try Harness.init(std.testing.allocator, "abcdef");
    defer count.deinit();
    try count.sendChar('3');
    try count.sendChar('x');
    try count.expectValue("def");
    try count.sendChar('.');
    try count.expectValue("");

    const replace = try Harness.init(std.testing.allocator, "abc");
    defer replace.deinit();
    try replace.sendChar('r');
    try replace.sendChar('X');
    try replace.expectValue("Xbc");
    try replace.sendChar('l');
    try replace.sendChar('.');
    try replace.expectValue("XXc");
}

test "Vim: >j and visual > indent lines" {
    const motion = try Harness.init(std.testing.allocator, "one\ntwo");
    defer motion.deinit();
    try motion.sendChar('>');
    try motion.sendChar('j');
    const text = try motion.value();
    defer motion.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "    one\n    two"));

    const visual = try Harness.init(std.testing.allocator, "one\ntwo");
    defer visual.deinit();
    try visual.sendChar('V');
    try visual.sendChar('>');
    try visual.expectValue("    one\ntwo");
}

test "Vim: G goes to the last line, paragraphs and screen lines work" {
    const g = try Harness.init(std.testing.allocator, "one\ntwo\nthree");
    defer g.deinit();
    try g.sendChar('G');
    try std.testing.expectEqual(Position.init(3, 1), g.editor.modelCursorPosition());

    const paragraphs = try Harness.init(std.testing.allocator, "one\ntwo\n\nthree\nfour");
    defer paragraphs.deinit();
    try paragraphs.sendChar('}');
    try std.testing.expectEqual(@as(usize, 3), paragraphs.editor.modelCursorPosition().lineNumber);
    try paragraphs.sendChar('{');
    try std.testing.expectEqual(@as(usize, 1), paragraphs.editor.modelCursorPosition().lineNumber);

    const long_line = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz";
    const screen = try Harness.initWithWidth(std.testing.allocator, long_line, 20);
    defer screen.deinit();
    try screen.sendChar('g');
    try screen.sendChar('j');
    try std.testing.expectEqual(@as(usize, 1), screen.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(screen.editor.modelCursorPosition().column > 1);
    try screen.sendChar('g');
    try screen.sendChar('k');
    try std.testing.expectEqual(@as(usize, 1), screen.editor.modelCursorPosition().column);
}

test "Vim: v% selects the matching bracket pair" {
    const h = try Harness.init(std.testing.allocator, "(foo)");
    defer h.deinit();
    try h.sendChar('v');
    try h.sendChar('%');
    try h.sendChar('d');
    try h.expectValue("");
}

test "Vim: zz keeps the cursor in the viewport" {
    const lines = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25";
    const h = try Harness.init(std.testing.allocator, lines);
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(20, 1));
    try h.sendChar('z');
    try h.sendChar('z');
    const view = h.editor.viewPositionOfModelPosition(h.editor.modelCursorPosition()).lineNumber;
    const top = h.editor.topViewLine();
    const height = h.editor.textHeight();
    try std.testing.expect(view >= top);
    try std.testing.expect(view < top + height);
}

test "Vim: star and hash search the word under the cursor" {
    const h = try Harness.init(std.testing.allocator, "foo bar foo");
    defer h.deinit();
    try h.sendChar('*');
    try std.testing.expectEqual(@as(usize, 9), h.editor.modelCursorPosition().column);
    try h.sendChar('#');
    try std.testing.expectEqual(@as(usize, 1), h.editor.modelCursorPosition().column);
}

test "Vim: f and t work as operator motions" {
    const f = try Harness.init(std.testing.allocator, "abc def");
    defer f.deinit();
    try f.sendChar('d');
    try f.sendChar('f');
    try f.sendChar(' ');
    try f.expectValue("def");

    const t = try Harness.init(std.testing.allocator, "abc def");
    defer t.deinit();
    try t.sendChar('d');
    try t.sendChar('t');
    try t.sendChar(' ');
    try t.expectValue(" def");
}

test "Vim: local marks jump to the exact position or first non-blank" {
    const h = try Harness.init(std.testing.allocator, "one\n  two\nthree");
    defer h.deinit();
    try h.sendChar('j');
    try h.sendChar('l');
    try h.sendChar('l');
    try h.sendChar('m');
    try h.sendChar('a');
    try h.sendChar('G');
    try h.sendChar('`');
    try h.sendChar('a');
    try std.testing.expectEqual(Position.init(2, 3), h.editor.modelCursorPosition());
    try h.sendChar('G');
    try h.sendChar('\'');
    try h.sendChar('a');
    try std.testing.expectEqual(Position.init(2, 3), h.editor.modelCursorPosition());
}

test "Vim: vG extends the visual selection to the last line" {
    const h = try Harness.init(std.testing.allocator, "a\nb\nc");
    defer h.deinit();
    try h.sendChar('v');
    try h.sendChar('G');
    try h.sendChar('d');
    try h.expectValue("");
}

test "Vim: visual block I and A insert on every selected line" {
    const prefix = try Harness.init(std.testing.allocator, "ab\ncd");
    defer prefix.deinit();
    try prefix.sendCtrl('v');
    try prefix.sendChar('j');
    try prefix.sendChar('I');
    try prefix.sendText("X");
    try prefix.send(.escape);
    try prefix.expectValue("Xab\nXcd");
    try prefix.sendChar('u');
    try prefix.expectValue("ab\ncd");

    const suffix = try Harness.init(std.testing.allocator, "ab\ncd");
    defer suffix.deinit();
    try suffix.sendCtrl('v');
    try suffix.sendChar('j');
    try suffix.sendChar('A');
    try suffix.sendText("X");
    try suffix.send(.escape);
    try suffix.expectValue("aXb\ncXd");
}

test "Vim: Ctrl-O and Ctrl-I delegate to the shared history" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo\nthree");
    defer h.deinit();
    try h.sendCtrl('o');
    try h.sendCtrl('i');
    try std.testing.expectEqual(@as(usize, 1), h.history.back);
    try std.testing.expectEqual(@as(usize, 1), h.history.forward);

    try h.sendChar('G');
    try std.testing.expect(h.history.records > 0);
    const before = h.history.records;
    try h.sendChar('h');
    try std.testing.expectEqual(before, h.history.records);
}

test "Vim: macros, sentences, gJ and numeric increment" {
    const macro = try Harness.init(std.testing.allocator, "abc");
    defer macro.deinit();
    try macro.sendChar('q');
    try macro.sendChar('a');
    try macro.sendChar('x');
    try macro.sendChar('q');
    try macro.sendChar('@');
    try macro.sendChar('a');
    try macro.expectValue("c");

    const sentence = try Harness.init(std.testing.allocator, "One. Two. Three.");
    defer sentence.deinit();
    try sentence.sendChar(')');
    try std.testing.expectEqual(@as(usize, 6), sentence.editor.modelCursorPosition().column);
    try sentence.sendChar(')');
    try std.testing.expectEqual(@as(usize, 11), sentence.editor.modelCursorPosition().column);
    try sentence.sendChar('(');
    try std.testing.expectEqual(@as(usize, 6), sentence.editor.modelCursorPosition().column);

    const join = try Harness.init(std.testing.allocator, "a\nb");
    defer join.deinit();
    try join.sendChar('g');
    try join.sendChar('J');
    try join.expectValue("ab");

    const number = try Harness.init(std.testing.allocator, "x 41");
    defer number.deinit();
    try number.sendCtrl('a');
    try number.expectValue("x 42");
    try number.sendCtrl('x');
    try number.expectValue("x 41");
}

test "Vim: macro insert, count and repeat" {
    const insert = try Harness.init(std.testing.allocator, "ab");
    defer insert.deinit();
    try insert.sendChar('q');
    try insert.sendChar('a');
    try insert.sendChar('i');
    try insert.sendText("X");
    try insert.send(.escape);
    try insert.sendChar('q');
    try insert.sendChar('@');
    try insert.sendChar('a');
    try insert.expectValue("XXab");
    try insert.sendChar('@');
    try insert.sendChar('@');
    try insert.expectValue("XXXab");

    const count = try Harness.init(std.testing.allocator, "abcdef");
    defer count.deinit();
    try count.sendChar('q');
    try count.sendChar('a');
    try count.sendChar('x');
    try count.sendChar('q');
    try count.sendChar('2');
    try count.sendChar('@');
    try count.sendChar('a');
    try count.expectValue("def");
}

test "Vim: bracket text objects walk outward and span lines" {
    const nested = try Harness.init(std.testing.allocator, "f([a])");
    defer nested.deinit();
    try nested.editor.setCursorPosition(Position.init(1, 4));
    try nested.sendChar('d');
    try nested.sendChar('i');
    try nested.sendChar('(');
    try nested.expectValue("f()");

    const multiline = try Harness.init(std.testing.allocator, "f(\n  a\n)");
    defer multiline.deinit();
    try multiline.editor.setCursorPosition(Position.init(2, 3));
    try multiline.sendChar('d');
    try multiline.sendChar('i');
    try multiline.sendChar('(');
    try multiline.expectValue("f()");
}

test "Vim: percent searches the rest of the cursor line" {
    const same_line = try Harness.init(std.testing.allocator, "x (a)");
    defer same_line.deinit();
    try same_line.sendChar('%');
    try std.testing.expectEqual(@as(usize, 5), same_line.editor.modelCursorPosition().column);

    const next_line = try Harness.init(std.testing.allocator, "x\n(a)");
    defer next_line.deinit();
    try next_line.sendChar('%');
    try std.testing.expectEqual(Position.init(1, 1), next_line.editor.modelCursorPosition());
}

test "Vim: bracket and quote text objects, including b alias" {
    const paren = try Harness.init(std.testing.allocator, "f(a, (b), c)");
    defer paren.deinit();
    try paren.editor.setCursorPosition(Position.init(1, 7));
    try paren.sendChar('d');
    try paren.sendChar('i');
    try paren.sendChar('b');
    try paren.expectValue("f(a, (), c)");

    const around = try Harness.init(std.testing.allocator, "f(a, (b), c)");
    defer around.deinit();
    try around.editor.setCursorPosition(Position.init(1, 7));
    try around.sendChar('d');
    try around.sendChar('a');
    try around.sendChar('(');
    try around.expectValue("f(a, , c)");

    const square = try Harness.init(std.testing.allocator, "x = [one]");
    defer square.deinit();
    try square.editor.setCursorPosition(Position.init(1, 7));
    try square.sendChar('d');
    try square.sendChar('i');
    try square.sendChar(']');
    try square.expectValue("x = []");

    const quote = try Harness.init(std.testing.allocator, "x = \"hello\";");
    defer quote.deinit();
    try quote.editor.setCursorPosition(Position.init(1, 7));
    try quote.sendChar('d');
    try quote.sendChar('i');
    try quote.sendChar('"');
    try quote.expectValue("x = \"\";");

    const visual = try Harness.init(std.testing.allocator, "f(inner)");
    defer visual.deinit();
    try visual.editor.setCursorPosition(Position.init(1, 3));
    try visual.sendChar('v');
    try visual.sendChar('i');
    try visual.sendChar('(');
    try visual.sendChar('d');
    try visual.expectValue("f()");
}
