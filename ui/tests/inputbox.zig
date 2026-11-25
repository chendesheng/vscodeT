const std = @import("std");
const ui = @import("ui");
const cell = ui.cell;
const style_mod = ui.style;
const Allocator = std.mem.Allocator;
const Color = style_mod.Color;
const event_mod = ui.event;
const Key = event_mod.Key;
const KeyEvent = event_mod.KeyEvent;
const Modifiers = event_mod.Modifiers;
const MouseEvent = event_mod.MouseEvent;
const InputBox = ui.inputbox.InputBox;

const Surface = ui.surface.Surface;

fn keyEvent(key: Key, mods: Modifiers) KeyEvent {
    return .{ .key = key, .mods = mods };
}

fn renderRow(surface: *Surface, input: *InputBox, allocator: Allocator, width: usize) ![]u8 {
    const root = try input.build(surface.document(), width);
    surface.document().setRoot(root);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});
    return surface.grid().rowText(allocator, 0);
}

fn expectRow(
    surface: *Surface,
    input: *InputBox,
    allocator: Allocator,
    width: usize,
    expected: []const u8,
) !void {
    const row = try renderRow(surface, input, allocator, width);
    defer allocator.free(row);
    try std.testing.expectEqualStrings(expected, row);
}

fn testWideWidth(cp: u21) u2 {
    return if (cp == '何') 2 else 1;
}

test "InputBox: typing, deleting and moving the caret" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;

    var changes: usize = 0;
    const Hooks = struct {
        fn onChange(context: ?*anyopaque, value: []const u8) void {
            _ = value;
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    input.callback_context = &changes;
    input.on_change = Hooks.onChange;

    var event = KeyEvent{ .key = .{ .text = "abc" } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
    try std.testing.expectEqual(@as(usize, 3), input.cursor);
    try std.testing.expectEqual(@as(usize, 1), changes);

    event = .{ .key = .backspace };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ab", input.getValue());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);

    event = .{ .key = .home };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    event = .{ .key = .delete };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("b", input.getValue());

    event = .{ .key = .{ .char = 'x' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("xb", input.getValue());
    try std.testing.expectEqual(@as(usize, 4), changes);

    // Up/down and Tab are left for the widget that hosts the box.
    event = .{ .key = .up };
    try std.testing.expect(!input.handleKey(&event));
    event = .{ .key = .tab };
    try std.testing.expect(!input.handleKey(&event));
}

test "InputBox: selection-aware insertion and deletion" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hello");

    input.select(.{ .start = 4, .end = 1 });
    const selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 1), selection.start);
    try std.testing.expectEqual(@as(usize, 4), selection.end);

    var event = KeyEvent{ .key = .{ .char = 'X' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("hXo", input.getValue());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
    try std.testing.expectEqual(@as(usize, 2), input.anchor);

    event = .{ .key = .backspace };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ho", input.getValue());

    input.select(.{ .start = 0, .end = 1 });
    event = .{ .key = .delete };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("o", input.getValue());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "InputBox: shift navigation and select all" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abc");
    try std.testing.expect(input.isSelectionAtEnd());

    var event = keyEvent(.left, .{ .shift = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
    var selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 2), selection.start);
    try std.testing.expectEqual(@as(usize, 3), selection.end);
    try std.testing.expect(!input.isSelectionAtEnd());

    // A plain arrow collapses the selection to its start.
    event = keyEvent(.left, .{});
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
    try std.testing.expectEqual(@as(usize, 2), input.anchor);

    event = keyEvent(.home, .{ .shift = true });
    try std.testing.expect(input.handleKey(&event));
    selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 0), selection.start);
    try std.testing.expectEqual(@as(usize, 2), selection.end);

    event = keyEvent(.{ .char = 'a' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 0), input.anchor);
    try std.testing.expectEqual(@as(usize, 3), input.cursor);
    // Select-all is a range, not a collapsed selection at the end.
    try std.testing.expect(!input.isSelectionAtEnd());
    selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 0), selection.start);
    try std.testing.expectEqual(@as(usize, 3), selection.end);
}

test "InputBox: word navigation and deletion" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("alpha beta gamma");

    var event = keyEvent(.left, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 11), input.cursor);

    event = keyEvent(.left, .{ .ctrl = true, .shift = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 11), input.anchor);
    try std.testing.expectEqual(@as(usize, 6), input.cursor);

    event = keyEvent(.backspace, .{});
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("alpha gamma", input.getValue());
    try std.testing.expectEqual(@as(usize, 6), input.cursor);

    event = keyEvent(.backspace, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("gamma", input.getValue());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    // Alt-left is another common terminal word chord.
    try input.setValue("a何b");
    event = keyEvent(.left, .{ .alt = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
    event = keyEvent(.right, .{ .alt = true, .shift = true });
    try std.testing.expect(input.handleKey(&event));
    const selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 0), selection.start);
    try std.testing.expectEqual(@as(usize, 5), selection.end);
}

test "InputBox: selection paints the selected run and hides the caret" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hello");
    input.select(.{ .start = 1, .end = 4 });

    const row = try renderRow(&surface, &input, allocator, 10);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hello", row);

    const grid = surface.grid();
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 0)] & cell.Attr.inverse);
    try std.testing.expect(grid.attrs[grid.index(1, 0)] & cell.Attr.inverse != 0);
    try std.testing.expect(grid.attrs[grid.index(2, 0)] & cell.Attr.inverse != 0);
    try std.testing.expect(grid.attrs[grid.index(3, 0)] & cell.Attr.inverse != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(4, 0)] & cell.Attr.inverse);

    // A configured background replaces reverse video.
    const selected_bg = Color{ .r = 20, .g = 40, .b = 80 };
    input.selection_background = selected_bg;
    input.selection_foreground = Color{ .r = 240, .g = 240, .b = 240 };
    const painted = try renderRow(&surface, &input, allocator, 10);
    defer allocator.free(painted);
    const painted_grid = surface.grid();
    try std.testing.expectEqual(
        cell.packColor(selected_bg),
        painted_grid.bg[painted_grid.index(1, 0)],
    );
    try std.testing.expectEqual(@as(u16, 0), painted_grid.attrs[painted_grid.index(1, 0)] & cell.Attr.inverse);
}

test "InputBox: selection covers both cells of a wide character" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{
        .cols = 10,
        .rows = 1,
        .measure_width = testWideWidth,
    });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("a何b");
    input.select(.{ .start = 1, .end = 4 });

    const row = try renderRow(&surface, &input, allocator, 10);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("a何b", row);

    const grid = surface.grid();
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 0)] & cell.Attr.inverse);
    try std.testing.expect(grid.attrs[grid.index(1, 0)] & cell.Attr.inverse != 0);
    try std.testing.expect(grid.attrs[grid.index(2, 0)] & cell.Attr.inverse != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(3, 0)] & cell.Attr.inverse);
}

test "InputBox: build paints the caret glyph at and within the value" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hi");

    try expectRow(&surface, &input, allocator, 10, "hi│");
    var left = keyEvent(.left, .{});
    try std.testing.expect(input.handleKey(&left));
    try expectRow(&surface, &input, allocator, 10, "h│i");
    try std.testing.expectEqualStrings("hi", input.getValue());

    // The input text keeps the browser's I-beam cursor.
    try std.testing.expectEqual(style_mod.Pointer.text, (try surface.pointerAt(0, 0)).?);
}

test "InputBox: placeholder can show while focused" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 16, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.placeholder = "Search files";
    input.placeholder_when_focused = true;
    input.focused = true;

    const row = try renderRow(&surface, &input, allocator, 16);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("│Search files", row);
}

test "InputBox: placeholder shows while empty and unfocused" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 12, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.placeholder = "Find";

    const row = try renderRow(&surface, &input, allocator, 12);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("Find", row);

    input.focused = true;
    try expectRow(&surface, &input, allocator, 12, "│");
}

test "InputBox: a long value scrolls to keep the caret visible" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 5, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abcdefghij");

    const row = try renderRow(&surface, &input, allocator, 5);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("ghij│", row);
}

test "InputBox: caret-follow scrolls past a wide character when needed" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 2, .rows = 1, .measure_width = testWideWidth });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("何");

    try expectRow(&surface, &input, allocator, 2, "│");
}

test "InputBox: horizontal scrolling and wheel input" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 5, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abcdefghij");

    try expectRow(&surface, &input, allocator, 5, "ghij│");

    // Manual scrolling keeps the window where the host put it.
    try std.testing.expect(input.scrollBy(surface.document(), -3));
    try expectRow(&surface, &input, allocator, 5, "defgh");

    // A horizontal wheel moves it back to the caret end.
    var wheel = MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_x = 3 };
    try std.testing.expect(input.handleMouse(&wheel));
    try expectRow(&surface, &input, allocator, 5, "ghij│");

    // Clamping at both ends.
    try std.testing.expect(input.scrollBy(surface.document(), -100));
    try std.testing.expect(!input.scrollBy(surface.document(), -1));
    try std.testing.expect(input.scrollBy(surface.document(), 100));
    try std.testing.expect(!input.scrollBy(surface.document(), 1));

    // Typing re-arms caret following.
    try std.testing.expect(input.scrollBy(surface.document(), -3));
    var event = KeyEvent{ .key = .{ .char = 'X' } };
    try std.testing.expect(input.handleKey(&event));
    try expectRow(&surface, &input, allocator, 5, "hijX│");
}

test "InputBox: clicking maps a cell to the byte caret" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{
        .cols = 10,
        .rows = 1,
        .measure_width = testWideWidth,
    });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("a何b");
    input.select(.{ .start = 1, .end = 1 });
    try expectRow(&surface, &input, allocator, 10, "a│何b");

    var click = MouseEvent{ .kind = .down, .x = 3, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&click));
    // The second cell is the boundary after the wide character.
    try std.testing.expectEqual(@as(usize, 4), input.cursor);

    click.x = 2;
    _ = input.handleMouse(&click);
    // The left half of the wide character puts the caret before it.
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    click.x = 1;
    try std.testing.expect(input.handleMouse(&click));
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    click.x = 0;
    _ = input.handleMouse(&click);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    // Held-button motion moves the caret too.
    var drag = MouseEvent{ .kind = .move, .x = 5, .y = 0, .button = .left };
    _ = input.handleMouse(&drag);
    try std.testing.expectEqual(@as(usize, 5), input.cursor);

    // Another button is not a text caret gesture.
    var right = MouseEvent{ .kind = .down, .x = 1, .y = 0, .button = .right };
    try std.testing.expect(!input.handleMouse(&right));
    try std.testing.expectEqual(@as(usize, 5), input.cursor);
}

test "InputBox: dragging selects and extends the selection" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abcd");
    const initial = try renderRow(&surface, &input, allocator, 10);
    allocator.free(initial);

    var down = MouseEvent{ .kind = .down, .x = 1, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&down));
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
    try std.testing.expectEqual(@as(usize, 1), input.anchor);

    var drag = MouseEvent{ .kind = .move, .x = 3, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&drag));
    try std.testing.expectEqual(@as(usize, 1), input.anchor);
    try std.testing.expectEqual(@as(usize, 3), input.cursor);
    const selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 1), selection.start);
    try std.testing.expectEqual(@as(usize, 3), selection.end);

    // Shift-click moves the focus end and keeps the anchor.
    var shift = MouseEvent{
        .kind = .down,
        .x = 0,
        .y = 0,
        .button = .left,
        .mods = .{ .shift = true },
    };
    try std.testing.expect(input.handleMouse(&shift));
    try std.testing.expectEqual(@as(usize, 1), input.anchor);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "InputBox: dragging past the edge autoscrolls" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 3, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abcdef");
    input.select(.{ .start = 0, .end = 0 });

    try expectRow(&surface, &input, allocator, 3, "│ab");

    var down = MouseEvent{ .kind = .down, .x = 0, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&down));
    var drag = MouseEvent{ .kind = .move, .x = 5, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&drag));
    try std.testing.expect(input.view_start > 0);
    try std.testing.expectEqual(@as(usize, 0), input.anchor);
    try std.testing.expect(input.cursor > 0);

    // The left edge autoscrolls when the pointer leaves the box. Put the
    // input inside a wrapper so the pointer can be left of its rect.
    const doc = surface.document();
    const wrapper = try doc.createElement(.div);
    wrapper.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    });
    input.view_start = 3;
    input.follow_caret = false;
    input.anchor = 3;
    input.cursor = 3;
    const root = try input.build(doc, 3);
    _ = try wrapper.appendChild(root);
    doc.setRoot(wrapper);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    var left = MouseEvent{ .kind = .move, .x = 0, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&left));
    try std.testing.expectEqual(@as(usize, 2), input.view_start);
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
}

test "InputBox: clipboard hooks copy, cut and paste" {
    const allocator = std.testing.allocator;
    const Clipboard = struct {
        const Self = @This();

        copied: [32]u8 = undefined,
        copied_len: usize = 0,
        paste_text: []const u8 = "",

        fn copy(context: ?*anyopaque, text: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const length = @min(text.len, self.copied.len);
            @memcpy(self.copied[0..length], text[0..length]);
            self.copied_len = length;
        }

        fn paste(context: ?*anyopaque) ?[]const u8 {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.paste_text;
        }
    };

    var clipboard = Clipboard{};
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    input.callback_context = &clipboard;
    input.on_copy = Clipboard.copy;
    input.on_paste = Clipboard.paste;
    try input.setValue("hello");
    input.select(.{ .start = 1, .end = 4 });

    var event = keyEvent(.{ .char = 'c' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ell", clipboard.copied[0..clipboard.copied_len]);
    try std.testing.expectEqualStrings("hello", input.getValue());

    event = keyEvent(.{ .char = 'x' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ho", input.getValue());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    clipboard.paste_text = "YZ";
    event = keyEvent(.{ .char = 'v' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("hYZo", input.getValue());
    try std.testing.expectEqual(@as(usize, 3), input.cursor);

    // Pasted control characters are filtered.
    clipboard.paste_text = "a\nb";
    event = keyEvent(.{ .char = 'v' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("hYZabo", input.getValue());
}

test "InputBox: clipboard chords without hooks are safe no-ops" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abc");
    input.select(.{ .start = 0, .end = 2 });

    var event = keyEvent(.{ .char = 'x' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());

    event = keyEvent(.{ .char = 'v' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
}

test "InputBox: undo and redo" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;

    var event = KeyEvent{ .key = .{ .char = 'a' } };
    try std.testing.expect(input.handleKey(&event));
    event = .{ .key = .{ .char = 'b' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ab", input.getValue());

    // Consecutive typing is one undo group.
    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("", input.getValue());

    event = keyEvent(.{ .char = 'y' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ab", input.getValue());

    // A new edit clears the redo stack.
    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    event = .{ .key = .{ .char = 'c' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("c", input.getValue());
    event = keyEvent(.{ .char = 'y' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("c", input.getValue());

    // A caret move separates typing groups.
    try input.setValue("");
    event = .{ .key = .{ .char = 'a' } };
    try std.testing.expect(input.handleKey(&event));
    event = .{ .key = .{ .char = 'b' } };
    try std.testing.expect(input.handleKey(&event));
    event = .{ .key = .left };
    try std.testing.expect(input.handleKey(&event));
    event = .{ .key = .{ .char = 'X' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("aXb", input.getValue());

    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ab", input.getValue());
    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("", input.getValue());

    // Undo restores the selection that was replaced.
    try input.setValue("abc");
    input.select(.{ .start = 1, .end = 2 });
    event = .{ .key = .backspace };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ac", input.getValue());
    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
    const selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 1), selection.start);
    try std.testing.expectEqual(@as(usize, 2), selection.end);

    // setValue resets the history.
    try input.setValue("z");
    event = keyEvent(.{ .char = 'z' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("z", input.getValue());
}

test "InputBox: setValue sanitizes and is idempotent" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;

    var changes: usize = 0;
    const Hooks = struct {
        fn onChange(context: ?*anyopaque, value: []const u8) void {
            _ = value;
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    input.callback_context = &changes;
    input.on_change = Hooks.onChange;

    try input.setValue("a\nb\tc\x7f");
    try std.testing.expectEqualStrings("abc", input.getValue());
    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqual(@as(usize, 3), input.cursor);

    // Setting the same sanitized value leaves the caret and callback alone.
    var event = KeyEvent{ .key = .home };
    try std.testing.expect(input.handleKey(&event));
    try input.setValue("abc");
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
    try std.testing.expectEqual(@as(usize, 1), changes);
}

test "InputBox: insertAtCursor replaces the selection" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hello");
    input.select(.{ .start = 1, .end = 3 });

    try input.insertAtCursor("XY");
    try std.testing.expectEqualStrings("hXYlo", input.getValue());
    try std.testing.expectEqual(@as(usize, 3), input.cursor);
    try std.testing.expectEqual(@as(usize, 3), input.anchor);

    // Control-only text is a no-op.
    try input.insertAtCursor("\n\t");
    try std.testing.expectEqualStrings("hXYlo", input.getValue());
}

test "InputBox: disabled boxes reject keys and paint dim" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 6, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hi");
    input.disable();
    try std.testing.expect(!input.focused);

    // Even if the host leaves the flag set, a disabled box ignores keys.
    input.focused = true;
    var event = KeyEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(!input.handleKey(&event));
    try std.testing.expectEqualStrings("hi", input.getValue());

    const row = try renderRow(&surface, &input, allocator, 6);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hi", row);
    const grid = surface.grid();
    try std.testing.expect(grid.attrs[grid.index(0, 0)] & cell.Attr.dim != 0);

    input.enable();
    input.focused = true;
    event = .{ .key = .{ .char = 'x' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("hix", input.getValue());
}

test "InputBox: paste filters control characters and enter/escape callbacks run" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;

    var changes: usize = 0;
    var enters: usize = 0;
    var escapes: usize = 0;
    const Hooks = struct {
        fn onChange(context: ?*anyopaque, value: []const u8) void {
            _ = value;
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
        fn onEnter(context: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    input.callback_context = &changes;
    input.on_change = Hooks.onChange;

    var event = KeyEvent{ .key = .{ .text = "a\nb\tc" } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
    try std.testing.expectEqual(@as(usize, 1), changes);

    event = .{ .key = .{ .text = "\x01\x02" } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
    try std.testing.expectEqual(@as(usize, 1), changes);

    input.callback_context = &enters;
    input.on_enter = Hooks.onEnter;
    event = .{ .key = .enter };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 1), enters);

    input.callback_context = &escapes;
    input.on_escape = Hooks.onEnter;
    event = .{ .key = .escape };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 1), escapes);
}

test "InputBox: document dispatch reaches the built listeners" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abc");

    const root = try input.build(surface.document(), 10);
    surface.document().setRoot(root);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    // Keys go to the active element or the root fallback.
    _ = surface.document().dispatchKey(.{ .char = 'a' }, .{ .ctrl = true });
    const selection = input.getSelection().?;
    try std.testing.expectEqual(@as(usize, 0), selection.start);
    try std.testing.expectEqual(@as(usize, 3), selection.end);

    // The wheel listener consumes a horizontal wheel.
    var wheel = MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_x = 1 };
    surface.document().dispatchMouse(root, &wheel);
    try std.testing.expect(wheel.default_prevented);
    try std.testing.expect(input.view_start > 0);

    _ = surface.document().dispatchKey(.backspace, .{});
    try std.testing.expectEqualStrings("", input.getValue());
}

test "InputBox: unknown ctrl/alt chords are consumed without editing" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abc");

    var event = keyEvent(.{ .char = 'q' }, .{ .ctrl = true });
    try std.testing.expect(input.handleKey(&event));
    event = keyEvent(.{ .char = 'q' }, .{ .alt = true });
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());

    // Up/down stay available to the host for list/history navigation.
    event = .{ .key = .up };
    try std.testing.expect(!input.handleKey(&event));
    event = .{ .key = .page_down };
    try std.testing.expect(!input.handleKey(&event));
}

test "InputBox: document focus syncs the flag and a cleared document is safe" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();

    const doc = surface.document();
    const node = try input.build(doc, 10);
    doc.setRoot(node);
    try std.testing.expect(doc.focus(node));
    try std.testing.expect(input.focused);

    // Moving DOM focus away fires blur and clears the flag, so keys no longer
    // reach the box even when the host forgot to write `focused` itself.
    const other = try doc.createElement(.div);
    other.asElement().focusable = true;
    _ = try node.appendChild(other);
    try std.testing.expect(doc.focus(other));
    try std.testing.expect(!input.focused);
    var event = KeyEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(!input.handleKey(&event));

    try std.testing.expect(doc.focus(node));
    input.disable();
    try std.testing.expect(doc.focusedElement() == null);
    try std.testing.expect(!node.focus());
    _ = doc.dispatchKey(.tab, .{});
    try std.testing.expectEqual(other, doc.focusedElement().?);
    input.enable();
    _ = doc.dispatchKey(.backtab, .{});
    try std.testing.expectEqual(node, doc.focusedElement().?);
    try std.testing.expect(input.focused);

    // `clear` invalidates the arena; disable must not dereference the old node.
    doc.clear();
    input.disable();
    try std.testing.expect(!input.focused);

    // A rebuilt node participates again.
    input.enable();
    const rebuilt = try input.build(doc, 10);
    doc.setRoot(rebuilt);
    try std.testing.expect(doc.focus(rebuilt));
    try std.testing.expect(input.focused);
}
