const std = @import("std");
const app = @import("./tui/app.zig");
const tui = @import("./tui/tui.zig");

pub const panic = tui.panic;

/// The standard library calls `root.debug.handleSegfault` for SIGSEGV, SIGBUS,
/// SIGILL and SIGFPE. A crash signal does not go through `panic`, so without
/// this hook the stack trace would be printed while the TUI still owns the
/// alternate screen and raw mode; the terminal would discard it on exit.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: anytype) noreturn {
        tui.restoreTerminalForCrash();
        std.debug.defaultHandleSegfault(addr, name, opt_ctx);
    }
};

/// The TUI owns the alternate screen, so `std.log` must never use its default
/// stderr writer while the screen is active. The app routes engine diagnostics
/// (libghostty-vt's parser included) into the workbench log file instead.
pub const std_options: std.Options = .{ .logFn = app.logStd };

pub fn main(init: std.process.Init) !void {
    try app.main(init);
}
