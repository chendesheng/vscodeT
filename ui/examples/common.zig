const std = @import("std");
const ui = @import("ui");

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
/// screen, requests SGR mouse reports, dispatches every decoded event through
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

    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h");
    defer {
        out.writeAll("\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    const orig_termios = enableRawMode(io);
    defer {
        if (orig_termios) |orig| disableRawMode(orig) catch {};
    }

    try surface.render(out, .{});
    try out.flush();

    var press: ?struct { x: usize, y: usize } = null;
    var press_moved = false;
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
                .mouse => |*mouse| {
                    const target = (try surface.elementFromPoint(mouse.x, mouse.y)) orelse
                        (doc.root orelse continue);
                    doc.dispatchMouse(target, mouse);

                    // The library leaves click synthesis and drag policy to the
                    // host. This loop is the host for the examples: a left press
                    // remembers its cell, a drag suppresses the click, and a
                    // plain release clicks the press/release common ancestor.
                    switch (mouse.kind) {
                        .down => if (mouse.button == .left) {
                            press = .{ .x = mouse.x, .y = mouse.y };
                            press_moved = false;
                        },
                        .move => if (mouse.button == .left and press != null) {
                            press_moved = true;
                        },
                        .up => if (mouse.button == .left) {
                            if (press) |pressed| {
                                if (!press_moved) {
                                    const press_target =
                                        (try surface.elementFromPoint(pressed.x, pressed.y)) orelse target;
                                    const click_target =
                                        ui.event.commonInclusiveAncestor(press_target, target) orelse
                                        press_target;
                                    var click = ui.MouseEvent{
                                        .kind = .click,
                                        .x = mouse.x,
                                        .y = mouse.y,
                                        .button = .left,
                                        .mods = mouse.mods,
                                    };
                                    doc.dispatchMouse(click_target, &click);
                                }
                                press = null;
                                press_moved = false;
                            }
                        },
                        else => {},
                    }
                },
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
