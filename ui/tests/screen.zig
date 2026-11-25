const std = @import("std");
const ui = @import("ui");
const moveCursor = ui.screen.moveCursor;
const hideCursor = ui.screen.hideCursor;
const showCursor = ui.screen.showCursor;

test "screen: cursor sequences" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try moveCursor(&writer, 3, 7);
    try hideCursor(&writer);
    try showCursor(&writer);
    try std.testing.expectEqualStrings("\x1b[3;7H\x1b[?25l\x1b[?25h", writer.buffered());
}
