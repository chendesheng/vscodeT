// TUI-to-VT input encoding for the integrated terminal.
//
// The browser terminal feeds xterm.js DOM keyboard/mouse events. In the TUI the
// decoded `ui` events are mapped to libghostty-vt's key/mouse/paste encoders so
// the bytes follow the current terminal modes (application cursor keys, kitty
// keyboard protocol, mouse format, bracketed paste).
//
// Bracketed paste is taken from the raw input stream because `ui.input` turns
// pasted control bytes into editor key events. The scanner only runs while the
// terminal owns focus; the editor path is untouched.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const ghostty = @import("ghostty-vt");
const emulator_mod = @import("./terminalEmulator.zig");

pub const TerminalEmulator = emulator_mod.TerminalEmulator;
pub const Input = ghostty.input;

pub const Encoder = struct {
    button_down: ?Input.MouseButton = null,

    pub fn key(self: *Encoder, emulator: *const TerminalEmulator, event: ui.KeyEvent, out: *std.array_list.Managed(u8)) !void {
        _ = self;
        if (event.key == .paste_start or event.key == .paste_end) return;
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        var key_event = toKeyEvent(event);
        switch (event.key) {
            .text => |text| {
                key_event.utf8 = text;
            },
            .char => |codepoint| {
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8) catch 0;
                if (len > 0) {
                    key_event.utf8 = utf8[0..len];
                    if (event.mods.shift and codepoint >= 'A' and codepoint <= 'Z') {
                        key_event.consumed_mods.shift = true;
                    }
                }
                key_event.unshifted_codepoint = unshifted(codepoint, event.mods);
            },
            else => {},
        }
        try emulator.encodeKey(&writer, key_event);
        try out.appendSlice(writer.buffered());
    }

    pub fn mouse(self: *Encoder, emulator: *const TerminalEmulator, event: ui.MouseEvent, cols: u16, rows: u16, out: *std.array_list.Managed(u8)) !bool {
        _ = cols;
        _ = rows;
        if (!emulator.mouseReporting()) return false;
        var mouse_event = Input.MouseEncodeEvent{
            .pos = .{
                .x = @as(f32, @floatFromInt(event.x)) + 0.5,
                .y = @as(f32, @floatFromInt(event.y)) + 0.5,
            },
            .mods = .{
                .shift = event.mods.shift,
                .ctrl = event.mods.ctrl,
                .alt = event.mods.alt,
            },
        };
        switch (event.kind) {
            .down => {
                mouse_event.action = .press;
                mouse_event.button = button(event.button);
                self.button_down = mouse_event.button;
            },
            .up => {
                mouse_event.action = .release;
                mouse_event.button = button(event.button);
                self.button_down = null;
            },
            .move => {
                mouse_event.action = .motion;
                mouse_event.button = self.button_down;
            },
            .wheel => {
                mouse_event.action = .press;
                if (event.delta_y < 0) {
                    mouse_event.button = .four;
                } else if (event.delta_y > 0) {
                    mouse_event.button = .five;
                } else if (event.delta_x < 0) {
                    mouse_event.button = .six;
                } else if (event.delta_x > 0) {
                    mouse_event.button = .seven;
                } else {
                    return false;
                }
            },
            .click => return false,
        }
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try emulator.encodeMouse(&writer, mouse_event);
        var wrote = false;
        if (writer.buffered().len > 0) {
            try out.appendSlice(writer.buffered());
            wrote = true;
        }
        return wrote;
    }

    pub fn focus(self: *Encoder, emulator: *const TerminalEmulator, focused: bool, out: *std.array_list.Managed(u8)) !void {
        _ = self;
        var buffer: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try emulator.encodeFocus(&writer, focused);
        try out.appendSlice(writer.buffered());
    }

    pub fn paste(
        self: *Encoder,
        emulator: *const TerminalEmulator,
        allocator: Allocator,
        content: []const u8,
        out: *std.array_list.Managed(u8),
    ) !void {
        _ = self;
        if (content.len == 0) return;
        const data = try allocator.dupe(u8, content);
        defer allocator.free(data);
        const parts = Input.encodePaste(data, emulator.pasteOptions());
        for (parts) |part| try out.appendSlice(part);
    }
};

fn toKeyEvent(event: ui.KeyEvent) Input.KeyEvent {
    return .{
        .action = .press,
        .key = keyFor(event.key),
        .mods = .{
            .shift = event.mods.shift or event.key == .backtab,
            .ctrl = event.mods.ctrl,
            .alt = event.mods.alt,
        },
    };
}

fn keyFor(key: ui.Key) Input.Key {
    return switch (key) {
        .text, .char, .paste_start, .paste_end => .unidentified,
        .enter => .enter,
        .backspace => .backspace,
        .delete => .delete,
        .insert => .insert,
        .tab, .backtab => .tab,
        .escape => .escape,
        .left => .arrow_left,
        .right => .arrow_right,
        .up => .arrow_up,
        .down => .arrow_down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
    };
}

fn button(button_kind: ui.MouseButton) ?Input.MouseButton {
    return switch (button_kind) {
        .none => null,
        .left => .left,
        .middle => .middle,
        .right => .right,
    };
}

fn unshifted(codepoint: u21, mods: ui.Modifiers) u21 {
    if (mods.shift and codepoint >= 'A' and codepoint <= 'Z') return codepoint + ('a' - 'A');
    return codepoint;
}

pub const PasteScan = union(enum) {
    none,
    incomplete,
    taken: []u8,
};

/// Removes the first complete bracketed paste from `buffer`, returning its
/// raw content. An incomplete paste keeps the whole buffer for the next read.
/// The caller owns the returned content.
pub fn takePaste(allocator: Allocator, buffer: *std.array_list.Managed(u8)) !PasteScan {
    const start_marker = "\x1b[200~";
    const end_marker = "\x1b[201~";
    const start = std.mem.indexOf(u8, buffer.items, start_marker) orelse return .none;
    const content_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, buffer.items, content_start, end_marker) orelse
        return .incomplete;
    const content = try allocator.dupe(u8, buffer.items[content_start..end]);
    errdefer allocator.free(content);
    const after_start = end + end_marker.len;
    const remaining = buffer.items.len - after_start;
    std.mem.copyForwards(u8, buffer.items[start .. start + remaining], buffer.items[after_start..]);
    buffer.items.len -= after_start - start;
    return .{ .taken = content };
}

test "terminalInput: takePaste extracts and removes one paste" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try buffer.appendSlice("a\x1b[200~one\ntwo\x1b[201~b");
    const scan = try takePaste(allocator, &buffer);
    switch (scan) {
        .taken => |content| {
            defer allocator.free(content);
            try std.testing.expectEqualStrings("one\ntwo", content);
            try std.testing.expectEqualStrings("ab", buffer.items);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "terminalInput: takePaste waits for the end marker" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try buffer.appendSlice("\x1b[200~unfinished");
    const scan = try takePaste(allocator, &buffer);
    try std.testing.expect(scan == .incomplete);
}

test "terminalInput: named keys encode through ghostty" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var emulator: TerminalEmulator = undefined;
    try emulator.init(allocator, io, .{
        .cols = 80,
        .rows = 24,
        .host = .{ .context = undefined },
    });
    defer emulator.deinit();
    var encoder = Encoder{};
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    try encoder.key(&emulator, .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } }, &out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 0x03) != null);

    out.clearRetainingCapacity();
    try encoder.key(&emulator, .{ .key = .up }, &out);
    try std.testing.expectEqualStrings("\x1b[A", out.items);

    out.clearRetainingCapacity();
    try encoder.key(&emulator, .{ .key = .{ .text = "abc" } }, &out);
    try std.testing.expectEqualStrings("abc", out.items);
}
