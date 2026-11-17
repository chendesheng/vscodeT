// Port of `src/vs/platform/log/test/common/log.test.ts`.
//
// Terminal adaptations:
// - The upstream `TestLogger extends AbstractMessageLogger` is spelled as a
//   struct owning an `AbstractMessageLogger`; the `error` override is the
//   logger's `on_error` hook.
// - Fake timers (`runWithFakedTimers`) become explicit `handleAt(..., now_ms)`
//   calls.
// - The adapter entries record the formatted argument list instead of the
//   `unknown[]` array; `format` space-joins the same values.
// - The "logging failures propagate" case uses an `AdapterLogger` whose sink
//   returns the error (upstream overrides `error` in an anonymous subclass).
const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("../../common/log.zig");
const error_message = @import("../../../../base/common/errorMessage.zig");
const ErrorLike = error_message.ErrorLike;
const ErrorObject = error_message.ErrorObject;
const toErrorMessage = error_message.toErrorMessage;

const TestEntry = struct {
    level: log.LogLevel,
    message: []u8,
};

/// Upstream's `errors: (string | Error)[]`. Strings are copied because the
/// logger frees its formatted message after `log`.
const RecordedError = union(enum) {
    string: []u8,
    error_value: *const ErrorObject,
};

const TestLogger = struct {
    allocator: Allocator,
    messages: std.array_list.Managed(TestEntry),
    errors: std.array_list.Managed(RecordedError),
    logger: log.AbstractMessageLogger,

    fn init(self: *TestLogger, allocator: Allocator) void {
        self.* = .{
            .allocator = allocator,
            .messages = std.array_list.Managed(TestEntry).init(allocator),
            .errors = std.array_list.Managed(RecordedError).init(allocator),
            .logger = undefined,
        };
        self.logger = log.AbstractMessageLogger.init(allocator, self, logMessage, false);
        self.logger.on_error = recordError;
        self.logger.on_error_context = self;
    }

    fn deinit(self: *TestLogger) void {
        for (self.messages.items) |entry| self.allocator.free(entry.message);
        for (self.errors.items) |entry| switch (entry) {
            .string => |text| self.allocator.free(text),
            .error_value => {},
        };
        self.messages.deinit();
        self.errors.deinit();
        self.logger.deinit();
    }

    fn iface(self: *TestLogger) log.ILogger {
        return self.logger.interface();
    }

    fn logMessage(context: *anyopaque, level: log.LogLevel, message: []const u8) anyerror!void {
        const self: *TestLogger = @ptrCast(@alignCast(context));
        try self.messages.append(.{
            .level = level,
            .message = try self.allocator.dupe(u8, message),
        });
    }

    fn recordError(context: *anyopaque, message: log.LogMessage) void {
        const self: *TestLogger = @ptrCast(@alignCast(context));
        const recorded: RecordedError = switch (message) {
            .string => |text| .{ .string = self.allocator.dupe(u8, text) catch return },
            .error_value => |value| .{ .error_value = value },
        };
        self.errors.append(recorded) catch {};
    }
};

const AdapterEntry = struct {
    level: log.LogLevel,
    text: []u8,
};

const AdapterLog = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(AdapterEntry),

    fn init(self: *AdapterLog, allocator: Allocator) void {
        self.* = .{
            .allocator = allocator,
            .entries = std.array_list.Managed(AdapterEntry).init(allocator),
        };
    }

    fn deinit(self: *AdapterLog) void {
        for (self.entries.items) |entry| self.allocator.free(entry.text);
        self.entries.deinit();
    }

    fn record(context: *anyopaque, level: log.LogLevel, args: []const log.LogArg) anyerror!void {
        const self: *AdapterLog = @ptrCast(@alignCast(context));
        const text = try log.format(self.allocator, args, true);
        try self.entries.append(.{ .level = level, .text = text });
    }

    fn adapter(self: *AdapterLog) log.Adapter {
        return .{ .context = self, .log_fn = record };
    }
};

fn nativeError(message: []const u8, stack: []const u8) ErrorObject {
    return .{ .message = message, .stack = stack, .is_native_error = true };
}

fn expectFormatted(allocator: Allocator, value: ErrorLike, expected: []const u8) !void {
    const text = try toErrorMessage(allocator, value, true);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "AdapterLogger retains unexpected error stacks when forwarding to another process" {
    const allocator = std.testing.allocator;
    var sink: AdapterLog = undefined;
    sink.init(allocator);
    defer sink.deinit();

    var logger = log.AdapterLogger.init(allocator, sink.adapter(), log.DEFAULT_LOG_LEVEL);
    defer logger.deinit();

    const error_object = nativeError("Unexpected error", "Error: Unexpected error\n    at generated.js:1:2");
    var handler = log.createUnexpectedErrorHandler(allocator, logger.interface());
    defer handler.deinit();

    try handler.handle(.{ .object = &error_object });

    try std.testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try std.testing.expectEqual(log.LogLevel.err, sink.entries.items[0].level);
    const expected = try toErrorMessage(allocator, .{ .object = &error_object }, true);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, sink.entries.items[0].text);
}

test "AdapterLogger preserves string arguments, warning formatting and log level filtering" {
    const allocator = std.testing.allocator;
    var sink: AdapterLog = undefined;
    sink.init(allocator);
    defer sink.deinit();

    var logger = log.AdapterLogger.init(allocator, sink.adapter(), log.DEFAULT_LOG_LEVEL);
    defer logger.deinit();

    const warning = ErrorObject{ .message = "Warning" };

    try logger.interface().err(.{ .string = "Error text" }, &.{.{ .integer = 42 }});
    try logger.warnMessage(.{ .error_value = &warning }, &.{});
    logger.setLevel(.off);
    try logger.interface().err(.{ .string = "Suppressed error" }, &.{});

    try std.testing.expectEqual(@as(usize, 2), sink.entries.items.len);
    try std.testing.expectEqual(log.LogLevel.err, sink.entries.items[0].level);
    try std.testing.expectEqualStrings("Error text 42", sink.entries.items[0].text);
    try std.testing.expectEqual(log.LogLevel.warning, sink.entries.items[1].level);
    try std.testing.expectEqualStrings("Warning", sink.entries.items[1].text);
}

test "createUnexpectedErrorHandler preserves native errors for debugger source mapping" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer handler.deinit();

    const error_object = nativeError("Unexpected error", "Error: Unexpected error");
    try handler.handle(.{ .object = &error_object });

    try std.testing.expectEqual(@as(usize, 1), test_logger.errors.items.len);
    switch (test_logger.errors.items[0]) {
        .error_value => |value| try std.testing.expect(value == &error_object),
        .string => return error.UnexpectedMessage,
    }
}

test "createUnexpectedErrorHandler retains the original stack in message loggers" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer handler.deinit();

    const stack = "Error: Unexpected error\n    at generated.js:1:2";
    const error_object = nativeError("Unexpected error", stack);
    try handler.handle(.{ .object = &error_object });

    try std.testing.expectEqual(@as(usize, 1), test_logger.messages.items.len);
    try std.testing.expectEqual(log.LogLevel.err, test_logger.messages.items[0].level);
    try std.testing.expectEqualStrings(stack, test_logger.messages.items[0].message);
    try std.testing.expectEqualStrings(stack, error_object.stack.?);
}

test "createUnexpectedErrorHandler preserves formatting for stackless errors and non-native values" {
    const allocator = std.testing.allocator;
    var test_logger: TestLogger = undefined;
    test_logger.init(allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(allocator, test_logger.iface());
    defer handler.deinit();

    const missing_stack = ErrorObject{ .message = "Missing stack", .is_native_error = true };
    const empty_stack = ErrorObject{ .message = "Empty stack", .stack = "", .is_native_error = true };
    const serialized = ErrorObject{
        .message = "Serialized error",
        .stack = "Error: Serialized error\n    at generated.js:1:2",
    };
    const nested = ErrorObject{ .message = "Nested error", .stack = "Error: Nested error\n    at generated.js:3:4" };
    const nested_detail = ErrorObject{ .detail = .{ .exception = &nested } };
    const first = ErrorObject{ .message = "First error", .is_native_error = true };
    const second = ErrorObject{ .message = "Second error", .is_native_error = true };

    const values = [_]ErrorLike{
        .{ .object = &missing_stack },
        .{ .object = &empty_stack },
        .{ .string = "Error text" },
        .{ .object = &serialized },
        .{ .object = &nested_detail },
        .{ .list = &.{ .{ .object = &first }, .{ .object = &second } } },
        .none,
    };

    for (values) |value| {
        try handler.handleAt(value, 0);
    }

    try std.testing.expectEqual(values.len, test_logger.errors.items.len);
    for (values, test_logger.errors.items) |value, recorded| {
        const expected = try toErrorMessage(allocator, value, true);
        defer allocator.free(expected);
        switch (recorded) {
            .string => |text| try std.testing.expectEqualStrings(expected, text),
            .error_value => return error.UnexpectedNativeError,
        }
    }
}

test "createUnexpectedErrorHandler suppresses duplicates through 1000ms without extending the interval" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer handler.deinit();

    const error_object = nativeError("Repeated error", "Error: Repeated error");
    try handler.handleAt(.{ .object = &error_object }, 0);
    try handler.handleAt(.{ .object = &error_object }, 1000);
    try handler.handleAt(.{ .object = &error_object }, 1001);

    try std.testing.expectEqual(@as(usize, 2), test_logger.errors.items.len);
}

test "createUnexpectedErrorHandler compares the complete formatted stack when suppressing duplicates" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer handler.deinit();

    const first = nativeError("Same message", "Error: Same message\n    at first.js:1:1");
    const second = nativeError("Same message", "Error: Same message\n    at second.js:2:2");
    try handler.handleAt(.{ .object = &first }, 0);
    try handler.handleAt(.{ .object = &second }, 0);

    try std.testing.expectEqual(@as(usize, 2), test_logger.errors.items.len);
}

test "createUnexpectedErrorHandler keeps duplicate suppression local to each handler" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var first_handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer first_handler.deinit();
    var second_handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer second_handler.deinit();

    const error_object = nativeError("Unexpected error", "Error: Unexpected error");
    try first_handler.handleAt(.{ .object = &error_object }, 0);
    try second_handler.handleAt(.{ .object = &error_object }, 0);

    try std.testing.expectEqual(@as(usize, 2), test_logger.errors.items.len);
}

test "createUnexpectedErrorHandler retains log level filtering" {
    var test_logger: TestLogger = undefined;
    test_logger.init(std.testing.allocator);
    defer test_logger.deinit();

    var handler = log.createUnexpectedErrorHandler(std.testing.allocator, test_logger.iface());
    defer handler.deinit();

    test_logger.logger.setLevel(.off);
    const suppressed = nativeError("Suppressed error", "Error: Suppressed error");
    try handler.handleAt(.{ .object = &suppressed }, 0);

    test_logger.logger.setLevel(.err);
    const logged = nativeError("Logged error", "Error: Logged error");
    try handler.handleAt(.{ .object = &logged }, 0);

    try std.testing.expectEqual(@as(usize, 1), test_logger.messages.items.len);
    try std.testing.expectEqual(log.LogLevel.err, test_logger.messages.items[0].level);
    try std.testing.expectEqualStrings("Error: Logged error", test_logger.messages.items[0].message);
}

test "createUnexpectedErrorHandler does not swallow logging failures" {
    const allocator = std.testing.allocator;
    const failing = struct {
        fn call(context: *anyopaque, level: log.LogLevel, args: []const log.LogArg) anyerror!void {
            _ = context;
            _ = level;
            _ = args;
            return error.LoggingFailed;
        }
    };

    var logger = log.AdapterLogger.init(allocator, .{ .context = undefined, .log_fn = failing.call }, log.DEFAULT_LOG_LEVEL);
    defer logger.deinit();

    var handler = log.createUnexpectedErrorHandler(allocator, logger.interface());
    defer handler.deinit();

    const error_object = nativeError("Unexpected error", "Error: Unexpected error");
    try std.testing.expectError(error.LoggingFailed, handler.handle(.{ .object = &error_object }));
}

test "toErrorMessage keeps the upstream verbose formatting" {
    const allocator = std.testing.allocator;
    const error_object = nativeError("Unexpected error", "Error: Unexpected error\n    at generated.js:1:2");
    try expectFormatted(allocator, .{ .object = &error_object }, "Unexpected error: Error: Unexpected error\n    at generated.js:1:2");
}
