//! Terminal byte stream -> key events.
//!
//! The decoder turns the ANSI escape sequences a terminal sends into the
//! semantic `Key` values in `event.zig`: printable runs, control bytes, cursor
//! and editing keys, and bracketed paste boundaries. Text runs borrow from the
//! input buffer, so dispatch an event before reusing that buffer.
//!
//! Terminals report key presses, not releases or repeats, so every event here
//! is a `key_down`. Extended keyboard reports (CSI u / kitty) are not enabled;
//! the sequences handled are what a normal xterm-compatible terminal sends.

const std = @import("std");
const event = @import("event.zig");

pub const Event = event.KeyEvent;
pub const Key = event.Key;
pub const Modifiers = event.Modifiers;

pub fn decode(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Event) {
    var tokens = try tokenize(allocator, input);
    defer tokens.deinit(allocator);

    var result: std.ArrayList(Event) = .empty;
    errdefer result.deinit(allocator);

    for (tokens.items) |token| {
        switch (token) {
            .string => |text| try decodeString(allocator, &result, text),
            .csi => |csi| try decodeCsi(allocator, &result, csi),
        }
    }
    return result;
}

fn decodeString(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(Event),
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
            try result.append(allocator, .{ .key = .{ .text = text[run_start..i] } });
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
            try result.append(allocator, .{ .key = named.key, .mods = named.mods });
        }
        i += 1;
    }
    if (run_start < text.len) {
        try result.append(allocator, .{ .key = .{ .text = text[run_start..] } });
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
    result: *std.ArrayList(Event),
    csi: Token.Csi,
) !void {
    const mods = parseModifiers(csi.parameters);
    switch (csi.final) {
        'A' => try result.append(allocator, .{ .key = .up, .mods = mods }),
        'B' => try result.append(allocator, .{ .key = .down, .mods = mods }),
        'C' => try result.append(allocator, .{ .key = .right, .mods = mods }),
        'D' => try result.append(allocator, .{ .key = .left, .mods = mods }),
        'H' => try result.append(allocator, .{ .key = .home, .mods = mods }),
        'F' => try result.append(allocator, .{ .key = .end, .mods = mods }),
        'Z' => try result.append(allocator, .{ .key = .backtab, .mods = mods }),
        '~' => {
            const code = parseFirst(csi.parameters) orelse 0;
            switch (code) {
                1, 7 => try result.append(allocator, .{ .key = .home, .mods = mods }),
                4, 8 => try result.append(allocator, .{ .key = .end, .mods = mods }),
                2 => try result.append(allocator, .{ .key = .insert, .mods = mods }),
                3 => try result.append(allocator, .{ .key = .delete, .mods = mods }),
                5 => try result.append(allocator, .{ .key = .page_up, .mods = mods }),
                6 => try result.append(allocator, .{ .key = .page_down, .mods = mods }),
                200 => try result.append(allocator, .{ .key = .paste_start }),
                201 => try result.append(allocator, .{ .key = .paste_end }),
                else => {},
            }
        },
        else => {
            if (csi.parameters.len == 0 and csi.intermediate.len == 0 and
                csi.final >= 0x20 and csi.final <= 0x7e)
            {
                try result.append(allocator, .{
                    .key = .{ .char = csi.final },
                    .mods = .{ .alt = true },
                });
            }
        },
    }
}

test "input: printable runs and control keys" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "q");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("q", events.items[0].key.text);
    try std.testing.expect(!events.items[0].mods.ctrl);

    var ctrl_q = try decode(allocator, "\x11");
    defer ctrl_q.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_q.items.len);
    try std.testing.expectEqual(@as(u21, 'q'), ctrl_q.items[0].key.char);
    try std.testing.expect(ctrl_q.items[0].mods.ctrl);
}

test "input: named keys and modifiers" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "\x1b[A\x1b[3~\x1b[1;5C\x1b[5~\x1b[Z");
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

    var ctrl_slash = try decode(allocator, "\x1f");
    defer ctrl_slash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), ctrl_slash.items[0].key.char);
    try std.testing.expect(ctrl_slash.items[0].mods.ctrl);

    var alt_slash = try decode(allocator, "\x1b/");
    defer alt_slash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alt_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), alt_slash.items[0].key.char);
    try std.testing.expect(alt_slash.items[0].mods.alt);

    var ctrl_d = try decode(allocator, "\x04");
    defer ctrl_d.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'd'), ctrl_d.items[0].key.char);
    try std.testing.expect(ctrl_d.items[0].mods.ctrl);

    var ctrl_bracket = try decode(allocator, "\x1d");
    defer ctrl_bracket.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_bracket.items.len);
    try std.testing.expectEqual(@as(u21, ']'), ctrl_bracket.items[0].key.char);
    try std.testing.expect(ctrl_bracket.items[0].mods.ctrl);

    var ctrl_backslash = try decode(allocator, "\x1c");
    defer ctrl_backslash.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_backslash.items.len);
    try std.testing.expectEqual(@as(u21, '\\'), ctrl_backslash.items[0].key.char);
    try std.testing.expect(ctrl_backslash.items[0].mods.ctrl);
}

test "input: bracketed paste" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "\x1b[200~hello\x1b[201~");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].key == .paste_start);
    try std.testing.expectEqualStrings("hello", events.items[1].key.text);
    try std.testing.expect(events.items[2].key == .paste_end);
}

test "input: utf-8 text runs and lone escape" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "héllo\x1b");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("héllo", events.items[0].key.text);
    try std.testing.expect(events.items[1].key == .escape);
}

test "input: shifted tab and control bytes" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "\t\r\x7f");
    defer events.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].key == .tab);
    try std.testing.expect(events.items[1].key == .enter);
    try std.testing.expect(events.items[2].key == .backspace);
}

// Regression: Ctrl-F used to be dropped, so the app never saw it (0x06).
test "input: every Ctrl-letter is decoded, Ctrl-H stays backspace" {
    const allocator = std.testing.allocator;

    var ctrl_f = try decode(allocator, "\x06");
    defer ctrl_f.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctrl_f.items.len);
    try std.testing.expectEqual(@as(u21, 'f'), ctrl_f.items[0].key.char);
    try std.testing.expect(ctrl_f.items[0].mods.ctrl);

    var ctrl_r = try decode(allocator, "\x12");
    defer ctrl_r.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'r'), ctrl_r.items[0].key.char);
    try std.testing.expect(ctrl_r.items[0].mods.ctrl);

    var ctrl_g = try decode(allocator, "\x07");
    defer ctrl_g.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 'g'), ctrl_g.items[0].key.char);

    // 0x08 is Backspace, not Ctrl-H: terminals cannot distinguish them.
    var ctrl_h = try decode(allocator, "\x08");
    defer ctrl_h.deinit(allocator);
    try std.testing.expectEqual(Key.backspace, ctrl_h.items[0].key);
    try std.testing.expect(!ctrl_h.items[0].mods.ctrl);
}
