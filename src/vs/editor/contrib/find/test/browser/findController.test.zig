// Adapted from `src/vs/editor/contrib/find/test/browser/findController.test.ts`.
//
// The upstream test drives a browser editor through the find controller and
// asserts widget DOM state. This terminal harness drives the same controller
// through `View.dispatchKey`, asserts the rendered cells, the editor selection
// and the decoration ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../../../../tui/editorView.zig").View;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const FindController = @import("../../browser/findController.zig").FindController;
const FindWidgetTheme = @import("../../browser/findWidget.zig").Theme;

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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

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
    try view.renderAnsi(&out.writer);
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
    const find_decorations = try editor.model.getAllDecorations(1, false);
    defer allocator.free(find_decorations);
    try std.testing.expectEqual(@as(usize, 0), find_decorations.len);

    try view.refresh();
    try view.renderAnsi(&out.writer);
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
    controller.setSeedSearchStringFromSelection(.never);
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
    try view.renderAnsi(&out.writer);
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var type_event = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&type_event));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    // The current match is the first word on line 1.
    const index = grid.index(gutter, 0);
    try std.testing.expect(grid.bg[index] != 0);
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 200, .g = 120, .b = 0 }), grid.bg[index]);

    var escape_event = ui.KeyEvent{ .key = .escape };
    _ = view.dispatchKey(&escape_event);
    try view.refresh();
    try view.renderAnsi(&out.writer);
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
    controller.setSeedSearchStringFromSelection(.never);
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
    controller.setSeedSearchStringFromSelection(.never);
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
    controller.setSeedSearchStringFromSelection(.never);
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const iface = controller.widget().interface();
    const width_cells = iface.width(iface.context, 60);
    const left = 60 - width_cells;
    // The Aa toggle is the first of the four 2-cell toggles, just before the
    // close cell at the right edge.
    const toggle_x = left + width_cells - 14;
    const grid = view.surface.grid();
    const normal_bg = grid.bg[grid.index(toggle_x, 0)];

    // Idle motion over the toggle highlights it; mode 1003 delivers this.
    var hover = ui.MouseEvent{ .kind = .move, .x = toggle_x, .y = 0 };
    _ = try view.dispatchMouse(&hover);
    try std.testing.expect(controller.widget().hover_control != null);
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const hovered_bg = view.surface.grid().bg[view.surface.grid().index(toggle_x, 0)];
    try std.testing.expect(hovered_bg != normal_bg);

    // Moving back to the editor clears the control hover.
    var away = ui.MouseEvent{ .kind = .move, .x = editor.gutterWidth(), .y = 2 };
    _ = try view.dispatchMouse(&away);
    try std.testing.expect(controller.widget().hover_control == null);
    try view.refresh();
    try view.renderAnsi(&out.writer);
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
    controller.setSeedSearchStringFromSelection(.never);
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

test "FindController: the host theme reaches the find bar" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    const theme = FindWidgetTheme{
        .background = ui.Color{ .r = 1, .g = 2, .b = 3 },
        .input_background = ui.Color{ .r = 4, .g = 5, .b = 6 },
        .input_foreground = ui.Color{ .r = 7, .g = 8, .b = 9 },
    };
    controller.setTheme(theme);

    try controller.open(false);
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(
        ui.cell.packColor(theme.background),
        grid.bg[grid.index(grid.cols - 1, 0)],
    );
}

test "FindController: visible controls toggle replace and close the bar" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    try controller.open(false);
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const iface = controller.widget().interface();
    const width_cells = iface.width(iface.context, 60);
    const left = 60 - width_cells;

    // The toggle is the first cell of the bar.
    var down = ui.MouseEvent{ .kind = .down, .x = left + 1, .y = 0, .button = .left };
    var up = ui.MouseEvent{ .kind = .up, .x = left + 1, .y = 0, .button = .left };
    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(controller.state.is_replace_revealed);

    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(!controller.state.is_replace_revealed);

    // The close cell is the last cell of the find row.
    down = .{ .kind = .down, .x = left + width_cells - 1, .y = 0, .button = .left };
    up = .{ .kind = .up, .x = left + width_cells - 1, .y = 0, .button = .left };
    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(!controller.isOpen());
}

test "FindController: replace-row controls preserve case and replace one" {
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
    controller.setSeedSearchStringFromSelection(.never);
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
    const row = 1;
    // Replace row: label 4, input, AB 2, replace 1, All 3.
    const preserve_x = left + width_cells - 9;
    var down = ui.MouseEvent{ .kind = .down, .x = preserve_x, .y = row, .button = .left };
    var up = ui.MouseEvent{ .kind = .up, .x = preserve_x, .y = row, .button = .left };
    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);
    try std.testing.expect(controller.state.preserveCase());

    const replace_x = left + width_cells - 6;
    down = .{ .kind = .down, .x = replace_x, .y = row, .button = .left };
    up = .{ .kind = .up, .x = replace_x, .y = row, .button = .left };
    _ = try view.dispatchMouse(&down);
    _ = try view.dispatchMouse(&up);

    const first_line = try editor.model.getLineContent(1);
    defer first_line.deinit();
    try std.testing.expectEqualStrings("omega", first_line.items);
}

test "FindController: addExtraSpaceOnTop controls the view-zone rows" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();

    const widget = controller.widget();
    try controller.open(false);
    try std.testing.expectEqual(@as(usize, 1), widget.viewZoneRows());
    widget.toggleReplace();
    try std.testing.expectEqual(@as(usize, 2), widget.viewZoneRows());

    widget.setAddExtraSpaceOnTop(false);
    try std.testing.expectEqual(@as(usize, 0), widget.viewZoneRows());
    widget.setAddExtraSpaceOnTop(true);
    try std.testing.expectEqual(@as(usize, 2), widget.viewZoneRows());
}

test "FindController: Up/Down navigate find input history" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());
    try controller.open(false);

    var alpha = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&alpha));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(view.dispatchKey(&enter));
    try controller.widget().find_input.clear();

    var beta = ui.KeyEvent{ .key = .{ .text = "beta" } };
    try std.testing.expect(view.dispatchKey(&beta));
    try std.testing.expect(view.dispatchKey(&enter));

    try controller.widget().find_input.clear();
    var up = ui.KeyEvent{ .key = .up };
    try std.testing.expect(view.dispatchKey(&up));
    try std.testing.expectEqualStrings("beta", controller.widget().find_input.getValue());
    try std.testing.expect(view.dispatchKey(&up));
    try std.testing.expectEqualStrings("alpha", controller.widget().find_input.getValue());

    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(view.dispatchKey(&down));
    try std.testing.expectEqualStrings("beta", controller.widget().find_input.getValue());
    try std.testing.expect(view.dispatchKey(&down));
    try std.testing.expectEqualStrings("", controller.widget().find_input.getValue());
}

test "FindController: replace input history survives close/reopen" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());

    controller.widget().openReplace();
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    try controller.widget().replace_input.setValue("replacement");
    controller.widget().close();

    controller.widget().openReplace();
    try view.refresh();
    try view.renderAnsi(&out.writer);
    try controller.widget().replace_input.clear();
    var up = ui.KeyEvent{ .key = .up };
    try std.testing.expect(view.dispatchKey(&up));
    try std.testing.expectEqualStrings("replacement", controller.widget().replace_input.getValue());
}

test "FindController: findOnType and closeOnResult options" {
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
    controller.setSeedSearchStringFromSelection(.never);
    defer controller.deinit();
    try view.addOverlayWidget(controller.widget().interface());
    try controller.open(false);

    const widget = controller.widget();
    widget.setFindOnType(false);
    var alpha = ui.KeyEvent{ .key = .{ .text = "alpha" } };
    try std.testing.expect(view.dispatchKey(&alpha));
    try std.testing.expectEqual(@as(usize, 0), controller.state.matches_count);

    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(view.dispatchKey(&enter));
    try std.testing.expectEqual(@as(usize, 2), controller.state.matches_count);

    widget.setCloseOnResult(true);
    try std.testing.expect(view.dispatchKey(&enter));
    try std.testing.expect(!widget.state.is_revealed);
}

test "FindController: seedSearchStringFromSelection modes" {
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

    try editor.setCursorPosition(Position.init(1, 2));
    try controller.open(false);
    try std.testing.expectEqualStrings("alpha", controller.widget().find_input.getValue());
    controller.close();
    try controller.widget().find_input.clear();

    controller.setSeedSearchStringFromSelection(.selection);
    try editor.setCursorPosition(Position.init(1, 2));
    try controller.open(false);
    try std.testing.expectEqualStrings("", controller.widget().find_input.getValue());
    controller.close();
    try controller.widget().find_input.clear();

    controller.setSeedSearchStringFromSelection(.never);
    try editor.setSelection(Range.init(1, 1, 1, 6));
    try controller.open(false);
    try std.testing.expectEqualStrings("", controller.widget().find_input.getValue());
    controller.close();
    try controller.widget().find_input.clear();

    controller.setSeedSearchStringFromSelection(.always);
    try editor.setSelection(Range.init(1, 1, 1, 6));
    try controller.open(false);
    try std.testing.expectEqualStrings("alpha", controller.widget().find_input.getValue());
}
