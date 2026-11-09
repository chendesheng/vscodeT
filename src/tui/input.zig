const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ansi = @import("./ansi.zig");

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

pub const Key = union(enum) {
    text: []const u8,
    char: u21,
    enter,
    backspace,
    delete,
    tab,
    backtab,
    escape,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    paste_start,
    paste_end,
};

pub const Event = struct {
    key: Key,
    mods: Mods = .{},
};

pub fn decode(allocator: Allocator, input: []const u8) !ArrayList(Event) {
    const tokens = try ansi.tokenize(allocator, input);
    defer tokens.deinit();

    var result = ArrayList(Event).init(allocator);
    errdefer result.deinit();

    for (tokens.items) |token| {
        switch (token) {
            .string => |text| try decodeString(&result, text),
            .csi => |csi| try decodeCsi(&result, csi),
        }
    }
    return result;
}

fn decodeString(result: *ArrayList(Event), text: []const u8) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch >= 0x20 and ch != 0x7f) {
            i += 1;
            continue;
        }

        if (run_start < i) try result.append(.{ .key = .{ .text = text[run_start..i] } });
        run_start = i + 1;

        switch (ch) {
            0x11 => try result.append(.{ .key = .{ .char = 'q' }, .mods = .{ .ctrl = true } }),
            0x13 => try result.append(.{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true } }),
            0x1a => try result.append(.{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } }),
            0x19 => try result.append(.{ .key = .{ .char = 'y' }, .mods = .{ .ctrl = true } }),
            0x01 => try result.append(.{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } }),
            0x03 => try result.append(.{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } }),
            0x0c => try result.append(.{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } }),
            0x04 => try result.append(.{ .key = .{ .char = 'd' }, .mods = .{ .ctrl = true } }),
            0x1c => try result.append(.{ .key = .{ .char = '\\' }, .mods = .{ .ctrl = true } }),
            0x1d => try result.append(.{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } }),
            0x1f => try result.append(.{ .key = .{ .char = '/' }, .mods = .{ .ctrl = true } }),
            0x08, 0x7f => try result.append(.{ .key = .backspace }),
            '\r', '\n' => try result.append(.{ .key = .enter }),
            '\t' => try result.append(.{ .key = .tab }),
            0x1b => try result.append(.{ .key = .escape }),
            else => {},
        }
        i += 1;
    }
    if (run_start < text.len) try result.append(.{ .key = .{ .text = text[run_start..] } });
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

fn parseMods(params: []const u8) Mods {
    const encoded = parseLast(params) orelse return .{};
    if (encoded < 2) return .{};
    const bits = encoded - 1;
    return .{
        .shift = (bits & 1) != 0,
        .alt = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
    };
}

fn decodeCsi(result: *ArrayList(Event), csi: ansi.AnsiToken.Csi) !void {
    const mods = parseMods(csi.parameters);
    switch (csi.final) {
        'A' => try result.append(.{ .key = .up, .mods = mods }),
        'B' => try result.append(.{ .key = .down, .mods = mods }),
        'C' => try result.append(.{ .key = .right, .mods = mods }),
        'D' => try result.append(.{ .key = .left, .mods = mods }),
        'H' => try result.append(.{ .key = .home, .mods = mods }),
        'F' => try result.append(.{ .key = .end, .mods = mods }),
        'Z' => try result.append(.{ .key = .backtab, .mods = mods }),
        '~' => {
            const code = parseFirst(csi.parameters) orelse 0;
            switch (code) {
                1, 7 => try result.append(.{ .key = .home, .mods = mods }),
                4, 8 => try result.append(.{ .key = .end, .mods = mods }),
                2 => try result.append(.{ .key = .insert, .mods = mods }),
                3 => try result.append(.{ .key = .delete, .mods = mods }),
                5 => try result.append(.{ .key = .page_up, .mods = mods }),
                6 => try result.append(.{ .key = .page_down, .mods = mods }),
                200 => try result.append(.{ .key = .paste_start }),
                201 => try result.append(.{ .key = .paste_end }),
                else => {},
            }
        },
        else => {
            if (csi.parameters.len == 0 and csi.intermediate.len == 0 and csi.final >= 0x20 and csi.final <= 0x7e) {
                try result.append(.{ .key = .{ .char = csi.final }, .mods = .{ .alt = true } });
            }
        },
    }
}

test "input: q is text, Ctrl-Q is a modified char" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "q");
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("q", events.items[0].key.text);
    try std.testing.expect(!events.items[0].mods.ctrl);

    var ctrl_q = try decode(allocator, "\x11");
    defer ctrl_q.deinit();
    try std.testing.expectEqual(@as(u21, 'q'), ctrl_q.items[0].key.char);
    try std.testing.expect(ctrl_q.items[0].mods.ctrl);
}

test "input: named keys and modifiers" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "\x1b[A\x1b[3~\x1b[1;5C\x1b[5~\x1b[Z");
    defer events.deinit();
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
    defer ctrl_slash.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctrl_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), ctrl_slash.items[0].key.char);
    try std.testing.expect(ctrl_slash.items[0].mods.ctrl);

    var alt_slash = try decode(allocator, "\x1b/");
    defer alt_slash.deinit();
    try std.testing.expectEqual(@as(usize, 1), alt_slash.items.len);
    try std.testing.expectEqual(@as(u21, '/'), alt_slash.items[0].key.char);
    try std.testing.expect(alt_slash.items[0].mods.alt);

    var ctrl_d = try decode(allocator, "\x04");
    defer ctrl_d.deinit();
    try std.testing.expectEqual(@as(u21, 'd'), ctrl_d.items[0].key.char);
    try std.testing.expect(ctrl_d.items[0].mods.ctrl);

    var ctrl_bracket = try decode(allocator, "\x1d");
    defer ctrl_bracket.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctrl_bracket.items.len);
    try std.testing.expectEqual(@as(u21, ']'), ctrl_bracket.items[0].key.char);
    try std.testing.expect(ctrl_bracket.items[0].mods.ctrl);

    var ctrl_backslash = try decode(allocator, "\x1c");
    defer ctrl_backslash.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctrl_backslash.items.len);
    try std.testing.expectEqual(@as(u21, '\\'), ctrl_backslash.items[0].key.char);
    try std.testing.expect(ctrl_backslash.items[0].mods.ctrl);
}

test "input: bracketed paste" {
    const allocator = std.testing.allocator;
    var events = try decode(allocator, "\x1b[200~hello\x1b[201~");
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].key == .paste_start);
    try std.testing.expectEqualStrings("hello", events.items[1].key.text);
    try std.testing.expect(events.items[2].key == .paste_end);
}
