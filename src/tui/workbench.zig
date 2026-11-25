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
    watched: std.MultiArrayList(Watch) = .empty,

    const Watch = struct {
        descriptor: if (builtin.os.tag == .windows) void else std.posix.pollfd,
        source: union(enum) { input, watcher, terminal_output: usize, terminal_exit: usize },
    };

    pub fn init(workbench: *Workbench, output: *std.Io.Writer, border_probe_bytes: ?[]const u8, image_probe_bytes: ?[]const u8) !TerminalWorkbench {
        var buffer = try std.array_list.Managed(u8).initCapacity(workbench.allocator, 4096);
        errdefer buffer.deinit();
        if (border_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        if (image_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        return .{ .workbench = workbench, .output = output, .input_buffer = buffer };
    }

    pub fn scheduleFrames(self: *TerminalWorkbench, needs_render: *bool) void {
        self.workbench.frame_scheduler = .{ .context = needs_render, .request = requestFrame };
    }

    fn requestFrame(context: *anyopaque) void {
        const needs_render: *bool = @ptrCast(@alignCast(context));
        needs_render.* = true;
    }

    pub fn deinit(self: *TerminalWorkbench) void {
        self.workbench.frame_scheduler = null;
        self.watched.deinit(self.workbench.allocator);
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
            try self.waitPosix(timeout, &result);
        }
        return result;
    }

    fn waitPosix(self: *TerminalWorkbench, timeout: i32, result: *Readiness) !void {
        const posix = std.posix;
        const workbench = self.workbench;
        self.watched.len = 0;
        try self.watch(posix.STDIN_FILENO, posix.POLL.IN, .input);
        if (workbench.fileWatcherFd()) |fd| try self.watch(fd, posix.POLL.IN, .watcher);
        if (workbench.terminal_service) |service| {
            for (0..service.instanceCount()) |index| {
                const instance = service.instanceAt(index).?;
                if (instance.fd()) |fd| {
                    const events: i16 = if (instance.hasPendingWrite()) posix.POLL.IN | posix.POLL.OUT else posix.POLL.IN;
                    try self.watch(fd, events, .{ .terminal_output = instance.id });
                }
                try self.watch(instance.process.exit_fd, posix.POLL.IN, .{ .terminal_exit = instance.id });
            }
        }
        const descriptors = self.watched.items(.descriptor);
        if (try posix.poll(descriptors, timeout) == 0) return;
        for (descriptors, self.watched.items(.source)) |descriptor, source| {
            if (descriptor.revents == 0) continue;
            switch (source) {
                .input => result.input = true,
                .watcher => if (workbench.pollFileWatcher(time_compat.milliTimestamp())) {
                    result.redraw = true;
                },
                .terminal_output => |id| {
                    const service = workbench.terminal_service orelse continue;
                    const instance = service.getInstanceFromId(id) orelse continue;
                    if (descriptor.revents & posix.POLL.OUT != 0) instance.flushInput();
                    if (descriptor.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        if (try instance.feedOutput()) result.redraw = true;
                    }
                },
                .terminal_exit => |id| {
                    const service = workbench.terminal_service orelse continue;
                    const instance = service.getInstanceFromId(id) orelse continue;
                    instance.onProcessExit();
                    if (service.getInstanceFromId(id)) |exited| try workbench.disposeExitedTerminal(exited);
                    result.redraw = true;
                },
            }
        }
    }

    fn watch(self: *TerminalWorkbench, fd: std.posix.fd_t, events: i16, source: @FieldType(Watch, "source")) !void {
        try self.watched.append(self.workbench.allocator, .{
            .descriptor = .{ .fd = fd, .events = events, .revents = 0 },
            .source = source,
        });
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
