const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const tui = @import("./tui.zig");
const input = @import("./input.zig");
const Editor = @import("./editor.zig").Editor;
const Screen = @import("./screen.zig").Screen;
const renderer = @import("./render.zig");
const Preview = @import("./preview.zig").Preview;
const ArrayList = std.array_list.Managed;

const Args = struct {
    path: []const u8,
    preview: bool,
};

fn parseArgs(args: std.process.Args) !Args {
    var it = args.iterate();
    _ = it.next(); // executable name
    const first = it.next() orelse return error.NoPathProvided;
    if (std.mem.eql(u8, first, "--preview")) {
        const path = it.next() orelse return error.NoPathProvided;
        return .{ .path = path, .preview = true };
    }
    return .{ .path = first, .preview = false };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = parseArgs(init.minimal.args) catch {
        std.debug.print("usage: zig <file>\n       zig --preview <file>\n", .{});
        return;
    };

    var out_buffer: [65536]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch {};

    try tui.enableBracketedPaste(out);
    defer tui.disableBracketedPaste(out) catch {};

    try tui.enterAltScreen(out);
    defer tui.exitAltScreen(out) catch {};

    try tui.disableLineWrap(out);
    defer tui.enableLineWrap(out) catch {};

    try tui.installSigWinch();

    var size = try tui.getTerminalSize();
    var editor = try Editor.create(allocator, io, args.path, size.width, size.height);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    if (args.preview) {
        try runPreview(allocator, out, editor, size);
        return;
    }

    var screen = try Screen.init(allocator, size.width, size.height);
    defer screen.deinit();

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 4096);
    defer input_buffer.deinit();

    var is_pasting = false;
    try renderer.render(editor, &screen, out);

    while (true) {
        const ready = try tui.pollInput(250);
        var resized = false;
        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            editor.setViewport(size.width, size.height);
            screen.deinit();
            screen = try Screen.init(allocator, size.width, size.height);
            resized = true;
        }

        if (!ready) {
            if (resized) try renderer.render(editor, &screen, out);
            continue;
        }

        input_buffer.clearRetainingCapacity();
        const bytes = try tui.readFd(posix.STDIN_FILENO, &input_buffer);

        const events = try input.decode(allocator, bytes);
        defer events.deinit();

        for (events.items) |event| {
            if (dispatch(editor, event, &is_pasting)) return;
        }

        try renderer.render(editor, &screen, out);
    }
}

fn runPreview(allocator: std.mem.Allocator, out: *Io.Writer, editor: *Editor, initial_size: tui.Size) !void {
    var size = initial_size;
    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    try preview.render(out);
    try out.flush();

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 256);
    defer input_buffer.deinit();

    while (true) {
        const ready = try tui.pollInput(250);

        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            editor.setViewport(size.width, size.height);
            try preview.resize();
            try tui.clearScreen(out);
            try preview.render(out);
            try out.flush();
            continue;
        }

        if (!ready) continue;

        input_buffer.clearRetainingCapacity();
        const bytes = try tui.readFd(posix.STDIN_FILENO, &input_buffer);
        for (bytes) |byte| {
            if (byte == 0x11) return; // Ctrl-Q
        }
    }
}

fn isCtrlQ(event: input.Event) bool {
    if (!event.mods.ctrl) return false;
    return switch (event.key) {
        .char => |ch| ch == 'q',
        else => false,
    };
}

fn dispatch(editor: *Editor, event: input.Event, is_pasting: *bool) bool {
    if (!isCtrlQ(event)) {
        editor.clearQuitArmed();
        editor.clearMessage();
    }

    if (is_pasting.*) {
        switch (event.key) {
            .paste_end => {
                is_pasting.* = false;
                return false;
            },
            .text => |text| {
                editor.insertText(text) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
                return false;
            },
            else => return false,
        }
    }

    switch (event.key) {
        .paste_start => {
            is_pasting.* = true;
            return false;
        },
        .paste_end => return false,
        .text => |text| {
            var offset: usize = 0;
            while (offset < text.len) {
                const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
                const end = @min(offset + length, text.len);
                editor.typeCharacter(text[offset..end]) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
                offset = end;
            }
            return false;
        },
        .char => |ch| {
            if (event.mods.alt) {
                switch (ch) {
                    '/' => editor.toggleBlockComment() catch |err| editor.setMessage("comment failed: {s}", .{@errorName(err)}),
                    'b' => editor.selectToBracket(true) catch |err| editor.setMessage("select bracket failed: {s}", .{@errorName(err)}),
                    'B' => editor.removeBrackets() catch |err| editor.setMessage("remove brackets failed: {s}", .{@errorName(err)}),
                    'd' => editor.selectAllOccurrences() catch |err| editor.setMessage("select occurrences failed: {s}", .{@errorName(err)}),
                    'r' => editor.reindentSelectedLines() catch |err| editor.setMessage("reindent failed: {s}", .{@errorName(err)}),
                    'R' => editor.reindentLines() catch |err| editor.setMessage("reindent failed: {s}", .{@errorName(err)}),
                    else => {},
                }
                return false;
            }
            if (event.mods.ctrl) {
                switch (ch) {
                    'q' => return editor.requestQuit(),
                    's' => editor.save() catch |err| editor.setMessage("save failed: {s}", .{@errorName(err)}),
                    'z' => editor.undo() catch |err| editor.setMessage("undo failed: {s}", .{@errorName(err)}),
                    'y' => editor.redo() catch |err| editor.setMessage("redo failed: {s}", .{@errorName(err)}),
                    'a' => editor.selectAll() catch |err| editor.setMessage("select all failed: {s}", .{@errorName(err)}),
                    'c' => {},
                    'l' => editor.expandLineSelection() catch |err| editor.setMessage("select line failed: {s}", .{@errorName(err)}),
                    '/' => editor.toggleLineComment() catch |err| editor.setMessage("comment failed: {s}", .{@errorName(err)}),
                    '\\' => editor.jumpToBracket() catch |err| editor.setMessage("jump failed: {s}", .{@errorName(err)}),
                    ']' => editor.indentLines() catch |err| editor.setMessage("indent failed: {s}", .{@errorName(err)}),
                    'd' => editor.selectNextOccurrence() catch |err| editor.setMessage("select occurrence failed: {s}", .{@errorName(err)}),
                    else => {},
                }
                return false;
            }
            var buffer: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(ch, &buffer) catch return false;
            editor.typeCharacter(buffer[0..encoded]) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            return false;
        },
        .enter => editor.newline() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .tab => editor.insertTab() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backtab => editor.outdent() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backspace => editor.deleteLeft() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .delete => editor.deleteRight() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .escape => {
            if (editor.cursorCount() > 1) {
                editor.removeSecondaryCursors() catch |err| editor.setMessage("remove cursors failed: {s}", .{@errorName(err)});
            } else {
                editor.cancelSelection() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            }
        },
        .left => {
            if (event.mods.ctrl) {
                editor.moveWordLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .right => {
            if (event.mods.ctrl) {
                editor.moveWordRight(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveRight(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .up => {
            if (event.mods.ctrl and event.mods.alt) {
                editor.addCursorAbove() catch |err| editor.setMessage("add cursor failed: {s}", .{@errorName(err)});
            } else if (event.mods.alt) {
                if (event.mods.shift) {
                    editor.copyLines(false) catch |err| editor.setMessage("copy lines failed: {s}", .{@errorName(err)});
                } else {
                    editor.moveLines(false) catch |err| editor.setMessage("move lines failed: {s}", .{@errorName(err)});
                }
            } else {
                editor.moveUp(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .down => {
            if (event.mods.ctrl and event.mods.alt) {
                editor.addCursorBelow() catch |err| editor.setMessage("add cursor failed: {s}", .{@errorName(err)});
            } else if (event.mods.alt) {
                if (event.mods.shift) {
                    editor.copyLines(true) catch |err| editor.setMessage("copy lines failed: {s}", .{@errorName(err)});
                } else {
                    editor.moveLines(true) catch |err| editor.setMessage("move lines failed: {s}", .{@errorName(err)});
                }
            } else {
                editor.moveDown(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .home => {
            if (event.mods.ctrl) {
                editor.moveDocStart(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLineStart(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .end => {
            if (event.mods.ctrl) {
                editor.moveDocEnd(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLineEnd(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .page_up => editor.movePageUp(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
        .page_down => editor.movePageDown(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
        .insert => {},
    }
    return false;
}

test "app: q inserts text and Ctrl-Q is the quit key" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const q_event = input.Event{ .key = .{ .text = "q" } };
    try std.testing.expect(!dispatch(editor, q_event, &pasting));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("qhello", line.items);
    try std.testing.expect(editor.isDirty());

    const ctrl_q = input.Event{ .key = .{ .char = 'q' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_q, &pasting));
    try std.testing.expect(editor.quit_armed);
    try std.testing.expect(dispatch(editor, ctrl_q, &pasting));
}

test "app: move lines and line comment shortcuts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const alt_down = input.Event{ .key = .down, .mods = .{ .alt = true } };
    try std.testing.expect(!dispatch(editor, alt_down, &pasting));
    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    try std.testing.expectEqualStrings("b", first.items);

    const ctrl_slash = input.Event{ .key = .{ .char = '/' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_slash, &pasting));
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("// a", second.items);

    const ctrl_l = input.Event{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_l, &pasting));
    try std.testing.expectEqual(@as(usize, 2), editor.modelSelection().endLineNumber);
}

test "app: jump to bracket shortcut" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const ctrl_backslash = input.Event{ .key = .{ .char = '\\' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_backslash, &pasting));
    try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().column);
}

test "app: indent lines shortcut" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "a", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const ctrl_bracket = input.Event{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_bracket, &pasting));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("    a", line.items);
}

test "app: typing an open bracket auto-closes it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const open_paren = input.Event{ .key = .{ .text = "(" } };
    try std.testing.expect(!dispatch(editor, open_paren, &pasting));

    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("()", value.items);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);
}
