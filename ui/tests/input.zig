const std = @import("std");
const ui = @import("ui");
const MouseEvent = ui.input.MouseEvent;
const Key = ui.input.Key;
const Modifiers = ui.event.Modifiers;
const MouseButton = ui.input.MouseButton;
const MouseKind = ui.input.MouseKind;
const Item = ui.input.Item;
const decode = ui.input.decode;
const decodeWithRemainder = ui.input.decodeWithRemainder;
const decodeKeys = ui.input.decodeKeys;

test "input: printable runs and control keys" {
    const allocator = std.testing.allocator;
    var events = try decodeKeys(allocator, "q");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("q", events.items[0].key.text);
    try std.testing.expect(!events.items[0].mods.ctrl);

    var ctrl_q = try decodeKeys(allocator, "\x11");
    defer ctrl_q.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_q.items.len);
    try std.testing.expectEqual(@as(u21, 'q'), ctrl_q.items[0].key.char);
    try std.testing.expect(ctrl_q.items[0].mods.ctrl);
}

test "input: named keys and modifiers" {
    const allocator = std.testing.allocator;
    var events = try decodeKeys(allocator, "\x1b[A\x1b[3~\x1b[1;5C\x1b[5~\x1b[Z\x1b[24~\x1b[18~\x1b[18;2~");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), events.items.len);
    try std.testing.expect(events.items[0].key == .up);
    try std.testing.expect(events.items[1].key == .delete);
    try std.testing.expect(events.items[2].key == .right);
    try std.testing.expect(events.items[2].mods.ctrl);
    try std.testing.expect(events.items[3].key == .page_up);
    try std.testing.expect(events.items[4].key == .backtab);
    try std.testing.expect(events.items[5].key == .f12);
    try std.testing.expect(events.items[6].key == .f7);
    try std.testing.expect(events.items[7].key == .f7 and events.items[7].mods.shift);
    for ([_]usize{ 1, 3, 5 }) |i| try std.testing.expectEqual(Modifiers{}, events.items[i].mods);
}

test "input: Shift+Tab moves focus backward and Alt+Shift+Z keeps focus" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const first = try root.appendChild(try doc.createElement(.div));
    const second = try root.appendChild(try doc.createElement(.div));
    first.asElement().focusable = true;
    second.asElement().focusable = true;
    try std.testing.expect(second.focus());

    var keys = try decodeKeys(allocator, "\x1b[Z\x1bZ");
    defer keys.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), keys.items.len);
    try std.testing.expect(keys.items[0].key == .backtab);
    doc.dispatchEvent(&keys.items[0]);
    try std.testing.expectEqual(first, doc.focusedElement().?);

    doc.dispatchEvent(&keys.items[1]);
    try std.testing.expectEqual(first, doc.focusedElement().?);
    try std.testing.expect(keys.items[1].key == .char);
    try std.testing.expectEqual(@as(u21, 'Z'), keys.items[1].key.char);
    try std.testing.expect(keys.items[1].mods.alt);
}

test "input: comment shortcuts and alt characters" {
    const allocator = std.testing.allocator;

    var ctrl_slash = try decodeKeys(allocator, "\x1f");
    defer ctrl_slash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), ctrl_slash.items[0].key.char);
    try std.testing.expect(ctrl_slash.items[0].mods.ctrl);

    var alt_slash = try decodeKeys(allocator, "\x1b/");
    defer alt_slash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alt_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), alt_slash.items[0].key.char);
    try std.testing.expect(alt_slash.items[0].mods.alt);

    var ctrl_d = try decodeKeys(allocator, "\x04");
    defer ctrl_d.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'd'), ctrl_d.items[0].key.char);
    try std.testing.expect(ctrl_d.items[0].mods.ctrl);

    var ctrl_bracket = try decodeKeys(allocator, "\x1d");
    defer ctrl_bracket.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_bracket.items.len);
    try std.testing.expectEqual(@as(u21, ']'), ctrl_bracket.items[0].key.char);
    try std.testing.expect(ctrl_bracket.items[0].mods.ctrl);

    var ctrl_backslash = try decodeKeys(allocator, "\x1c");
    defer ctrl_backslash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_backslash.items.len);
    try std.testing.expectEqual(@as(u21, '\\'), ctrl_backslash.items[0].key.char);
    try std.testing.expect(ctrl_backslash.items[0].mods.ctrl);
}

test "input: bracketed paste" {
    const allocator = std.testing.allocator;
    var events = try decodeKeys(allocator, "\x1b[200~hello\x1b[201~");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].key == .paste_start);
    try std.testing.expectEqualStrings("hello", events.items[1].key.text);
    try std.testing.expect(events.items[2].key == .paste_end);
}

test "input: terminal DCS and OSC replies are ignored" {
    const allocator = std.testing.allocator;
    // The cell-border capability answer plus DA1 must never surface as keys,
    // and text after them must still decode.
    var events = try decodeKeys(
        allocator,
        "\x1bP1+bcell-border;ok;1;pen,rect\x1b\\\x1b[?62;22ca",
    );
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("a", events.items[0].key.text);

    var osc = try decodeKeys(allocator, "\x1b]11;rgb:0000/0000/0000\x07b");
    defer osc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), osc.items.len);
    try std.testing.expectEqualStrings("b", osc.items[0].key.text);
}

test "input: kitty graphics APC replies are ignored" {
    const allocator = std.testing.allocator;
    // Both probe replies arrive as APC strings and must not become keys.
    var events = try decodeKeys(
        allocator,
        "\x1b_Gi=31;OK\x1b\\\x1b_Gi=32,e=T,U=1;OK\x1b\\\x1b[?62;22cc",
    );
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("c", events.items[0].key.text);
}

test "input: DCS filtering does not swallow Alt-Shift-P or Alt-]" {
    const allocator = std.testing.allocator;
    var alt_p = try decodeKeys(allocator, "\x1bP");
    defer alt_p.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alt_p.items.len);
    try std.testing.expectEqual(@as(u21, 'P'), alt_p.items[0].key.char);
    try std.testing.expect(alt_p.items[0].mods.alt);

    var alt_bracket = try decodeKeys(allocator, "\x1b]");
    defer alt_bracket.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alt_bracket.items.len);
    try std.testing.expectEqual(@as(u21, ']'), alt_bracket.items[0].key.char);
    try std.testing.expect(alt_bracket.items[0].mods.alt);
}

test "input: utf-8 text runs and lone escape" {
    const allocator = std.testing.allocator;
    var events = try decodeKeys(allocator, "héllo\x1b");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("héllo", events.items[0].key.text);
    try std.testing.expect(events.items[1].key == .escape);
}

test "input: shifted tab and control bytes" {
    const allocator = std.testing.allocator;
    var events = try decodeKeys(allocator, "\t\r\x7f");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].key == .tab);
    try std.testing.expect(events.items[1].key == .enter);
    try std.testing.expect(events.items[2].key == .backspace);
}

// Regression: Ctrl-F used to be dropped, so the app never saw it (0x06).
test "input: every Ctrl-letter is decoded, Ctrl-H stays backspace" {
    const allocator = std.testing.allocator;

    var ctrl_f = try decodeKeys(allocator, "\x06");
    defer ctrl_f.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_f.items.len);
    try std.testing.expectEqual(@as(u21, 'f'), ctrl_f.items[0].key.char);
    try std.testing.expect(ctrl_f.items[0].mods.ctrl);

    var ctrl_r = try decodeKeys(allocator, "\x12");
    defer ctrl_r.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'r'), ctrl_r.items[0].key.char);
    try std.testing.expect(ctrl_r.items[0].mods.ctrl);

    var ctrl_g = try decodeKeys(allocator, "\x07");
    defer ctrl_g.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'g'), ctrl_g.items[0].key.char);

    // 0x08 is Backspace, not Ctrl-H: terminals cannot distinguish them.
    var ctrl_h = try decodeKeys(allocator, "\x08");
    defer ctrl_h.deinit(allocator);
    try std.testing.expectEqual(Key.backspace, ctrl_h.items[0].key);
    try std.testing.expect(!ctrl_h.items[0].mods.ctrl);
}

fn mouseAt(items: []const Item, index: usize) !MouseEvent {
    if (index >= items.len) return error.TestUnexpectedResult;
    return switch (items[index]) {
        .mouse => |mouse| mouse,
        .key, .focus => error.TestUnexpectedResult,
    };
}

test "input: SGR mouse presses, releases and buttons" {
    const allocator = std.testing.allocator;

    var press = try decode(allocator, "\x1b[<0;10;5M");
    defer press.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), press.items.len);
    const left = try mouseAt(press.items, 0);
    try std.testing.expectEqual(MouseKind.down, left.kind);
    try std.testing.expectEqual(MouseButton.left, left.button);
    try std.testing.expectEqual(@as(usize, 9), left.x);
    try std.testing.expectEqual(@as(usize, 4), left.y);

    var middle = try decode(allocator, "\x1b[<1;1;1M");
    defer middle.deinit(allocator);
    try std.testing.expectEqual(MouseButton.middle, (try mouseAt(middle.items, 0)).button);

    var release = try decode(allocator, "\x1b[<2;3;4m");
    defer release.deinit(allocator);
    const right = try mouseAt(release.items, 0);
    try std.testing.expectEqual(MouseKind.up, right.kind);
    try std.testing.expectEqual(MouseButton.right, right.button);
    try std.testing.expectEqual(@as(usize, 2), right.x);
    try std.testing.expectEqual(@as(usize, 3), right.y);
}

test "input: SGR mouse motion and modifiers" {
    const allocator = std.testing.allocator;

    var motion = try decode(allocator, "\x1b[<32;4;2M");
    defer motion.deinit(allocator);
    const dragged = try mouseAt(motion.items, 0);
    try std.testing.expectEqual(MouseKind.move, dragged.kind);
    try std.testing.expectEqual(MouseButton.left, dragged.button);

    // Mode 1003 idle motion reports no held button.
    var idle = try decode(allocator, "\x1b[<35;6;2M");
    defer idle.deinit(allocator);
    const hover = try mouseAt(idle.items, 0);
    try std.testing.expectEqual(MouseKind.move, hover.kind);
    try std.testing.expectEqual(MouseButton.none, hover.button);

    // shift (4) + alt (8) + ctrl (16) on a left press.
    var modified = try decode(allocator, "\x1b[<28;2;2M");
    defer modified.deinit(allocator);
    const mods = (try mouseAt(modified.items, 0)).mods;
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.alt);
    try std.testing.expect(mods.ctrl);
}

test "input: split SGR mouse reports leave an incomplete remainder" {
    const allocator = std.testing.allocator;

    var first = try decodeWithRemainder(allocator, "\x1b[<35;18;15");
    defer first.items.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), first.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.consumed);

    var text_first = try decodeWithRemainder(allocator, "a\x1b[<35;18");
    defer text_first.items.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), text_first.items.items.len);
    try std.testing.expectEqualStrings("a", text_first.items.items[0].key.key.text);
    try std.testing.expectEqual(@as(usize, 1), text_first.consumed);

    var complete = try decodeWithRemainder(allocator, "\x1b[<35;18;15M\x1b[<35;16;11M");
    defer complete.items.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), complete.items.items.len);
    try std.testing.expectEqual(@as(usize, 24), complete.consumed);
    try std.testing.expectEqual(MouseKind.move, complete.items.items[0].mouse.kind);
    try std.testing.expectEqual(@as(usize, 17), complete.items.items[0].mouse.x);
    try std.testing.expectEqual(@as(usize, 14), complete.items.items[0].mouse.y);
}

test "input: SGR wheel reports in lines" {
    const allocator = std.testing.allocator;

    var down = try decode(allocator, "\x1b[<65;5;3M");
    defer down.deinit(allocator);
    const wheel_down = try mouseAt(down.items, 0);
    try std.testing.expectEqual(MouseKind.wheel, wheel_down.kind);
    try std.testing.expectEqual(@as(i32, 3), wheel_down.delta_y);
    try std.testing.expectEqual(@as(i32, 0), wheel_down.delta_x);

    var up = try decode(allocator, "\x1b[<64;5;3M");
    defer up.deinit(allocator);
    try std.testing.expectEqual(@as(i32, -3), (try mouseAt(up.items, 0)).delta_y);

    // Shift+wheel turns the vertical notch sideways, as in a browser.
    var shifted = try decode(allocator, "\x1b[<69;5;3M");
    defer shifted.deinit(allocator);
    const sideways = try mouseAt(shifted.items, 0);
    try std.testing.expectEqual(@as(i32, 0), sideways.delta_y);
    try std.testing.expectEqual(@as(i32, 3), sideways.delta_x);

    var left = try decode(allocator, "\x1b[<67;5;3M");
    defer left.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 3), (try mouseAt(left.items, 0)).delta_x);
}

test "input: malformed mouse reports are ignored and never type text" {
    const allocator = std.testing.allocator;

    var malformed = try decode(allocator, "\x1b[<0;1M\x1b[<0;1;1;2M\x1b[<65;1;1m");
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), malformed.items.len);

    // A report glued between keystrokes keeps its place and produces no text.
    var mixed = try decode(allocator, "a\x1b[<0;2;3Mb");
    defer mixed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), mixed.items.len);
    const first_key = switch (mixed.items[0]) {
        .key => |key| key,
        .mouse, .focus => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("a", first_key.key.text);
    const mouse = try mouseAt(mixed.items, 1);
    try std.testing.expectEqual(@as(usize, 1), mouse.x);
    try std.testing.expectEqual(@as(usize, 2), mouse.y);
    const second_key = switch (mixed.items[2]) {
        .key => |key| key,
        .mouse, .focus => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("b", second_key.key.text);
}

test "input decodes terminal focus reports as focus events" {
    var items = try decode(std.testing.allocator, "\x1b[I\x1b[O");
    defer items.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expect(items.items[0].focus);
    try std.testing.expect(!items.items[1].focus);
}
