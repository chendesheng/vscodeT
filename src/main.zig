const std = @import("std");
const app = @import("tui/app.zig");
const tui = @import("tui/tui.zig");

pub const panic = tui.panic;

pub fn main(init: std.process.Init) !void {
    try app.main(init);
}
