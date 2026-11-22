// Native Helix engine tests.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const extension_api = @import("../../../../../workbench/api/common/extensionApi.zig");
const builtin_host = @import("../../../../../workbench/api/browser/builtinExtensionHost.zig");
const HelixEngine = @import("../../browser/helixEngine.zig").HelixEngine;
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;

const Harness = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    engine: *HelixEngine,
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
        self.engine = try HelixEngine.init(
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

    fn sendAlt(self: *Harness, char: u21) !void {
        var event = ui.KeyEvent{ .key = .{ .char = char }, .mods = .{ .alt = true } };
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

    fn cursor(self: *Harness) Position {
        return self.editor.modelCursorPosition();
    }

    fn selectionCount(self: *Harness) !usize {
        const selections = try self.editor.getSelections();
        defer self.allocator.free(selections);
        return selections.len;
    }

    fn firstSelection(self: *Harness) !Selection {
        const selections = try self.editor.getSelections();
        defer self.allocator.free(selections);
        return selections[0];
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

test "Helix: insert, escape, undo and redo" {
    const h = try Harness.init(std.testing.allocator, "hello");
    defer h.deinit();

    try h.sendChar('i');
    try h.sendText("abc");
    try h.send(.escape);
    try h.expectValue("abchello");

    try h.sendChar('u');
    try h.expectValue("hello");

    try h.sendChar('U');
    try h.expectValue("abchello");
}

test "Helix: bare cursor d deletes one character" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar('d');
    try h.expectValue("bc");
    try h.sendChar('u');
    try h.expectValue("abc");
}

test "Helix: w selects a word and d deletes it" {
    const h = try Harness.init(std.testing.allocator, "hello world");
    defer h.deinit();

    try h.sendChar('w');
    try h.sendChar('d');
    try h.expectValue("world");

    try h.sendChar('u');
    try h.expectValue("hello world");
}

test "Helix: x selects a line and d deletes it" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();

    try h.sendChar('x');
    try h.sendChar('d');
    try h.expectValue("two");

    try h.sendChar('u');
    try h.expectValue("one\ntwo");
}

test "Helix: select mode extends the selection" {
    const h = try Harness.init(std.testing.allocator, "hello");
    defer h.deinit();

    try h.sendChar('v');
    try h.sendChar('l');
    try h.sendChar('l');
    try h.sendChar('d');
    try h.expectValue("llo");
}

test "Helix: percent selects the whole file" {
    const h = try Harness.init(std.testing.allocator, "abc\ndef");
    defer h.deinit();

    try h.sendChar('%');
    try h.sendChar('d');
    try h.expectValue("");
    try h.sendChar('u');
    try h.expectValue("abc\ndef");
}

test "Helix: c changes the selection in one undo group" {
    const h = try Harness.init(std.testing.allocator, "hello world");
    defer h.deinit();

    try h.sendChar('w');
    try h.sendChar('c');
    try h.sendText("X");
    try h.send(.escape);
    try h.expectValue("Xworld");

    try h.sendChar('u');
    try h.expectValue("hello world");
}

test "Helix: y and p use the unnamed register" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar('y');
    try h.sendChar('l');
    try h.sendChar('p');
    try h.expectValue("abac");
}

test "Helix: named registers" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar('"');
    try h.sendChar('a');
    try h.sendChar('y');
    try h.sendChar('l');
    try h.sendChar('"');
    try h.sendChar('a');
    try h.sendChar('p');
    try h.expectValue("abac");
}

test "Helix: multi-selection regex change and keep primary" {
    const h = try Harness.init(std.testing.allocator, "foo bar foo");
    defer h.deinit();

    try h.sendChar('%');
    try h.sendChar('s');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 2), try h.selectionCount());

    try h.sendChar('c');
    try h.sendText("X");
    try h.send(.escape);
    try h.expectValue("X bar X");
    try std.testing.expectEqual(@as(usize, 2), try h.selectionCount());

    try h.sendChar(',');
    try std.testing.expectEqual(@as(usize, 1), try h.selectionCount());
}

test "Helix: search and n/N move through matches" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();

    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 1), (try h.firstSelection()).startColumn);

    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 5), (try h.firstSelection()).startColumn);
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 9), (try h.firstSelection()).startColumn);
    try h.sendChar('N');
    try std.testing.expectEqual(@as(usize, 5), (try h.firstSelection()).startColumn);
}

test "Helix: command line save and switch buffer" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar(':');
    try h.sendText("w");
    try h.send(.enter);
    try std.testing.expectEqualStrings("workbench.action.files.save", h.commands.last.?);

    try h.sendChar(':');
    try h.sendText("bn");
    try h.send(.enter);
    try std.testing.expectEqual(@as(isize, 1), h.window.tab_delta);
}

test "Helix: x y p yanks and pastes a line" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();

    try h.sendChar('x');
    try h.sendChar('y');
    try h.sendChar('p');
    try h.expectValue("one\none\ntwo");

    try h.sendChar('u');
    try h.expectValue("one\ntwo");
}

test "Helix: Q records and q replays a macro" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar('Q');
    try h.sendChar('d');
    try h.sendChar('Q');
    try h.expectValue("bc");

    try h.sendChar('q');
    try h.expectValue("c");
}

test "Helix: dot repeats the last insertion" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();

    try h.sendChar('i');
    try h.sendText("X");
    try h.send(.escape);
    try h.expectValue("Xabc");

    try h.sendChar('.');
    try h.expectValue("XXabc");
}

test "Helix: j follows visual lines and gj follows logical lines" {
    const long = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\nsecond";
    const h = try Harness.initWithWidth(std.testing.allocator, long, 20);
    defer h.deinit();

    try h.sendChar('j');
    try std.testing.expectEqual(@as(usize, 1), h.cursor().lineNumber);
    try std.testing.expect(h.cursor().column > 1);

    try h.sendChar('g');
    try h.sendChar('j');
    try std.testing.expectEqual(@as(usize, 2), h.cursor().lineNumber);
}

test "Helix: f and t search across lines" {
    const f = try Harness.init(std.testing.allocator, "a\nb\nc");
    defer f.deinit();
    try f.sendChar('f');
    try f.sendChar('c');
    try f.sendChar('d');
    try f.expectValue("");

    const t = try Harness.init(std.testing.allocator, "a\nb\nc");
    defer t.deinit();
    try t.sendChar('t');
    try t.sendChar('c');
    try t.sendChar('d');
    try t.expectValue("c");
}

test "Helix: X extends to line bounds and Alt-x excludes the break" {
    const x = try Harness.init(std.testing.allocator, "one\ntwo");
    defer x.deinit();
    try x.sendChar('X');
    try x.sendChar('d');
    try x.expectValue("two");

    const alt = try Harness.init(std.testing.allocator, "one\ntwo");
    defer alt.deinit();
    try alt.sendAlt('x');
    try alt.sendChar('d');
    try alt.expectValue("\ntwo");
}

test "Helix: Ctrl-c dispatches the comment command" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendCtrl('c');
    try std.testing.expectEqualStrings("editor.action.commentLine", h.commands.last.?);
    try h.expectValue("abc");
}

test "Helix: goto definition dispatches the editor command" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('g');
    try h.sendChar('d');
    try std.testing.expectEqualStrings("editor.action.revealDefinition", h.commands.last.?);
}

test "Helix: gv restores the last selection" {
    const h = try Harness.init(std.testing.allocator, "one two");
    defer h.deinit();
    try h.sendChar('w');
    try h.sendChar('d');
    try h.sendChar('u');
    try h.sendChar('g');
    try h.sendChar('v');
    try h.sendChar('d');
    try h.expectValue("two");
}

test "Helix: count multiplies motions" {
    const h = try Harness.init(std.testing.allocator, "one two three four");
    defer h.deinit();
    try h.sendChar('2');
    try h.sendChar('w');
    try h.sendChar('d');
    try h.expectValue("three four");
}

test "Helix: macro registers and absolute/relative line motions" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo\nthree");
    defer h.deinit();
    try h.sendChar('2');
    try h.sendChar('G');
    try std.testing.expectEqual(@as(usize, 2), h.cursor().lineNumber);
    try h.sendChar('g');
    try h.sendChar('e');
    try std.testing.expectEqual(@as(usize, 3), h.cursor().lineNumber);
    try h.sendChar('g');
    try h.sendChar('h');
    try std.testing.expectEqual(@as(usize, 1), h.cursor().column);
}

test "Helix: insert variants a, I, A, o and O" {
    const a = try Harness.init(std.testing.allocator, "abc");
    defer a.deinit();
    try a.sendChar('a');
    try a.sendText("X");
    try a.send(.escape);
    try a.expectValue("aXbc");

    const line_start = try Harness.init(std.testing.allocator, "  abc");
    defer line_start.deinit();
    try line_start.editor.setCursorPosition(Position.init(1, 4));
    try line_start.sendChar('I');
    try line_start.sendText("X");
    try line_start.send(.escape);
    try line_start.expectValue("  Xabc");

    const line_end = try Harness.init(std.testing.allocator, "abc");
    defer line_end.deinit();
    try line_end.sendChar('A');
    try line_end.sendText("X");
    try line_end.send(.escape);
    try line_end.expectValue("abcX");

    const below = try Harness.init(std.testing.allocator, "abc");
    defer below.deinit();
    try below.sendChar('o');
    try below.sendText("X");
    try below.send(.escape);
    try below.expectValue("abc\nX");

    const above = try Harness.init(std.testing.allocator, "abc");
    defer above.deinit();
    try above.sendChar('O');
    try above.sendText("X");
    try above.send(.escape);
    try above.expectValue("X\nabc");
}

test "Helix: b, e and W select word ranges" {
    const b = try Harness.init(std.testing.allocator, "hello world");
    defer b.deinit();
    try b.editor.setCursorPosition(Position.init(1, 7));
    try b.sendChar('b');
    try b.sendChar('d');
    try b.expectValue("world");

    const e = try Harness.init(std.testing.allocator, "hello world");
    defer e.deinit();
    try e.sendChar('e');
    try e.sendChar('d');
    try e.expectValue(" world");

    const big = try Harness.init(std.testing.allocator, "a  b  c");
    defer big.deinit();
    try big.sendChar('W');
    try big.sendChar('d');
    try big.expectValue("b  c");
}

test "Helix: F, T and Alt-. search backwards and repeat" {
    const f = try Harness.init(std.testing.allocator, "a.b.c");
    defer f.deinit();
    try f.editor.setCursorPosition(Position.init(1, 5));
    try f.sendChar('F');
    try f.sendChar('.');
    try f.sendChar('d');
    try f.expectValue("a.bc");

    const t = try Harness.init(std.testing.allocator, "a.b.c");
    defer t.deinit();
    try t.editor.setCursorPosition(Position.init(1, 5));
    try t.sendChar('T');
    try t.sendChar('.');
    try t.sendChar('d');
    try t.expectValue("a.b.");

    const repeat = try Harness.init(std.testing.allocator, "a.b.c");
    defer repeat.deinit();
    try repeat.sendChar('f');
    try repeat.sendChar('.');
    try std.testing.expectEqual(@as(usize, 3), (try repeat.firstSelection()).endColumn);
    try repeat.sendAlt('.');
    try std.testing.expectEqual(@as(usize, 5), (try repeat.firstSelection()).endColumn);
}

test "Helix: gh, gl and gs go to line boundaries" {
    const h = try Harness.init(std.testing.allocator, "  abc");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 4));
    try h.sendChar('g');
    try h.sendChar('h');
    try std.testing.expectEqual(@as(usize, 1), h.cursor().column);
    try h.sendChar('g');
    try h.sendChar('l');
    try std.testing.expectEqual(@as(usize, 6), h.cursor().column);
    try h.sendChar('g');
    try h.sendChar('s');
    try std.testing.expectEqual(@as(usize, 3), h.cursor().column);
}

test "Helix: P, R and r edit through registers and chars" {
    const p = try Harness.init(std.testing.allocator, "abc");
    defer p.deinit();
    try p.sendChar('y');
    try p.sendChar('l');
    try p.sendChar('P');
    try p.expectValue("aabc");

    const replace = try Harness.init(std.testing.allocator, "abc");
    defer replace.deinit();
    try replace.sendChar('y');
    try replace.sendChar('l');
    try replace.sendChar('R');
    try replace.expectValue("aac");

    const r = try Harness.init(std.testing.allocator, "abc");
    defer r.deinit();
    try r.sendChar('r');
    try r.sendChar('X');
    try r.expectValue("Xbc");
}

test "Helix: case changes and indentation" {
    const toggle = try Harness.init(std.testing.allocator, "abc");
    defer toggle.deinit();
    try toggle.sendChar('%');
    try toggle.sendChar('~');
    try toggle.expectValue("ABC");

    const lower = try Harness.init(std.testing.allocator, "ABC");
    defer lower.deinit();
    try lower.sendChar('%');
    try lower.sendChar('`');
    try lower.expectValue("abc");

    const upper = try Harness.init(std.testing.allocator, "abc");
    defer upper.deinit();
    try upper.sendChar('%');
    try upper.sendAlt('`');
    try upper.expectValue("ABC");

    const indent = try Harness.init(std.testing.allocator, "one\ntwo");
    defer indent.deinit();
    try indent.sendChar('x');
    try indent.sendChar('>');
    const indented = try indent.value();
    defer indent.allocator.free(indented);
    try std.testing.expect(std.mem.startsWith(u8, indented, "    one\ntwo"));
}

test "Helix: J and Alt-J join lines" {
    const join = try Harness.init(std.testing.allocator, "one\ntwo");
    defer join.deinit();
    try join.sendChar('J');
    try join.expectValue("one two");

    const select = try Harness.init(std.testing.allocator, "one\ntwo");
    defer select.deinit();
    try select.sendChar('x');
    try select.sendAlt('J');
    try select.expectValue("one two");
    const selection = try select.firstSelection();
    try std.testing.expectEqual(@as(usize, 4), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 5), selection.endColumn);
}

test "Helix: Ctrl-a and Ctrl-x increment numbers" {
    const h = try Harness.init(std.testing.allocator, "x 41");
    defer h.deinit();
    try h.sendCtrl('a');
    try h.expectValue("x 42");
    try h.sendCtrl('x');
    try h.expectValue("x 41");
}

test "Helix: S splits selections on a regex" {
    const h = try Harness.init(std.testing.allocator, "a,b,c");
    defer h.deinit();
    try h.sendChar('%');
    try h.sendChar('S');
    try h.sendText(",");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 3), try h.selectionCount());
    try h.sendChar('c');
    try h.sendText("X");
    try h.send(.escape);
    try h.expectValue("X,X,X");
}

test "Helix: Alt-s splits a selection on newlines" {
    const h = try Harness.init(std.testing.allocator, "a\nb\nc");
    defer h.deinit();
    try h.sendChar('%');
    try h.sendAlt('s');
    try std.testing.expectEqual(@as(usize, 3), try h.selectionCount());
    try h.sendChar('c');
    try h.sendText("X");
    try h.send(.escape);
    try h.expectValue("X\nX\nX");
}

test "Helix: C copies a line down" {
    const h = try Harness.init(std.testing.allocator, "abc\ndef");
    defer h.deinit();
    try h.sendChar('x');
    try h.sendChar('C');
    try h.expectValue("abc\nabc\ndef");
}

test "Helix: rotation, merge and trim selections" {
    const rotate = try Harness.init(std.testing.allocator, "foo bar foo");
    defer rotate.deinit();
    try rotate.sendChar('%');
    try rotate.sendChar('s');
    try rotate.sendText("foo");
    try rotate.send(.enter);
    try rotate.sendChar(')');
    try std.testing.expectEqual(@as(usize, 9), (try rotate.firstSelection()).startColumn);
    try rotate.sendChar('(');
    try std.testing.expectEqual(@as(usize, 1), (try rotate.firstSelection()).startColumn);

    const merge = try Harness.init(std.testing.allocator, "a b");
    defer merge.deinit();
    try merge.sendChar('%');
    try merge.sendChar('s');
    try merge.sendText("a|b");
    try merge.send(.enter);
    try std.testing.expectEqual(@as(usize, 2), try merge.selectionCount());
    try merge.sendAlt('-');
    try std.testing.expectEqual(@as(usize, 1), try merge.selectionCount());

    const trim = try Harness.init(std.testing.allocator, "  abc  \ndef");
    defer trim.deinit();
    try trim.sendChar('x');
    try trim.sendChar('_');
    try trim.expectValue("abc\ndef");
}

test "Helix: W and linewise yank registers" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo");
    defer h.deinit();
    try h.sendChar('X');
    try h.sendChar('y');
    try h.sendChar('j');
    try h.sendChar('P');
    try h.expectValue("one\none\ntwo");
}

test "Helix: star sets a word-boundary search" {
    const h = try Harness.init(std.testing.allocator, "foo bar foo");
    defer h.deinit();
    try h.sendChar('*');
    try std.testing.expectEqualStrings("\\bfoo\\b", h.engine.last_search.items);
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 9), (try h.firstSelection()).startColumn);
}

test "Helix: command line escape, quit, edit and reload" {
    const escape = try Harness.init(std.testing.allocator, "abc");
    defer escape.deinit();
    try escape.sendChar(':');
    try escape.sendText("q");
    try escape.send(.escape);
    try escape.sendChar('x');
    try escape.sendChar('d');
    const escaped = try escape.value();
    defer escape.allocator.free(escaped);
    try std.testing.expectEqual(@as(usize, 0), escaped.len);

    const quit = try Harness.init(std.testing.allocator, "abc");
    defer quit.deinit();
    try quit.sendChar(':');
    try quit.sendText("q!");
    try quit.send(.enter);
    try std.testing.expect(quit.window.forced_close);

    const edit = try Harness.init(std.testing.allocator, "abc");
    defer edit.deinit();
    try edit.sendChar(':');
    try edit.sendText("e other.txt");
    try edit.send(.enter);
    try std.testing.expectEqualStrings("other.txt", edit.window.opened_path.?);

    const reload = try Harness.init(std.testing.allocator, "abc");
    defer reload.deinit();
    try reload.sendChar(':');
    try reload.sendText("reload");
    try reload.send(.enter);
    try std.testing.expectEqualStrings("workbench.action.files.revert", reload.commands.last.?);

    const unknown = try Harness.init(std.testing.allocator, "abc");
    defer unknown.deinit();
    try unknown.sendChar(':');
    try unknown.sendText("nonsense");
    try unknown.send(.enter);
    try std.testing.expectEqualStrings("Helix: unsupported command", unknown.window.message.?);
}

test "Helix: mm matches brackets and surround works" {
    const match = try Harness.init(std.testing.allocator, "(a)");
    defer match.deinit();
    try match.sendChar('m');
    try match.sendChar('m');
    try std.testing.expectEqual(@as(usize, 3), match.cursor().column);

    const add = try Harness.init(std.testing.allocator, "abc");
    defer add.deinit();
    try add.sendChar('%');
    try add.sendChar('m');
    try add.sendChar('s');
    try add.sendChar('(');
    try add.expectValue("(abc)");
    try add.sendChar('m');
    try add.sendChar('d');
    try add.sendChar('(');
    try add.expectValue("abc");

    const replace = try Harness.init(std.testing.allocator, "(abc)");
    defer replace.deinit();
    try replace.editor.setCursorPosition(Position.init(1, 2));
    try replace.sendChar('v');
    try replace.sendChar('l');
    try replace.sendChar('l');
    try replace.sendChar('l');
    try replace.sendChar('m');
    try replace.sendChar('r');
    try replace.sendChar('(');
    try replace.sendChar('[');
    try replace.expectValue("[abc]");
}

test "Helix: view, window and space modes dispatch commands" {
    const view = try Harness.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer view.deinit();
    try view.editor.setCursorPosition(Position.init(3, 1));
    try view.sendChar('z');
    try view.sendChar('c');
    try std.testing.expect(view.editor.topViewLine() >= 1);

    const window = try Harness.init(std.testing.allocator, "abc");
    defer window.deinit();
    try window.sendCtrl('w');
    try window.sendChar('v');
    try std.testing.expectEqualStrings("workbench.action.splitEditorOrthogonal", window.commands.last.?);

    const space = try Harness.init(std.testing.allocator, "abc");
    defer space.deinit();
    try space.sendChar(' ');
    try space.sendChar('?');
    try std.testing.expectEqualStrings("workbench.action.showCommands", space.commands.last.?);
}

test "Helix: collapse, flip and forward selection" {
    const h = try Harness.init(std.testing.allocator, "%abc");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 1));
    try h.sendChar('%');
    try h.sendAlt(';');
    var selection = try h.firstSelection();
    try std.testing.expectEqual(Position.init(1, 1), selection.getPosition());
    try h.sendAlt(';');
    selection = try h.firstSelection();
    try std.testing.expectEqual(Position.init(1, 5), selection.getPosition());
    try h.sendAlt(':');
    selection = try h.firstSelection();
    try std.testing.expectEqual(Position.init(1, 1), selection.getSelectionStart());
    try h.sendChar(';');
    try std.testing.expectEqual(@as(usize, 1), try h.selectionCount());
}

test "Helix: counts and UTF-8 movement" {
    const count = try Harness.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer count.deinit();
    try count.sendChar('3');
    try count.sendChar('x');
    try count.sendChar('d');
    try count.expectValue("four");

    const utf8 = try Harness.init(std.testing.allocator, "a\u{00e9}bc");
    defer utf8.deinit();
    try utf8.sendChar('l');
    try std.testing.expectEqual(@as(usize, 2), utf8.cursor().column);
    try utf8.sendChar('l');
    try std.testing.expectEqual(@as(usize, 4), utf8.cursor().column);
    try utf8.sendChar('d');
    try utf8.expectValue("a\u{00e9}c");
}

test "Helix: dot with a count repeats the insertion" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('i');
    try h.sendText("X");
    try h.send(.escape);
    try h.sendChar('2');
    try h.sendChar('.');
    try h.expectValue("XXXabc");
}

test "Helix: prompt append, backspace and Ctrl-u" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar(':');
    try h.sendText("wn");
    try h.send(.backspace);
    try h.sendCtrl('u');
    try h.sendText("w");
    try h.send(.enter);
    try std.testing.expectEqualStrings("workbench.action.files.save", h.commands.last.?);
}

test "Helix: insert Ctrl-w, Ctrl-u and Ctrl-k delete text" {
    const word = try Harness.init(std.testing.allocator, "one two");
    defer word.deinit();
    try word.sendChar('A');
    try word.sendCtrl('w');
    try word.expectValue("one ");
    try word.sendCtrl('u');
    try word.expectValue("");
    try word.send(.escape);

    const end = try Harness.init(std.testing.allocator, "abc");
    defer end.deinit();
    try end.sendChar('i');
    try end.sendCtrl('k');
    try end.expectValue("");
    try end.send(.escape);
}

test "Helix: Ctrl-o, Ctrl-i and Ctrl-s use the history service" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendCtrl('o');
    try h.sendCtrl('i');
    try h.sendCtrl('s');
    try std.testing.expectEqual(@as(usize, 1), h.history.back);
    try std.testing.expectEqual(@as(usize, 1), h.history.forward);
    try std.testing.expectEqual(@as(usize, 1), h.history.records);
}

test "Helix: Alt-* sets a raw regex search" {
    const h = try Harness.init(std.testing.allocator, "foo");
    defer h.deinit();
    try h.sendChar('%');
    try h.sendAlt('*');
    try std.testing.expectEqualStrings("foo", h.engine.last_search.items);
}

test "Helix: noh clears the search" {
    const h = try Harness.init(std.testing.allocator, "foo foo");
    defer h.deinit();
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try h.sendChar(':');
    try h.sendText("noh");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 0), h.engine.last_search.items.len);
    try h.sendChar('n');
}

test "Helix: set ignorecase affects search" {
    const h = try Harness.init(std.testing.allocator, "Foo foo");
    defer h.deinit();
    try h.sendChar(':');
    try h.sendText("set ignorecase");
    try h.send(.enter);
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 1), (try h.firstSelection()).startColumn);

    try h.sendChar(':');
    try h.sendText("noh");
    try h.send(.enter);
    try h.sendChar(':');
    try h.sendText("set noignorecase");
    try h.send(.enter);
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try std.testing.expectEqual(@as(usize, 5), (try h.firstSelection()).startColumn);
}

test "Helix: Alt-, removes the primary selection and Alt-_ merges consecutive" {
    const remove = try Harness.init(std.testing.allocator, "a b");
    defer remove.deinit();
    try remove.sendChar('%');
    try remove.sendChar('s');
    try remove.sendText("a|b");
    try remove.send(.enter);
    try remove.sendAlt(',');
    try std.testing.expectEqual(@as(usize, 1), try remove.selectionCount());
    try std.testing.expectEqual(@as(usize, 3), (try remove.firstSelection()).startColumn);

    const merge = try Harness.init(std.testing.allocator, "ab");
    defer merge.deinit();
    try merge.sendChar('%');
    try merge.sendChar('s');
    try merge.sendText("a|b");
    try merge.send(.enter);
    try std.testing.expectEqual(@as(usize, 2), try merge.selectionCount());
    try merge.sendAlt('_');
    try std.testing.expectEqual(@as(usize, 1), try merge.selectionCount());
}

test "Helix: command line buffer and window commands" {
    const wq = try Harness.init(std.testing.allocator, "abc");
    defer wq.deinit();
    try wq.sendChar(':');
    try wq.sendText("wq");
    try wq.send(.enter);
    try std.testing.expectEqualStrings("workbench.action.closeActiveEditor", wq.commands.last.?);

    const split = try Harness.init(std.testing.allocator, "abc");
    defer split.deinit();
    try split.sendCtrl('w');
    try split.sendChar('q');
    try std.testing.expectEqualStrings("workbench.action.closeActiveEditor", split.commands.last.?);

    const comment = try Harness.init(std.testing.allocator, "abc");
    defer comment.deinit();
    try comment.sendChar(' ');
    try comment.sendChar('c');
    try std.testing.expectEqualStrings("editor.action.commentLine", comment.commands.last.?);
}

test "Helix: line motions g j/k and page motions keep the cursor visible" {
    const h = try Harness.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer h.deinit();
    try h.sendChar('g');
    try h.sendChar('e');
    try std.testing.expectEqual(@as(usize, 4), h.cursor().lineNumber);
    try h.sendChar('g');
    try h.sendChar('k');
    try std.testing.expectEqual(@as(usize, 3), h.cursor().lineNumber);
    try h.sendCtrl('u');
    try h.sendCtrl('d');
    try std.testing.expect(h.cursor().lineNumber >= 1);
}

test "Helix: n in select mode adds search matches" {
    const h = try Harness.init(std.testing.allocator, "foo foo foo");
    defer h.deinit();
    try h.sendChar('/');
    try h.sendText("foo");
    try h.send(.enter);
    try h.sendChar('v');
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 2), try h.selectionCount());
    try h.sendChar('n');
    try std.testing.expectEqual(@as(usize, 3), try h.selectionCount());
}

test "Helix: Shift-Tab inserts a tab in insert mode" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('i');
    try h.send(.backtab);
    try h.send(.escape);
    try h.expectValue("\tabc");
}

test "Helix: Alt-* keeps the selection as a raw regex" {
    const h = try Harness.init(std.testing.allocator, "a.c");
    defer h.deinit();
    try h.sendChar('%');
    try h.sendAlt('*');
    try std.testing.expectEqualStrings("a.c", h.engine.last_search.items);
}

test "Helix: miw and maw select inside and around a word" {
    const inside = try Harness.init(std.testing.allocator, "hello world");
    defer inside.deinit();
    try inside.editor.setCursorPosition(Position.init(1, 2));
    try inside.sendChar('m');
    try inside.sendChar('i');
    try inside.sendChar('w');
    try inside.sendChar('d');
    try inside.expectValue(" world");

    const around = try Harness.init(std.testing.allocator, "hello world");
    defer around.deinit();
    try around.editor.setCursorPosition(Position.init(1, 2));
    try around.sendChar('m');
    try around.sendChar('a');
    try around.sendChar('w');
    try around.sendChar('d');
    try around.expectValue("world");
}

test "Helix: mi( and ma( select inside and around brackets" {
    const inside = try Harness.init(std.testing.allocator, "f(abc)");
    defer inside.deinit();
    try inside.editor.setCursorPosition(Position.init(1, 3));
    try inside.sendChar('m');
    try inside.sendChar('i');
    try inside.sendChar('(');
    try inside.sendChar('d');
    try inside.expectValue("f()");

    const around = try Harness.init(std.testing.allocator, "f(abc)");
    defer around.deinit();
    try around.editor.setCursorPosition(Position.init(1, 3));
    try around.sendChar('m');
    try around.sendChar('a');
    try around.sendChar('(');
    try around.sendChar('d');
    try around.expectValue("f");
}

test "Helix: mi\" and ma\" select inside and around quotes" {
    const inside = try Harness.init(std.testing.allocator, "x = \"hello\";");
    defer inside.deinit();
    try inside.editor.setCursorPosition(Position.init(1, 7));
    try inside.sendChar('m');
    try inside.sendChar('i');
    try inside.sendChar('"');
    try inside.sendChar('d');
    try inside.expectValue("x = \"\";");

    const around = try Harness.init(std.testing.allocator, "x = \"hello\";");
    defer around.deinit();
    try around.editor.setCursorPosition(Position.init(1, 7));
    try around.sendChar('m');
    try around.sendChar('a');
    try around.sendChar('"');
    try around.sendChar('d');
    try around.expectValue("x = ;");
}

test "Helix: mip and map select paragraphs" {
    const inside = try Harness.init(std.testing.allocator, "one\ntwo\n\nthree");
    defer inside.deinit();
    try inside.editor.setCursorPosition(Position.init(2, 2));
    try inside.sendChar('m');
    try inside.sendChar('i');
    try inside.sendChar('p');
    const inside_selection = try inside.firstSelection();
    try std.testing.expectEqual(Position.init(1, 1), inside_selection.getStartPosition());
    try std.testing.expectEqual(Position.init(2, 4), inside_selection.getEndPosition());

    const around = try Harness.init(std.testing.allocator, "one\ntwo\n\nthree");
    defer around.deinit();
    try around.editor.setCursorPosition(Position.init(2, 2));
    try around.sendChar('m');
    try around.sendChar('a');
    try around.sendChar('p');
    const around_selection = try around.firstSelection();
    try std.testing.expectEqual(Position.init(1, 1), around_selection.getStartPosition());
    try std.testing.expectEqual(Position.init(4, 1), around_selection.getEndPosition());
}

test "Helix: mim selects the closest surround pair" {
    const h = try Harness.init(std.testing.allocator, "f(a, (b), c)");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 7));
    try h.sendChar('m');
    try h.sendChar('i');
    try h.sendChar('m');
    try h.sendChar('d');
    try h.expectValue("f(a, (), c)");
}

test "Helix: text objects work on every selection" {
    const h = try Harness.init(std.testing.allocator, "one two three");
    defer h.deinit();
    try h.editor.setSelections(&[_]Selection{
        Selection.init(1, 1, 1, 1),
        Selection.init(1, 5, 1, 5),
        Selection.init(1, 9, 1, 9),
    });
    try h.sendChar('m');
    try h.sendChar('i');
    try h.sendChar('w');
    try std.testing.expectEqual(@as(usize, 3), try h.selectionCount());
    try h.sendChar('d');
    try h.expectValue("  ");
}

test "Helix: tree-sitter-only text objects report a message" {
    const h = try Harness.init(std.testing.allocator, "abc");
    defer h.deinit();
    try h.sendChar('m');
    try h.sendChar('i');
    try h.sendChar('f');
    try std.testing.expectEqualStrings("Helix: tree-sitter text object unavailable", h.window.message.?);
    try h.expectValue("abc");
}

test "Helix: text-object prefixes can arrive in one text run" {
    const h = try Harness.init(std.testing.allocator, "hello world");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 2));
    try h.sendChar('m');
    try h.sendText("iw");
    try h.sendChar('d');
    try h.expectValue(" world");
}

test "Helix: j and k keep the desired column across short lines" {
    const h = try Harness.init(std.testing.allocator, "0123456789abcdef\nab\n0123456789abcdef");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 10));

    // The short line clamps the caret and remembers the desired column.
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(2, 3), h.cursor());

    // The next visual line restores it instead of staying pinned to the clamp.
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.cursor());

    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(2, 3), h.cursor());
    try h.sendChar('k');
    try std.testing.expectEqual(Position.init(1, 10), h.cursor());
}

test "Helix: counted j keeps the desired column" {
    const h = try Harness.init(std.testing.allocator, "0123456789abcdef\nab\n0123456789abcdef");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 10));
    try h.sendChar('2');
    try h.sendChar('j');
    try std.testing.expectEqual(Position.init(3, 10), h.cursor());
}

test "Helix: select-mode j keeps the desired column" {
    const h = try Harness.init(std.testing.allocator, "0123456789abcdef\nab\n0123456789abcdef");
    defer h.deinit();
    try h.editor.setCursorPosition(Position.init(1, 10));
    try h.sendChar('v');
    try h.sendChar('j');
    try h.sendChar('j');
    const selection = try h.firstSelection();
    try std.testing.expectEqual(Position.init(1, 10), selection.getSelectionStart());
    try std.testing.expectEqual(Position.init(3, 10), selection.getPosition());
}

test "Helix: j collapses the selection before moving" {
    const h = try Harness.init(std.testing.allocator, "one two\nthree");
    defer h.deinit();
    try h.sendChar('w');
    const word_selection = try h.firstSelection();
    try std.testing.expect(!word_selection.isEmpty());

    try h.sendChar('j');
    const collapsed = try h.firstSelection();
    try std.testing.expect(collapsed.isEmpty());
    try std.testing.expectEqual(Position.init(2, 5), collapsed.getPosition());
}
