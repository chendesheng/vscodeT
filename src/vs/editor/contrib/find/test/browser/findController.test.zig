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
