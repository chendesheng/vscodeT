const app = @import("tui/app.zig");
const tui = @import("tui/tui.zig");

pub const panic = tui.panic;

pub fn main() !void {
    try app.main();
}
