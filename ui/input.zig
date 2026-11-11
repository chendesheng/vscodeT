//! Terminal byte stream -> keyboard and mouse events.
//!
//! The decoder turns the ANSI escape sequences a terminal sends into the
//! semantic `Key` values in `event.zig`: printable runs, control bytes, cursor
//! and editing keys, and bracketed paste boundaries. SGR mouse reports
//! (`CSI < b ; x ; y M/m`, mode 1006) become `MouseEvent`s with zero-based cell
//! coordinates and wheel deltas in lines. Text runs borrow from the input
//! buffer, so dispatch an event before reusing that buffer.
//!
//! Terminals report key presses, not releases or repeats, so every key event
//! here is a `key_down`. Extended keyboard reports (CSI u / kitty) are not
//! enabled; the sequences handled are what a normal xterm-compatible terminal
//! sends.

const std = @import("std");
const event = @import("event.zig");

pub const KeyEvent = event.KeyEvent;
pub const MouseEvent = event.MouseEvent;
pub const Key = event.Key;
pub const MouseButton = event.MouseButton;
pub const MouseKind = event.MouseKind;
pub const Modifiers = event.Modifiers;

/// One decoded terminal event, in arrival order.
pub const Item = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
};

pub fn decode(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Item) {
    var tokens = try tokenize(allocator, input);
    defer tokens.deinit(allocator);

    var result: std.ArrayList(Item) = .empty;
    errdefer result.deinit(allocator);

    for (tokens.items) |token| {
        switch (token) {
            .string => |text| try decodeString(allocator, &result, text),
            .csi => |csi| try decodeCsi(allocator, &result, csi),
        }
    }
    return result;
}

/// Decodes the keyboard events in `input`, dropping mouse reports. Keyboard-only
/// hosts and tests use this; the app uses `decode` for the full stream.
pub fn decodeKeys(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(KeyEvent) {
    var items = try decode(allocator, input);
    defer items.deinit(allocator);

    var result: std.ArrayList(KeyEvent) = .empty;
    errdefer result.deinit(allocator);
    for (items.items) |item| {
        switch (item) {
            .key => |key_event| try result.append(allocator, key_event),
            .mouse => {},
        }
    }
    return result;
}

fn decodeString(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(Item),
    text: []const u8,
) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch >= 0x20 and ch != 0x7f) {
            i += 1;
            continue;
        }

        if (run_start < i) {
            try result.append(allocator, .{ .key = .{ .key = .{ .text = text[run_start..i] } } });
        }
        run_start = i + 1;

        const control: ?struct { key: Key, mods: Modifiers = .{} } = switch (ch) {
            0x7f => .{ .key = .backspace },
            0x08 => .{ .key = .backspace },
            '\r', '\n' => .{ .key = .enter },
            '\t' => .{ .key = .tab },
            0x1b => .{ .key = .escape },
            0x00 => .{ .key = .{ .char = ' ' }, .mods = .{ .ctrl = true } },
            // Ctrl-A through Ctrl-Z are the control bytes 0x01..0x1a. The
            // exceptions above (Backspace, Tab, Enter, Escape) share a byte
            // with a letter and win, because that is what terminals send.
            0x01...0x07, 0x0b...0x0c, 0x0e...0x1a => .{
                .key = .{ .char = 'a' + (ch - 1) },
                .mods = .{ .ctrl = true },
            },
            0x1c => .{ .key = .{ .char = '\\' }, .mods = .{ .ctrl = true } },
            0x1d => .{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } },
            0x1e => .{ .key = .{ .char = '^' }, .mods = .{ .ctrl = true } },
            0x1f => .{ .key = .{ .char = '/' }, .mods = .{ .ctrl = true } },
            else => null,
        };
        if (control) |named| {
            try result.append(allocator, .{ .key = .{ .key = named.key, .mods = named.mods } });
        }
        i += 1;
    }
    if (run_start < text.len) {
        try result.append(allocator, .{ .key = .{ .key = .{ .text = text[run_start..] } } });
    }
}

const Token = union(enum) {
    string: []const u8,
    csi: Csi,

    const Csi = struct {
        parameters: []const u8,
        intermediate: []const u8,
        final: u8,
    };
};

const ESC = 0x1b;

fn isIntermediateChar(chr: u8) bool {
    return 0x20 <= chr and chr <= 0x2f;
}

fn isFinalChar(chr: u8) bool {
    return 0x40 <= chr and chr <= 0x7e;
}

fn isFinalCharForEscSequence(chr: u8) bool {
    return 0x30 <= chr and chr <= 0x7e;
}

const State = enum {
    normal,
    esc,
    esc_parameter,
    esc_parameter_intermediate,
    esc_intermediate,
    bracketed_paste,
};

fn tokenize(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Token) {
    var state: State = .normal;
    var result: std.ArrayList(Token) = .empty;
    errdefer result.deinit(allocator);

    var last_pos: usize = 0;
    var pos: usize = 0;
    var current: Token = .{ .csi = .{ .parameters = "", .intermediate = "", .final = 0 } };

    while (pos < input.len) {
        const chr = input[pos];
        switch (state) {
            .normal => {
                if (chr == ESC) {
                    if (last_pos < pos) {
                        try result.append(allocator, .{ .string = input[last_pos..pos] });
                    }
                    state = .esc;
                    last_pos = pos + 1;
                }
            },
            .esc => {
                if (chr == '[') {
                    state = .esc_parameter;
                    last_pos = pos + 1;
                } else if (chr == '/') {
                    // Terminals send `ESC /` for Alt+/; `/` is otherwise an
                    // ANSI intermediate byte.
                    current.csi = .{ .parameters = "", .intermediate = "", .final = chr };
                    try result.append(allocator, current);
                    state = .normal;
                    last_pos = pos + 1;
                } else if (isIntermediateChar(chr)) {
                    state = .esc_intermediate;
                    last_pos = pos;
                } else if (isFinalCharForEscSequence(chr)) {
                    current.csi = .{ .parameters = "", .intermediate = "", .final = chr };
                    try result.append(allocator, current);
                    state = .normal;
                    last_pos = pos + 1;
                } else {
                    state = .normal;
                }
            },
            .esc_parameter => {
                if (isIntermediateChar(chr)) {
                    current.csi.parameters = input[last_pos..pos];
                    state = .esc_parameter_intermediate;
                    last_pos = pos;
                } else if (isFinalChar(chr)) {
                    current.csi.parameters = input[last_pos..pos];
                    current.csi.intermediate = "";
                    current.csi.final = chr;
                    try result.append(allocator, current);
                    if (std.mem.eql(u8, current.csi.parameters, "200") and chr == '~') {
                        state = .bracketed_paste;
                    } else {
                        state = .normal;
                    }
                    last_pos = pos + 1;
                }
            },
            .esc_parameter_intermediate => {
                if (isFinalChar(chr)) {
                    current.csi.intermediate = input[last_pos..pos];
                    current.csi.final = chr;
                    try result.append(allocator, current);
                    state = .normal;
                }
            },
            .esc_intermediate => {
                if (isFinalCharForEscSequence(chr)) {
                    current.csi = .{
                        .parameters = "",
                        .intermediate = input[last_pos..pos],
                        .final = chr,
                    };
                    try result.append(allocator, current);
                    state = .normal;
                }
            },
            .bracketed_paste => {
                if (pos + 6 <= input.len and std.mem.eql(u8, input[pos .. pos + 6], "\x1b[201~")) {
                    if (last_pos < pos) {
                        try result.append(allocator, .{ .string = input[last_pos..pos] });
                    }
                    try result.append(allocator, .{
                        .csi = .{ .parameters = "201", .intermediate = "", .final = '~' },
                    });
                    state = .normal;
                    pos += 5;
                    last_pos = pos + 1;
                }
            },
        }
        pos += 1;
    }

    switch (state) {
        // A lone ESC has no following byte to close a sequence; report the key.
        .esc => try result.append(allocator, .{ .string = input[pos - 1 .. pos] }),
        else => {
            if (last_pos < pos) {
                try result.append(allocator, .{ .string = input[last_pos..pos] });
            }
        },
    }
    return result;
}

fn parseFirst(params: []const u8) ?usize {
    if (params.len == 0) return null;
    var it = std.mem.splitScalar(u8, params, ';');
    const first = it.next() orelse return null;
    return std.fmt.parseUnsigned(usize, first, 10) catch null;
}

fn parseLast(params: []const u8) ?usize {
    if (params.len == 0) return null;
    var last: ?usize = null;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        last = std.fmt.parseUnsigned(usize, part, 10) catch last;
    }
    return last;
}

fn parseModifiers(params: []const u8) Modifiers {
    const encoded = parseLast(params) orelse return .{};
    if (encoded < 2) return .{};
    const bits = encoded - 1;
    return .{
        .shift = (bits & 1) != 0,
        .alt = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
    };
}

fn decodeCsi(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(Item),
    csi: Token.Csi,
) !void {
    if (csi.final == 'M' or csi.final == 'm') {
        // SGR reports: `CSI < b ; x ; y M` for press/motion and the same with
        // `m` for a release. The coordinates are one-based cells.
        if (decodeMouseReport(csi)) |mouse| {
            try result.append(allocator, .{ .mouse = mouse });
        }
        return;
    }

    const mods = parseModifiers(csi.parameters);
    switch (csi.final) {
        'A' => try result.append(allocator, .{ .key = .{ .key = .up, .mods = mods } }),
        'B' => try result.append(allocator, .{ .key = .{ .key = .down, .mods = mods } }),
        'C' => try result.append(allocator, .{ .key = .{ .key = .right, .mods = mods } }),
        'D' => try result.append(allocator, .{ .key = .{ .key = .left, .mods = mods } }),
        'H' => try result.append(allocator, .{ .key = .{ .key = .home, .mods = mods } }),
        'F' => try result.append(allocator, .{ .key = .{ .key = .end, .mods = mods } }),
        'Z' => try result.append(allocator, .{ .key = .{ .key = .backtab, .mods = mods } }),
        '~' => {
            const code = parseFirst(csi.parameters) orelse 0;
            switch (code) {
                1, 7 => try result.append(allocator, .{ .key = .{ .key = .home, .mods = mods } }),
                4, 8 => try result.append(allocator, .{ .key = .{ .key = .end, .mods = mods } }),
                2 => try result.append(allocator, .{ .key = .{ .key = .insert, .mods = mods } }),
                3 => try result.append(allocator, .{ .key = .{ .key = .delete, .mods = mods } }),
                5 => try result.append(allocator, .{ .key = .{ .key = .page_up, .mods = mods } }),
                6 => try result.append(allocator, .{ .key = .{ .key = .page_down, .mods = mods } }),
                200 => try result.append(allocator, .{ .key = .{ .key = .paste_start } }),
                201 => try result.append(allocator, .{ .key = .{ .key = .paste_end } }),
                else => {},
            }
        },
        else => {
            if (csi.parameters.len == 0 and csi.intermediate.len == 0 and
                csi.final >= 0x20 and csi.final <= 0x7e)
            {
                try result.append(allocator, .{
                    .key = .{ .key = .{ .char = csi.final }, .mods = .{ .alt = true } },
                });
            }
        },
    }
}

/// Parses an SGR mouse report. Returns null for a legacy/X10 report, a
/// malformed parameter list, a wheel release, or an unknown wheel base.
fn decodeMouseReport(csi: Token.Csi) ?MouseEvent {
    if (csi.intermediate.len != 0 or csi.parameters.len < 2) return null;
    if (csi.parameters[0] != '<') return null;

    var fields: [3]usize = undefined;
    var count: usize = 0;
    var params = std.mem.splitScalar(u8, csi.parameters[1..], ';');
    while (params.next()) |field| {
        if (count == fields.len) return null;
        fields[count] = std.fmt.parseUnsigned(usize, field, 10) catch return null;
        count += 1;
    }
    if (count != fields.len) return null;

    const code = fields[0];
    const x = fields[1] -| 1;
    const y = fields[2] -| 1;
    const release = csi.final == 'm';
    const is_motion = (code & 32) != 0;
    const base = code & ~@as(usize, 4 | 8 | 16 | 32);
    const mods = Modifiers{
        .shift = (code & 4) != 0,
        .alt = (code & 8) != 0,
        .ctrl = (code & 16) != 0,
    };

    if (base >= 64) {
        if (release or base > 67) return null;
        // One notch is three cells or lines, as in a browser. Shift turns a
        // vertical notch sideways.
        const vertical: i32 = if (base == 64) -3 else if (base == 65) 3 else 0;
        const sideways: i32 = if (base == 66) -3 else if (base == 67) 3 else 0;
        const delta_y: i32 = if (mods.shift) 0 else vertical;
        const delta_x: i32 = if (sideways != 0) sideways else if (mods.shift) vertical else 0;
        return .{
            .kind = .wheel,
            .x = x,
            .y = y,
            .mods = mods,
            .delta_x = delta_x,
            .delta_y = delta_y,
        };
    }

    const button: MouseButton = switch (base) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    if (is_motion) {
        return .{ .kind = .move, .x = x, .y = y, .button = button, .mods = mods };
    }
    if (release) {
        return .{ .kind = .up, .x = x, .y = y, .button = button, .mods = mods };
    }
    return .{ .kind = .down, .x = x, .y = y, .button = button, .mods = mods };
}

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
    var events = try decodeKeys(allocator, "\x1b[A\x1b[3~\x1b[1;5C\x1b[5~\x1b[Z");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    try std.testing.expect(events.items[0].key == .up);
    try std.testing.expect(events.items[1].key == .delete);
    try std.testing.expect(events.items[2].key == .right);
    try std.testing.expect(events.items[2].mods.ctrl);
    try std.testing.expect(events.items[3].key == .page_up);
    try std.testing.expect(events.items[4].key == .backtab);
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
        .key => error.TestUnexpectedResult,
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

    // shift (4) + alt (8) + ctrl (16) on a left press.
    var modified = try decode(allocator, "\x1b[<28;2;2M");
    defer modified.deinit(allocator);
    const mods = (try mouseAt(modified.items, 0)).mods;
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.alt);
    try std.testing.expect(mods.ctrl);
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
        .mouse => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("a", first_key.key.text);
    const mouse = try mouseAt(mixed.items, 1);
    try std.testing.expectEqual(@as(usize, 1), mouse.x);
    try std.testing.expectEqual(@as(usize, 2), mouse.y);
    const second_key = switch (mixed.items[2]) {
        .key => |key| key,
        .mouse => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("b", second_key.key.text);
}
