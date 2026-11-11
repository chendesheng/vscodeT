const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const tui = @import("./tui.zig");
const ui = @import("ui");
const input = ui.input;
const Editor = @import("./editor.zig").Editor;
const View = @import("./view.zig").View;
const Preview = @import("./preview.zig").Preview;
const FindController = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
const word_character_classifier = @import("../vs/editor/common/core/wordCharacterClassifier.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const languages = @import("../vs/editor/common/languages.zig");
const hoverTypes = @import("../vs/editor/contrib/hover/browser/hoverTypes.zig");
const ContentHoverController = @import("../vs/editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const MarkdownHoverParticipant = @import("../vs/editor/contrib/hover/browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;
const WordHighlighterContribution = @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const TuiHoverProvider = @import("./hoverProvider.zig").TuiHoverProvider;
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
    // The whole-word search classifier cache is process-lifetime by design;
    // release it before the safe allocator checks for leaks on exit.
    defer word_character_classifier.freeWordClassifierCache();

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

    try tui.enableMouseCapture(out);
    defer tui.disableMouseCapture(out) catch {};

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

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const find = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setViewDecorations,
    });
    defer find.deinit();
    try view.addOverlayWidget(find.widget().interface());

    // Hover contribution: the markdown participant renders provider results and
    // line-decoration hover messages; the TUI provider stands in for language
    // extensions.
    var tui_hover_provider = TuiHoverProvider.init(allocator);
    defer tui_hover_provider.deinit();
    const hover_providers = [_]languages.HoverProvider{tui_hover_provider.interface()};
    var hover_participant = MarkdownHoverParticipant.init(allocator, editor.model, &hover_providers);
    defer hover_participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{hover_participant.interface()};
    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
        .coordinates = .{
            .context = view,
            .model_column_at_view_line_start = viewModelColumnAtViewLineStart,
        },
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    // Word occurrence highlighting follows the caret/selection. The textual
    // provider stands in for language highlight providers.
    const word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
        .context = view,
        .has_text_focus = viewHasEditorFocus,
        .set_decorations = viewSetWordDecorations,
        .request_frame = viewRequestFrame,
    }, .{});
    defer word_highlighter.deinit();
    word_highlighter.onEditorChanged(time_compat.milliTimestamp());

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 4096);
    defer input_buffer.deinit();

    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    var is_pasting = false;
    try view.render(out);
    try syncCursor(out, view);
    try out.flush();

    var needs_render = false;
    while (true) {
        const now_ms = time_compat.milliTimestamp();
        if (hover.onTick(now_ms)) needs_render = true;
        if (word_highlighter.onTick(now_ms)) needs_render = true;
        var timeout = hover.pollTimeout(now_ms, 250);
        if (word_highlighter.pollTimeout(now_ms)) |word_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(word_timeout, 250))));
        }
        const ready = try tui.pollInput(timeout);
        var resized = false;
        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            editor.setViewport(size.width, size.height);
            try view.resize();
            try tui.clearScreen(out);
            resized = true;
        }

        if (!ready) {
            if (resized or needs_render) {
                try view.refresh();
                try view.render(out);
                try syncCursor(out, view);
                try out.flush();
                needs_render = false;
            }
            continue;
        }

        input_buffer.clearRetainingCapacity();
        const bytes = try tui.readFd(posix.STDIN_FILENO, &input_buffer);

        var events = try input.decode(allocator, bytes);
        defer events.deinit(allocator);

        for (events.items) |*item| {
            switch (item.*) {
                .key => |*event| {
                    if (try handleKeyEvent(view, hover, word_highlighter, find, editor, event, &is_pasting)) return;
                },
                .mouse => |*event| {
                    handleMouseEvent(view, hover, find, editor, event) catch |err| {
                        editor.setMessage("mouse failed: {s}", .{@errorName(err)});
                    };
                },
            }
        }

        word_highlighter.onEditorChanged(time_compat.milliTimestamp());
        try view.refresh();
        try tui.hideCursor(out);
        try view.render(out);
        try syncCursor(out, view);
        try out.flush();
        needs_render = false;
    }
}

/// Handles one decoded event. A focused widget owns the keyboard; Ctrl-Q stays
/// global so the quit prompt works from inside a widget, and Ctrl-F/Ctrl-R open
/// the find bar from either side (Ctrl-H is Backspace on terminals). Returns
/// true when the app should quit.
fn handleKeyEvent(
    view: *View,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
    find: *FindController,
    editor: *Editor,
    event: *input.KeyEvent,
    is_pasting: *bool,
) !bool {
    if (isCtrlQ(event.*)) {
        const quit = dispatch(editor, event.*, is_pasting);
        find.onEditorChanged();
        return quit;
    }
    if (hover.onKeyDown(event)) return false;
    if (word_highlighter.handleKey(event)) {
        find.onEditorChanged();
        return false;
    }
    if (isCtrlChar(event.*, 'f')) {
        find.startFind() catch |err| editor.setMessage("find failed: {s}", .{@errorName(err)});
        return false;
    }
    if (isCtrlChar(event.*, 'r')) {
        find.startReplace() catch |err| editor.setMessage("find failed: {s}", .{@errorName(err)});
        return false;
    }
    if (view.dispatchKey(event)) return false;
    if (dispatch(editor, event.*, is_pasting)) return true;
    find.onEditorChanged();
    return false;
}

/// Routes one mouse event through the view. The view owns hit testing, focus,
/// caret placement, drag selection, click synthesis and wheel scrolling.
fn handleMouseEvent(
    view: *View,
    hover: *ContentHoverController,
    find: *FindController,
    editor: *Editor,
    event: *input.MouseEvent,
) !void {
    if (event.kind != .move) {
        editor.clearQuitArmed();
        editor.clearMessage();
    }

    const target = try view.mouseTargetAt(event.x, event.y);
    const hover_event = hoverTypes.EditorMouseEvent{
        .target = target,
        .x = event.x,
        .y = event.y,
        .mods = event.mods,
        .button = event.button,
    };
    switch (event.kind) {
        .down => hover.onMouseDown(hover_event),
        .up => hover.onMouseUp(),
        .move => switch (target.type) {
            // The gutter and overlay widgets are inside the editor area in
            // VS Code, so they produce a mouse move (with no anchor) and the
            // sticky hover gets its grace period. The status row is outside
            // the editor, so it is a mouse leave.
            .content_text, .content_empty, .content_widget, .gutter_line_numbers, .scrollbar, .overlay_widget => hover.onMouseMove(hover_event),
            .status, .unknown => hover.onEditorMouseLeave(hover_event),
        },
        .wheel, .click => {},
    }

    const top_before = editor.topViewLine();
    if (try view.dispatchMouse(event)) find.onEditorChanged();
    if (event.kind == .wheel and !event.default_prevented) {
        hover.onEditorScrollChanged(editor.topViewLine() != top_before);
    }
}

fn viewTextHeight(context: *anyopaque) usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.editor.textHeight();
}

fn viewVisibleRowOf(context: *anyopaque, position: Position) ?usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.visibleRowOf(position);
}

fn viewRequestFrame(_: *anyopaque) void {
    // The event loop refreshes and renders after every input batch and after
    // any hover timer fired, so no extra frame request is needed.
}

fn viewFocusEditor(context: *anyopaque) void {
    const view: *View = @ptrCast(@alignCast(context));
    view.focusEditor();
}

fn viewHasEditorFocus(context: *anyopaque) bool {
    const view: *View = @ptrCast(@alignCast(context));
    return view.hasEditorFocus();
}

fn viewSetWordDecorations(context: *anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context));
    view.setWordHighlights(decorations) catch {};
}

fn viewSetHoverDecoration(context: *anyopaque, range: ?Range) void {
    const view: *View = @ptrCast(@alignCast(context));
    if (range) |value| {
        view.setHoverDecorations(&[_]editorBrowser.Decoration{
            .{ .range = value, .kind = .hover_highlight },
        }) catch {};
    } else {
        view.setHoverDecorations(&.{}) catch {};
    }
}

fn viewModelColumnAtViewLineStart(context: *anyopaque, position: Position) usize {
    const view: *View = @ptrCast(@alignCast(context));
    const view_position = view.editor.viewPositionOfModelPosition(position);
    const data = view.editor.viewLineData(view_position.lineNumber) catch return 1;
    return view.editor.modelColumnOfViewPosition(view_position.lineNumber, data.minColumn);
}

/// Hides the hardware cursor when it has no cell, otherwise moves it to the
/// view's caret and shows it.
fn syncCursor(out: *Io.Writer, view: *View) !void {
    if (view.cursorCell()) |cell| {
        try tui.moveCursor(out, .{ .row = cell.row + 1, .col = cell.col + 1 });
        try tui.showCursor(out);
    } else {
        try tui.hideCursor(out);
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

        var events = try ui.input.decode(allocator, bytes);
        defer events.deinit(allocator);

        var redraw = false;
        for (events.items) |*item| {
            switch (item.*) {
                .key => |*event| {
                    if (try preview.handleKey(event.*)) redraw = true;
                },
                .mouse => |*event| {
                    if (try preview.handleMouse(event)) redraw = true;
                },
            }
            if (preview.shouldQuit()) return;
        }
        if (redraw) {
            try preview.render(out);
            try out.flush();
        }
    }
}

fn isCtrlQ(event: input.KeyEvent) bool {
    return isCtrlChar(event, 'q');
}

fn isCtrlChar(event: input.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

fn setViewDecorations(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.setDecorations(decorations) catch {};
}

fn dispatch(editor: *Editor, event: input.KeyEvent, is_pasting: *bool) bool {
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
    const q_event = input.KeyEvent{ .key = .{ .text = "q" } };
    try std.testing.expect(!dispatch(editor, q_event, &pasting));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("qhello", line.items);
    try std.testing.expect(editor.isDirty());

    const ctrl_q = input.KeyEvent{ .key = .{ .char = 'q' }, .mods = .{ .ctrl = true } };
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
    const alt_down = input.KeyEvent{ .key = .down, .mods = .{ .alt = true } };
    try std.testing.expect(!dispatch(editor, alt_down, &pasting));
    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    try std.testing.expectEqualStrings("b", first.items);

    const ctrl_slash = input.KeyEvent{ .key = .{ .char = '/' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_slash, &pasting));
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("// a", second.items);

    const ctrl_l = input.KeyEvent{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } };
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
    const ctrl_backslash = input.KeyEvent{ .key = .{ .char = '\\' }, .mods = .{ .ctrl = true } };
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
    const ctrl_bracket = input.KeyEvent{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } };
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
    const open_paren = input.KeyEvent{ .key = .{ .text = "(" } };
    try std.testing.expect(!dispatch(editor, open_paren, &pasting));

    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("()", value.items);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);
}

// Regression: the decoder used to drop 0x06, so Ctrl-F never reached the app.
test "app: Ctrl-F opens the find bar through the byte decoder" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "alpha beta\nalpha gamma",
        "test.txt",
        100,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const find = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setViewDecorations,
    });
    defer find.deinit();
    try view.addOverlayWidget(find.widget().interface());

    const hover = try ContentHoverController.init(allocator, editor.model, &.{}, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();

    const word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
        .context = view,
        .has_text_focus = viewHasEditorFocus,
        .set_decorations = viewSetWordDecorations,
        .request_frame = viewRequestFrame,
    }, .{});
    defer word_highlighter.deinit();

    var pasting = false;
    var open_events = try ui.input.decodeKeys(allocator, "\x06");
    defer open_events.deinit(allocator);
    for (open_events.items) |*event| {
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, editor, event, &pasting));
    }

    try std.testing.expect(find.isOpen());
    try std.testing.expectEqualStrings("", find.state.search_string);

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const open_row = try view.surface.grid().rowText(allocator, 0);
    defer allocator.free(open_row);
    try std.testing.expect(std.mem.indexOf(u8, open_row, "Find") != null);
    try std.testing.expect(view.surface.document().active_element != null);

    // Escape is handled by the widget, not inserted into the document.
    var close_events = try ui.input.decodeKeys(allocator, "\x1b");
    defer close_events.deinit(allocator);
    for (close_events.items) |*event| {
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, editor, event, &pasting));
    }
    try std.testing.expect(!find.isOpen());

    try view.refresh();
    try view.render(&out.writer);
    const closed_row = try view.surface.grid().rowText(allocator, 0);
    defer allocator.free(closed_row);
    try std.testing.expect(std.mem.indexOf(u8, closed_row, "Find") == null);
}

test "app: the word under the caret highlights its occurrences" {
    const allocator = std.testing.allocator;
    defer word_character_classifier.freeWordClassifierCache();
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "word word word other", "test.txt", 60, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
        .context = view,
        .has_text_focus = viewHasEditorFocus,
        .set_decorations = viewSetWordDecorations,
        .request_frame = viewRequestFrame,
    }, .{});
    defer word_highlighter.deinit();

    word_highlighter.onEditorChanged(0);
    try std.testing.expect(word_highlighter.onTick(50));

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    for ([_]usize{ 0, 5, 10 }) |offset| {
        const background = ui.cell.unpackColor(grid.bg[grid.index(gutter + offset, 0)]);
        try std.testing.expectEqual(@as(u8, 71), background.r);
        try std.testing.expectEqual(@as(u8, 71), background.g);
        try std.testing.expectEqual(@as(u8, 71), background.b);
    }
    // `other` is not an occurrence of `word`.
    const other = ui.cell.unpackColor(grid.bg[grid.index(gutter + 16, 0)]);
    try std.testing.expectEqual(@as(u8, 32), other.r);

    // Move to `other`: the old highlights are replaced.
    try editor.setCursorPosition(Position.init(1, 17));
    word_highlighter.onEditorChanged(100);
    try std.testing.expect(word_highlighter.onTick(150));
    try view.refresh();
    try view.render(&out.writer);

    const moved = ui.cell.unpackColor(view.surface.grid().bg[view.surface.grid().index(gutter + 0, 0)]);
    try std.testing.expectEqual(@as(u8, 32), moved.r);
}

test "app: hover coordinate host uses the wrapped segment start" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "aaaa bbbb cccc dddd", "test.zig", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 1), viewModelColumnAtViewLineStart(view, Position.init(1, 3)));
    // `dddd` wraps to the second view line, which starts at model column 16.
    try std.testing.expectEqual(@as(usize, 16), viewModelColumnAtViewLineStart(view, Position.init(1, 18)));
}

test "app: hovering a word shows the rendered markdown hover" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "const value = 42;", "test.zig", 60, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var tui_provider = TuiHoverProvider.init(allocator);
    defer tui_provider.deinit();
    const providers = [_]languages.HoverProvider{tui_provider.interface()};
    var participant = MarkdownHoverParticipant.init(allocator, editor.model, &providers);
    defer participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{participant.interface()};

    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
        .coordinates = .{
            .context = view,
            .model_column_at_view_line_start = viewModelColumnAtViewLineStart,
        },
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    const target = editorBrowser.MouseTarget{
        .type = .content_text,
        .position = Position.init(1, 7),
        .range = Range.init(1, 7, 1, 7),
        .mouse_column = 10,
    };
    const event = hoverTypes.EditorMouseEvent{ .target = target, .x = 9, .y = 0 };
    hover.onMouseMove(event);
    try std.testing.expect(!hover.isVisible());

    const now = time_compat.milliTimestamp();
    _ = hover.onTick(now + 1000); // async half of the hover delay
    _ = hover.onTick(now + 2000); // sync half
    try std.testing.expect(hover.isVisible());

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const box = view.content_entries.items[0];
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '┌'), grid.cluster[grid.index(box.left, box.top)]);
    try std.testing.expectEqual(@as(u32, '┘'), grid.cluster[grid.index(box.left + box.width - 1, box.top + box.height - 1)]);

    var found_word = false;
    for (0..5) |row| {
        const text = try view.surface.grid().rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "value") != null) found_word = true;
    }
    try std.testing.expect(found_word);

    // The word range is highlighted below the hover (the dark-theme
    // `hoverHighlight` composited over the editor background).
    const highlighted = ui.cell.unpackColor(grid.bg[grid.index(editor.gutterWidth() + 6, 0)]);
    try std.testing.expectEqual(@as(u8, 32), highlighted.r);
    try std.testing.expectEqual(@as(u8, 42), highlighted.g);
    try std.testing.expectEqual(@as(u8, 52), highlighted.b);

    // Leaving the text hides the hover and clears the highlight.
    var leave = event;
    leave.target.type = .gutter_line_numbers;
    hover.onEditorMouseLeave(leave);
    try std.testing.expect(!hover.isVisible());
    try view.refresh();
    try view.render(&out.writer);
    const cleared = ui.cell.unpackColor(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth() + 6, 0)]);
    // Back to the current-line background, not the hover highlight.
    try std.testing.expectEqual(@as(u8, 32), cleared.r);
    try std.testing.expectEqual(@as(u8, 32), cleared.g);
    try std.testing.expectEqual(@as(u8, 36), cleared.b);

    // Show it again, click inside the box and close it with Escape. The click
    // focuses the hover, Escape gives the keyboard back to the editor.
    hover.onMouseMove(event);
    _ = hover.onTick(time_compat.milliTimestamp() + 3000);
    _ = hover.onTick(time_compat.milliTimestamp() + 4000);
    try std.testing.expect(hover.isVisible());
    try view.refresh();
    try view.render(&out.writer);

    const entry = view.content_entries.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = entry.left + 2,
        .y = entry.top + 1,
        .button = .left,
    };
    _ = try view.dispatchMouse(&down);
    var release = down;
    release.kind = .up;
    _ = try view.dispatchMouse(&release);
    try std.testing.expect(view.surface.document().active_element != null);
    try std.testing.expect(hover.isFocused());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape));
    try std.testing.expect(!hover.isVisible());
    try std.testing.expect(view.surface.document().active_element == null);
}

test "app: long hover content scrolls without moving the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "value\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const LongProvider = struct {
        contents: [1]languages.IMarkdownString = undefined,

        fn provide(context: *anyopaque, _: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: @import("../vs/base/common/cancellation.zig").CancellationToken, _: ?*const languages.HoverContext) anyerror!?languages.Hover {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.contents[0] = .{ .value = "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\neight\n\nnine\n\nten" };
            return .{ .contents = &self.contents, .range = Range.init(1, 1, 1, 5) };
        }
    };
    var long_provider = LongProvider{};
    const providers = [_]languages.HoverProvider{.{
        .context = &long_provider,
        .provide_hover = LongProvider.provide,
    }};

    var participant = MarkdownHoverParticipant.init(allocator, editor.model, &providers);
    defer participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{participant.interface()};
    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    const target = editorBrowser.MouseTarget{
        .type = .content_text,
        .position = Position.init(1, 1),
        .range = Range.init(1, 1, 1, 1),
        .mouse_column = 1,
    };
    hover.onMouseMove(.{ .target = target, .x = 3, .y = 0 });
    _ = hover.onTick(time_compat.milliTimestamp() + 1000);
    _ = hover.onTick(time_compat.milliTimestamp() + 2000);
    try std.testing.expect(hover.isVisible());

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const widget = hover.widget().widget;
    try std.testing.expect(widget.content_rows > widget.visible_rows);
    try std.testing.expect(widget.show_scrollbar);

    const top_before = editor.topViewLine();
    const entry = view.content_entries.items[0];
    var wheel = ui.MouseEvent{
        .kind = .wheel,
        .x = entry.left + 3,
        .y = entry.top + 2,
        .delta_y = 1,
    };
    _ = try view.dispatchMouse(&wheel);
    try std.testing.expect(wheel.default_prevented);
    try std.testing.expect(widget.scroll_top > 0);
    try std.testing.expectEqual(top_before, editor.topViewLine());
}

test "app: decoded clicks, drags and wheel reach the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9";
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    const find = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setViewDecorations,
    });
    defer find.deinit();
    try view.addOverlayWidget(find.widget().interface());

    const hover = try ContentHoverController.init(allocator, editor.model, &.{}, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();

    const gutter = editor.gutterWidth();
    var press_buf: [40]u8 = undefined;
    var release_buf: [40]u8 = undefined;
    const press = try std.fmt.bufPrint(&press_buf, "\x1b[<0;{d};2M", .{gutter + 2});
    const release = try std.fmt.bufPrint(&release_buf, "\x1b[<0;{d};2m", .{gutter + 2});

    var buffer: [128]u8 = undefined;
    const events = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ press, release });
    var items = try ui.input.decode(allocator, events);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, editor, mouse),
        }
    }

    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    // Drag from the start of line 3 five cells to the right.
    var drag_buf: [64]u8 = undefined;
    const drag = try std.fmt.bufPrint(
        &drag_buf,
        "\x1b[<0;{d};3M\x1b[<32;{d};3M\x1b[<0;{d};3m",
        .{ gutter + 1, gutter + 6, gutter + 6 },
    );
    var drag_items = try ui.input.decode(allocator, drag);
    defer drag_items.deinit(allocator);
    for (drag_items.items) |*item| {
        switch (item.*) {
            .key => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, editor, mouse),
        }
    }
    const selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 3), selection.selectionStartLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selection.selectionStartColumn);
    try std.testing.expectEqual(@as(usize, 6), selection.positionColumn);

    var wheel_items = try ui.input.decode(allocator, "\x1b[<65;1;1M");
    defer wheel_items.deinit(allocator);
    for (wheel_items.items) |*item| {
        switch (item.*) {
            .key => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, editor, mouse),
        }
    }
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().lineNumber);

    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings(text, value.items);
}
