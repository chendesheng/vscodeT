// Tests for the terminal view's render-state-to-cell conversion.
const std = @import("std");
const ui = @import("ui");
const emulator_mod = @import("../vs/workbench/contrib/terminal/browser/terminalEmulator.zig");
const view = @import("./terminalView.zig");

test "terminalView: paints text and reports the cursor" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var emulator: emulator_mod.TerminalEmulator = undefined;
    try emulator.init(allocator, io, .{
        .cols = 20,
        .rows = 3,
        .host = .{ .context = undefined },
    });
    defer emulator.deinit();

    emulator.feed("hi\\r\\n");
    try emulator.update();
    var grid = try ui.CellGrid.init(allocator, 20, 3);
    defer grid.deinit();
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 20, .h = 3 };
    try view.paint(&emulator, &grid, rect);
    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "hi"));
    try std.testing.expect(view.cursorCell(&emulator, rect) != null);
}
