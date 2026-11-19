// Terminal host for the ported log service (`src/vs/platform/log/common/log.zig`
// and `logService.zig`).
//
// Upstream writes through `FileLoggerService`/`FileLogger`, which need a `URI`,
// `IFileService` and a throttled asynchronous flush. The TUI has no URI or file
// service layer, so this host keeps one synchronous main log file and writes
// the same line format as upstream's `FileLogger`:
//
//     YYYY-MM-DD HH:MM:SS.mmmZ [level] message\n
//
// Timestamps are UTC because the terminal host has no time-zone database; the
// `debug`/`warning` labels match `FileLogger.stringifyLogLevel`.
//
// The default location is `$XDG_STATE_HOME/vscode-textbuffer/logs/main.log`
// (falling back to `$HOME/.local/state/...`). `VSCODE_TEXTBUFFER_LOG` overrides
// the file path, mirroring `VSCODE_TEXTBUFFER_USER_SETTINGS`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = @import("./log.zig");
const LogService = @import("./logService.zig").LogService;
const time_compat = @import("../../../base/common/timeCompat.zig");

pub const FileLogger = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    writer: Io.File.Writer,
    writer_buffer: [4096]u8 = undefined,
    message_logger: log.AbstractMessageLogger,
    service: *LogService,

    pub fn create(allocator: Allocator, io: Io, path: []const u8) !*FileLogger {
        const file = try openFile(io, path);
        errdefer file.close(io);

        const self = try allocator.create(FileLogger);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .writer = undefined,
            .message_logger = undefined,
            .service = undefined,
        };
        self.writer = .init(file, io, &self.writer_buffer);
        self.message_logger = log.AbstractMessageLogger.init(allocator, self, writeLine, false);
        self.service = try LogService.create(allocator, self.message_logger.interface(), &.{});
        return self;
    }

    pub fn destroy(self: *FileLogger) void {
        self.service.deinit();
        self.message_logger.deinit();
        self.writer.interface.flush() catch {};
        self.file.close(self.io);
        self.allocator.destroy(self);
    }

    /// The `ILogService` the TUI consumes.
    pub fn logger(self: *FileLogger) log.ILogger {
        return self.service.interface();
    }
};

/// `$XDG_STATE_HOME/vscode-textbuffer/logs/main.log`, `$HOME/.local/state/...`
/// or `VSCODE_TEXTBUFFER_LOG`. Returns `null` when the environment has no home
/// directory. The caller owns the returned path.
pub fn defaultLogPath(allocator: Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("VSCODE_TEXTBUFFER_LOG")) |path| {
        return try allocator.dupe(u8, path);
    }
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "vscode-textbuffer", "logs", "main.log" });
    }
    if (environ.get("HOME")) |home| {
        return try std.fs.path.join(allocator, &.{ home, ".local", "state", "vscode-textbuffer", "logs", "main.log" });
    }
    return null;
}

fn openFile(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.dirname(path)) |directory| {
        try Io.Dir.cwd().createDirPath(io, directory);
    }
    return Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => Io.Dir.cwd().createFile(io, path, .{}),
        else => return err,
    };
}

fn writeLine(context: *anyopaque, level: log.LogLevel, message: []const u8) anyerror!void {
    const self: *FileLogger = @ptrCast(@alignCast(context));
    const writer = &self.writer.interface;
    try writeTimestamp(writer, time_compat.milliTimestamp());
    try writer.print(" [{s}] {s}\n", .{ levelLabel(level), message });
    try writer.flush();
}

/// Upstream `FileLogger.stringifyLogLevel` (note `warning`, not `warn`).
fn levelLabel(level: log.LogLevel) []const u8 {
    return switch (level) {
        .trace => "trace",
        .debug => "debug",
        .info => "info",
        .warning => "warning",
        .err => "error",
        .off => "",
    };
}

fn writeTimestamp(writer: *Io.Writer, now_ms: i64) !void {
    const seconds = @divFloor(now_ms, 1000);
    const millis: u16 = @intCast(@mod(now_ms, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print(
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    );
}

test "log line format" {
    const allocator = std.testing.allocator;
    const path = "zig-cache-test/tui-logger/main.log";
    defer Io.Dir.cwd().deleteTree(std.testing.io, "zig-cache-test") catch {};

    const logger = try FileLogger.create(allocator, std.testing.io, path);
    defer logger.destroy();

    const iface = logger.logger();
    try std.testing.expectEqual(log.LogLevel.info, iface.getLevel());
    try iface.info("hello", &.{.{ .integer = 7 }});
    iface.flush();

    const contents = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4096));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, " [info] hello 7\n") != null);
    try std.testing.expect(contents.len > " [info] hello 7\n".len);
}
