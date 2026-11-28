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
// The location comes from the upstream `logsPath` resolution in
// `src/tui/vscodeProfile.zig`: the terminal user data directory's `logs`
// folder, or the upstream `--logsPath` switch.
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

/// FileLoggerService from fileLog.ts, used by extension-host RPC loggers when
/// the standalone Node distribution has no native spdlog module. The existing
/// file service owns URI handling and writes; raw output channels must not
/// add formatting bytes because ExtHostOutputChannel tracks byte offsets.
pub const FileLoggerService = struct {
    allocator: Allocator,
    files: @import("../../files/common/files.zig").IFileService,
    loggers: std.StringHashMap(*ResourceLogger),
    on_did_change_loggers: @import("../../../base/common/event.zig").Emitter(void),

    pub const Options = struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        level: log.LogLevel = .trace,
        raw: bool = false,
        hidden: bool = false,
        extension_id: ?[]const u8 = null,
        no_rotation: bool = false,
    };

    pub const ResourceLogger = struct {
        arena: std.heap.ArenaAllocator,
        resource: std.Uri,
        key: []const u8,
        options: Options,
        locally_created: bool = false,
        backup_index: usize = 1,
    };

    const uri_util = @import("../../../base/common/stdUri.zig");

    pub fn init(allocator: Allocator, files: @import("../../files/common/files.zig").IFileService) FileLoggerService {
        return .{ .allocator = allocator, .files = files, .loggers = .init(allocator), .on_did_change_loggers = .init(allocator) };
    }

    pub fn clear(self: *FileLoggerService) void {
        var entries = self.loggers.valueIterator();
        while (entries.next()) |entry| self.destroy(entry.*);
        self.loggers.clearRetainingCapacity();
        self.on_did_change_loggers.fire({}) catch {};
    }

    pub fn deinit(self: *FileLoggerService) void {
        self.clear();
        self.loggers.deinit();
        self.on_did_change_loggers.deinit();
    }

    fn destroy(self: *FileLoggerService, logger: *ResourceLogger) void {
        logger.arena.deinit();
        self.allocator.destroy(logger);
    }

    pub fn getLogger(self: *FileLoggerService, resource: std.Uri) !?*ResourceLogger {
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        return self.loggers.get(key);
    }

    fn copyOptions(arena: Allocator, options: Options) !Options {
        var result = options;
        if (options.id) |id| result.id = try arena.dupe(u8, id);
        if (options.name) |name| result.name = try arena.dupe(u8, name);
        if (options.extension_id) |id| result.extension_id = try arena.dupe(u8, id);
        return result;
    }

    pub fn registerLogger(self: *FileLoggerService, resource: std.Uri, options: Options) !*ResourceLogger {
        if (try self.getLogger(resource)) |logger| {
            const updated = try copyOptions(logger.arena.allocator(), options);
            // Registration metadata from a Node-local logger does not replace
            // the raw/rotation settings of an already-created RPC logger.
            logger.options.id = updated.id orelse logger.options.id;
            logger.options.name = updated.name orelse logger.options.name;
            logger.options.extension_id = updated.extension_id orelse logger.options.extension_id;
            logger.options.hidden = updated.hidden;
            self.on_did_change_loggers.fire({}) catch {};
            return logger;
        }
        const logger = try self.allocator.create(ResourceLogger);
        errdefer self.allocator.destroy(logger);
        logger.arena = .init(self.allocator);
        errdefer logger.arena.deinit();
        const arena = logger.arena.allocator();
        logger.resource = try uri_util.clone(arena, resource);
        logger.key = try uri_util.resourceKey(arena, resource);
        logger.options = try copyOptions(arena, options);
        logger.locally_created = false;
        logger.backup_index = 1;
        try self.loggers.put(logger.key, logger);
        self.on_did_change_loggers.fire({}) catch {};
        return logger;
    }

    pub fn createLogger(self: *FileLoggerService, resource: std.Uri, options: Options) !void {
        const logger = try self.registerLogger(resource, options);
        if (logger.locally_created) return;
        logger.options = try copyOptions(logger.arena.allocator(), options);
        self.files.writeFile(resource, "", .{ .create = true, .overwrite = false }) catch |err| switch (err) {
            error.FileExists => {},
            else => return err,
        };
        logger.locally_created = true;
    }

    pub fn deregisterLogger(self: *FileLoggerService, resource: std.Uri) !void {
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        if (self.loggers.fetchRemove(key)) |entry| {
            self.destroy(entry.value);
            self.on_did_change_loggers.fire({}) catch {};
        }
    }

    pub fn setVisibility(self: *FileLoggerService, resource: std.Uri, visible: bool) !void {
        if (try self.getLogger(resource)) |logger| {
            logger.options.hidden = !visible;
            self.on_did_change_loggers.fire({}) catch {};
        }
    }

    pub const Entry = struct { level: log.LogLevel, message: []const u8 };

    pub fn append(self: *FileLoggerService, resource: std.Uri, level: log.LogLevel, message: []const u8) !void {
        try self.appendBatch(resource, &.{.{ .level = level, .message = message }});
    }

    /// A $log RPC carries an ordered batch. Format it once and write only
    /// that batch, preserving raw output-channel byte offsets.
    pub fn appendBatch(self: *FileLoggerService, resource: std.Uri, entries: []const Entry) !void {
        const logger = (try self.getLogger(resource)) orelse return error.LoggerNotCreated;
        if (!logger.locally_created) return error.LoggerNotCreated;
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        for (entries) |entry| {
            if (!log.canLog(logger.options.level, entry.level)) continue;
            if (logger.options.raw) {
                try writer.writer.writeAll(entry.message);
            } else {
                try writeTimestamp(&writer.writer, time_compat.milliTimestamp());
                try writer.writer.print(" [{s}] {s}\n", .{ levelLabel(entry.level), entry.message });
            }
        }
        const bytes = writer.written();
        if (bytes.len == 0) return;
        // The upstream file logger rotates formatted logs at 5 MiB. Raw
        // channels explicitly opt out because their offsets refer to one file.
        if (!logger.options.no_rotation) {
            const stat = try self.files.stat(resource);
            if (stat.size > 5 * 1024 * 1024) {
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const a = scratch.allocator();
                const path = try uri_util.path(resource, a);
                var backup = resource;
                backup.path = .{ .raw = try std.fmt.allocPrint(a, "{s}_{d}", .{ path, logger.backup_index }) };
                try self.files.copy(resource, backup, true);
                try self.files.writeFile(resource, "", .{ .create = true, .overwrite = true });
                logger.backup_index = if (logger.backup_index == 5) 1 else logger.backup_index + 1;
            }
        }
        try self.files.writeFile(resource, bytes, .{ .create = true, .overwrite = true, .append = true });
    }
};
