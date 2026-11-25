//! Terminal host for the workbench. Owns tty input bytes between reads,
//! dispatches file-descriptor readiness, and writes completed frames.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const tui = @import("tui.zig");
const terminal_input = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
pub const Workbench = @import("../vs/workbench/browser/workbench.zig").Workbench;

pub const TerminalWorkbench = struct {
    workbench: *Workbench,
    output: *std.Io.Writer,
    input_buffer: std.array_list.Managed(u8),
    awaiting_continuation: bool = false,

    pub fn init(workbench: *Workbench, output: *std.Io.Writer, border_probe_bytes: ?[]const u8, image_probe_bytes: ?[]const u8) !TerminalWorkbench {
        var buffer = try std.array_list.Managed(u8).initCapacity(workbench.allocator, 4096);
        errdefer buffer.deinit();
        if (border_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        if (image_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        return .{ .workbench = workbench, .output = output, .input_buffer = buffer };
    }

    pub fn deinit(self: *TerminalWorkbench) void {
        self.input_buffer.deinit();
    }

    pub fn hasBufferedInput(self: *const TerminalWorkbench) bool {
        return self.input_buffer.items.len != 0 and !self.awaiting_continuation;
    }

    const Readiness = struct { input: bool = false, redraw: bool = false };

    pub fn wait(self: *TerminalWorkbench, timeout: i32) !Readiness {
        const workbench = self.workbench;
        var result = Readiness{};
        if (builtin.os.tag == .windows) {
            const polled = try tui.pollInputWithHandle(workbench.fileWatcherHandle(), timeout);
            result.input = polled.input;
            if (polled.extra) {
                if (workbench.pollFileWatcher(time_compat.milliTimestamp())) result.redraw = true;
            }
        } else {
            var extra_fds: [tui.max_poll_fds]std.posix.fd_t = undefined;
            var extra_ready: [tui.max_poll_fds]bool = undefined;
            var terminal_indices: [tui.max_poll_fds]usize = undefined;
            var count: usize = 0;
            var has_watcher = false;
            if (workbench.fileWatcherFd()) |fd| {
                extra_fds[count] = fd;
                has_watcher = true;
                count += 1;
            }
            var terminal_count: usize = 0;
            for (0..workbench.terminalCount()) |index| {
                const fd = workbench.terminalFd(index) orelse continue;
                if (count >= tui.max_poll_fds) break;
                extra_fds[count] = fd;
                terminal_indices[terminal_count] = index;
                terminal_count += 1;
                count += 1;
            }
            result.input = try tui.pollInputWithFds(
                extra_fds[0..count],
                extra_ready[0..count],
                timeout,
            );
            if (has_watcher and extra_ready[0]) {
                if (workbench.pollFileWatcher(time_compat.milliTimestamp())) result.redraw = true;
            }
            const terminal_offset: usize = if (has_watcher) 1 else 0;
            for (0..terminal_count) |index| {
                if (!extra_ready[terminal_offset + index]) continue;
                if (workbench.onTerminalReady(terminal_indices[index])) result.redraw = true;
            }
        }
        return result;
    }

    pub fn handleResize(self: *TerminalWorkbench) !bool {
        const size = try tui.resizedSize() orelse return false;
        try self.workbench.resize(size.width, size.height);
        self.workbench.setCellPixelSize(size.cell_width_px, size.cell_height_px);
        try tui.clearScreen(self.output);
        return true;
    }

    const Batch = struct { decoded: ui.input.DecodeResult, pasted: bool };

    pub fn readEvents(self: *TerminalWorkbench, input_ready: bool) !Batch {
        const w = self.workbench;
        if (input_ready or self.input_buffer.items.len == 0) _ = try tui.readFd(w.io, 0, &self.input_buffer);
        var pasted = false;
        if (w.terminalAcceptsPaste()) {
            while (true) {
                switch (try terminal_input.takePaste(w.allocator, &self.input_buffer)) {
                    .taken => |bytes| {
                        defer w.allocator.free(bytes);
                        try w.pasteTerminal(bytes);
                        pasted = true;
                    },
                    .incomplete => return .{ .decoded = .{ .items = .empty, .consumed = 0 }, .pasted = pasted },
                    .none => break,
                }
            }
        }
        return .{ .decoded = try ui.input.decodeWithRemainder(w.allocator, self.input_buffer.items), .pasted = pasted };
    }

    /// Decoded events may borrow input bytes until dispatch finishes.
    pub fn consume(self: *TerminalWorkbench, count: usize) void {
        const remaining = self.input_buffer.items[count..];
        std.mem.copyForwards(u8, self.input_buffer.items[0..remaining.len], remaining);
        self.input_buffer.shrinkRetainingCapacity(remaining.len);
        self.awaiting_continuation = remaining.len != 0;
    }

    pub fn render(self: *TerminalWorkbench) !void {
        try self.workbench.render(self.output);
        try self.workbench.syncCursor(self.output);
        try self.output.flush();
    }
};
