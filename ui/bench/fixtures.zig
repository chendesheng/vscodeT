//! Scene builders shared by the UI benchmarks. Keep these small and explicit:
//! the benchmark should measure the library, not a fixture framework.

const std = @import("std");
const ui = @import("ui");

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

pub fn fullScreenRoot(doc: *ui.Document) !*ui.Node {
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .overflow = .hidden,
    });
    doc.setRoot(root);
    return root;
}

/// An absolutely positioned one-row region with a text child.
pub fn row(
    doc: *ui.Document,
    parent: *ui.Node,
    top: usize,
    rect: Rect,
    text: []const u8,
    background: ?ui.Color,
    white_space: ui.WhiteSpace,
) !*ui.Node {
    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(rect.x) },
        .top = .{ .cells = @floatFromInt(top) },
        .width = .{ .cells = @floatFromInt(rect.w) },
        .height = .{ .cells = @floatFromInt(rect.h) },
        .background = background,
        .white_space = white_space,
        .overflow = .hidden,
    });
    _ = try parent.appendChild(line);
    if (text.len > 0) {
        const child = try doc.createText(text);
        _ = try line.appendChild(child);
    }
    return line;
}

/// An absolutely positioned bordered box with a text child. Used by the
/// borders/table scenarios; `cell_borders` decides whether the border consumes
/// layout cells.
pub fn borderedBox(
    doc: *ui.Document,
    parent: *ui.Node,
    rect: Rect,
    text: []const u8,
    border_color: ui.Color,
    background: ?ui.Color,
) !*ui.Node {
    const box = try doc.createElement(.div);
    box.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(rect.x) },
        .top = .{ .cells = @floatFromInt(rect.y) },
        .width = .{ .cells = @floatFromInt(rect.w) },
        .height = .{ .cells = @floatFromInt(rect.h) },
        .border = ui.EdgeDecl.all(1),
        .border_color = border_color,
        .background = background,
        .white_space = .pre,
        .overflow = .hidden,
    });
    _ = try parent.appendChild(box);
    if (text.len > 0) _ = try box.appendChild(try doc.createText(text));
    return box;
}

/// A deterministic ASCII line with a different length per index, so edits and
/// scrolls do not accidentally measure a single repeated string.
pub fn lineText(buffer: []u8, index: usize) []const u8 {
    const width = 40 + index % 61;
    var at: usize = 0;
    while (at < width and at < buffer.len) : (at += 1) {
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 +-*/()[]{}";
        buffer[at] = alphabet[(index * 7 + at * 13) % alphabet.len];
    }
    return buffer[0..@min(at, buffer.len)];
}

/// A wrapping paragraph with occasional CJK and an emoji, for wide-glyph and
/// line-break coverage.
pub fn paragraphText(buffer: []u8, index: usize) []const u8 {
    const body =
        "The quick brown fox jumps over the lazy dog. " ++
        "The quick brown fox jumps over the lazy dog. " ++
        "The quick brown fox jumps over the lazy dog. " ++
        "中文字符宽度测试。 中文字符宽度测试。 " ++
        "emoji 🚀 and combining e\u{301}. emoji 🚀 and combining e\u{301}. " ++
        "trailing words repeat to force several wrapped lines. " ++
        "trailing words repeat to force several wrapped lines. ";
    var at: usize = 0;
    var cursor = index % body.len;
    while (at < buffer.len) : (at += 1) {
        buffer[at] = body[cursor];
        cursor = (cursor + 1) % body.len;
    }
    return buffer[0..at];
}

pub fn rowBackground(index: usize) ?ui.Color {
    return if (index % 2 == 0)
        ui.Color{ .r = 24, .g = 26, .b = 32 }
    else
        null;
}

pub fn accent(index: usize) ui.Color {
    return .{
        .r = @intCast(80 + (index * 17) % 160),
        .g = @intCast(80 + (index * 31) % 160),
        .b = @intCast(80 + (index * 47) % 160),
    };
}
