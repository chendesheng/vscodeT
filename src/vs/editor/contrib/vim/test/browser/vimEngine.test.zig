// Native Vim engine tests.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const extension_api = @import("../../../../../workbench/api/common/extensionApi.zig");
const builtin_host = @import("../../../../../workbench/api/browser/builtinExtensionHost.zig");
const VimEngine = @import("../../browser/vimEngine.zig").VimEngine;
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;

const Harness = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    engine: *VimEngine,
    commands: CommandState,
    window: WindowState,
    history: HistoryState,

    fn init(allocator: std.mem.Allocator, text: []const u8) !*Harness {
        return initWithWidth(allocator, text, 60);
    }

    fn initWithWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) !*Harness {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        const editor = try Editor.createFromText(allocator, io, text, "test.txt", width, 12);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .engine = undefined,
            .commands = .{},
            .window = .{},
            .history = .{},
        };
        self.engine = try VimEngine.init(
            allocator,
            builtin_host.editorInterface(editor),
            self.window.interface(),
            self.commands.interface(),
            null,
        );
        self.engine.setHistoryService(self.history.interface());
        return self;
    }

    fn deinit(self: *Harness) void {
        self.engine.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.allocator.destroy(self);
    }

    fn send(self: *Harness, key: ui.Key) !void {
        var event = ui.KeyEvent{ .key = key };
        _ = try self.engine.handleKey(&event);
    }

    fn sendChar(self: *Harness, char: u21) !void {
        try self.send(.{ .char = char });
    }

    fn sendText(self: *Harness, text: []const u8) !void {
        try self.send(.{ .text = text });
    }

    fn sendCtrl(self: *Harness, char: u21) !void {
        var event = ui.KeyEvent{ .key = .{ .char = char }, .mods = .{ .ctrl = true } };
        _ = try self.engine.handleKey(&event);
    }

    fn value(self: *Harness) ![]u8 {
        var text = try self.editor.model.getValue(.LF, false);
        defer text.deinit();
        return self.allocator.dupe(u8, text.items);
    }

    fn expectValue(self: *Harness, expected: []const u8) !void {
        const text = try self.value();
        defer self.allocator.free(text);
        try std.testing.expectEqualStrings(expected, text);
    }
};

const CommandState = struct {
    last: ?[]const u8 = null,

    fn interface(self: *CommandState) extension_api.ICommandService {
        return .{ .context = self, .register_fn = register, .execute_fn = execute };
    }
    fn register(_: *anyopaque, _: []const u8, _: []const u8, _: extension_api.CommandHandler) anyerror!extension_api.IDisposable {
        return extension_api.IDisposable.none;
    }
    fn execute(context: *anyopaque, id: []const u8) anyerror!bool {
        const self: *CommandState = @ptrCast(@alignCast(context));
        self.last = id;
        return true;
    }
};

const HistoryState = struct {
    back: usize = 0,
    forward: usize = 0,
    records: usize = 0,

    fn interface(self: *HistoryState) extension_api.IHistoryService {
        return .{
            .context = self,
            .go_back_fn = goBack,
            .go_forward_fn = goForward,
            .record_navigation_fn = record,
        };
    }
    fn goBack(context: *anyopaque) anyerror!bool {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.back += 1;
        return true;
    }
    fn goForward(context: *anyopaque) anyerror!bool {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.forward += 1;
        return true;
    }
    fn record(context: *anyopaque) void {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.records += 1;
    }
};

const WindowState = struct {
    message: ?[]const u8 = null,
    forced_close: bool = false,
    opened_path: ?[]const u8 = null,
    tab_delta: isize = 0,

    fn interface(self: *WindowState) extension_api.IWindowService {
        return .{
            .context = self,
            .create_status_entry_fn = createStatus,
            .set_message_fn = setMessage,
            .force_close_active_fn = forceClose,
            .open_path_fn = openPath,
            .switch_tab_fn = switchTab,
        };
    }
    fn createStatus(_: *anyopaque, _: []const u8, _: []const u8) anyerror!extension_api.IStatusEntry {
        return error.Unsupported;
    }
    fn setMessage(context: *anyopaque, text: []const u8) void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.message = text;
    }
    fn forceClose(context: *anyopaque) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.forced_close = true;
    }
    fn openPath(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.opened_path = path;
    }
    fn switchTab(context: *anyopaque, delta: isize) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.tab_delta = delta;
    }
};

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
