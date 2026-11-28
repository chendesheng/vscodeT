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

/// A host-level overlay painted after the scene. Native widgets such as
/// `ContextMenu` are not part of the document; they paint their own cells and
/// receive input before the document does.
pub const Overlay = struct {
    context: ?*anyopaque = null,
    paint: *const fn (context: ?*anyopaque, grid: *ui.CellGrid) void,
    key_down: ?*const fn (context: ?*anyopaque, event: *ui.KeyEvent) bool = null,
    mouse: ?*const fn (context: ?*anyopaque, event: *ui.MouseEvent) bool = null,
};

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
    /// Gallery scenes that own a keyboard focus (text input, tree/list focus)
    /// receive decoded keys instead of the gallery's scene navigation.
    wants_keys: bool = false,
    /// Rebuild the gallery after each handled key or mouse action, for scenes
    /// whose listeners mutate state instead of updating node styles in place.
    rebuild_after_event: bool = false,
    /// Optional native overlay painted after the scene and answered before the
    /// document gets the event.
    overlay: ?Overlay = null,
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
            // Touchscreens often report a held-button motion event for a tap.
            // Only leaving the pressed cell starts a drag, so same-cell jitter
            // still produces the synthetic click on release.
            .move => if (event.button == .left) {
                if (self.press) |pressed| {
                    if (event.x != pressed.x or event.y != pressed.y) self.moved = true;
                }
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

var resize_read_fd: std.posix.fd_t = -1;
var resize_write_fd: std.posix.fd_t = -1;

fn onResizeSignal(_: std.posix.SIG) callconv(.c) void {
    if (resize_write_fd >= 0) {
        _ = std.posix.system.write(resize_write_fd, "x", 1);
    }
}

/// Installs a `SIGWINCH` handler and returns the read end of a self-pipe. The
/// handler writes a byte from async-signal context; an event loop polls both
/// stdin and this descriptor, drains it on wakeup, and re-queries `TIOCGWINSZ`.
/// The descriptor and handler live for the rest of the process.
pub fn resizeWatcherFd() !std.posix.fd_t {
    if (resize_read_fd >= 0) return resize_read_fd;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    resize_read_fd = fds[0];
    resize_write_fd = fds[1];

    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = onResizeSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &action, null);
    return resize_read_fd;
}

/// Empties the self-pipe after a `SIGWINCH` wakeup.
pub fn drainResizeWatcher(fd: std.posix.fd_t) void {
    var buffer: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buffer) catch return;
        if (n == 0) return;
    }
}

/// Creates a fullscreen surface, builds `example` under a full-size root and
/// runs the static presenter (wait for `q`). The scene is rebuilt when the
/// terminal resizes.
pub fn runStatic(allocator: std.mem.Allocator, io: std.Io, example: Example) !void {
    var runner = try Runner.init(allocator, example);
    defer runner.deinit();
    // Build after the runner reached its final address: nodes keep a
    // `*Document` back-pointer, so building inside `init` would leave them
    // pointing at the returned stack copy.
    try runner.rebuildScene();
    try runner.runStatic(io);
}

/// Same setup, but runs the interactive loop (keys, mouse, hover). The scene is
/// rebuilt when the terminal resizes, with the pointer gesture state reset.
pub fn runInteractive(allocator: std.mem.Allocator, io: std.Io, example: Example) !void {
    var runner = try Runner.init(allocator, example);
    defer runner.deinit();
    // See `runStatic`: build only once the runner is at its final address.
    try runner.rebuildScene();
    try runner.runInteractive(io);
}

const Runner = struct {
    allocator: std.mem.Allocator,
    example: Example,
    surface: ui.Surface,

    fn init(allocator: std.mem.Allocator, example: Example) !Runner {
        var surface = try fullscreenSurface(allocator);
        errdefer surface.deinit();
        return .{
            .allocator = allocator,
            .example = example,
            .surface = surface,
        };
    }

    fn deinit(self: *Runner) void {
        self.surface.deinit();
    }

    /// Renders the scene and, when the example has one, its native overlay.
    fn present(self: *Runner, out: *std.Io.Writer) !void {
        const overlay = if (self.example.overlay) |value|
            ui.Overlay{ .context = value.context, .paint = value.paint }
        else
            null;
        try self.surface.renderWithOverlay(out, .{}, overlay);
    }

    fn rebuildScene(self: *Runner) !void {
        const doc = self.surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
        });
        doc.setRoot(root);
        try self.example.build(self.example.context, doc, root, .{
            .width = doc.cols,
            .height = doc.rows,
        });
    }

    /// Recreates the surface frame and rebuilds the scene when the terminal
    /// viewport changed. Returns true when a new frame was produced.
    fn resizeIfNeeded(self: *Runner) !bool {
        const size = terminalSize();
        const doc = self.surface.document();
        if (size.width == doc.cols and size.height == doc.rows) return false;
        try self.surface.resize(size.width, size.height);
        try self.rebuildScene();
        return true;
    }

    fn enterScreen(out: *std.Io.Writer, mouse: bool) !void {
        try out.writeAll("\x1b[?1049h\x1b[?25l");
        if (mouse) try out.writeAll("\x1b[?1003h\x1b[?1006h");
    }

    fn leaveScreen(out: *std.Io.Writer, mouse: bool) void {
        if (mouse) out.writeAll("\x1b[?1006l\x1b[?1003l") catch {};
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    /// Draws the example on the alternate screen and waits for `q` (or Ctrl-Q),
    /// then restores the terminal. When stdin is a pipe the bytes are decoded the
    /// same way, so a demo can be driven non-interactively; EOF exits.
    fn runStatic(self: *Runner, io: std.Io) !void {
        var buffer: [8192]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        const out = &stdout.interface;

        try enterScreen(out, false);
        defer leaveScreen(out, false);

        const orig_termios = enableRawMode(io);
        defer {
            if (orig_termios) |orig| disableRawMode(orig) catch {};
        }

        try self.present(out);
        try out.flush();

        const resize_fd = try resizeWatcherFd();
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = resize_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        while (true) {
            _ = std.posix.poll(&fds, -1) catch continue;
            const stdin_ready =
                (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0;

            if ((fds[1].revents & std.posix.POLL.IN) != 0) {
                drainResizeWatcher(resize_fd);
                if (try self.resizeIfNeeded()) {
                    try self.present(out);
                    try out.flush();
                }
            }

            if (!stdin_ready) continue;

            var bytes: [512]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
            if (n == 0) return;

            var events = try ui.input.decodeKeys(self.allocator, bytes[0..n]);
            defer events.deinit(self.allocator);
            for (events.items) |event| {
                if (isQuitKey(event)) return;
            }
        }
    }

    /// Interactive example loop for keyboard and mouse demos: enters the
    /// alternate screen, requests all-motion SGR mouse reports, dispatches
    /// every decoded event through the document (hit-testing mouse events with
    /// `Surface.elementFromPoint`) and redraws after each batch. `q` and Ctrl-Q
    /// quit; EOF exits. A terminal resize rebuilds the scene and drops the
    /// in-progress press state.
    ///
    /// The example owns all behavior in listeners: press-to-focus, click/drag,
    /// wheel handling and status updates. This loop only wires terminal input to
    /// the same `ui` APIs an application uses.
    fn runInteractive(self: *Runner, io: std.Io) !void {
        var buffer: [8192]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        const out = &stdout.interface;

        try enterScreen(out, true);
        defer leaveScreen(out, true);
        // Interactive scenes use the pointer-shape protocol; terminals without
        // OSC 22 ignore it, and scenes that set no style keep the default.
        self.surface.setPointerShapes(true);
        defer ui.pointer.writeShape(out, .default) catch {};

        const orig_termios = enableRawMode(io);
        defer {
            if (orig_termios) |orig| disableRawMode(orig) catch {};
        }

        try self.present(out);
        try out.flush();

        var router = MouseRouter{};
        const resize_fd = try resizeWatcherFd();
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = resize_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        while (true) {
            _ = std.posix.poll(&fds, -1) catch continue;
            const stdin_ready =
                (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0;

            if ((fds[1].revents & std.posix.POLL.IN) != 0) {
                drainResizeWatcher(resize_fd);
                if (try self.resizeIfNeeded()) {
                    router = .{};
                    try self.present(out);
                    try out.flush();
                }
            }

            if (!stdin_ready) continue;

            var bytes: [1024]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
            if (n == 0) return;

            var items = try ui.input.decode(self.allocator, bytes[0..n]);
            defer items.deinit(self.allocator);

            const doc = self.surface.document();
            for (items.items) |*item| {
                switch (item.*) {
                    .focus => {},
                    .key => |*key| {
                        if (isQuitKey(key.*)) return;
                        if (self.example.overlay) |overlay| {
                            if (overlay.key_down) |handler| {
                                if (handler(overlay.context, key)) continue;
                            }
                        }
                        _ = doc.dispatchKey(key.key, key.mods);
                    },
                    .mouse => |*mouse| {
                        if (self.example.overlay) |overlay| {
                            if (overlay.mouse) |handler| {
                                if (handler(overlay.context, mouse)) continue;
                            }
                        }
                        if (mouse.kind == .move) {
                            if (try self.surface.pointerAt(mouse.x, mouse.y)) |shape| {
                                _ = self.surface.setPointer(shape);
                            }
                        }
                        try router.dispatch(&self.surface, mouse);
                    },
                }
            }

            try self.present(out);
            try out.flush();
        }
    }
};

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
    var text_style = style;
    // Demo text runs are preformatted one-liners unless a scene opts into
    // flow or wrapping.
    if (text_style.white_space == null) text_style.white_space = .pre;
    node.setStyle(text_style);
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
    var label_style = box_style;
    if (label_style.white_space == null) label_style.white_space = .pre;
    const box = try addBox(doc, parent, label_style);
    _ = try addText(doc, box, value, text_style);
    return box;
}

pub fn rgb(r: u8, g: u8, b: u8) ui.Color {
    return .{ .r = r, .g = g, .b = b };
}
