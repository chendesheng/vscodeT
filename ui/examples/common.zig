const std = @import("std");
const ui = @import("ui");

pub const Size = struct {
    width: usize,
    height: usize,
};

/// The terminal's cells, or 80x24 when stdout is not a terminal.
pub fn terminalSize() Size {
    var size: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    _ = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&size),
    );
    return .{
        .width = if (size.col == 0) 80 else size.col,
        .height = if (size.row == 0) 24 else size.row,
    };
}

/// A fullscreen surface: the terminal's current size, or the 80x24 fallback.
pub fn fullscreenSurface(allocator: std.mem.Allocator) !ui.Surface {
    const size = terminalSize();
    return ui.Surface.init(allocator, .{ .cols = size.width, .rows = size.height });
}

/// One gallery scene. `context` owns whatever state the scene needs; `build`
/// may be called repeatedly and must recreate its nodes and listeners.
pub const Example = struct {
    title: []const u8,
    context: ?*anyopaque = null,
    build: *const fn (
        context: ?*anyopaque,
        doc: *ui.Document,
        parent: *ui.Node,
        size: Size,
    ) anyerror!void,
    deinit: ?*const fn (context: ?*anyopaque) void = null,
};

/// Hit-tests a pointer event, dispatches it to the document and synthesizes a
/// left click on the press/release common ancestor when the press did not drag.
/// This is the host-side policy shared by the standalone examples and gallery.
pub const MouseRouter = struct {
    press: ?struct { x: usize, y: usize } = null,
    moved: bool = false,

    pub fn dispatch(self: *MouseRouter, surface: *ui.Surface, event: *ui.MouseEvent) !void {
        const doc = surface.document();
        const target = (try surface.elementFromPoint(event.x, event.y)) orelse
            (doc.root orelse return);
        doc.dispatchMouse(target, event);

        switch (event.kind) {
            .down => if (event.button == .left) {
                self.press = .{ .x = event.x, .y = event.y };
                self.moved = false;
            },
            .move => if (event.button == .left and self.press != null) {
                self.moved = true;
            },
            .up => if (event.button == .left) {
                if (self.press) |pressed| {
                    if (!self.moved) {
                        const press_target =
                            (try surface.elementFromPoint(pressed.x, pressed.y)) orelse target;
                        const click_target =
                            ui.event.commonInclusiveAncestor(press_target, target) orelse
                            press_target;
                        var click = ui.MouseEvent{
                            .kind = .click,
                            .x = event.x,
                            .y = event.y,
                            .button = .left,
                            .mods = event.mods,
                        };
                        doc.dispatchMouse(click_target, &click);
                    }
                    self.press = null;
                    self.moved = false;
                }
            },
            else => {},
        }
    }
};

/// Creates a fullscreen surface, builds `example` under a full-size root and
/// runs the static presenter (wait for `q`).
pub fn runStatic(allocator: std.mem.Allocator, example: Example) !void {
    var surface = try fullscreenSurface(allocator);
    defer surface.deinit();
    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);
    try example.build(example.context, doc, root, .{
        .width = doc.cols,
        .height = doc.rows,
    });
    try present(&surface, allocator);
}

/// Same setup, but runs the interactive loop (keys, mouse, hover).
pub fn runInteractive(allocator: std.mem.Allocator, example: Example) !void {
    var surface = try fullscreenSurface(allocator);
    defer surface.deinit();
    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);
    try example.build(example.context, doc, root, .{
        .width = doc.cols,
        .height = doc.rows,
    });
    try presentInteractive(&surface, allocator);
}

/// Draws the example on the alternate screen and waits for `q` (or Ctrl-Q),
/// then restores the terminal. When stdin is a pipe the bytes are decoded the
/// same way, so a demo can be driven non-interactively; EOF exits.
pub fn present(surface: *ui.Surface, allocator: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    try out.writeAll("\x1b[?1049h\x1b[?25l");
    defer {
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    const orig_termios = enableRawMode(io);
    defer {
        if (orig_termios) |orig| disableRawMode(orig) catch {};
    }

    try surface.render(out, .{});
    try out.flush();

    try waitForQ(allocator);
}

fn waitForQ(allocator: std.mem.Allocator) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const ready = (std.posix.poll(&fds, -1) catch 0) > 0;
        if (!ready) continue;

        var bytes: [512]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
        if (n == 0) return;

        var events = try ui.input.decodeKeys(allocator, bytes[0..n]);
        defer events.deinit(allocator);
        for (events.items) |event| {
            const q = switch (event.key) {
                .text => |text| std.mem.indexOfScalar(u8, text, 'q') != null,
                .char => |ch| ch == 'q',
                else => false,
            };
            if (q) return;
        }
    }
}

/// Interactive example loop for keyboard and mouse demos: enters the alternate
/// screen, requests all-motion SGR mouse reports, dispatches every decoded event through
/// the document (hit-testing mouse events with `Surface.elementFromPoint`) and
/// redraws after each batch. `q` and Ctrl-Q quit; EOF exits.
///
/// The example owns all behavior in listeners: press-to-focus, click/drag,
/// wheel handling and status updates. This loop only wires terminal input to the
/// same `ui` APIs an application uses.
pub fn presentInteractive(surface: *ui.Surface, allocator: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h");
    defer {
        out.writeAll("\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    const orig_termios = enableRawMode(io);
    defer {
        if (orig_termios) |orig| disableRawMode(orig) catch {};
    }

    try surface.render(out, .{});
    try out.flush();

    var router = MouseRouter{};
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const ready = (std.posix.poll(&fds, -1) catch 0) > 0;
        if (!ready) continue;

        var bytes: [1024]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
        if (n == 0) return;

        var items = try ui.input.decode(allocator, bytes[0..n]);
        defer items.deinit(allocator);

        const doc = surface.document();
        for (items.items) |*item| {
            switch (item.*) {
                .key => |*key| {
                    if (isQuitKey(key.*)) return;
                    _ = doc.dispatchKey(key.key, key.mods);
                },
                .mouse => |*mouse| try router.dispatch(surface, mouse),
            }
        }

        try surface.render(out, .{});
        try out.flush();
    }
}

fn isQuitKey(event: ui.KeyEvent) bool {
    if (event.mods.ctrl) {
        return switch (event.key) {
            .char => |ch| ch == 'q',
            else => false,
        };
    }
    return switch (event.key) {
        .text => |text| std.mem.eql(u8, text, "q"),
        .char => |ch| ch == 'q',
        else => false,
    };
}

/// Puts stdin in raw mode when it is a terminal, returning the original state
/// for `disableRawMode`. Returns null for redirected input.
pub fn enableRawMode(io: std.Io) ?std.posix.termios {
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

pub fn disableRawMode(orig: std.posix.termios) !void {
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.FLUSH, orig);
}

pub fn addBox(doc: *ui.Document, parent: *ui.Node, style: ui.Style) !*ui.Node {
    const node = try doc.createElement(.div);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

pub fn addText(
    doc: *ui.Document,
    parent: *ui.Node,
    value: []const u8,
    style: ui.Style,
) !*ui.Node {
    const node = try doc.createText(value);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

/// A positioned box with one text run inside. Text nodes are inline content;
/// their parent box owns position and size.
pub fn addLabel(
    doc: *ui.Document,
    parent: *ui.Node,
    value: []const u8,
    box_style: ui.Style,
    text_style: ui.Style,
) !*ui.Node {
    const box = try addBox(doc, parent, box_style);
    _ = try addText(doc, box, value, text_style);
    return box;
}

pub fn rgb(r: u8, g: u8, b: u8) ui.Color {
    return .{ .r = r, .g = g, .b = b };
}
