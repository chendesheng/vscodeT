// Port of `src/vs/platform/log/common/bufferLog.ts`.
//
// Terminal adaptation: `AbstractMessageLogger` is composed rather than
// extended, so `BufferLogger.init` initializes in place (the base logger holds
// a pointer to the buffer logger's callback context).
const std = @import("std");
const Allocator = std.mem.Allocator;
const log_module = @import("log.zig");
const AbstractMessageLogger = log_module.AbstractMessageLogger;
const ILogger = log_module.ILogger;
const LogLevel = log_module.LogLevel;
const LogLevelListener = log_module.LogLevelListener;

pub const BufferLogger = struct {
    allocator: Allocator,
    base: AbstractMessageLogger,
    logger: ?ILogger = null,
    buffer: std.array_list.Managed(Entry),
    listener: LogLevelListener,
    listener_id: ?usize = null,

    const Entry = struct {
        level: LogLevel,
        message: []u8,
    };

    /// Initializes in place so the base logger's callback context is stable.
    pub fn init(self: *BufferLogger, allocator: Allocator, log_level: LogLevel) void {
        self.* = .{
            .allocator = allocator,
            .base = undefined,
            .buffer = std.array_list.Managed(Entry).init(allocator),
            .listener = .{ .context = self, .callback = forwardLevel },
        };
        self.base = AbstractMessageLogger.init(allocator, self, logMessage, false);
        self.base.setLevel(log_level);
    }

    pub fn deinit(self: *BufferLogger) void {
        if (self.listener_id) |id| {
            if (self.logger) |logger| logger.unsubscribeLogLevel(id);
        }
        for (self.buffer.items) |entry| self.allocator.free(entry.message);
        self.buffer.deinit();
        self.base.deinit();
    }

    pub fn interface(self: *BufferLogger) ILogger {
        return self.base.interface();
    }

    pub fn setLogger(self: *BufferLogger, logger: ILogger) !void {
        if (self.logger) |previous| {
            if (self.listener_id) |id| previous.unsubscribeLogLevel(id);
        }
        self.logger = logger;
        self.base.setLevel(logger.getLevel());
        self.listener_id = try logger.subscribeLogLevel(&self.listener);

        var first_error: ?anyerror = null;
        for (self.buffer.items) |entry| {
            log_module.log(logger, entry.level, entry.message) catch |err| {
                if (first_error == null) first_error = err;
            };
            self.allocator.free(entry.message);
        }
        self.buffer.clearRetainingCapacity();
        if (first_error) |err| return err;
    }

    fn forwardLevel(context: *anyopaque, level: LogLevel) void {
        const self: *BufferLogger = @ptrCast(@alignCast(context));
        self.base.setLevel(level);
    }

    fn logMessage(context: *anyopaque, level: LogLevel, message: []const u8) anyerror!void {
        const self: *BufferLogger = @ptrCast(@alignCast(context));
        if (self.logger) |logger| {
            return log_module.log(logger, level, message);
        }
        try self.buffer.append(.{
            .level = level,
            .message = try self.allocator.dupe(u8, message),
        });
    }
};

test "BufferLogger buffers until a logger is attached" {
    const allocator = std.testing.allocator;

    var received = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (received.items) |item| allocator.free(item);
        received.deinit();
    }

    const sink = struct {
        fn call(context: *anyopaque, level: LogLevel, args: []const log_module.LogArg) anyerror!void {
            _ = level;
            const list: *std.array_list.Managed([]u8) = @ptrCast(@alignCast(context));
            const text = try log_module.format(list.allocator, args, false);
            try list.append(text);
        }
    };

    var adapter = log_module.AdapterLogger.init(allocator, .{ .context = &received, .log_fn = sink.call }, .info);
    defer adapter.deinit();

    var buffer_logger: BufferLogger = undefined;
    buffer_logger.init(allocator, .info);
    defer buffer_logger.deinit();

    try buffer_logger.interface().info("before", &.{});
    try buffer_logger.interface().trace("suppressed", &.{});
    try std.testing.expectEqual(@as(usize, 1), buffer_logger.buffer.items.len);

    try buffer_logger.setLogger(adapter.interface());
    try std.testing.expectEqual(@as(usize, 0), buffer_logger.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 1), received.items.len);
    try std.testing.expectEqualStrings("before", received.items[0]);

    try buffer_logger.interface().info("after", &.{});
    try std.testing.expectEqual(@as(usize, 2), received.items.len);
    try std.testing.expectEqualStrings("after", received.items[1]);

    // Level changes from the attached logger are forwarded.
    adapter.setLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, buffer_logger.base.getLevel());
}
