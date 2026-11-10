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

        var events = try ui.input.decode(allocator, bytes[0..n]);
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
