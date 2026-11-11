// Adapted from `src/vs/editor/contrib/find/test/browser/findController.test.ts`.
//
// The upstream test drives a browser editor through the find controller and
// asserts widget DOM state. This terminal harness drives the same controller
// through `View.dispatchKey`, asserts the rendered cells, the editor selection
// and the decoration ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Editor = @import("../../../../../../tui/editor.zig").Editor;
const View = @import("../../../../../../tui/view.zig").View;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");
const FindController = @import("../../browser/findController.zig").FindController;

fn createEditor(allocator: Allocator) !*Editor {
    const io = std.Io.Threaded.global_single_threaded.io();
    return Editor.createFromText(allocator, io, "alpha\nbeta alpha\ngamma", "test.txt", 60, 8);
}

fn setDecorations(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.setDecorations(decorations) catch {};
}

fn rowText(view: *View, allocator: Allocator, row: usize) ![]u8 {
    return view.surface.grid().rowText(allocator, row);
}

test "FindController: opens, searches incrementally and closes" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const open_row = try rowText(view, allocator, 0);
    defer allocator.free(open_row);
    try std.testing.expect(std.mem.indexOf(u8, open_row, "Find") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_row, "0/0") != null);
    try std.testing.expect(view.surface.document().activeElement() != null);

    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));
    try std.testing.expectEqualStrings("alpha", controller.state.search_string);
    try std.testing.expectEqual(@as(usize, 2), controller.state.matches_count);
    try std.testing.expectEqual(@as(usize, 2), controller.model.getDecorations().getCount());

    const selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 6), selection.endColumn);

    try view.refresh();
    try view.render(&out.writer);
    const count_row = try rowText(view, allocator, 0);
    defer allocator.free(count_row);
    try std.testing.expect(std.mem.indexOf(u8, count_row, "1/2") != null);

    var enter_event = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(view.dispatchKey(&enter_event));
    const next_selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 2), next_selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 6), next_selection.startColumn);

    var escape_event = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape_event));
    try std.testing.expect(!controller.isOpen());
    try std.testing.expectEqual(@as(usize, 0), view.decorations.items.len);

    try view.refresh();
    try view.render(&out.writer);
    const closed_row = try rowText(view, allocator, 0);
    defer allocator.free(closed_row);
    try std.testing.expect(std.mem.indexOf(u8, closed_row, "Find") == null);
    try std.testing.expect(view.surface.document().active_element == null);
}

test "FindController: replace row replaces the current match" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));

    try controller.startReplace();
    try view.refresh();
    try std.testing.expect(controller.state.is_replace_revealed);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const replace_row = try rowText(view, allocator, 1);
    defer allocator.free(replace_row);
    try std.testing.expect(std.mem.indexOf(u8, replace_row, "Repl") != null);

    var replace_text = ui.KeyEvent{ .key = .{ .text = "omega" } };
    try std.testing.expect(view.dispatchKey(&replace_text));
    try std.testing.expectEqualStrings("omega", controller.state.replace_string);

    var enter_event = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(view.dispatchKey(&enter_event));

    const first_line = try editor.model.getLineContent(1);
    defer first_line.deinit();
    try std.testing.expectEqualStrings("omega", first_line.items);
    try std.testing.expectEqual(@as(usize, 1), controller.state.matches_count);

    var escape_event = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape_event));
    try std.testing.expect(!controller.isOpen());
}

test "FindController: decorations paint the match cells" {
    const allocator = std.testing.allocator;
    const editor = try Editor.createFromText(
        allocator,
        std.Io.Threaded.global_single_threaded.io(),
        "alpha\nbeta alpha\ngamma",
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

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    // The current match is the first word on line 1.
    const index = grid.index(gutter, 0);
    try std.testing.expect(grid.bg[index] != 0);
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 200, .g = 120, .b = 0 }), grid.bg[index]);

    var escape_event = ui.KeyEvent{ .key = .escape };
    _ = view.dispatchKey(&escape_event);
    try view.refresh();
    try view.render(&out.writer);
    const cleared = view.surface.grid();
    try std.testing.expect(cleared.bg[cleared.index(gutter, 0)] != ui.cell.packColor(.{ .r = 200, .g = 120, .b = 0 }));
}

test "FindController: Alt-L limits the search to the selection" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));
    try std.testing.expectEqual(@as(usize, 2), controller.state.matches_count);

    // Find in the second word only.
    try editor.setSelection(@import("../../../../common/core/range.zig").Range.init(2, 6, 2, 11));
    var scope_event = ui.KeyEvent{ .key = .{ .char = 'l' }, .mods = .{ .alt = true } };
    try std.testing.expect(view.dispatchKey(&scope_event));
    try std.testing.expect(controller.state.search_scope != null);
    try std.testing.expectEqual(@as(usize, 1), controller.state.matches_count);

    // Toggling again clears the scope.
    var unscoped_event = ui.KeyEvent{ .key = .{ .char = 'l' }, .mods = .{ .alt = true } };
    try std.testing.expect(view.dispatchKey(&unscoped_event));
    try std.testing.expect(controller.state.search_scope == null);
    try std.testing.expectEqual(@as(usize, 2), controller.state.matches_count);

    // Alt+Enter selects all matches.
    var select_all_event = ui.KeyEvent{ .key = .enter, .mods = .{ .alt = true } };
    try std.testing.expect(view.dispatchKey(&select_all_event));
    try std.testing.expectEqual(@as(usize, 2), editor.cursorCount());

    var escape_event = ui.KeyEvent{ .key = .escape };
    _ = view.dispatchKey(&escape_event);
}

test "FindController: reopening keeps the current match" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));

    var escape_event = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape_event));
    try std.testing.expect(!controller.isOpen());

    const before = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), before.startLineNumber);

    try controller.startFind();
    try std.testing.expect(controller.isOpen());
    const after = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), after.startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), after.startColumn);

    var close_event = ui.KeyEvent{ .key = .escape };
    _ = view.dispatchKey(&close_event);
}

test "FindController: clicking the input focuses it and clicking the editor blurs it" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();

    const iface = controller.widget().interface();
    const width_cells = iface.width(iface.context, 60);
    const left = 60 - width_cells;
    // The find input starts six cells into the bar; click inside its text.
    var click = ui.MouseEvent{
        .kind = .down,
        .x = left + 8,
        .y = 0,
        .button = .left,
    };
    _ = try view.dispatchMouse(&click);
    try std.testing.expectEqual(
        iface.focus_node(iface.context).?,
        view.surface.document().activeElement().?,
    );
    try std.testing.expect(iface.is_focused(iface.context));

    // The widget restores its input after the per-frame rebuild.
    try view.refresh();
    try std.testing.expect(view.surface.document().active_element != null);
    try std.testing.expect(iface.is_focused(iface.context));

    // A click on the editor text blurs the widget; the next rebuild does not
    // take focus back, so keys reach the editor.
    var away = ui.MouseEvent{
        .kind = .down,
        .x = editor.gutterWidth(),
        .y = 2,
        .button = .left,
    };
    try std.testing.expect(try view.dispatchMouse(&away));
    try std.testing.expect(!iface.is_focused(iface.context));
    try std.testing.expect(view.surface.document().active_element == null);
    try view.refresh();
    try std.testing.expect(view.surface.document().active_element == null);
}

test "FindController: find toggles hover and click from the mouse" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const iface = controller.widget().interface();
    const width_cells = iface.width(iface.context, 60);
    const left = 60 - width_cells;
    // The Aa toggle is the first of the four 3-cell toggles at the right edge.
    const toggle_x = left + width_cells - 12;
    const grid = view.surface.grid();
    const normal_bg = grid.bg[grid.index(toggle_x, 0)];

    // Idle motion over the toggle highlights it; mode 1003 delivers this.
    var hover = ui.MouseEvent{ .kind = .move, .x = toggle_x, .y = 0 };
    _ = try view.dispatchMouse(&hover);
    try std.testing.expect(controller.widget().hover_control != null);
    try view.refresh();
    try view.render(&out.writer);
    const hovered_bg = view.surface.grid().bg[view.surface.grid().index(toggle_x, 0)];
    try std.testing.expect(hovered_bg != normal_bg);

    // Moving back to the editor clears the control hover.
    var away = ui.MouseEvent{ .kind = .move, .x = editor.gutterWidth(), .y = 2 };
    _ = try view.dispatchMouse(&away);
    try std.testing.expect(controller.widget().hover_control == null);
    try view.refresh();
    try view.render(&out.writer);
    try std.testing.expectEqual(
        normal_bg,
        view.surface.grid().bg[view.surface.grid().index(toggle_x, 0)],
    );

    // Clicking the toggle changes the option and keeps the input focused.
    var down = ui.MouseEvent{ .kind = .down, .x = toggle_x, .y = 0, .button = .left };
    _ = try view.dispatchMouse(&down);
    var up = ui.MouseEvent{ .kind = .up, .x = toggle_x, .y = 0, .button = .left };
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(controller.state.matchCase());
    try std.testing.expect(view.surface.document().active_element != null);

    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(!controller.state.matchCase());
}

test "FindController: clicking All runs replace-all" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const controller = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setDecorations,
    });
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));
    try controller.startReplace();
    try view.refresh();
    var replace_text = ui.KeyEvent{ .key = .{ .text = "omega" } };
    try std.testing.expect(view.dispatchKey(&replace_text));

    const iface = controller.widget().interface();
    const width_cells = iface.width(iface.context, 60);
    const left = 60 - width_cells;
    const all_x = left + width_cells - 4;
    var down = ui.MouseEvent{ .kind = .down, .x = all_x, .y = 1, .button = .left };
    _ = try view.dispatchMouse(&down);
    var up = ui.MouseEvent{ .kind = .up, .x = all_x, .y = 1, .button = .left };
    _ = try view.dispatchMouse(&up);

    const first_line = try editor.model.getLineContent(1);
    defer first_line.deinit();
    try std.testing.expectEqualStrings("omega", first_line.items);
    const second_line = try editor.model.getLineContent(2);
    defer second_line.deinit();
    try std.testing.expectEqualStrings("beta omega", second_line.items);
    try std.testing.expect(view.surface.document().active_element != null);
}
