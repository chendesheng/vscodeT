// Port of `src/vs/editor/contrib/snippet/test/browser/snippetController2.test.ts`.
// Fixtures start with the upstream model.setValue text, when specified,
// because the terminal test harness creates its model from a buffer.
const std = @import("std");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Controller = @import("../../browser/snippetController2.zig").SnippetController2;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const Range = @import("../../../../common/core/range.zig").Range;
const SnippetEdit = @import("../../browser/snippetSession.zig").SnippetEdit;
const a = std.testing.allocator;

const Fixture = struct {
    editor: *Editor,
    ctrl: *Controller,

    fn init(text: []const u8, setup_selections: bool) !Fixture {
        const editor = try Editor.createFromText(a, std.testing.io, text, "test.txt", 80, 24);
        errdefer {
            editor.deinit();
            a.destroy(editor);
        }
        editor.model.updateOptions(.{ .insertSpaces = true, .tabSize = 4, .indentSize = .{ .number = 4 }, .trimAutoWhitespace = true, .bracketColorizationOptions = null });
        if (setup_selections) try editor.setSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(2, 5, 2, 5) });
        return .{ .editor = editor, .ctrl = try Controller.getOrCreate(editor) };
    }

    fn deinit(self: Fixture) void {
        self.editor.deinit();
        a.destroy(self.editor);
    }

    fn expectState(self: Fixture, in_snippet: bool, prev: bool, next: bool) !void {
        try std.testing.expectEqual(in_snippet, self.ctrl.state.in_snippet_mode);
        try std.testing.expectEqual(prev, self.ctrl.state.has_prev_tabstop);
        try std.testing.expectEqual(next, self.ctrl.state.has_next_tabstop);
        try std.testing.expectEqual(self.ctrl.state, self.editor.snippet_state);
    }

    fn expectSelections(self: Fixture, expected: []const Selection) !void {
        const actual = try self.editor.getModelSelections();
        defer a.free(actual);
        try std.testing.expectEqualSlices(Selection, expected, actual);
    }

    fn expectText(self: Fixture, expected: []const u8) !void {
        var value = try self.editor.model.getValue(null, false);
        defer value.deinit();
        try std.testing.expectEqualStrings(expected, value.items);
    }
};

test "SnippetController2: creation" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, insert -> abort" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("foo${1:bar}foo$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(2, 8, 2, 11) });
    f.ctrl.cancel(false);
    try f.expectState(false, false, false);
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(2, 8, 2, 11) });
}

test "SnippetController2: insert, insert -> tab, tab, done" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("${1:one}${2:two}$0", .{});
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectState(true, true, true);
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.editor.insertText("\t");
    try std.testing.expectEqual(false, f.ctrl.state.in_snippet_mode);
    try std.testing.expectEqual(false, f.ctrl.state.has_next_tabstop);
    try std.testing.expectEqual(false, f.ctrl.state.has_prev_tabstop);
}

test "SnippetController2: insert, insert -> cursor moves out (left/right)" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("foo${1:bar}foo$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(2, 8, 2, 11) });
    try f.editor.setSelections(&.{ Selection.init(1, 12, 1, 12), Selection.init(2, 16, 2, 16) });
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, insert -> cursor moves out (up/down)" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("foo${1:bar}foo$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(2, 8, 2, 11) });
    try f.editor.setSelections(&.{ Selection.init(2, 4, 2, 7), Selection.init(3, 8, 3, 11) });
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, insert -> cursors collapse" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("foo${1:bar}foo$0", .{});
    try std.testing.expectEqual(true, f.ctrl.state.in_snippet_mode);
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(2, 8, 2, 11) });
    try f.editor.setSelections(&.{Selection.init(1, 4, 1, 7)});
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, insert plain text -> no snippet mode" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("foobar", .{});
    try f.expectState(false, false, false);
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
}

test "SnippetController2: insert, delete snippet text" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("${1:foobar}$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 7), Selection.init(2, 5, 2, 11) });
    try f.editor.deleteLeft();
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(2, 5, 2, 5) });
    try f.editor.insertText("abc");
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.editor.insertTab();
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, nested trivial snippet" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("${1:foo}bar$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 4), Selection.init(2, 5, 2, 8) });
    try f.ctrl.insert("FOO$0", .{});
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 4), Selection.init(2, 8, 2, 8) });
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, nested snippet" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("${1:foobar}$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 7), Selection.init(2, 5, 2, 11) });
    try f.ctrl.insert("far$1boo$0", .{});
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 4), Selection.init(2, 8, 2, 8) });
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
    try f.expectState(true, true, true);
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
    try f.expectState(false, false, false);
}

test "SnippetController2: insert, nested plain text" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("${1:foobar}$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 7), Selection.init(2, 5, 2, 11) });
    try f.ctrl.insert("farboo", .{});
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 11, 2, 11) });
    try f.expectState(false, false, false);
}

test "SnippetController2: Nested snippets without final placeholder jumps to next outer placeholder, #27898" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("for(const ${1:element} of ${2:array}) {$0}", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 11, 1, 18), Selection.init(2, 15, 2, 22) });
    _ = try f.ctrl.next();
    try f.expectState(true, true, true);
    try f.expectSelections(&.{ Selection.init(1, 22, 1, 27), Selection.init(2, 26, 2, 31) });
    try f.ctrl.insert("document", .{});
    try f.expectState(true, true, true);
    try f.expectSelections(&.{ Selection.init(1, 30, 1, 30), Selection.init(2, 34, 2, 34) });
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
}

test "SnippetController2: Inconsistent tab stop behaviour with recursive snippets and tab / shift tab, #27543" {
    const f = try Fixture.init("if\n    $state\nfi", true);
    defer f.deinit();
    try f.ctrl.insert("1_calize(${1:nl}, '${2:value}')$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 10, 1, 12), Selection.init(2, 14, 2, 16) });
    try f.ctrl.insert("2_calize(${1:nl}, '${2:value}')$0", .{});
    try f.expectSelections(&.{ Selection.init(1, 19, 1, 21), Selection.init(2, 23, 2, 25) });
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 24, 1, 29), Selection.init(2, 28, 2, 33) });
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 31, 1, 31), Selection.init(2, 35, 2, 35) });
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 34, 1, 39), Selection.init(2, 38, 2, 43) });
    _ = try f.ctrl.previous();
    try f.expectSelections(&.{ Selection.init(1, 31, 1, 31), Selection.init(2, 35, 2, 35) });
}

test "SnippetController2: Snippet tabstop selecting content of previously entered variable only works when separated by space, #23728" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("import ${2:${1:module}} from '${1:module}'$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 8, 1, 14), Selection.init(1, 21, 1, 27) });
    try f.ctrl.insert("foo", .{});
    try f.expectSelections(&.{ Selection.init(1, 11, 1, 11), Selection.init(1, 21, 1, 21) });
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 8, 1, 11)});
}

test "SnippetController2: HTML Snippets Combine, #32211" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    f.editor.model.updateOptions(.{ .insertSpaces = false, .tabSize = 4, .trimAutoWhitespace = false, .indentSize = null, .bracketColorizationOptions = null });
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("\n\t\t\t<!DOCTYPE html>\n\t\t\t<html lang=\"en\">\n\t\t\t<head>\n\t\t\t\t<meta charset=\"UTF-8\">\n\t\t\t\t<meta name=\"viewport\" content=\"width=${2:device-width}, initial-scale=${3:1.0}\">\n\t\t\t\t<meta http-equiv=\"X-UA-Compatible\" content=\"${5:ie=edge}\">\n\t\t\t\t<title>${7:Document}</title>\n\t\t\t</head>\n\t\t\t<body>\n\t\t\t\t${8}\n\t\t\t</body>\n\t\t\t</html>\n\t\t", .{});
    _ = try f.ctrl.next();
    _ = try f.ctrl.next();
    _ = try f.ctrl.next();
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(11, 5, 11, 5)});
    try f.ctrl.insert("<input type=\"${2:text}\">", .{});
    try f.expectSelections(&.{Selection.init(11, 18, 11, 22)});
}

test "SnippetController2: Problems with nested snippet insertion #39594" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("$1 = ConvertTo-Json $1", .{});
    try f.expectSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(1, 19, 1, 19) });
    try f.editor.setSelections(&.{Selection.init(1, 19, 1, 19)});
    try f.expectState(false, false, false);
}

test "SnippetController2: Problems with nested snippet insertion #39594 (part2)" {
    const f = try Fixture.init("a-\naaa-", false);
    defer f.deinit();
    try f.editor.setSelections(&.{ Selection.init(2, 5, 2, 5), Selection.init(1, 3, 1, 3) });
    try f.ctrl.insert("log($1);$0", .{});
    try f.expectSelections(&.{ Selection.init(2, 9, 2, 9), Selection.init(1, 7, 1, 7) });
    try f.expectState(true, false, true);
}

test "SnippetController2: “Nested” snippets terminating abruptly in VSCode 1.19.2. #42012" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("var ${2:${1:name}} = ${1:name} + 1;${0}", .{});
    try f.expectSelections(&.{ Selection.init(1, 5, 1, 9), Selection.init(1, 12, 1, 16) });
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectState(true, true, true);
}

test "SnippetController2: Placeholders order #58267" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("\\pth{$1}$0", .{});
    try f.expectSelections(&.{Selection.init(1, 6, 1, 6)});
    try f.expectState(true, false, true);
    try f.ctrl.insert("\\itv{${1:left}}{${2:right}}{${3:left_value}}{${4:right_value}}$0", .{});
    try f.expectSelections(&.{Selection.init(1, 11, 1, 15)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 17, 1, 22)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 24, 1, 34)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 36, 1, 47)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 48, 1, 48)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 49, 1, 49)});
    try f.expectState(false, false, false);
}

test "SnippetController2: Must tab through deleted tab stops in snippets #31619" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("foo${1:a${2:bar}baz}end$0", .{});
    try f.expectSelections(&.{Selection.init(1, 4, 1, 11)});
    try f.editor.deleteLeft();
    try f.expectSelections(&.{Selection.init(1, 4, 1, 4)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(1, 7, 1, 7)});
    try f.expectState(false, false, false);
}

test "SnippetController2: Cancelling snippet mode should discard added cursors #68512 (soft cancel)" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert(".REGION ${2:FUNCTION_NAME}\nCREATE.FUNCTION ${1:VOID} ${2:FUNCTION_NAME}(${3:})\n\t${4:}\nEND\n.ENDREGION$0", .{});
    try f.expectSelections(&.{Selection.init(2, 17, 2, 21)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 9, 1, 22), Selection.init(2, 22, 2, 35) });
    try f.expectState(true, true, true);
    try f.editor.setSelections(&.{ Selection.init(1, 22, 1, 22), Selection.init(2, 35, 2, 35) });
    try f.expectState(true, true, true);
    try f.editor.setSelections(&.{ Selection.init(2, 1, 2, 1), Selection.init(2, 36, 2, 36) });
    try f.expectState(false, false, false);
    try f.expectSelections(&.{ Selection.init(2, 1, 2, 1), Selection.init(2, 36, 2, 36) });
}

test "SnippetController2: Cancelling snippet mode should discard added cursors #68512 (hard cancel)" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert(".REGION ${2:FUNCTION_NAME}\nCREATE.FUNCTION ${1:VOID} ${2:FUNCTION_NAME}(${3:})\n\t${4:}\nEND\n.ENDREGION$0", .{});
    try f.expectSelections(&.{Selection.init(2, 17, 2, 21)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{ Selection.init(1, 9, 1, 22), Selection.init(2, 22, 2, 35) });
    try f.expectState(true, true, true);
    try f.editor.setSelections(&.{ Selection.init(1, 22, 1, 22), Selection.init(2, 35, 2, 35) });
    try f.expectState(true, true, true);
    f.ctrl.cancel(true);
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(1, 22, 1, 22)});
}

test "SnippetController2: User defined snippet tab stops ignored #72862" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("export default $1", .{});
    try f.expectState(true, false, true);
}

test "SnippetController2: Optional tabstop in snippets #72358" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.insert("${1:prop: {$2\\},}\nmore$0", .{});
    try f.expectState(true, false, true);
    try f.expectSelections(&.{Selection.init(1, 1, 1, 10)});
    try f.editor.deleteLeft();
    try f.expectSelections(&.{Selection.init(1, 1, 1, 1)});
    _ = try f.ctrl.next();
    try f.expectSelections(&.{Selection.init(2, 5, 2, 5)});
    try f.expectState(false, false, false);
}

test "SnippetController2: issue #90135: confusing trim whitespace edits" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.insertTab();
    try f.ctrl.insert("\nfoo", .{});
    try f.expectSelections(&.{Selection.init(2, 8, 2, 8)});
}

test "SnippetController2: issue #145727: insertSnippet can put snippet selections in wrong positions (1 of 2)" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.insertTab();
    try f.ctrl.insert("\naProperty: aClass<${2:boolean}> = new aClass<${2:boolean}>();\n", .{ .adjust_whitespace = false });
    try f.expectSelections(&.{ Selection.init(2, 19, 2, 26), Selection.init(2, 41, 2, 48) });
}

test "SnippetController2: issue #145727: insertSnippet can put snippet selections in wrong positions (2 of 2)" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.insertTab();
    try f.ctrl.insert("\naProperty: aClass<${2:boolean}> = new aClass<${2:boolean}>();\n", .{});
    try f.expectSelections(&.{ Selection.init(2, 23, 2, 30), Selection.init(2, 45, 2, 52) });
}

test "SnippetController2: leading TAB by snippets won't replace by spaces #101870" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    f.editor.model.updateOptions(.{ .insertSpaces = true, .tabSize = 4, .trimAutoWhitespace = null, .indentSize = null, .bracketColorizationOptions = null });
    try f.ctrl.insert("\tHello World\n\tNew Line", .{});
    try f.expectText("    Hello World\n    New Line");
}

test "SnippetController2: leading TAB by snippets won't replace by spaces #101870 (part 2)" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    f.editor.model.updateOptions(.{ .insertSpaces = true, .tabSize = 4, .trimAutoWhitespace = null, .indentSize = null, .bracketColorizationOptions = null });
    try f.ctrl.insert("\tHello World\n\tNew Line\n${1:\tmore}", .{});
    try f.expectText("    Hello World\n    New Line\n    more");
}

test "SnippetController2: apply, tab, done" {
    const f = try Fixture.init("foo(\"bar\")", false);
    defer f.deinit();
    try f.ctrl.apply(&.{ .{ .range = Range.init(1, 5, 1, 10), .template = "$1" }, .{ .range = Range.init(1, 1, 1, 1), .template = "const ${1:new_const} = \"bar\";\n" } }, .{});
    try f.expectText("const new_const = \"bar\";\nfoo(new_const)");
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 16), Selection.init(2, 5, 2, 14) });
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(2, 14, 2, 14)});
}

test "SnippetController2: apply, tab, done with special final tabstop" {
    const f = try Fixture.init("foo(\"bar\")", false);
    defer f.deinit();
    try f.ctrl.apply(&.{ .{ .range = Range.init(1, 5, 1, 10), .template = "$1" }, .{ .range = Range.init(1, 1, 1, 1), .template = "const ${1:new_const}$0 = \"bar\";\n" } }, .{});
    try f.expectText("const new_const = \"bar\";\nfoo(new_const)");
    try f.expectState(true, false, true);
    try f.expectSelections(&.{ Selection.init(1, 7, 1, 16), Selection.init(2, 5, 2, 14) });
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(1, 16, 1, 16)});
}

test "SnippetController2: apply, tab, tab, done" {
    const f = try Fixture.init("foo\nbar", false);
    defer f.deinit();
    try f.ctrl.apply(&.{ .{ .range = Range.init(1, 4, 1, 4), .template = "${3}" }, .{ .range = Range.init(2, 4, 2, 4), .template = "$3" }, .{ .range = Range.init(1, 1, 1, 1), .template = "### ${2:Header}\n" } }, .{});
    try f.expectText("### Header\nfoo\nbar");
    try f.expectState(true, false, true);
    try f.expectSelections(&.{Selection.init(1, 5, 1, 11)});
    _ = try f.ctrl.next();
    try f.expectState(true, true, true);
    try f.expectSelections(&.{ Selection.init(2, 4, 2, 4), Selection.init(3, 4, 3, 4) });
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(3, 4, 3, 4)});
}

test "SnippetController2: nested into apply works" {
    const f = try Fixture.init("onetwo", false);
    defer f.deinit();
    try f.editor.setSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(2, 1, 2, 1) });
    try f.ctrl.apply(&.{.{ .range = Range.init(1, 7, 1, 7), .template = "$0${1:three}" }}, .{});
    try f.expectText("onetwothree");
    try f.expectState(true, false, true);
    try f.expectSelections(&.{Selection.init(1, 7, 1, 12)});
    try f.ctrl.insert("foo$1bar$1", .{});
    try f.expectText("onetwofoobar");
    try f.expectSelections(&.{ Selection.init(1, 10, 1, 10), Selection.init(1, 13, 1, 13) });
    try f.expectState(true, false, true);
    _ = try f.ctrl.next();
    try f.expectState(true, true, true);
    try f.expectSelections(&.{Selection.init(1, 13, 1, 13)});
    _ = try f.ctrl.next();
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(1, 7, 1, 7)});
}

test "SnippetController2: nested into insert abort \"outer\" snippet" {
    const f = try Fixture.init("one\ntwo", false);
    defer f.deinit();
    try f.editor.setSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(2, 1, 2, 1) });
    try f.ctrl.insert("foo${1:bar}bazz${1:bang}", .{});
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(1, 11, 1, 14), Selection.init(2, 4, 2, 7), Selection.init(2, 11, 2, 14) });
    try f.expectState(true, false, true);
    try f.ctrl.apply(&.{.{ .range = Range.init(1, 4, 1, 7), .template = "$0A" }}, .{});
    try f.expectText("fooAbazzbarone\nfoobarbazzbartwo");
    try f.expectState(false, false, false);
    try f.expectSelections(&.{Selection.init(1, 4, 1, 4)});
}

test "SnippetController2: nested into \"insert\" abort \"outer\" snippet (2)" {
    const f = try Fixture.init("one\ntwo", false);
    defer f.deinit();
    try f.editor.setSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(2, 1, 2, 1) });
    try f.ctrl.insert("foo${1:bar}bazz${1:bang}", .{});
    try f.expectSelections(&.{ Selection.init(1, 4, 1, 7), Selection.init(1, 11, 1, 14), Selection.init(2, 4, 2, 7), Selection.init(2, 11, 2, 14) });
    try f.expectState(true, false, true);
    const edits = [_]SnippetEdit{ .{ .range = Range.init(1, 4, 1, 7), .template = "A" }, .{ .range = Range.init(1, 11, 1, 14), .template = "B" }, .{ .range = Range.init(2, 4, 2, 7), .template = "C" }, .{ .range = Range.init(2, 11, 2, 14), .template = "D" } };
    try f.ctrl.apply(&edits, .{});
    try f.expectText("fooAbazzBone\nfooCbazzDtwo");
    try f.expectState(false, false, false);
    try f.expectSelections(&.{ Selection.init(1, 5, 1, 5), Selection.init(1, 10, 1, 10), Selection.init(2, 5, 2, 5), Selection.init(2, 10, 2, 10) });
}

test "SnippetController2: Bug: cursor position $0 with user snippets #163808" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.ctrl.insert("<Element1 Attr1=\"foo\" $1>\n  <Element2 Attr1=\"$2\"/>\n$0\"\n</Element1>", .{});
    try f.expectSelections(&.{Selection.init(1, 23, 1, 23)});
    try f.ctrl.insert("Qualifier=\"$0\"", .{});
    try f.expectText("<Element1 Attr1=\"foo\" Qualifier=\"\">\n  <Element2 Attr1=\"\"/>\n\"\n</Element1>");
    try f.expectSelections(&.{Selection.init(1, 34, 1, 34)});
}

test "SnippetController2: EOL-Sequence (CRLF) shifts tab stop in isFileTemplate snippets #167386" {
    const f = try Fixture.init("", false);
    defer f.deinit();
    try f.editor.model.setEOL(.CRLF);
    try f.ctrl.apply(&.{.{ .range = f.editor.model.getFullModelRange(), .template = "line 54321${1:FOO}\nline 54321${1:FOO}\n(no tab stop)\nline 54321${1:FOO}\nline 54321" }}, .{});
    try f.expectSelections(&.{ Selection.init(1, 11, 1, 14), Selection.init(2, 11, 2, 14), Selection.init(4, 11, 4, 14) });
}

test "SnippetController2: \"Surround With\" code action snippets use incorrect indentation levels and styles #169319" {
    const f = try Fixture.init("function foo(f, x, condition) {\n    f();\n    return x;\n}", false);
    defer f.deinit();
    const sel = Range.init(2, 5, 3, 14);
    try f.editor.setSelection(sel);
    try f.ctrl.apply(&.{.{ .range = sel, .template = "if (${1:condition}) {\n\t$TM_SELECTED_TEXT$0\n}" }}, .{});
    try f.expectText("function foo(f, x, condition) {\n    if (condition) {\n        f();\n        return x;\n    }\n}");
}

test "SnippetController2: $TM_SELECTED_TEXT resolves per edit, not the last selection (multi-cursor wrap snippet) #206121" {
    const f = try Fixture.init("aaa\nbbb\nccc", false);
    defer f.deinit();
    try f.editor.setSelections(&.{ Selection.init(1, 1, 1, 4), Selection.init(2, 1, 2, 4), Selection.init(3, 1, 3, 4) });
    try f.ctrl.apply(&.{ .{ .range = Range.init(1, 1, 1, 4), .template = "if(${1:cond}) {$TM_SELECTED_TEXT}$0" }, .{ .range = Range.init(2, 1, 2, 4), .template = "if(${1:cond}) {$TM_SELECTED_TEXT}$0" }, .{ .range = Range.init(3, 1, 3, 4), .template = "if(${1:cond}) {$TM_SELECTED_TEXT}$0" } }, .{});
    try f.expectText("if(cond) {aaa}\nif(cond) {bbb}\nif(cond) {ccc}");
}

test "SnippetController2: apply with multiple cursors threads $CURSOR_NUMBER per edit" {
    const f = try Fixture.init("aa\nbb\ncc", false);
    defer f.deinit();
    try f.ctrl.apply(&.{
        .{ .range = Range.init(1, 3, 1, 3), .template = ":$CURSOR_NUMBER" },
        .{ .range = Range.init(2, 3, 2, 3), .template = ":$CURSOR_NUMBER" },
        .{ .range = Range.init(3, 3, 3, 3), .template = ":$CURSOR_NUMBER" },
    }, .{});
    try f.expectText("aa:1\nbb:2\ncc:3");
}

test "SnippetController2: undo restores original selection after apply (regression for #170041)" {
    const f = try Fixture.init("Some text and more text", false);
    defer f.deinit();
    try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
    try f.ctrl.apply(&.{.{ .range = Range.init(1, 6, 1, 10), .template = "${0:hi}" }}, .{});
    try f.expectText("Some hi and more text");
    try f.editor.undo();
    try f.expectText("Some text and more text");
    try f.expectSelections(&.{Selection.init(1, 1, 1, 1)});
}

test "SnippetController2: Snippet transformation does not work after inserting variable using intellisense, #112362" {
    // Upstream marks this regression test skipped. Keep its assertions so
    // enabling that case later does not require reconstructing the fixture.
    const skipped_upstream = true;
    if (skipped_upstream) return error.SkipZigTest;
    {
        const f = try Fixture.init("", false);
        defer f.deinit();
        try f.ctrl.insert("$1\n\n${1/([A-Za-z0-9]+): ([A-Za-z]+).*/$1: '$2',/gm}", .{});
        try f.expectSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(3, 1, 3, 1) });
        try f.editor.insertText("foo: number;");
        _ = try f.ctrl.next();
        try f.expectText("foo: number;\n\nfoo: 'number',");
    }
    {
        const f = try Fixture.init("", false);
        defer f.deinit();
        try f.ctrl.insert("$1\n\n${1/([A-Za-z0-9]+): ([A-Za-z]+).*/$1: '$2',/gm}", .{});
        try f.expectSelections(&.{ Selection.init(1, 1, 1, 1), Selection.init(3, 1, 3, 1) });
        try f.editor.insertText("foo: ");
        try f.ctrl.insert("number;", .{});
        _ = try f.ctrl.next();
        try f.expectText("foo: number;\n\nfoo: 'number',");
    }
}
