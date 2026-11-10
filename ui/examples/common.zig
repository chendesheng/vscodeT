const std = @import("std");
const ui = @import("ui");

/// Draws one frame on the alternate screen, shows it for two seconds, then
/// restores the terminal. The examples are static; the next milestone adds
/// input, cursors and scrolling.
pub fn present(surface: *ui.Surface) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    try out.writeAll("\x1b[?1049h\x1b[?25l");
    defer {
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    try surface.render(out, .{});
    try out.flush();
    io.sleep(.fromMilliseconds(2000), .awake) catch {};
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
