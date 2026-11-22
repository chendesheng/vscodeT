// Port of the core cases from
// `src/vs/editor/contrib/snippet/test/browser/snippetSession.test.ts`.

const std = @import("std");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const SnippetSession = @import("../../browser/snippetSession.zig").SnippetSession;
const SnippetEdit = @import("../../browser/snippetSession.zig").SnippetEdit;

fn createEditor(text: []const u8) !*Editor {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    return Editor.createFromText(allocator, io, text, "test.txt", 60, 12);
}

fn expectLine(editor: *Editor, line_number: usize, expected: []const u8) !void {
    var line = try editor.model.getLineContent(line_number);
    defer line.deinit();
    try std.testing.expectEqualStrings(expected, line.items);
}

fn expectSelections(editor: *Editor, expected: []const Selection) !void {
    const actual = try editor.getModelSelections();
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |selection, index| {
        const other = actual[index];
        try std.testing.expectEqual(selection.selectionStartLineNumber, other.selectionStartLineNumber);
        try std.testing.expectEqual(selection.selectionStartColumn, other.selectionStartColumn);
        try std.testing.expectEqual(selection.positionLineNumber, other.positionLineNumber);
        try std.testing.expectEqual(selection.positionColumn, other.positionColumn);
    }
}

test "SnippetSession: text edits and selection" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "foo${1:bar}foo$0", .{});
    defer session.deinit();
    try session.insert();

    try expectLine(editor, 1, "foobarfoofunction foo() {");
    try expectLine(editor, 2, "    foobarfooconsole.log(a);");
    try expectSelections(editor, &.{
        Selection.init(1, 4, 1, 7),
        Selection.init(2, 8, 2, 11),
    });

    try std.testing.expect(try session.next());
    try expectSelections(editor, &.{
        Selection.init(1, 10, 1, 10),
        Selection.init(2, 14, 2, 14),
    });
}

test "SnippetSession: just text" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "foobar", .{});
    defer session.deinit();
    try session.insert();

    try expectLine(editor, 1, "foobarfunction foo() {");
    try expectLine(editor, 2, "    foobarconsole.log(a);");
    try expectSelections(editor, &.{
        Selection.init(1, 7, 1, 7),
        Selection.init(2, 11, 2, 11),
    });
}

test "SnippetSession: repeated tabstops are selected together" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "file=${TM_FILENAME} ${1:name} ${1:name}", .{});
    defer session.deinit();
    try session.insert();

    const selections = try editor.getModelSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections.len);

    try editor.insertText("value");
    var text = try editor.model.getValue(.TextDefined, false);
    defer text.deinit();
    try std.testing.expectEqualStrings("file=test.txt value value", text.items);
}

test "SnippetSession: selections next and prev" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "f$1oo${2:bar}foo$0", .{});
    defer session.deinit();
    try session.insert();

    try expectSelections(editor, &.{
        Selection.init(1, 2, 1, 2),
        Selection.init(2, 6, 2, 6),
    });
    try std.testing.expect(try session.next());
    try expectSelections(editor, &.{
        Selection.init(1, 4, 1, 7),
        Selection.init(2, 8, 2, 11),
    });
    try std.testing.expect(try session.prev());
    try expectSelections(editor, &.{
        Selection.init(1, 2, 1, 2),
        Selection.init(2, 6, 2, 6),
    });
    try std.testing.expect(try session.next());
    try std.testing.expect(try session.next());
    try expectSelections(editor, &.{
        Selection.init(1, 10, 1, 10),
        Selection.init(2, 14, 2, 14),
    });
}

test "SnippetSession: typing advances placeholders" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "f${1:oo}_$2_$0", .{});
    defer session.deinit();
    try session.insert();

    try editor.insertText("X");
    try std.testing.expect(try session.next());
    try editor.insertText("bar");
    try std.testing.expect(try session.prev());
    try expectSelections(editor, &.{
        Selection.init(1, 2, 1, 3),
        Selection.init(2, 6, 2, 7),
    });
    try std.testing.expect(try session.next());
    try expectSelections(editor, &.{
        Selection.init(1, 4, 1, 7),
        Selection.init(2, 8, 2, 11),
    });
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "fX_bar_function foo() {");
    try expectSelections(editor, &.{
        Selection.init(1, 8, 1, 8),
        Selection.init(2, 12, 2, 12),
    });
}

test "SnippetSession: shorter and longer snippet into selection" {
    const allocator = std.testing.allocator;
    {
        const editor = try createEditor("foo_bar_foo");
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try editor.setSelections(&.{
            Selection.init(1, 1, 1, 4),
            Selection.init(1, 9, 1, 12),
        });
        const session = try SnippetSession.init(allocator, editor, "x$0", .{});
        defer session.deinit();
        try session.insert();
        try expectLine(editor, 1, "x_bar_x");
        try expectSelections(editor, &.{
            Selection.init(1, 2, 1, 2),
            Selection.init(1, 8, 1, 8),
        });
    }
    {
        const editor = try createEditor("foo_bar_foo");
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try editor.setSelections(&.{
            Selection.init(1, 1, 1, 4),
            Selection.init(1, 9, 1, 12),
        });
        const session = try SnippetSession.init(allocator, editor, "LONGER$0", .{});
        defer session.deinit();
        try session.insert();
        try expectLine(editor, 1, "LONGER_bar_LONGER");
        try expectSelections(editor, &.{
            Selection.init(1, 7, 1, 7),
            Selection.init(1, 18, 1, 18),
        });
    }
}

test "SnippetSession: does not grow final tabstop" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("foo_zzz_foo");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelection(Range.init(1, 5, 1, 8));

    const session = try SnippetSession.init(allocator, editor, "$1bar$0", .{});
    defer session.deinit();
    try session.insert();
    try expectSelections(editor, &.{Selection.init(1, 5, 1, 5)});
    try editor.insertText("foo-");
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "foo_foo-bar_foo");
    try expectSelections(editor, &.{Selection.init(1, 12, 1, 12)});
    try editor.insertText("XXX");
    try expectLine(editor, 1, "foo_foo-barXXX_foo");
    try std.testing.expect(try session.prev());
    try expectSelections(editor, &.{Selection.init(1, 5, 1, 9)});
    try std.testing.expect(try session.next());
    // Upstream keeps the final tabstop collapsed after the typed text.
    try expectSelections(editor, &.{Selection.init(1, 15, 1, 15)});
}

test "SnippetSession: touching tabstops stay separate" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "$1$2$3$0", .{});
    defer session.deinit();
    try session.insert();
    try editor.insertText("111");
    try std.testing.expect(try session.next());
    try editor.insertText("222");
    try std.testing.expect(try session.next());
    try editor.insertText("333");
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "111222333function foo() {");
    try expectSelections(editor, &.{
        Selection.init(1, 10, 1, 10),
        Selection.init(2, 14, 2, 14),
    });
    try std.testing.expect(try session.prev());
    try expectSelections(editor, &.{
        Selection.init(1, 7, 1, 10),
        Selection.init(2, 11, 2, 14),
    });
}

test "SnippetSession: whitespace normalization" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "foo\n\t${1:bar}\n$0", .{});
    defer session.deinit();
    try session.insert();
    try expectLine(editor, 1, "foo");
    try expectLine(editor, 2, "    bar");
    try expectLine(editor, 3, "function foo() {");
    try expectLine(editor, 5, "        bar");
}

test "SnippetSession: no whitespace adjust" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelection(Range.init(2, 5, 2, 5));

    const session = try SnippetSession.init(allocator, editor, "abc\n    foo\n        bar\n$0", .{
        .adjust_whitespace = false,
    });
    defer session.deinit();
    try session.insert();
    try expectLine(editor, 2, "    abc");
    try expectLine(editor, 3, "    foo");
    try expectLine(editor, 4, "        bar");
    try expectLine(editor, 5, "console.log(a);");
}

test "SnippetSession: merge nested snippet" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "This ${1:is ${2:nested}}.$0", .{});
    defer session.deinit();
    try session.insert();
    try std.testing.expect(try session.next());
    try expectSelections(editor, &.{Selection.init(1, 9, 1, 15)});

    try session.merge("really ${1:nested}$0", .{});
    try expectLine(editor, 1, "This is really nested.");
    try expectSelections(editor, &.{Selection.init(1, 16, 1, 22)});
    try std.testing.expect(try session.next());
    try std.testing.expect(!session.isAtLastPlaceholder());
    try std.testing.expect(try session.next());
    try std.testing.expect(session.isAtLastPlaceholder());
}

test "SnippetSession: merge preserves mirrors in nested snippet" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "(${1:x})", .{});
    defer session.deinit();
    try session.insert();
    try session.merge("${1:y}-${1}", .{});

    try expectLine(editor, 1, "(y-y)");
    const selections = try editor.getModelSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections.len);
}

test "SnippetSession: deep merge keeps a single cursor" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "\\sin\\left(${1:x}\\right) ", .{});
    defer session.deinit();
    try session.insert();
    for (0..25) |_| {
        try session.merge("\\sin\\left(${1:x}\\right) ", .{});
        const selections = try editor.getModelSelections();
        defer allocator.free(selections);
        try std.testing.expectEqual(@as(usize, 1), selections.len);
    }
}

test "SnippetSession: transform runs when leaving placeholder" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "${1/foo/bar/}$0", .{});
    defer session.deinit();
    try session.insert();
    try editor.insertText("foo");
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "bar");
    try expectSelections(editor, &.{Selection.init(1, 4, 1, 4)});
}

test "SnippetSession: transform with if branch and capitalization" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const session = try SnippetSession.init(allocator, editor, "${1/(.*)/${1:/upcase}/}$0", .{});
    defer session.deinit();
    try session.insert();
    try editor.insertText("foo");
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "FOO");
}

test "SnippetSession: selection within placeholders" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("function foo() {\n    console.log(a);\n}\n");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&.{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 5, 2, 5),
    });

    const session = try SnippetSession.init(allocator, editor, "${1:foo}farboo${2:bar}$0", .{});
    defer session.deinit();
    try session.insert();
    try std.testing.expect(try session.isSelectionWithinPlaceholders());

    try editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try std.testing.expect(!try session.isSelectionWithinPlaceholders());

    try editor.setSelections(&.{
        Selection.init(1, 6, 1, 6),
        Selection.init(2, 10, 2, 10),
    });
    try std.testing.expect(!try session.isSelectionWithinPlaceholders());

    try std.testing.expect(try session.next());
    try std.testing.expect(try session.isSelectionWithinPlaceholders());
}

test "SnippetSession: per-edit line variables" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("a\nb\nc");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const edits = [_]SnippetEdit{
        .{ .range = Range.init(1, 2, 1, 2), .template = "$TM_LINE_NUMBER" },
        .{ .range = Range.init(3, 2, 3, 2), .template = "$TM_LINE_NUMBER" },
    };
    const session = try SnippetSession.initWithEdits(allocator, editor, &edits, .{});
    defer session.deinit();
    try session.insert();

    try expectLine(editor, 1, "a1");
    try expectLine(editor, 3, "c3");
}

test "SnippetSession: per-edit selection variable" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("aaa\nbbb\nccc");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const edits = [_]SnippetEdit{
        .{ .range = Range.init(2, 1, 2, 4), .template = "[$TM_SELECTED_TEXT]" },
        .{ .range = Range.init(3, 1, 3, 4), .template = "[$TM_SELECTED_TEXT]" },
    };
    const session = try SnippetSession.initWithEdits(allocator, editor, &edits, .{});
    defer session.deinit();
    try session.insert();

    try expectLine(editor, 2, "[bbb]");
    try expectLine(editor, 3, "[ccc]");
}

test "SnippetSession: edits with placeholders" {
    const allocator = std.testing.allocator;
    const editor = try createEditor("foo(\"bar\")");
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const edits = [_]SnippetEdit{
        .{ .range = Range.init(1, 1, 1, 1), .template = "const ${1:new_const} = \"bar\"" },
        .{ .range = Range.init(1, 5, 1, 9), .template = "$1" },
    };
    const session = try SnippetSession.initWithEdits(allocator, editor, &edits, .{});
    defer session.deinit();
    try session.insert();
    try expectLine(editor, 1, "const new_const = \"bar\"foo(new_const\")");
    try std.testing.expect(try session.next());
    try expectLine(editor, 1, "const new_const = \"bar\"foo(new_const\")");
}
