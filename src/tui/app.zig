const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const tui = @import("./tui.zig");
const input = @import("./input.zig");
const Editor = @import("./editor.zig").Editor;
const Screen = @import("./screen.zig").Screen;
const renderer = @import("./render.zig");
const ArrayList = std.array_list.Managed;

fn getFirstArg(args: std.process.Args) ![]const u8 {
    var it = args.iterate();
    _ = it.next(); // executable name
    return it.next() orelse error.NoPathProvided;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const path = getFirstArg(init.minimal.args) catch {
        std.debug.print("usage: zig <file>\n", .{});
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
    var editor = try Editor.create(allocator, io, path, size.width, size.height);
    defer {
        editor.deinit();
        allocator.destroy(editor);
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

fn isCtrlQ(event: input.Event) bool {
    if (!event.mods.ctrl) return false;
    return switch (event.key) {
        .char => |ch| ch == 'q',
        else => false,
    };
}

fn dispatch(editor: *Editor, event: input.Event, is_pasting: *bool) bool {
    if (!isCtrlQ(event)) editor.clearQuitArmed();

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
            editor.insertText(text) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            return false;
        },
        .char => |ch| {
            if (event.mods.ctrl) {
                switch (ch) {
                    'q' => return editor.requestQuit(),
                    's' => editor.save() catch |err| editor.setMessage("save failed: {s}", .{@errorName(err)}),
                    'z' => editor.undo() catch |err| editor.setMessage("undo failed: {s}", .{@errorName(err)}),
                    'y' => editor.redo() catch |err| editor.setMessage("redo failed: {s}", .{@errorName(err)}),
                    'a' => editor.selectAll() catch |err| editor.setMessage("select all failed: {s}", .{@errorName(err)}),
                    'c' => {},
                    'l' => editor.clearMessage(),
                    else => {},
                }
                return false;
            }
            var buffer: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(ch, &buffer) catch return false;
            editor.insertText(buffer[0..encoded]) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            return false;
        },
        .enter => editor.newline() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .tab => editor.insertTab() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backtab => editor.outdent() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backspace => editor.deleteLeft() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .delete => editor.deleteRight() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .escape => editor.cancelSelection() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
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
        .up => editor.moveUp(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
        .down => editor.moveDown(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
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
