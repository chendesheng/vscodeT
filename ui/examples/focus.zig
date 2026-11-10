//! Keyboard focus: focusable items, Tab traversal, Enter/Space activation and
//! the active element. This is the interactive example; it closes after two
//! seconds so `zig build examples` stays non-blocking.
//!
//! Run with `cd ui && zig build example-focus`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const labels = [_][]const u8{ "Open file", "Search", "Settings" };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 60, .rows = 12 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(16, 16, 22),
    });
    doc.setRoot(root);

    _ = try common.addLabel(doc, root, "keyboard focus", .{
        .position = .absolute,
        .left = .{ .cells = 3 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 50 },
        .height = .{ .cells = 1 },
    }, .{
        .color = common.rgb(255, 255, 255),
        .bold = true,
    });

    const status_bar = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 11 },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .background = common.rgb(40, 40, 52),
    });
    const status = try common.addText(doc, status_bar, "", .{
        .color = common.rgb(220, 220, 235),
    });

    var app = App{
        .doc = doc,
        .status = status,
    };

    inline for (labels, 0..) |label, i| {
        const top: f64 = @floatFromInt(2 + i * 3);
        const node = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = 3 },
            .top = .{ .cells = top },
            .width = .{ .cells = 50 },
            .height = .{ .cells = 1 },
            .border = ui.Edges.all(1),
            .border_color = common.rgb(70, 70, 90),
            .background = common.rgb(28, 28, 38),
            .padding = .{ .left = 2 },
        });
        _ = try common.addText(doc, node, label, .{
            .color = common.rgb(190, 190, 210),
        });

        app.items[i] = .{
            .app = &app,
            .node = node,
            .label = label,
        };
        node.asElement().focusable = true;
        try node.addEventListener(app.items[i].listener());
        try node.addEventListener(app.items[i].focusListener());
    }

    try root.addEventListener(.{ .context = &app, .key_down = App.onRootKey });
    _ = doc.focus(app.items[0].node);
    app.updateStatus();

    const io = std.Io.Threaded.global_single_threaded.io();
    var out_buffer: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;

    try out.writeAll("\x1b[?1049h\x1b[?25l");
    defer {
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    // The example also runs without a terminal (for `zig build examples`):
    // raw mode fails, one frame is drawn, and the example exits after the
    // same two-second window.
    const orig_termios = enableRawMode(io);
    defer {
        if (orig_termios) |orig| disableRawMode(orig) catch {};
    }

    try surface.render(out, .{});
    try out.flush();

    if (orig_termios == null) {
        io.sleep(.fromMilliseconds(2000), .awake) catch {};
        return;
    }

    var elapsed_ms: usize = 0;
    while (!app.quit and elapsed_ms < 2000) : (elapsed_ms += 50) {
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = (std.posix.poll(&fds, 50) catch 0) > 0;
        if (!ready) continue;

        var input_buffer: [512]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &input_buffer) catch 0;
        if (n == 0) continue;

        var events = try ui.input.decode(allocator, input_buffer[0..n]);
        defer events.deinit(allocator);

        var redraw = false;
        for (events.items) |event| {
            _ = doc.dispatchKey(event.key, event.mods);
            redraw = true;
            if (app.quit) break;
        }
        if (redraw) {
            try surface.render(out, .{});
            try out.flush();
        }
    }
}

const App = struct {
    doc: *ui.Document,
    status: *ui.Node,
    items: [labels.len]Item = undefined,
    quit: bool = false,

    fn updateStatus(self: *App) void {
        const active = self.doc.activeElement();
        var name: []const u8 = "root";
        for (&self.items) |*item| {
            if (active == item.node) {
                name = item.label;
                break;
            }
        }
        var buffer: [160]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            " focus: {s}   Tab move   Enter activate   q quit",
            .{name},
        ) catch "";
        self.status.setTextContent(text) catch {};
    }

    fn activate(self: *App, label: []const u8) void {
        var buffer: [160]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            " activated: {s}   Tab move   Enter activate   q quit",
            .{label},
        ) catch "";
        self.status.setTextContent(text) catch {};
    }

    fn onRootKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));

        const ctrl_q = event.mods.ctrl and switch (event.key) {
            .char => |ch| ch == 'q',
            else => false,
        };
        if (ctrl_q) {
            self.quit = true;
            event.preventDefault();
            return;
        }

        switch (event.key) {
            .text => |text| {
                if (std.mem.eql(u8, text, "q")) {
                    self.quit = true;
                    event.preventDefault();
                }
            },
            .escape => {
                self.doc.blur();
                self.updateStatus();
            },
            else => {},
        }
    }
};

const Item = struct {
    app: *App,
    node: *ui.Node,
    label: []const u8,
    focused: bool = false,

    fn listener(self: *Item) ui.Listener {
        return .{ .context = self, .key_down = onKeyDown };
    }

    fn focusListener(self: *Item) ui.Listener {
        return .{
            .context = self,
            .focus = onFocus,
            .blur = onBlur,
        };
    }

    fn onFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        self.focused = true;
        self.applyStyle();
        self.app.updateStatus();
    }

    fn onBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        self.focused = false;
        self.applyStyle();
        self.app.updateStatus();
    }

    fn onKeyDown(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        switch (event.key) {
            .enter => self.app.activate(self.label),
            // A terminal sends Space as printable text, not a control key.
            .text => |text| {
                if (std.mem.eql(u8, text, " ")) self.app.activate(self.label);
            },
            .char => |ch| {
                if (ch == ' ') self.app.activate(self.label);
            },
            else => {},
        }
    }

    fn applyStyle(self: *Item) void {
        var style = self.node.style().*;
        style.background = if (self.focused)
            common.rgb(55, 70, 110)
        else
            common.rgb(28, 28, 38);
        style.border_color = if (self.focused)
            common.rgb(120, 180, 255)
        else
            common.rgb(70, 70, 90);
        style.color = if (self.focused)
            common.rgb(255, 255, 255)
        else
            common.rgb(190, 190, 210);
        self.node.setStyle(style);
    }
};

fn enableRawMode(io: std.Io) ?std.posix.termios {
    if (!(std.Io.File.stdin().isTty(io) catch false)) return null;
    const orig = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return null;
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.oflag.OPOST = false;
    raw.cc[@backingInt(std.posix.system.V.MIN)] = 0;
    raw.cc[@backingInt(std.posix.system.V.TIME)] = 0;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.FLUSH, raw) catch return null;
    return orig;
}

fn disableRawMode(orig: std.posix.termios) !void {
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.FLUSH, orig);
}
