// Port of terminalEditor.ts layout and terminal attachment to an editor pane.
// The terminal renderer replaces the xterm DOM container.

const std = @import("std");
const ui = @import("ui");
const TerminalInstance = @import("./terminalInstance.zig").TerminalInstance;
const renderer = @import("./terminalRenderer.zig");

pub fn layout(instance: *TerminalInstance, width: usize, height: usize) void {
    if (width == 0 or height == 0) return;
    instance.layout(@intCast(@min(width, std.math.maxInt(u16))), @intCast(@min(height, std.math.maxInt(u16))));
}

pub fn paint(instance: *TerminalInstance, grid: *ui.CellGrid, rect: ui.Rect) !void {
    layout(instance, ui.cell.snap(rect.w), ui.cell.snap(rect.h));
    try renderer.paint(&instance.emulator, grid, rect);
}

pub fn cursorCell(instance: *const TerminalInstance, rect: ui.Rect) ?renderer.Cursor {
    return renderer.cursorCell(&instance.emulator, rect);
}
