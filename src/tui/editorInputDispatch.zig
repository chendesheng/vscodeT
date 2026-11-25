//! Terminal key-event dispatch shared by the TUI read loop and the wasm host.
//!
//! The byte-to-`ui.input.KeyEvent` decoding stays in `ui/src/terminal/input.zig`; this module
//! maps a decoded key to the editor command or edit operation that the terminal
//! host performs. It deliberately has no terminal, workbench or OS dependency so
//! the same behavior backs the native TUI and the browser demo.

const std = @import("std");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const input = @import("ui").input;
const View = @import("./editorView.zig").View;
const ContentHoverController = @import("../vs/editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const WordHighlighterContribution = @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const FindController = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
const SuggestController = @import("../vs/editor/contrib/suggest/browser/suggestController.zig").SuggestController;

/// Returns true when Ctrl+Q should terminate the host (the TUI handles it,
/// the browser demo ignores it).
pub fn isCtrlQ(event: input.KeyEvent) bool {
    return isCtrlChar(event, 'q');
}

pub fn isCtrlChar(event: input.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

/// Dispatches one decoded key event to the editor. Returns true when the event
/// should quit the terminal host (only Ctrl+Q does).
pub fn dispatch(editor: *Editor, event: input.KeyEvent, is_pasting: *bool) bool {
    if (!isCtrlQ(event)) editor.clearMessage();

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

    if (editor.dispatchShortcut(event) catch |err| blk: {
        editor.setMessage("shortcut failed: {s}", .{@errorName(err)});
        break :blk false;
    }) {
        return false;
    }

    switch (event.key) {
        .paste_start => {
            is_pasting.* = true;
            return false;
        },
        .paste_end => return false,
        .f12 => {},
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
            if (event.mods.alt and event.mods.shift) {
                editor.growSelection(false) catch |err| editor.setMessage("shrink selection failed: {s}", .{@errorName(err)});
            } else if (event.mods.ctrl) {
                editor.moveWordLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .right => {
            if (event.mods.alt and event.mods.shift) {
                editor.growSelection(true) catch |err| editor.setMessage("expand selection failed: {s}", .{@errorName(err)});
            } else if (event.mods.ctrl) {
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

/// Runs the editor contributions and editor command for a decoded key.
/// Returns true when the key requests a host quit.
pub fn handleKeyEvent(
    view: *View,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
    find: *FindController,
    suggest: ?*SuggestController,
    editor: *Editor,
    event: *input.KeyEvent,
    is_pasting: *bool,
    now_ms: i64,
    fallback: ?input.KeyEvent,
) !bool {
    if (suggest) |controller| {
        if (try controller.handleKey(event, now_ms)) return false;
    }
    if (hover.onKeyDown(event)) return false;
    if (suggest) |controller| {
        if (controller.hasSnippetSession()) {
            switch (event.key) {
                .tab => if (try controller.nextSnippetPlaceholder()) return false,
                .backtab => if (try controller.previousSnippetPlaceholder()) return false,
                .escape => {
                    controller.cancelSnippetSession();
                    return false;
                },
                else => {},
            }
        }
    }
    if (word_highlighter.handleKey(event)) {
        find.onEditorChanged();
        return false;
    }
    if (view.dispatchKey(event)) return false;
    if (suggest) |controller| {
        switch (event.key) {
            .char, .text, .enter, .tab, .backspace, .delete => controller.beforeTyping(),
            else => {},
        }
    }
    if (dispatch(editor, fallback orelse event.*, is_pasting)) return true;
    if (suggest) |controller| {
        if (printableChar(event.*)) |ch| {
            _ = try controller.onTypedCharacter(ch, now_ms);
        }
        _ = try controller.onEditorChanged();
    }
    find.onEditorChanged();
    return false;
}

fn printableChar(event: input.KeyEvent) ?u8 {
    return switch (event.key) {
        .char => |ch| if (ch >= 0x20 and ch <= 0x7e and !event.mods.ctrl and !event.mods.alt) @intCast(ch) else null,
        .text => |text| if (text.len == 1 and text[0] >= 0x20 and text[0] <= 0x7e) text[0] else null,
        else => null,
    };
}
