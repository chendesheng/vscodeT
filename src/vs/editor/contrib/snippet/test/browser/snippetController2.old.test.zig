// Port of `src/vs/editor/contrib/snippet/test/browser/snippetController2.old.test.ts`.
const std = @import("std");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Controller = @import("../../browser/snippetController2.zig").SnippetController2;
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const a = std.testing.allocator;

const Fixture = struct {
    editor: *Editor,
    ctrl: *Controller,

    fn init(text: []const u8) !Fixture {
        const editor = try Editor.createFromText(a, std.testing.io, text, "test.txt", 80, 24);
        errdefer {
            editor.deinit();
            a.destroy(editor);
        }
        editor.model.updateOptions(.{ .insertSpaces = false, .tabSize = 4, .indentSize = .{ .number = 4 }, .trimAutoWhitespace = true, .bracketColorizationOptions = null });
        return .{ .editor = editor, .ctrl = try Controller.getOrCreate(editor) };
    }

    fn deinit(self: Fixture) void {
        self.editor.deinit();
        a.destroy(self.editor);
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

    fn expectLine(self: Fixture, line: usize, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, try self.editor.model.borrowLineContent(line));
    }
};

test "SnippetController2: old: Simple accepted" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.expectLine(4, "\tfor (var index; index < array.length; index++) {");
        try f.expectLine(5, "\t\tvar element = array[index];");
        try f.expectLine(6, "\t\t");
        try f.expectLine(7, "\t}");
        try f.editor.insertText("i");
        try f.expectLine(4, "\tfor (var i; i < array.length; i++) {");
        try f.expectLine(5, "\t\tvar element = array[i];");
        try f.expectLine(6, "\t\t");
        try f.expectLine(7, "\t}");
        _ = try f.ctrl.next();
        try f.editor.insertText("arr");
        try f.expectLine(4, "\tfor (var i; i < arr.length; i++) {");
        try f.expectLine(5, "\t\tvar element = arr[i];");
        try f.expectLine(6, "\t\t");
        try f.expectLine(7, "\t}");
        _ = try f.ctrl.previous();
        try f.editor.insertText("j");
        try f.expectLine(4, "\tfor (var j; j < arr.length; j++) {");
        try f.expectLine(5, "\t\tvar element = arr[j];");
        try f.expectLine(6, "\t\t");
        try f.expectLine(7, "\t}");
        _ = try f.ctrl.next();
        _ = try f.ctrl.next();
        try std.testing.expectEqual(Position.init(6, 3), f.editor.modelCursorPosition());
    }
}

test "SnippetController2: old: Simple canceled" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.expectLine(4, "\tfor (var index; index < array.length; index++) {");
        try f.expectLine(5, "\t\tvar element = array[index];");
        try f.expectLine(6, "\t\t");
        try f.expectLine(7, "\t}");
        f.ctrl.cancel(false);
        try std.testing.expectEqual(Position.init(4, 16), f.editor.modelCursorPosition());
    }
}

test "SnippetController2: old: Stops when calling model.setValue()" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.editor.replaceGeneratedContents("goodbye", true);
        try std.testing.expect(!f.ctrl.isInSnippet());
    }
}

test "SnippetController2: old: Stops when undoing" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.editor.model.undo();
        try std.testing.expect(!f.ctrl.isInSnippet());
    }
}

test "SnippetController2: old: Stops when moving cursor outside" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.editor.setCursorPosition(Position.init(1, 1));
        try std.testing.expect(!f.ctrl.isInSnippet());
    }
}

test "SnippetController2: old: Stops when disconnecting editor model" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        try f.editor.setModel(null);
        try std.testing.expect(!f.ctrl.isInSnippet());
    }
}

test "SnippetController2: old: Stops when disposing editor" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        try f.editor.setCursorPosition(Position.init(4, 2));
        try f.ctrl.insert("for (var ${1:index}; $1 < ${2:array}.length; $1++) {\n\tvar element = $2[$1];\n\t$0\n}", .{});
        const Probe = struct {
            cleared: bool = false,
            fn changed(state: @import("../../browser/snippetController2.zig").SnippetState, self: *@This()) !void {
                self.cleared = !state.in_snippet_mode;
            }
        };
        var probe: Probe = .{};
        _ = try f.editor.on_did_change_snippet_state.listen(&probe, Probe.changed);
        f.editor.deinit();
        a.destroy(f.editor);
        try std.testing.expect(probe.cleared);
    }
}

test "SnippetController2: old: Final tabstop with multiple selections" {
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 1, 1, 1),
            Selection.init(2, 1, 2, 1),
        });
        try f.ctrl.insert("foo$0", .{});
        try f.expectSelections(&.{ Selection.init(1, 4, 1, 4), Selection.init(2, 4, 2, 4) });
    }
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 1, 1, 1),
            Selection.init(2, 1, 2, 1),
        });
        try f.ctrl.insert("foo$0bar", .{});
        try f.expectSelections(&.{ Selection.init(1, 4, 1, 4), Selection.init(2, 4, 2, 4) });
    }
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 1, 1, 1),
            Selection.init(1, 5, 1, 5),
        });
        try f.ctrl.insert("foo$0bar", .{});
        try f.expectSelections(&.{ Selection.init(1, 4, 1, 4), Selection.init(1, 14, 1, 14) });
    }
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 1, 1, 1),
            Selection.init(1, 5, 1, 5),
        });
        try f.ctrl.insert("foo\n$0\nbar", .{});
        try f.expectSelections(&.{ Selection.init(2, 1, 2, 1), Selection.init(4, 1, 4, 1) });
    }
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 1, 1, 1),
            Selection.init(1, 5, 1, 5),
        });
        try f.ctrl.insert("foo\n$0\nbar", .{});
        try f.expectSelections(&.{ Selection.init(2, 1, 2, 1), Selection.init(4, 1, 4, 1) });
    }
    {
        const f = try Fixture.init("function test() {\n\tvar x = 3;\n\tvar arr = [];\n\t\n}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(2, 7, 2, 7),
        });
        try f.ctrl.insert("xo$0r", .{ .overwrite_before = 1 });
        try f.expectSelections(&.{Selection.init(2, 8, 2, 8)});
    }
}

test "SnippetController2: old: Final tabstop, #11742 simple" {
    {
        const f = try Fixture.init("example example sc");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 19, 1, 19)});
        try f.ctrl.insert("{{% url_**$1** %}}", .{ .overwrite_before = 2 });
        try f.expectText("example example {{% url_**** %}}");
        try f.expectSelections(&.{Selection.init(1, 27, 1, 27)});
    }
    {
        const f = try Fixture.init("af");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 3, 1, 3)});
        try f.ctrl.insert("afterEach((done) => {\n\t${1}test\n});", .{ .overwrite_before = 2 });
        try f.expectText("afterEach((done) => {\n\ttest\n});");
        try f.expectSelections(&.{Selection.init(2, 2, 2, 2)});
    }
    {
        const f = try Fixture.init("af");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 3, 1, 3)});
        try f.ctrl.insert("afterEach((done) => {\n${1}\ttest\n});", .{ .overwrite_before = 2 });
        try f.expectText("afterEach((done) => {\n\ttest\n});");
        try f.expectSelections(&.{Selection.init(2, 1, 2, 1)});
    }
    {
        const f = try Fixture.init("afterone");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 9, 1, 9)});
        try f.ctrl.insert("aft${1}er", .{ .overwrite_before = 8 });
        try f.expectText("after");
        try f.expectSelections(&.{Selection.init(1, 4, 1, 4)});
    }
}

test "SnippetController2: old: Final tabstop, #11742 different indents" {
    {
        const f = try Fixture.init("af\n\taf");
        defer f.deinit();
        try f.editor.setSelections(&.{ Selection.init(2, 4, 2, 4), Selection.init(1, 3, 1, 3) });
        try f.ctrl.insert("afterEach((done) => {\n\t${0}test\n});", .{ .overwrite_before = 2 });
        try f.expectSelections(&.{ Selection.init(5, 3, 5, 3), Selection.init(2, 2, 2, 2) });
    }
}

test "SnippetController2: old: Final tabstop, #11890 stay at the beginning" {
    {
        const f = try Fixture.init("  af");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 5, 1, 5)});
        try f.ctrl.insert("afterEach((done) => {\n${1}\ttest\n});", .{ .overwrite_before = 2 });
        try f.expectSelections(&.{Selection.init(2, 3, 2, 3)});
    }
}

test "SnippetController2: old: Final tabstop, no tabstop" {
    {
        const f = try Fixture.init("af\n\taf");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 3, 1, 3)});
        try f.ctrl.insert("afterEach", .{ .overwrite_before = 2 });
        try f.expectSelections(&.{Selection.init(1, 10, 1, 10)});
    }
}

test "SnippetController2: old: Multiple cursor and overwriteBefore/After, issue #11060" {
    {
        const f = try Fixture.init("this._\nabc");
        defer f.deinit();
        try f.editor.setSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 4, 2, 4) });
        try f.ctrl.insert("_foo", .{ .overwrite_before = 1 });
        try f.expectText("this._foo\nabc_foo");
    }
    {
        const f = try Fixture.init("this._\nabc");
        defer f.deinit();
        try f.editor.setSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 4, 2, 4) });
        try f.ctrl.insert("XX", .{ .overwrite_before = 1 });
        try f.expectText("this.XX\nabcXX");
    }
    {
        const f = try Fixture.init("this._\nabc\ndef_");
        defer f.deinit();
        try f.editor.setSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 4, 2, 4), Selection.init(3, 5, 3, 5) });
        try f.ctrl.insert("_foo", .{ .overwrite_before = 1 });
        try f.expectText("this._foo\nabc_foo\ndef_foo");
    }
    {
        const f = try Fixture.init("this._\nabc\ndef._");
        defer f.deinit();
        try f.editor.setSelections(&.{ Selection.init(1, 7, 1, 7), Selection.init(2, 4, 2, 4), Selection.init(3, 6, 3, 6) });
        try f.ctrl.insert("._foo", .{ .overwrite_before = 2 });
        try f.expectText("this._foo\nabc._foo\ndef._foo");
    }
    {
        const f = try Fixture.init("this._\nabc\ndef._");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(3, 6, 3, 6),
            Selection.init(1, 7, 1, 7),
            Selection.init(2, 4, 2, 4),
        });
        try f.ctrl.insert("._foo", .{ .overwrite_before = 2 });
        try f.expectText("this._foo\nabc._foo\ndef._foo");
    }
    {
        const f = try Fixture.init("this._\nabc\ndef._");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(2, 4, 2, 4),
            Selection.init(3, 6, 3, 6),
            Selection.init(1, 7, 1, 7),
        });
        try f.ctrl.insert("._foo", .{ .overwrite_before = 2 });
        try f.expectText("this._._foo\na._foo\ndef._._foo");
    }
}

test "SnippetController2: old: Multiple cursor and overwriteBefore/After, #16277" {
    {
        const f = try Fixture.init("{foo}\n{foo && true}");
        defer f.deinit();
        try f.editor.setSelections(&.{
            Selection.init(1, 5, 1, 5),
            Selection.init(2, 5, 2, 5),
        });
        try f.ctrl.insert("document", .{ .overwrite_before = 3 });
        try f.expectText("{document}\n{document && true}");
    }
}

test "SnippetController2: old: Insert snippet twice, #19449" {
    {
        const f = try Fixture.init("for (var i=0; i<len; i++) {  }");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
        try f.ctrl.insert("for (var ${1:i}=0; ${1:i}<len; ${1:i}++) { $0 }", .{});
        try f.expectText("for (var i=0; i<len; i++) {  }for (var i=0; i<len; i++) {  }");
    }
    {
        const f = try Fixture.init("for (var i=0; i<len; i++) {  }");
        defer f.deinit();
        try f.editor.setSelections(&.{Selection.init(1, 1, 1, 1)});
        try f.ctrl.insert("for (let ${1:i}=0; ${1:i}<len; ${1:i}++) { $0 }", .{});
        try f.expectText("for (let i=0; i<len; i++) {  }for (var i=0; i<len; i++) {  }");
    }
}
