// Port of `src/vs/platform/log/common/log.ts`.
//
// Terminal adaptations:
// - Variadic `...args: unknown[]` parameters become `[]const LogArg`; there is
//   no JS `String()`/`JSON.stringify`, so object values are passed
//   pre-serialized (`object_json`).
// - `ILogger.error` is `err` and `LogLevel.Error` is `.err` (`error` is a Zig
//   keyword).
// - Zig has no class inheritance. `AbstractLogger` and `AbstractMessageLogger`
//   are composed structs: the abstract `log(level, message)` method is a
//   callback (as in `AdapterLogger`) and the `error` override that test loggers
//   add is an `on_error` hook.
// - Events use the repository `Emitter`; `onDidChangeLogLevel` subscriptions
//   take a caller-owned `LogLevelListener` and return a listener id.
// - Not ported in this file:
//   - `ConsoleLogger`/`ConsoleMainLogger`: the TUI owns the terminal (alternate
//     screen and raw mode), so there is no console to write to during a
//     session; `fileLog.zig` writes to the main log file instead.
//   - `registerDevConsoleLogForwarder`: no development console layer.
//   - `AbstractLoggerService`/`ILoggerService`: they key loggers by `URI` and
//     feed the log-output picker, which the TUI does not have. `LogService` is
//     the service the TUI consumes.
//   - `CONTEXT_LOG_LEVEL`: no context-key layer yet (tracked by the actions
//     slice).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const error_message = @import("../../../base/common/errorMessage.zig");
const ErrorLike = error_message.ErrorLike;
const ErrorObject = error_message.ErrorObject;
const toErrorMessage = error_message.toErrorMessage;
const time_compat = @import("../../../base/common/timeCompat.zig");

const log_module = @This();

pub const LogLevel = enum(u8) {
    off = 0,
    trace = 1,
    debug = 2,
    info = 3,
    warning = 4,
    err = 5,
};

pub const DEFAULT_LOG_LEVEL: LogLevel = .info;

/// Upstream `canLog`.
pub fn canLog(logger_level: LogLevel, message_level: LogLevel) bool {
    return logger_level != .off and @backingInt(logger_level) <= @backingInt(message_level);
}

/// Upstream `LogLevelToString`.
pub fn LogLevelToString(level: LogLevel) []const u8 {
    return switch (level) {
        .trace => "trace",
        .debug => "debug",
        .info => "info",
        .warning => "warn",
        .err => "error",
        .off => "off",
    };
}

pub const LocalizedString = struct {
    original: []const u8,
    value: []const u8,
};

/// Upstream `LogLevelToLocalizedString` (English originals).
pub fn LogLevelToLocalizedString(level: LogLevel) LocalizedString {
    const value = switch (level) {
        .trace => "Trace",
        .debug => "Debug",
        .info => "Info",
        .warning => "Warning",
        .err => "Error",
        .off => "Off",
    };
    return .{ .original = value, .value = value };
}

/// Upstream `parseLogLevel`. Upstream expects the input to be lowercase.
pub fn parseLogLevel(log_level: []const u8) ?LogLevel {
    const parsed: LogLevel = if (std.mem.eql(u8, log_level, "trace"))
        .trace
    else if (std.mem.eql(u8, log_level, "debug"))
        .debug
    else if (std.mem.eql(u8, log_level, "info"))
        .info
    else if (std.mem.eql(u8, log_level, "warn"))
        .warning
    else if (std.mem.eql(u8, log_level, "error"))
        .err
    else if (std.mem.eql(u8, log_level, "critical"))
        .err
    else if (std.mem.eql(u8, log_level, "off"))
        .off
    else
        return null;
    return parsed;
}

/// A single value of upstream's `...args: unknown[]`.
pub const LogArg = union(enum) {
    string: []const u8,
    integer: i64,
    /// A JS `number` that is not an integer.
    number: f64,
    boolean: bool,
    /// An object already serialized by the caller (`JSON.stringify`).
    object_json: []const u8,
    error_value: *const ErrorObject,
    /// Upstream `null`/`undefined` printed as `null`.
    null_value,
};

/// Upstream `string | Error` at the `error` call site.
pub const LogMessage = union(enum) {
    string: []const u8,
    error_value: *const ErrorObject,
};

/// Upstream `format(args, verbose)`.
pub fn format(allocator: Allocator, args: []const LogArg, verbose: bool) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    for (args, 0..) |arg, index| {
        if (index > 0) try result.append(' ');
        switch (arg) {
            .string => |text| try result.appendSlice(text),
            .integer => |value| try result.print("{d}", .{value}),
            .number => |value| try result.print("{d}", .{value}),
            .boolean => |value| try result.appendSlice(if (value) "true" else "false"),
            .object_json => |json| try result.appendSlice(json),
            .null_value => try result.appendSlice("null"),
            .error_value => |value| {
                const message = try toErrorMessage(allocator, .{ .object = value }, verbose);
                defer allocator.free(message);
                try result.appendSlice(message);
            },
        }
    }

    return result.toOwnedSlice();
}

pub const LogLevelListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, level: LogLevel) void,
};

pub const ILogger = struct {
    context: *anyopaque,
    get_level_fn: *const fn (context: *anyopaque) LogLevel,
    set_level_fn: *const fn (context: *anyopaque, level: LogLevel) void,
    trace_fn: *const fn (context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void,
    debug_fn: *const fn (context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void,
    info_fn: *const fn (context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void,
    warn_fn: *const fn (context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void,
    err_fn: *const fn (context: *anyopaque, message: LogMessage, args: []const LogArg) anyerror!void,
    flush_fn: *const fn (context: *anyopaque) void,
    subscribe_log_level_fn: *const fn (context: *anyopaque, listener: *LogLevelListener) anyerror!usize,
    unsubscribe_log_level_fn: *const fn (context: *anyopaque, id: usize) void,
    dispose_fn: *const fn (context: *anyopaque) void,

    pub fn getLevel(self: ILogger) LogLevel {
        return self.get_level_fn(self.context);
    }

    pub fn setLevel(self: ILogger, level: LogLevel) void {
        self.set_level_fn(self.context, level);
    }

    pub fn trace(self: ILogger, message: []const u8, args: []const LogArg) !void {
        return self.trace_fn(self.context, message, args);
    }

    pub fn debug(self: ILogger, message: []const u8, args: []const LogArg) !void {
        return self.debug_fn(self.context, message, args);
    }

    pub fn info(self: ILogger, message: []const u8, args: []const LogArg) !void {
        return self.info_fn(self.context, message, args);
    }

    pub fn warn(self: ILogger, message: []const u8, args: []const LogArg) !void {
        return self.warn_fn(self.context, message, args);
    }

    /// Upstream `error`. The name is `err` because `error` is a Zig keyword.
    pub fn err(self: ILogger, message: LogMessage, args: []const LogArg) !void {
        return self.err_fn(self.context, message, args);
    }

    pub fn flush(self: ILogger) void {
        self.flush_fn(self.context);
    }

    pub fn subscribeLogLevel(self: ILogger, listener: *LogLevelListener) !usize {
        return self.subscribe_log_level_fn(self.context, listener);
    }

    pub fn unsubscribeLogLevel(self: ILogger, id: usize) void {
        self.unsubscribe_log_level_fn(self.context, id);
    }

    pub fn dispose(self: ILogger) void {
        self.dispose_fn(self.context);
    }
};

/// Upstream `log(logger, level, message)`.
pub fn log(logger: ILogger, level: LogLevel, message: []const u8) !void {
    switch (level) {
        .trace => try logger.trace(message, &.{}),
        .debug => try logger.debug(message, &.{}),
        .info => try logger.info(message, &.{}),
        .warning => try logger.warn(message, &.{}),
        .err => try logger.err(.{ .string = message }, &.{}),
        .off => {},
    }
}

/// The level and event state shared by every concrete logger (the portable
/// part of upstream `AbstractLogger`).
pub const LoggerBase = struct {
    allocator: Allocator,
    level: LogLevel = DEFAULT_LOG_LEVEL,
    emitter: Emitter(LogLevel),
    disposed: bool = false,

    pub fn init(allocator: Allocator) LoggerBase {
        return .{
            .allocator = allocator,
            .emitter = Emitter(LogLevel).init(allocator),
        };
    }

    pub fn deinit(self: *LoggerBase) void {
        self.emitter.deinit();
    }

    pub fn getLevel(self: *const LoggerBase) LogLevel {
        return self.level;
    }

    pub fn setLevel(self: *LoggerBase, level: LogLevel) void {
        if (self.level != level) {
            self.level = level;
            self.emitter.fire(level) catch {};
        }
    }

    pub fn checkLogLevel(self: *const LoggerBase, level: LogLevel) bool {
        return log_module.canLog(self.level, level);
    }

    pub fn canLog(self: *const LoggerBase, level: LogLevel) bool {
        if (self.disposed) return false;
        return self.checkLogLevel(level);
    }

    pub fn subscribeLogLevel(self: *LoggerBase, listener: *LogLevelListener) !usize {
        return self.emitter.listen(listener, struct {
            fn call(level: LogLevel, value: *LogLevelListener) anyerror!void {
                value.callback(value.context, level);
            }
        }.call);
    }

    pub fn unsubscribeLogLevel(self: *LoggerBase, id: usize) void {
        self.emitter.unlisten(id);
    }

    pub fn dispose(self: *LoggerBase) void {
        self.disposed = true;
    }
};

/// Adapts a concrete logger (a type with the `ILogger` methods) to the
/// `ILogger` vtable. Follows the repository `commandOf` pattern.
pub fn loggerOf(comptime T: type) type {
    return struct {
        fn getLevelFn(context: *anyopaque) LogLevel {
            const self: *T = @ptrCast(@alignCast(context));
            return self.getLevel();
        }

        fn setLevelFn(context: *anyopaque, level: LogLevel) void {
            const self: *T = @ptrCast(@alignCast(context));
            self.setLevel(level);
        }

        fn traceFn(context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.trace(message, args);
        }

        fn debugFn(context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.debug(message, args);
        }

        fn infoFn(context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.info(message, args);
        }

        fn warnFn(context: *anyopaque, message: []const u8, args: []const LogArg) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.warn(message, args);
        }

        fn errFn(context: *anyopaque, message: LogMessage, args: []const LogArg) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.err(message, args);
        }

        fn flushFn(context: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(context));
            self.flush();
        }

        fn subscribeLogLevelFn(context: *anyopaque, listener: *LogLevelListener) anyerror!usize {
            const self: *T = @ptrCast(@alignCast(context));
            return self.subscribeLogLevel(listener);
        }

        fn unsubscribeLogLevelFn(context: *anyopaque, id: usize) void {
            const self: *T = @ptrCast(@alignCast(context));
            self.unsubscribeLogLevel(id);
        }

        fn disposeFn(context: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(context));
            self.dispose();
        }

        /// Returns the `ILogger` view of `self`.
        pub fn of(self: *T) ILogger {
            return .{
                .context = self,
                .get_level_fn = getLevelFn,
                .set_level_fn = setLevelFn,
                .trace_fn = traceFn,
                .debug_fn = debugFn,
                .info_fn = infoFn,
                .warn_fn = warnFn,
                .err_fn = errFn,
                .flush_fn = flushFn,
                .subscribe_log_level_fn = subscribeLogLevelFn,
                .unsubscribe_log_level_fn = unsubscribeLogLevelFn,
                .dispose_fn = disposeFn,
            };
        }
    };
}

pub const LogFn = *const fn (context: *anyopaque, level: LogLevel, message: []const u8) anyerror!void;
pub const ErrorHook = *const fn (context: *anyopaque, message: LogMessage) void;

/// Upstream `AbstractMessageLogger`. The abstract `log(level, message)` is a
/// callback. `on_error` mirrors test loggers that override `error` to record
/// the message before the base implementation filters and formats it.
pub const AbstractMessageLogger = struct {
    base: LoggerBase,
    log_context: *anyopaque,
    log_fn: LogFn,
    log_always: bool = false,
    on_error: ?ErrorHook = null,
    on_error_context: ?*anyopaque = null,

    pub fn init(allocator: Allocator, log_context: *anyopaque, log_fn: LogFn, log_always: bool) AbstractMessageLogger {
        return .{
            .base = LoggerBase.init(allocator),
            .log_context = log_context,
            .log_fn = log_fn,
            .log_always = log_always,
        };
    }

    pub fn deinit(self: *AbstractMessageLogger) void {
        self.base.deinit();
    }

    pub fn interface(self: *AbstractMessageLogger) ILogger {
        return loggerOf(AbstractMessageLogger).of(self);
    }

    pub fn getLevel(self: *AbstractMessageLogger) LogLevel {
        return self.base.getLevel();
    }

    pub fn setLevel(self: *AbstractMessageLogger, level: LogLevel) void {
        self.base.setLevel(level);
    }

    pub fn subscribeLogLevel(self: *AbstractMessageLogger, listener: *LogLevelListener) !usize {
        return self.base.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *AbstractMessageLogger, id: usize) void {
        self.base.unsubscribeLogLevel(id);
    }

    pub fn dispose(self: *AbstractMessageLogger) void {
        self.base.dispose();
    }

    pub fn checkLogLevel(self: *AbstractMessageLogger, level: LogLevel) bool {
        return self.log_always or self.base.checkLogLevel(level);
    }

    pub fn canLog(self: *AbstractMessageLogger, level: LogLevel) bool {
        if (self.base.disposed) return false;
        return self.checkLogLevel(level);
    }

    pub fn trace(self: *AbstractMessageLogger, message: []const u8, args: []const LogArg) !void {
        if (self.canLog(.trace)) try self.logWithMessage(.trace, message, args, true);
    }

    pub fn debug(self: *AbstractMessageLogger, message: []const u8, args: []const LogArg) !void {
        if (self.canLog(.debug)) try self.logWithMessage(.debug, message, args, false);
    }

    pub fn info(self: *AbstractMessageLogger, message: []const u8, args: []const LogArg) !void {
        if (self.canLog(.info)) try self.logWithMessage(.info, message, args, false);
    }

    pub fn warn(self: *AbstractMessageLogger, message: []const u8, args: []const LogArg) !void {
        if (self.canLog(.warning)) try self.logWithMessage(.warning, message, args, false);
    }

    pub fn err(self: *AbstractMessageLogger, message: LogMessage, args: []const LogArg) !void {
        if (self.on_error) |hook| hook(self.on_error_context orelse self.log_context, message);
        if (!self.canLog(.err)) return;
        switch (message) {
            .string => |text| try self.logWithMessage(.err, text, args, false),
            .error_value => |value| {
                // Upstream replaces the first argument with `message.stack`;
                // a missing stack stringifies as `undefined`.
                try self.logWithMessage(.err, value.stack orelse "undefined", args, false);
            },
        }
    }

    pub fn flush(self: *AbstractMessageLogger) void {
        _ = self;
    }

    fn logWithMessage(self: *AbstractMessageLogger, level: LogLevel, message: []const u8, args: []const LogArg, verbose: bool) !void {
        var all = std.array_list.Managed(LogArg).init(self.base.allocator);
        defer all.deinit();
        try all.append(.{ .string = message });
        try all.appendSlice(args);

        const text = try format(self.base.allocator, all.items, verbose);
        defer self.base.allocator.free(text);
        try self.log_fn(self.log_context, level, text);
    }
};

pub const Adapter = struct {
    context: *anyopaque,
    log_fn: *const fn (context: *anyopaque, level: LogLevel, args: []const LogArg) anyerror!void,
};

/// Upstream `AdapterLogger`.
pub const AdapterLogger = struct {
    base: LoggerBase,
    adapter: Adapter,

    pub fn init(allocator: Allocator, adapter: Adapter, log_level: LogLevel) AdapterLogger {
        var self = AdapterLogger{
            .base = LoggerBase.init(allocator),
            .adapter = adapter,
        };
        self.setLevel(log_level);
        return self;
    }

    pub fn deinit(self: *AdapterLogger) void {
        self.base.deinit();
    }

    pub fn interface(self: *AdapterLogger) ILogger {
        return loggerOf(AdapterLogger).of(self);
    }

    pub fn getLevel(self: *AdapterLogger) LogLevel {
        return self.base.getLevel();
    }

    pub fn setLevel(self: *AdapterLogger, level: LogLevel) void {
        self.base.setLevel(level);
    }

    pub fn subscribeLogLevel(self: *AdapterLogger, listener: *LogLevelListener) !usize {
        return self.base.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *AdapterLogger, id: usize) void {
        self.base.unsubscribeLogLevel(id);
    }

    pub fn dispose(self: *AdapterLogger) void {
        self.base.dispose();
    }

    pub fn canLog(self: *AdapterLogger, level: LogLevel) bool {
        return self.base.canLog(level);
    }

    pub fn trace(self: *AdapterLogger, message: []const u8, args: []const LogArg) !void {
        try self.forward(.trace, .{ .string = message }, args, false);
    }

    pub fn debug(self: *AdapterLogger, message: []const u8, args: []const LogArg) !void {
        try self.forward(.debug, .{ .string = message }, args, false);
    }

    pub fn info(self: *AdapterLogger, message: []const u8, args: []const LogArg) !void {
        try self.forward(.info, .{ .string = message }, args, false);
    }

    pub fn warn(self: *AdapterLogger, message: []const u8, args: []const LogArg) !void {
        try self.forward(.warning, .{ .string = message }, args, false);
    }

    /// Zig spelling of upstream's `warn(message: string | Error, ...)`, which
    /// widens the base `ILogger` signature in `AdapterLogger`.
    pub fn warnMessage(self: *AdapterLogger, message: LogMessage, args: []const LogArg) !void {
        try self.forward(.warning, message, args, false);
    }

    pub fn err(self: *AdapterLogger, message: LogMessage, args: []const LogArg) !void {
        try self.forward(.err, message, args, true);
    }

    pub fn flush(self: *AdapterLogger) void {
        _ = self;
    }

    fn forward(self: *AdapterLogger, level: LogLevel, message: LogMessage, args: []const LogArg, verbose: bool) !void {
        if (!self.canLog(level)) return;

        var all = std.array_list.Managed(LogArg).init(self.base.allocator);
        defer all.deinit();

        var formatted: ?[]u8 = null;
        defer if (formatted) |text| self.base.allocator.free(text);

        const first: []const u8 = switch (message) {
            .string => |text| text,
            .error_value => |value| blk: {
                // `extractMessage` uses the trace level to decide whether the
                // stack is included; `error` always formats verbosely.
                const include_stack = verbose or self.canLog(.trace);
                const text = try toErrorMessage(self.base.allocator, .{ .object = value }, include_stack);
                formatted = text;
                break :blk text;
            },
        };

        try all.append(.{ .string = first });
        try all.appendSlice(args);
        try self.adapter.log_fn(self.adapter.context, level, all.items);
    }
};

/// Upstream `MultiplexLogger`. The logger slice is borrowed; the caller keeps
/// the loggers alive for as long as the multiplexer is used.
pub const MultiplexLogger = struct {
    base: LoggerBase,
    loggers: []const ILogger,

    pub fn init(allocator: Allocator, loggers: []const ILogger) MultiplexLogger {
        var self = MultiplexLogger{
            .base = LoggerBase.init(allocator),
            .loggers = loggers,
        };
        if (loggers.len > 0) {
            self.setLevel(loggers[0].getLevel());
        }
        return self;
    }

    pub fn deinit(self: *MultiplexLogger) void {
        self.base.deinit();
    }

    pub fn interface(self: *MultiplexLogger) ILogger {
        return loggerOf(MultiplexLogger).of(self);
    }

    pub fn getLevel(self: *MultiplexLogger) LogLevel {
        return self.base.getLevel();
    }

    pub fn setLevel(self: *MultiplexLogger, level: LogLevel) void {
        for (self.loggers) |logger| logger.setLevel(level);
        self.base.setLevel(level);
    }

    pub fn subscribeLogLevel(self: *MultiplexLogger, listener: *LogLevelListener) !usize {
        return self.base.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *MultiplexLogger, id: usize) void {
        self.base.unsubscribeLogLevel(id);
    }

    pub fn trace(self: *MultiplexLogger, message: []const u8, args: []const LogArg) !void {
        for (self.loggers) |logger| try logger.trace(message, args);
    }

    pub fn debug(self: *MultiplexLogger, message: []const u8, args: []const LogArg) !void {
        for (self.loggers) |logger| try logger.debug(message, args);
    }

    pub fn info(self: *MultiplexLogger, message: []const u8, args: []const LogArg) !void {
        for (self.loggers) |logger| try logger.info(message, args);
    }

    pub fn warn(self: *MultiplexLogger, message: []const u8, args: []const LogArg) !void {
        for (self.loggers) |logger| try logger.warn(message, args);
    }

    pub fn err(self: *MultiplexLogger, message: LogMessage, args: []const LogArg) !void {
        for (self.loggers) |logger| try logger.err(message, args);
    }

    pub fn flush(self: *MultiplexLogger) void {
        for (self.loggers) |logger| logger.flush();
    }

    pub fn dispose(self: *MultiplexLogger) void {
        for (self.loggers) |logger| logger.dispose();
        self.base.dispose();
    }
};

/// Upstream `NullLogger`.
pub const NullLogger = struct {
    base: LoggerBase,

    pub fn init(allocator: Allocator) NullLogger {
        return .{ .base = LoggerBase.init(allocator) };
    }

    pub fn deinit(self: *NullLogger) void {
        self.base.deinit();
    }

    pub fn interface(self: *NullLogger) ILogger {
        return loggerOf(NullLogger).of(self);
    }

    pub fn getLevel(self: *NullLogger) LogLevel {
        _ = self;
        return .info;
    }

    pub fn setLevel(self: *NullLogger, level: LogLevel) void {
        _ = self;
        _ = level;
    }

    pub fn subscribeLogLevel(self: *NullLogger, listener: *LogLevelListener) !usize {
        return self.base.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *NullLogger, id: usize) void {
        self.base.unsubscribeLogLevel(id);
    }

    pub fn trace(self: *NullLogger, message: []const u8, args: []const LogArg) !void {
        _ = self;
        _ = message;
        _ = args;
    }

    pub fn debug(self: *NullLogger, message: []const u8, args: []const LogArg) !void {
        _ = self;
        _ = message;
        _ = args;
    }

    pub fn info(self: *NullLogger, message: []const u8, args: []const LogArg) !void {
        _ = self;
        _ = message;
        _ = args;
    }

    pub fn warn(self: *NullLogger, message: []const u8, args: []const LogArg) !void {
        _ = self;
        _ = message;
        _ = args;
    }

    pub fn err(self: *NullLogger, message: LogMessage, args: []const LogArg) !void {
        _ = self;
        _ = message;
        _ = args;
    }

    pub fn flush(self: *NullLogger) void {
        _ = self;
    }

    pub fn dispose(self: *NullLogger) void {
        self.base.dispose();
    }
};

/// Upstream `NullLogService`.
pub const NullLogService = struct {
    logger: NullLogger,

    pub fn init(allocator: Allocator) NullLogService {
        return .{ .logger = NullLogger.init(allocator) };
    }

    pub fn deinit(self: *NullLogService) void {
        self.logger.deinit();
    }

    pub fn interface(self: *NullLogService) ILogger {
        return loggerOf(NullLogService).of(self);
    }

    pub fn getLevel(self: *NullLogService) LogLevel {
        return self.logger.getLevel();
    }

    pub fn setLevel(self: *NullLogService, level: LogLevel) void {
        self.logger.setLevel(level);
    }

    pub fn subscribeLogLevel(self: *NullLogService, listener: *LogLevelListener) !usize {
        return self.logger.subscribeLogLevel(listener);
    }

    pub fn unsubscribeLogLevel(self: *NullLogService, id: usize) void {
        self.logger.unsubscribeLogLevel(id);
    }

    pub fn trace(self: *NullLogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.trace(message, args);
    }

    pub fn debug(self: *NullLogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.debug(message, args);
    }

    pub fn info(self: *NullLogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.info(message, args);
    }

    pub fn warn(self: *NullLogService, message: []const u8, args: []const LogArg) !void {
        return self.logger.warn(message, args);
    }

    pub fn err(self: *NullLogService, message: LogMessage, args: []const LogArg) !void {
        return self.logger.err(message, args);
    }

    pub fn flush(self: *NullLogService) void {
        self.logger.flush();
    }

    pub fn dispose(self: *NullLogService) void {
        self.logger.dispose();
    }
};

/// Upstream `createUnexpectedErrorHandler`. The handler owns the formatted
/// previous message used for the 1000 ms duplicate suppression.
pub const UnexpectedErrorHandler = struct {
    io: std.Io,
    allocator: Allocator,
    logger: ILogger,
    previous_message: ?[]u8 = null,
    previous_time_ms: i64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, logger: ILogger) UnexpectedErrorHandler {
        return .{ .allocator = allocator, .io = io, .logger = logger };
    }

    pub fn deinit(self: *UnexpectedErrorHandler) void {
        if (self.previous_message) |message| self.allocator.free(message);
        self.previous_message = null;
    }

    /// Uses the wall clock. `handleAt` is the testable seam for the duplicate
    /// window.
    pub fn handle(self: *UnexpectedErrorHandler, error_value: ErrorLike) !void {
        const now_ms: i64 = time_compat.milliTimestamp(self.io);
        return self.handleAt(error_value, now_ms);
    }

    pub fn handleAt(self: *UnexpectedErrorHandler, error_value: ErrorLike, now_ms: i64) !void {
        const message = try toErrorMessage(self.allocator, error_value, true);
        defer self.allocator.free(message);
        if (message.len == 0) return;

        if (self.previous_message) |previous| {
            if (std.mem.eql(u8, previous, message) and now_ms - self.previous_time_ms <= 1000) {
                return;
            }
        }

        if (self.previous_message) |previous| self.allocator.free(previous);
        self.previous_message = try self.allocator.dupe(u8, message);
        self.previous_time_ms = now_ms;

        // Keep native errors for debugger source mapping, but retain the
        // message fallback for stackless errors.
        const native_error: ?*const ErrorObject = switch (error_value) {
            .object => |object| if (object.is_native_error and object.stack != null and object.stack.?.len > 0) object else null,
            else => null,
        };
        if (native_error) |object| {
            try self.logger.err(.{ .error_value = object }, &.{});
        } else {
            try self.logger.err(.{ .string = message }, &.{});
        }
    }
};

pub fn createUnexpectedErrorHandler(allocator: Allocator, io: std.Io, logger: ILogger) UnexpectedErrorHandler {
    return UnexpectedErrorHandler.init(allocator, io, logger);
}

test "canLog and parseLogLevel" {
    try std.testing.expect(canLog(.info, .info));
    try std.testing.expect(canLog(.info, .err));
    try std.testing.expect(!canLog(.info, .debug));
    try std.testing.expect(!canLog(.off, .err));

    try std.testing.expectEqual(LogLevel.off, parseLogLevel("off").?);
    try std.testing.expectEqual(LogLevel.warning, parseLogLevel("warn").?);
    try std.testing.expectEqual(LogLevel.err, parseLogLevel("critical").?);
    try std.testing.expectEqual(@as(?LogLevel, null), parseLogLevel("verbose"));
}

test "format prints arguments in order" {
    const allocator = std.testing.allocator;
    const object = ErrorObject{ .message = "boom", .stack = "Error: boom\n    at x.js:1:1" };
    const text = try format(allocator, &.{
        .{ .string = "Error text" },
        .{ .integer = 42 },
        .{ .boolean = true },
        .{ .null_value = {} },
        .{ .object_json = "{\"a\":1}" },
        .{ .error_value = &object },
    }, true);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Error text 42 true null {\"a\":1} boom: Error: boom\n    at x.js:1:1", text);
}
