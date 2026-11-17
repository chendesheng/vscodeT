// Port of `src/vs/platform/log/common/logService.ts`.
//
// Terminal adaptation: upstream registers `primaryLogger.onDidChangeLogLevel`
// in the constructor. The listener needs a stable address, so the service (and
// its multiplexer) is created on the heap by `create`; `deinit` unsubscribes
// and releases the multiplexer. Upstream's `Disposable` also unregisters the
// listener, which is the same contract.
const std = @import("std");
const Allocator = std.mem.Allocator;
const log_module = @import("log.zig");
const ILogger = log_module.ILogger;
const LogLevel = log_module.LogLevel;
const LogArg = log_module.LogArg;
const LogMessage = log_module.LogMessage;
const LogLevelListener = log_module.LogLevelListener;
const MultiplexLogger = log_module.MultiplexLogger;
const loggerOf = log_module.loggerOf;

pub const LogService = struct {
    allocator: Allocator,
    logger: *MultiplexLogger,
    listener: LogLevelListener,
    listener_id: ?usize = null,

    /// Builds `MultiplexLogger([primary, ...other])` and forwards the primary
    /// logger's level changes into it.
    pub fn create(allocator: Allocator, primary: ILogger, other_loggers: []const ILogger) !*LogService {
        const loggers = try allocator.alloc(ILogger, other_loggers.len + 1);
        errdefer allocator.free(loggers);
        loggers[0] = primary;
        @memcpy(loggers[1..], other_loggers);

        const multiplexer = try allocator.create(MultiplexLogger);
        errdefer allocator.destroy(multiplexer);
        multiplexer.* = MultiplexLogger.init(allocator, loggers);
        errdefer multiplexer.deinit();

        const service = try allocator.create(LogService);
        errdefer allocator.destroy(service);
        service.* = .{
            .allocator = allocator,
            .logger = multiplexer,
            .listener = .{ .context = service, .callback = forwardLevel },
        };
        service.listener_id = try primary.subscribeLogLevel(&service.listener);
        return service;
    }

    pub fn deinit(self: *LogService) void {
        if (self.listener_id) |id| {
            self.logger.loggers[0].unsubscribeLogLevel(id);
        }
        self.listener_id = null;
        self.logger.deinit();
        self.allocator.free(self.logger.loggers);
        self.allocator.destroy(self.logger);
        self.allocator.destroy(self);
    }

    fn forwardLevel(context: *anyopaque, level: LogLevel) void {
        const self: *LogService = @ptrCast(@alignCast(context));
        self.setLevel(level);
    }

    pub fn interface(self: *LogService) ILogger {
        return loggerOf(LogService).of(self);
    }

    pub fn getLevel(self: *LogService) LogLevel {
        return self.logger.getLevel();
    }

    pub fn setLevel(self: *LogService, level: LogLevel) void {
        self.logger.setLevel(level);
    }

    pub fn subscribeLogLevel(self: *LogService, listener: *LogLevelListener) !usize {
        return self.logger.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *LogService, id: usize) void {
        self.logger.unsubscribeLogLevel(id);
    }

    pub fn trace(self: *LogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.trace(message, args);
    }

    pub fn debug(self: *LogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.debug(message, args);
    }

    pub fn info(self: *LogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.info(message, args);
    }

    pub fn warn(self: *LogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.warn(message, args);
    }

    pub fn err(self: *LogService, message: LogMessage, args: []const LogArg) !void {
        return self.logger.err(message, args);
    }

    pub fn flush(self: *LogService) void {
        self.logger.flush();
    }

    pub fn dispose(self: *LogService) void {
        self.logger.dispose();
    }
};

test "LogService forwards level changes from the primary logger" {
    const allocator = std.testing.allocator;

    var received = std.array_list.Managed(LogArg).init(allocator);
    defer received.deinit();

    const sink = struct {
        fn call(context: *anyopaque, level: LogLevel, args: []const LogArg) anyerror!void {
            _ = level;
            const list: *std.array_list.Managed(LogArg) = @ptrCast(@alignCast(context));
            for (args) |arg| try list.append(arg);
        }
    };

    var primary = log_module.AdapterLogger.init(allocator, .{ .context = &received, .log_fn = sink.call }, .info);
    defer primary.deinit();

    const service = try LogService.create(allocator, primary.interface(), &.{});
    defer service.deinit();

    try std.testing.expectEqual(LogLevel.info, service.getLevel());

    primary.setLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, service.getLevel());

    try service.interface().info("hello", &.{.{ .string = "world" }});
    try std.testing.expectEqual(@as(usize, 2), received.items.len);
    try std.testing.expectEqualStrings("hello", received.items[0].string);
    try std.testing.expectEqualStrings("world", received.items[1].string);
}
