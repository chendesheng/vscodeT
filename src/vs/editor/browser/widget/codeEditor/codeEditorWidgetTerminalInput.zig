//! Terminal input adapter for CodeEditorWidget.trigger and viewUserInputEvents
//! in `src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts`.
//!
//! Translates an already-decoded ui KeyEvent into editor commands and type/paste
//! operations. Raw input, terminal quit and the read loop remain in src/tui;
//! widget dispatch uses the view's explicit key-target interface. Terminal
//! bracketed paste and the legacy navigation fallbacks are adaptations to input
//! with no browser keyboard/composition event source.

const std = @import("std");
const Editor = @import("codeEditorWidgetTerminal.zig").Editor;
const input = @import("ui").input;
const IEditorKeyTarget = @import("../../editorBrowser.zig").IEditorKeyTarget;
const ContentHoverController = @import("../../../contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const WordHighlighterContribution = @import("../../../contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const hoverTypes = @import("../../../contrib/hover/browser/hoverTypes.zig");
const SuggestController = @import("../../../contrib/suggest/browser/suggestController.zig").SuggestController;

/// Host shortcut identity; the host alone decides whether to quit.
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

/// Dispatch one decoded editor event. The legacy bool result is always false;
/// host-level actions have already been handled by the caller.
pub fn dispatch(editor: *Editor, event: input.KeyEvent, is_pasting: *bool) bool {
    if (!isCtrlQ(event)) editor.clearMessage();

    if (is_pasting.*) {
        switch (event.key) {
            .paste_end => {
                is_pasting.* = false;
                return false;
            },
            .text => |text| {
                editor.pasteText(text) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
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
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {},
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
/// The result is false: host quit is handled before this editor dispatch.
pub fn handleKeyEvent(
    view: IEditorKeyTarget,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
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
    if (word_highlighter.handleKey(event)) return false;
    if (view.dispatchKey(event)) return false;
    return dispatch(editor, fallback orelse event.*, is_pasting);
}

pub fn handleMouseEvent(
    view: anytype,
    hover: *ContentHoverController,
    suggest: ?*SuggestController,
    editor: *Editor,
    event: *input.MouseEvent,
) !bool {
    if (event.kind != .move) {
        editor.clearMessage();
    }

    const target = try view.mouseTargetAt(event.x, event.y);
    if (event.kind == .move) {
        view.setGlyphHover(target);
    } else {
        view.clearGlyphHover();
    }
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
            .content_text, .content_empty, .content_widget, .gutter_line_numbers, .gutter_glyph_margin, .gutter_line_decorations, .gutter_view_zone, .content_view_zone, .scrollbar, .overview_ruler, .overlay_widget => hover.onMouseMove(hover_event),
            .status, .unknown, .textarea, .outside_editor => hover.onEditorMouseLeave(hover_event),
        },
        .wheel, .click => {},
    }

    if (event.kind == .down and target.type != .content_widget) {
        if (suggest) |controller| controller.cancel();
    }
    return view.dispatchMouse(event);
}
