//! Terminal capability probe for the cell-border protocol.
//!
//! The protocol has no environment-variable signal. The application sends the
//! query followed by Primary Device Attributes and reads replies in order: a
//! cell-border answer before DA1 means support, DA1 without one means the
//! terminal (or multiplexer) discarded the unknown DCS. A short timeout covers
//! terminals that answer neither. This file owns the terminal byte-stream part;
//! the wire format and parser live in `ui/cell_border.zig`.

const std = @import("std");
const posix = std.posix;
const ui = @import("ui");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const tui = @import("./tui.zig");

pub const timeout_ms: i64 = 250;

pub const Result = struct {
    supported: bool = false,
    capabilities: ui.cell_border.Capabilities = .{},
    /// Bytes read while probing, including the replies. The caller feeds them
    /// through the normal input decoder, which ignores DCS/OSC replies; this
    /// keeps a key typed during startup from being lost.
    leftover: ?[]u8 = null,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        if (self.leftover) |bytes| allocator.free(bytes);
    }
};

pub fn probe(allocator: std.mem.Allocator, out: *std.Io.Writer) !Result {
    try out.writeAll(ui.cell_border.query);
    try out.writeAll(ui.cell_border.da1);
    try out.flush();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    const deadline = time_compat.milliTimestamp() + timeout_ms;
    while (true) {
        const now = time_compat.milliTimestamp();
        if (now >= deadline) break;
        const remaining: i32 = @intCast(@min(deadline - now, timeout_ms));
        if (!try tui.pollInput(remaining)) break;
        const before = buffer.items.len;
        _ = try tui.readFd(posix.STDIN_FILENO, &buffer);
        // A readable fd with no bytes is EOF (piped stdin); stop instead of
        // spinning until the deadline.
        if (buffer.items.len == before) break;
        if (ui.cell_border.containsDa1(buffer.items)) break;
    }

    const capabilities = ui.cell_border.parseReply(buffer.items);
    const supported = if (capabilities) |value| value.has(.pen) else false;
    const leftover = if (buffer.items.len == 0) null else try allocator.dupe(u8, buffer.items);

    return .{
        .supported = supported,
        .capabilities = capabilities orelse .{},
        .leftover = leftover,
    };
}
