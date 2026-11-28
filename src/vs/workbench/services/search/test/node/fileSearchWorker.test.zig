// Tests for the terminal file-search worker (a TUI adaptation; upstream
// covers the same cache through `fileSearch.integrationTest.ts`): one listing per session, latest
// request wins, owned results, missing-ripgrep errors and cancellation.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("../../common/search.zig");
const worker_mod = @import("../../node/fileSearchWorker.zig");
const FileSearchWorker = worker_mod.FileSearchWorker;
const time_compat = @import("../../../../../base/common/timeCompat.zig");

fn writeFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(io, directory);
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn realRoot(tmp: *std.testing.TmpDir, io: Io) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..length]);
}

fn writeFakeRg(
    tmp: *std.testing.TmpDir,
    io: Io,
    allocator: Allocator,
    name: []const u8,
    log_path: []const u8,
    body: []const u8,
) ![]u8 {
    const script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\echo "$@" >> "{s}"
        \\{s}
    , .{ log_path, body });
    defer allocator.free(script);
    var file = try tmp.dir.createFile(io, name, .{});
    try file.writeStreamingAll(io, script);
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], name });
}

fn readFile(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

/// Waits until `path` exists. Cancellation tests use this to cancel a child
/// that has actually started, instead of racing process startup.
fn waitForPath(io: Io, path: []const u8, timeout_ms: i64) !void {
    const deadline = time_compat.milliTimestamp(std.testing.io) + timeout_ms;
    while (true) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (time_compat.milliTimestamp(std.testing.io) >= deadline) return error.Timeout;
                time_compat.sleepMillis(std.testing.io, 5);
                continue;
            },
            else => return err,
        };
        return;
    }
}

test "FileSearchWorker: one listing serves many queries" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try realRoot(&tmp, io);
    defer allocator.free(root);
    const log_path = try std.fs.path.join(allocator, &.{ root, "spawns.log" });
    defer allocator.free(log_path);
    const script = try writeFakeRg(&tmp, io, allocator, "fake-rg.sh", log_path,
        \\printf 'alpha.txt\nbeta.txt\ngamma.txt\n'
    );
    defer allocator.free(script);

    const worker = try FileSearchWorker.init(allocator, .{ .rg_path = script });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = root, .name = "root" }}, &.{}, .{});
    try worker.request("alpha");
    var first = worker.takeResult(3000) orelse return error.TestUnexpectedResult;
    defer first.deinit();
    try std.testing.expectEqualStrings("alpha", first.filter);
    try std.testing.expectEqual(@as(usize, 1), first.matches.len);
    try std.testing.expectEqualStrings("alpha.txt", first.matches[0].label);

    try worker.request("beta");
    var second = worker.takeResult(3000) orelse return error.TestUnexpectedResult;
    defer second.deinit();
    try std.testing.expectEqualStrings("beta", second.filter);
    try std.testing.expectEqual(@as(usize, 1), second.matches.len);
    try std.testing.expectEqualStrings("beta.txt", second.matches[0].label);

    const log = try readFile(allocator, io, log_path);
    defer allocator.free(log);
    var lines: usize = 0;
    var iterator = std.mem.splitScalar(u8, std.mem.trim(u8, log, " \t\r\n"), '\n');
    while (iterator.next()) |line| {
        if (line.len > 0) lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lines);
}

test "FileSearchWorker: latest request wins" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try realRoot(&tmp, io);
    defer allocator.free(root);
    const log_path = try std.fs.path.join(allocator, &.{ root, "spawns.log" });
    defer allocator.free(log_path);
    const script = try writeFakeRg(&tmp, io, allocator, "fake-rg.sh", log_path,
        \\sleep 0.1
        \\printf 'alpha.txt\nbeta.txt\ngamma.txt\n'
    );
    defer allocator.free(script);

    const worker = try FileSearchWorker.init(allocator, .{ .rg_path = script });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = root, .name = "root" }}, &.{}, .{});
    try worker.request("alpha");
    try worker.request("beta");
    var result = worker.takeResult(3000) orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqualStrings("beta", result.filter);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
}

test "FileSearchWorker: taken results survive session end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try realRoot(&tmp, io);
    defer allocator.free(root);
    const log_path = try std.fs.path.join(allocator, &.{ root, "spawns.log" });
    defer allocator.free(log_path);
    const script = try writeFakeRg(&tmp, io, allocator, "fake-rg.sh", log_path,
        \\printf 'alpha.txt\n'
    );
    defer allocator.free(script);

    const worker = try FileSearchWorker.init(allocator, .{ .rg_path = script });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = root, .name = "root" }}, &.{}, .{});
    try worker.request("alpha");
    var result = worker.takeResult(3000) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    worker.endSession();
    try std.testing.expectEqualStrings("alpha", result.filter);
    try std.testing.expectEqualStrings("alpha.txt", result.matches[0].label);
    try std.testing.expect(!worker.isBusy());
}

test "FileSearchWorker: empty workspace completes without spawning" {
    const allocator = std.testing.allocator;
    const worker = try FileSearchWorker.init(allocator, .{
        .rg_path = "definitely-not-a-real-ripgrep-binary",
    });
    defer worker.deinit();

    try worker.beginSession(&.{}, &.{}, .{});
    try worker.request("file");
    var result = worker.takeResult(2000) orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.error_message == null);
}

test "FileSearchWorker: missing rg publishes a clear error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const worker = try FileSearchWorker.init(allocator, .{
        .rg_path = "/nonexistent/ripgrep-for-quick-open-tests",
    });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = "/tmp", .name = "tmp" }}, &.{}, .{});
    try worker.request("file");
    var result = worker.takeResult(2000) orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.error_message != null);
    try std.testing.expectEqualStrings(worker_mod.MISSING_RIPGREP_MESSAGE, result.error_message.?);
}

test "FileSearchWorker: endSession cancels a sleeping listing quickly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try realRoot(&tmp, io);
    defer allocator.free(root);
    const log_path = try std.fs.path.join(allocator, &.{ root, "spawns.log" });
    defer allocator.free(log_path);
    const ready = try std.fs.path.join(allocator, &.{ root, "ready.txt" });
    defer allocator.free(ready);
    const body = try std.fmt.allocPrint(allocator,
        \\sleep 5 &
        \\echo "$!" > "{s}"
        \\wait "$!"
        \\printf 'late.txt\n'
    , .{ready});
    defer allocator.free(body);
    const script = try writeFakeRg(&tmp, io, allocator, "sleep-rg.sh", log_path, body);
    defer allocator.free(script);

    const worker = try FileSearchWorker.init(allocator, .{ .rg_path = script });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = root, .name = "root" }}, &.{}, .{});
    try worker.request("late");
    // Wait for the wrapper's sleep child: it holds the stdout pipe open, so
    // endSession must kill the whole process group to return promptly.
    try waitForPath(io, ready, 3000);
    const started = time_compat.milliTimestamp(std.testing.io);
    worker.endSession();
    const elapsed = time_compat.milliTimestamp(std.testing.io) - started;
    try std.testing.expect(elapsed < 2000);
    try std.testing.expect(!worker.isBusy());
    try std.testing.expect(!worker.hasAnyResult());
}

test "FileSearchWorker: materializes only the top MAX_RESULTS records" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try realRoot(&tmp, io);
    defer allocator.free(root);
    const log_path = try std.fs.path.join(allocator, &.{ root, "spawns.log" });
    defer allocator.free(log_path);
    const script = try writeFakeRg(&tmp, io, allocator, "many-rg.sh", log_path,
        \\i=0
        \\while [ "$i" -lt 600 ]; do
        \\  printf 'file%03d.txt\n' "$i"
        \\  i=$((i + 1))
        \\done
    );
    defer allocator.free(script);

    const worker = try FileSearchWorker.init(allocator, .{ .rg_path = script });
    defer worker.deinit();

    try worker.beginSession(&.{.{ .resource = root, .name = "root" }}, &.{}, .{});
    try worker.request("file");
    var result = worker.takeResult(5000) orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqual(worker_mod.MAX_RESULTS, result.matches.len);
}
