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
const event = @import("../dom/event.zig");

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
    focus: bool,
};

pub const DecodeResult = struct {
    items: std.ArrayList(Item),
    /// Bytes consumed. A trailing incomplete escape sequence is left after
    /// this offset so a caller reading a terminal can wait for the rest and
    /// decode the sequence instead of typing its tail as text.
    consumed: usize,
};

pub fn decode(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Item) {
    const result = try decodeWithRemainder(allocator, input);
    return result.items;
}

pub fn decodeWithRemainder(allocator: std.mem.Allocator, input: []const u8) !DecodeResult {
    var tokenized = try tokenize(allocator, input);
    defer tokenized.tokens.deinit(allocator);

    var result: std.ArrayList(Item) = .empty;
    errdefer result.deinit(allocator);

    for (tokenized.tokens.items) |token| {
        switch (token) {
            .string => |text| try decodeString(allocator, &result, text),
            .key => |key| try result.append(allocator, .{ .key = key }),
            .csi => |csi| try decodeCsi(allocator, &result, csi),
        }
    }
    return .{ .items = result, .consumed = tokenized.consumed };
}

/// Decodes the keyboard events in `input`, dropping mouse and focus reports. Keyboard-only
/// hosts and tests use this; the app uses `decode` for the full stream.
pub fn decodeKeys(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(KeyEvent) {
    var items = try decode(allocator, input);
    defer items.deinit(allocator);

    var result: std.ArrayList(KeyEvent) = .empty;
    errdefer result.deinit(allocator);
    for (items.items) |item| {
        switch (item) {
            .key => |key_event| try result.append(allocator, key_event),
            .mouse, .focus => {},
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
    key: KeyEvent,

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

const Tokenized = struct {
    tokens: std.ArrayList(Token),
    consumed: usize,
};

const State = enum {
    normal,
    esc,
    esc_parameter,
    ss3,
    esc_parameter_intermediate,
    esc_intermediate,
    bracketed_paste,
    /// A Device Control String (`ESC P ... ST`). Terminal replies such as the
    /// cell-border capability answer arrive this way and must not become keys.
    dcs,
    /// An Operating System Command (`ESC ] ... BEL|ST`); replies are swallowed.
    osc,
    /// An Application Programming Command (`ESC _ ... ST`). Kitty graphics
    /// replies use this form; a standalone `ESC _` is Alt+Shift+- and stays a
    /// key event.
    apc,
};

fn tokenize(allocator: std.mem.Allocator, input: []const u8) !Tokenized {
    var state: State = .normal;
    var result: std.ArrayList(Token) = .empty;
    errdefer result.deinit(allocator);

    var last_pos: usize = 0;
    var pos: usize = 0;
    var sequence_start: ?usize = null;
    var current: Token = .{ .csi = .{ .parameters = "", .intermediate = "", .final = 0 } };

    while (pos < input.len) {
        const chr = input[pos];
        switch (state) {
            .normal => {
                if (chr == ESC) {
                    if (last_pos < pos) {
                        try result.append(allocator, .{ .string = input[last_pos..pos] });
                    }
                    sequence_start = pos;
                    state = .esc;
                    last_pos = pos + 1;
                }
            },
            .esc => {
                if (chr == '[') {
                    state = .esc_parameter;
                    last_pos = pos + 1;
                } else if (chr == 'O') {
                    state = .ss3;
                } else if (chr == 'P' and
                    pos + 15 < input.len and
                    std.mem.startsWith(u8, input[pos + 1 ..], "1+bcell-border;"))
                {
                    // Only swallow the reply to our own query; a bare `ESC P`
                    // is Alt-Shift-P and must stay a key event.
                    state = .dcs;
                    last_pos = pos + 1;
                } else if (chr == ']' and pos + 1 < input.len and std.ascii.isDigit(input[pos + 1])) {
                    state = .osc;
                    last_pos = pos + 1;
                } else if (chr == '_' and pos + 1 < input.len and input[pos + 1] == 'G') {
                    // Only swallow kitty graphics replies (`ESC _ G`); a bare
                    // `ESC _` is Alt+Shift+- and must stay a key event.
                    state = .apc;
                    last_pos = pos + 1;
                } else if (isFinalCharForEscSequence(chr) or chr == '/') {
                    // ESC Z is Alt+Shift+Z. Only ESC [ Z is backtab.
                    try result.append(allocator, .{ .key = .{ .key = .{ .char = chr }, .mods = .{ .alt = true } } });
                    state = .normal;
                    last_pos = pos + 1;
                } else if (isIntermediateChar(chr)) {
                    state = .esc_intermediate;
                    last_pos = pos;
                } else {
                    state = .normal;
                }
            },
            .ss3 => {
                if (chr == 'P') {
                    try result.append(allocator, .{ .key = .{ .key = .f1 } });
                    last_pos = pos + 1;
                } else {
                    // The terminal may also send ESC O for Alt+Shift+O.
                    try result.append(allocator, .{ .key = .{ .key = .{ .char = 'O' }, .mods = .{ .alt = true } } });
                    last_pos = pos;
                    pos -= 1;
                }
                state = .normal;
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
                        sequence_start = null;
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
            .dcs => {
                if (chr == 0x9c) {
                    state = .normal;
                    last_pos = pos + 1;
                } else if (chr == ESC and pos + 1 < input.len and input[pos + 1] == '\\') {
                    state = .normal;
                    pos += 1;
                    last_pos = pos + 1;
                }
            },
            .osc => {
                if (chr == 0x07 or chr == 0x9c) {
                    state = .normal;
                    last_pos = pos + 1;
                } else if (chr == ESC and pos + 1 < input.len and input[pos + 1] == '\\') {
                    state = .normal;
                    pos += 1;
                    last_pos = pos + 1;
                }
            },
            .apc => {
                if (chr == 0x9c) {
                    state = .normal;
                    last_pos = pos + 1;
                } else if (chr == ESC and pos + 1 < input.len and input[pos + 1] == '\\') {
                    state = .normal;
                    pos += 1;
                    last_pos = pos + 1;
                }
            },
        }
        pos += 1;
    }

    var consumed = input.len;
    switch (state) {
        // A lone ESC has no following byte to close a sequence; report the key.
        .esc => try result.append(allocator, .{ .string = input[pos - 1 .. pos] }),
        // A trailing partial sequence must be decoded again when the rest of
        // its bytes arrive. Typing its tail as text would turn a split SGR
        // mouse report such as `ESC [ <35;...M` into `<35;...M` in the editor.
        .ss3, .esc_parameter, .esc_parameter_intermediate, .esc_intermediate, .dcs, .osc, .apc => {
            consumed = sequence_start orelse input.len;
        },
        else => {
            if (last_pos < pos) {
                try result.append(allocator, .{ .string = input[last_pos..pos] });
            }
        },
    }
    return .{ .tokens = result, .consumed = consumed };
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
    if (std.mem.indexOfScalar(u8, params, ';') == null) return .{};
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

    if ((csi.final == 'I' or csi.final == 'O') and csi.parameters.len == 0 and csi.intermediate.len == 0) {
        try result.append(allocator, .{ .focus = csi.final == 'I' });
        return;
    }
    const mods = parseModifiers(csi.parameters);
    switch (csi.final) {
        'P' => try result.append(allocator, .{ .key = .{ .key = .f1, .mods = mods } }),
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
                11 => try result.append(allocator, .{ .key = .{ .key = .f1, .mods = mods } }),
                24 => try result.append(allocator, .{ .key = .{ .key = .f12, .mods = mods } }),
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
