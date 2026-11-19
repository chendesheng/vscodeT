// The terminal engine adapter. VS Code's browser terminal wraps xterm.js in
// `src/vs/workbench/contrib/terminal/browser/xterm/xtermTerminal.ts`; this TUI
// uses libghostty-vt instead. The adapter owns the ghostty `Terminal`, a
// persistent `TerminalStream`, the render state and the effects that answer
// program queries. Everything version-sensitive about the ghostty Zig API is
// contained here.
//
// The ghostty Zig module API is not stable, but the engine is: we pin
// libghostty-vt 1.0.1 in `build.zig.zon`. The C ABI is stable from 1.0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ghostty = @import("ghostty-vt");

pub const RenderState = ghostty.RenderState;
pub const Style = ghostty.Style;
pub const Terminal = ghostty.Terminal;
pub const Stream = ghostty.TerminalStream;
pub const Input = ghostty.input;

/// RGB terminal colors. The default 256-color palette is ghostty's; the first
/// sixteen entries are overridden with the active workbench theme.
pub const Colors = struct {
    foreground: ghostty.color.RGB = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC },
    background: ghostty.color.RGB = .{ .r = 0x1E, .g = 0x1E, .b = 0x1E },
    cursor: ?ghostty.color.RGB = null,
    ansi: [16]ghostty.color.RGB = default_ansi,

    pub const default_ansi = [16]ghostty.color.RGB{
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xCD, .g = 0x31, .b = 0x31 },
        .{ .r = 0x0D, .g = 0xBC, .b = 0x79 },
        .{ .r = 0xE5, .g = 0xE5, .b = 0x10 },
        .{ .r = 0x24, .g = 0x72, .b = 0xC8 },
        .{ .r = 0xBC, .g = 0x3F, .b = 0xBC },
        .{ .r = 0x11, .g = 0xA8, .b = 0xCD },
        .{ .r = 0xE5, .g = 0xE5, .b = 0xE5 },
        .{ .r = 0x66, .g = 0x66, .b = 0x66 },
        .{ .r = 0xF1, .g = 0x4C, .b = 0x4C },
        .{ .r = 0x23, .g = 0xD1, .b = 0x8B },
        .{ .r = 0xF5, .g = 0xF5, .b = 0x43 },
        .{ .r = 0x3B, .g = 0x8E, .b = 0xEA },
        .{ .r = 0xD6, .g = 0x7C, .b = 0xD6 },
        .{ .r = 0x29, .g = 0xB8, .b = 0xDB },
        .{ .r = 0xE5, .g = 0xE5, .b = 0xE5 },
    };
};

/// Callbacks the engine uses to talk back to the instance/process. All are
/// invoked synchronously from `feed`; they must only queue work, not block.
pub const Host = struct {
    context: *anyopaque,
    write_pty: *const fn (*anyopaque, []const u8) void = noWrite,
    bell: *const fn (*anyopaque) void = noBell,
    title_changed: *const fn (*anyopaque, []const u8) void = noTitle,
    pwd_changed: *const fn (*anyopaque, []const u8) void = noPwd,
    reset: *const fn (*anyopaque) void = noReset,
    render_hold: *const fn (*anyopaque, bool) void = noHold,

    fn noWrite(_: *anyopaque, _: []const u8) void {}
    fn noBell(_: *anyopaque) void {}
    fn noTitle(_: *anyopaque, _: []const u8) void {}
    fn noPwd(_: *anyopaque, _: []const u8) void {}
    fn noReset(_: *anyopaque) void {}
    fn noHold(_: *anyopaque, _: bool) void {}
};

pub const Options = struct {
    cols: u16,
    rows: u16,
    scrollback_lines: ?usize = 1000,
    colors: Colors = .{},
    host: Host,
};

pub const TerminalEmulator = struct {
    allocator: Allocator,
    terminal: Terminal,
    stream: Stream,
    render_state: RenderState = .empty,
    host: Host,
    cols: u16,
    rows: u16,
    /// Set while the program holds the screen with synchronized output.
    render_hold: bool = false,
    /// Set by the bell effect; the panel can show a bell marker.
    bell_pending: bool = false,

    /// Initializes in place. The stream handler points at `self.terminal`, so
    /// the emulator must never be moved after this call.
    pub fn init(self: *TerminalEmulator, allocator: Allocator, io: Io, options: Options) !void {
        const cols = @max(options.cols, 1);
        const rows = @max(options.rows, 1);
        self.allocator = allocator;
        self.cols = cols;
        self.rows = rows;
        self.host = options.host;
        self.render_hold = false;
        self.bell_pending = false;
        self.render_state = .empty;

        self.terminal = try Terminal.init(io, allocator, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback_lines = options.scrollback_lines,
        });
        errdefer self.terminal.deinit(allocator);

        applyColors(&self.terminal, options.colors);

        var handler = self.terminal.vtHandler();
        var effects = Stream.Handler.Effects.readonly;
        effects.write_pty = writePtyEffect;
        effects.bell = bellEffect;
        effects.title_changed = titleEffect;
        effects.pwd_changed = pwdEffect;
        effects.reset = resetEffect;
        effects.render_hold = renderHoldEffect;
        effects.device_attributes = deviceAttributesEffect;
        effects.color_scheme = colorSchemeEffect;
        effects.size = sizeEffect;
        handler.effects = effects;

        self.stream = Stream.init(.{ .allocator = allocator, .handler = handler });
    }

    pub fn deinit(self: *TerminalEmulator) void {
        self.stream.deinit();
        self.render_state.deinit(self.allocator);
        self.terminal.deinit(self.allocator);
    }

    /// Feed bytes read from the pty into the persistent parser.
    pub fn feed(self: *TerminalEmulator, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.stream.nextSlice(bytes);
    }

    pub fn update(self: *TerminalEmulator) !void {
        if (self.render_hold) return;
        try self.render_state.update(self.allocator, &self.terminal);
    }

    /// Capture a frame while synchronized output is active.
    pub fn captureHeld(self: *TerminalEmulator) !void {
        try self.render_state.update(self.allocator, &self.terminal);
    }

    pub fn cleanRenderState(self: *TerminalEmulator) void {
        self.render_state.clean();
    }

    pub fn resize(self: *TerminalEmulator, cols: u16, rows: u16) !void {
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        try self.terminal.resize(self.allocator, .{
            .cols = self.cols,
            .rows = self.rows,
            .cell_size_px = null,
        });
        self.render_hold = false;
        try self.render_state.update(self.allocator, &self.terminal);
    }

    pub fn scrollViewport(self: *TerminalEmulator, delta: isize) void {
        self.terminal.scrollViewport(.{ .delta = delta });
    }

    pub fn scrollToBottom(self: *TerminalEmulator) void {
        self.terminal.scrollViewport(.bottom);
    }

    pub fn title(self: *const TerminalEmulator) ?[]const u8 {
        return self.terminal.getTitle();
    }

    pub fn pwd(self: *const TerminalEmulator) ?[]const u8 {
        return self.terminal.getPwd();
    }

    pub fn encodeKey(self: *const TerminalEmulator, writer: *Io.Writer, event: Input.KeyEvent) !void {
        try Input.encodeKey(writer, event, Input.KeyEncodeOptions.fromTerminal(&self.terminal));
    }

    pub fn encodeFocus(self: *const TerminalEmulator, writer: *Io.Writer, focused: bool) !void {
        if (!self.terminal.modes.get(.focus_event)) return;
        try Input.encodeFocus(writer, if (focused) .gained else .lost);
    }

    pub fn mouseReporting(self: *const TerminalEmulator) bool {
        return self.terminal.flags.mouse_event != .none;
    }

    pub fn encodeMouse(self: *const TerminalEmulator, writer: *Io.Writer, event: Input.MouseEncodeEvent) !void {
        const options: Input.MouseEncodeOptions = .{
            .event = self.terminal.flags.mouse_event,
            .format = self.terminal.flags.mouse_format,
            .size = .{
                .screen = .{ .width = self.cols, .height = self.rows },
                .cell = .{ .width = 1, .height = 1 },
                .padding = .{},
            },
        };
        try Input.encodeMouse(writer, event, options);
    }

    pub fn pasteOptions(self: *const TerminalEmulator) Input.PasteOptions {
        return Input.PasteOptions.fromTerminal(&self.terminal);
    }
};

fn applyColors(terminal: *Terminal, colors: Colors) void {
    terminal.colors.background = .init(colors.background);
    terminal.colors.foreground = .init(colors.foreground);
    if (colors.cursor) |cursor| terminal.colors.cursor = .init(cursor);
    for (colors.ansi, 0..) |color, index| {
        terminal.colors.palette.set(@intCast(index), color);
    }
}

fn fromHandler(handler: *Stream.Handler) *TerminalEmulator {
    const stream: *Stream = @fieldParentPtr("handler", handler);
    return @alignCast(@fieldParentPtr("stream", stream));
}

fn writePtyEffect(handler: *Stream.Handler, data: []const u8) void {
    const self = fromHandler(handler);
    self.host.write_pty(self.host.context, data);
}

fn bellEffect(handler: *Stream.Handler) void {
    const self = fromHandler(handler);
    self.bell_pending = true;
    self.host.bell(self.host.context);
}

fn titleEffect(handler: *Stream.Handler) void {
    const self = fromHandler(handler);
    if (self.terminal.getTitle()) |title| {
        self.host.title_changed(self.host.context, title);
    }
}

fn pwdEffect(handler: *Stream.Handler) void {
    const self = fromHandler(handler);
    if (self.terminal.getPwd()) |pwd| {
        self.host.pwd_changed(self.host.context, pwd);
    }
}

fn resetEffect(handler: *Stream.Handler) void {
    const self = fromHandler(handler);
    self.host.reset(self.host.context);
}

fn renderHoldEffect(handler: *Stream.Handler, held: bool) void {
    const self = fromHandler(handler);
    self.render_hold = held;
    if (held) {
        // Capture exactly the frame the program wants left on screen.
        self.render_state.update(self.allocator, &self.terminal) catch {};
    }
    self.host.render_hold(self.host.context, held);
}

fn deviceAttributesEffect(_: *Stream.Handler) ghostty.device_attributes.Attributes {
    return .{};
}

fn colorSchemeEffect(_: *Stream.Handler) ?ghostty.device_status.ColorScheme {
    return .dark;
}

fn sizeEffect(handler: *Stream.Handler) ?ghostty.size_report.Size {
    const self = fromHandler(handler);
    return .{
        .rows = self.rows,
        .columns = self.cols,
        .cell_width = 1,
        .cell_height = 1,
    };
}

const TestSink = struct {
    written: std.array_list.Managed(u8),
};

fn testWrite(context: *anyopaque, data: []const u8) void {
    const self: *TestSink = @ptrCast(@alignCast(context));
    self.written.appendSlice(data) catch {};
}

test "terminalEmulator: feeds text and updates the render state" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = TestSink{ .written = std.array_list.Managed(u8).init(allocator) };
    defer state.written.deinit();

    var emulator: TerminalEmulator = undefined;
    try emulator.init(allocator, io, .{
        .cols = 20,
        .rows = 3,
        .host = .{ .context = &state, .write_pty = testWrite },
    });
    defer emulator.deinit();

    emulator.feed("hello\r\nworld");
    try emulator.update();
    try std.testing.expectEqual(@as(usize, 3), @as(usize, emulator.render_state.rows));
    try std.testing.expect(emulator.render_state.dirty != .false);

    emulator.feed("\x1b]0;my-title\x07");
    try std.testing.expectEqualStrings("my-title", emulator.title().?);
    try std.testing.expectEqualStrings("my-title", emulator.terminal.getTitle().?);

    state.written.clearRetainingCapacity();
    emulator.feed("\x1b[c");
    try std.testing.expect(state.written.items.len > 0);
}
