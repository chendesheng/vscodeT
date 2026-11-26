// Port of `src/vs/editor/browser/widget/diffEditor/diffProviderFactoryService.ts`.
// Native snapshot requests use the existing editor worker message queue rather
// than synchronizing URI-backed browser models. The result is borrowed during
// the UI-thread callback; cancellation detaches that callback.
const std = @import("std");
const worker = @import("../../services/editorWorkerService.zig");
const document = @import("../../../common/diff/documentDiffProvider.zig");
const Options = @import("diffEditorOptions.zig").Options;

pub const Result = document.IDocumentDiff;

/// A virtual-document source, owned by the request. The extension prepares
/// immutable resource identity on the UI thread and resolves bytes on the
/// worker without accessing its live repository or editor objects.
pub const SnapshotSource = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator) anyerror!Texts,
    destroy: *const fn (*anyopaque) void,

    pub const Texts = struct { original: []const u8, modified: []const u8 };
};

/// Bounded result cache owned by one editor worker. Content digests replace
/// the upstream URI/model-version key for immutable snapshot inputs. Entries
/// are copied into each request arena so eviction cannot invalidate a reply.
pub const Cache = struct {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const Key = struct {
        original: [Sha256.digest_length]u8,
        modified: [Sha256.digest_length]u8,
        algorithm: @import("diffEditorOptions.zig").DiffAlgorithmName,
        ignore_whitespace: bool,
        time_ms: i64,
        show_moves: bool,

        fn init(original: []const u8, modified: []const u8, options: Options) Key {
            var key: Key = .{
                .original = undefined,
                .modified = undefined,
                .algorithm = options.diff_algorithm,
                .ignore_whitespace = options.ignore_trim_whitespace,
                .time_ms = options.max_computation_time_ms,
                .show_moves = options.show_moves,
            };
            Sha256.hash(original, &key.original, .{});
            Sha256.hash(modified, &key.modified, .{});
            return key;
        }
    };
    const Entry = struct { key: Key, result: Result, arena: std.heap.ArenaAllocator };
    entries: [10]?Entry = @splat(null),
    next: usize = 0,

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| if (entry.*) |*value| value.arena.deinit();
        self.* = .{};
    }

    fn get(self: *Cache, allocator: std.mem.Allocator, key: Key) !?Result {
        for (self.entries) |entry| {
            if (entry) |value| if (std.meta.eql(value.key, key)) return try clone(allocator, value.result);
        }
        return null;
    }

    fn put(self: *Cache, key: Key, result: Result) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const copy = try clone(arena.allocator(), result);
        if (self.entries[self.next]) |*entry| entry.arena.deinit();
        self.entries[self.next] = .{ .key = key, .result = copy, .arena = arena };
        self.next = (self.next + 1) % self.entries.len;
    }

    fn cloneChanges(allocator: std.mem.Allocator, changes: []const document.DetailedLineRangeMapping) ![]const document.DetailedLineRangeMapping {
        const copy = try allocator.dupe(document.DetailedLineRangeMapping, changes);
        for (copy) |*change| {
            if (change.inner_changes) |inner| change.inner_changes = try allocator.dupe(@import("../../../common/diff/rangeMapping.zig").RangeMapping, inner);
        }
        return copy;
    }

    fn clone(allocator: std.mem.Allocator, result: Result) !Result {
        var copy = result;
        copy.changes = try cloneChanges(allocator, result.changes);
        const moves = try allocator.dupe(document.MovedText, result.moves);
        for (moves) |*moved| moved.changes = try cloneChanges(allocator, moved.changes);
        copy.moves = moves;
        return copy;
    }
};

pub const WorkerBasedDocumentDiffProvider = struct {
    pub const Listener = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque, *Request, ?Result) bool,
    };

    pub const Request = struct {
        arena: std.heap.ArenaAllocator,
        message: worker.Request = .{ .compute = compute, .reply = reply },
        original: []const u8,
        modified: []const u8,
        options: Options,
        listener: ?Listener,
        result: ?Result = null,
        source: ?SnapshotSource = null,
        failure: ?anyerror = null,
        cache: ?*Cache = null,
        cache_hit: bool = false,

        pub fn cancel(self: *Request) void {
            self.listener = null;
        }

        fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
            const strings = @import("../../../../base/common/strings.zig");
            const source = if (strings.startsWithUTF8BOM(text)) text[strings.UTF8_BOM_CHARACTER.len..] else text;
            var lines = try strings.splitLines(allocator, source);
            return lines.toOwnedSlice();
        }

        fn compute(message: *worker.Request) void {
            const self: *Request = @fieldParentPtr("message", message);
            const allocator = self.arena.allocator();
            if (self.source) |source| {
                const texts = source.read(source.context, allocator) catch |err| {
                    self.failure = err;
                    return;
                };
                self.original = texts.original;
                self.modified = texts.modified;
            }
            const key = if (self.cache != null) Cache.Key.init(self.original, self.modified, self.options) else null;
            if (self.cache) |cache| {
                if (cache.get(allocator, key.?) catch null) |cached| {
                    self.result = cached;
                    self.cache_hit = true;
                    return;
                }
            }
            const original = splitLines(allocator, self.original) catch return;
            const modified = splitLines(allocator, self.modified) catch return;
            var provider = document.LineDiffProvider.init(self.options.diff_algorithm);
            self.result = provider.computeDiffFromLines(allocator, original, modified, .{
                .ignoreTrimWhitespace = self.options.ignore_trim_whitespace,
                .maxComputationTimeMs = self.options.max_computation_time_ms,
                .computeMoves = self.options.show_moves,
            }) catch null;
            if (self.cache) |cache| if (self.result) |result| cache.put(key.?, result) catch {};
        }

        fn reply(message: *worker.Request) bool {
            const self: *Request = @fieldParentPtr("message", message);
            defer {
                if (self.source) |source| source.destroy(source.context);
                self.arena.deinit();
                std.heap.page_allocator.destroy(self);
            }
            const listener = self.listener orelse return false;
            return listener.run(listener.context, self, self.result);
        }
    };

    /// Consumes the source on success and failure.
    pub fn computeResolvedDiff(
        service: *worker.EditorWorkerService,
        cache: ?*Cache,
        source: SnapshotSource,
        options: Options,
        listener: Listener,
        now_ms: i64,
    ) !*Request {
        errdefer source.destroy(source.context);
        const request = try std.heap.page_allocator.create(Request);
        request.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .original = "",
            .modified = "",
            .options = options.normalize(),
            .listener = listener,
            .source = source,
            .cache = cache,
        };
        service.computeDiff(&request.message, now_ms);
        return request;
    }

    pub fn computeDiff(
        service: *worker.EditorWorkerService,
        cache: ?*Cache,
        original: []const u8,
        modified: []const u8,
        options: Options,
        listener: Listener,
        now_ms: i64,
    ) !*Request {
        const request = try std.heap.page_allocator.create(Request);
        errdefer std.heap.page_allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const original_copy = try allocator.dupe(u8, original);
        const modified_copy = try allocator.dupe(u8, modified);
        request.* = .{
            .arena = arena,
            .original = original_copy,
            .modified = modified_copy,
            .options = options.normalize(),
            .listener = listener,
            .cache = cache,
        };
        service.computeDiff(&request.message, now_ms);
        return request;
    }
};

test "diffProviderFactory: worker replies with detached snapshot result" {
    var cache = Cache{};
    defer cache.deinit();
    var service = worker.EditorWorkerService.init();
    defer service.deinit();
    const Capture = struct {
        count: usize = 0,
        cache_hit: bool = false,
        fn receive(context: *anyopaque, request: *WorkerBasedDocumentDiffProvider.Request, result: ?Result) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (result) |value| self.count = value.changes.len;
            self.cache_hit = request.cache_hit;
            return true;
        }
    };
    var capture = Capture{};
    const listener: WorkerBasedDocumentDiffProvider.Listener = .{ .context = &capture, .run = Capture.receive };
    const cancelled = try WorkerBasedDocumentDiffProvider.computeDiff(&service, &cache, "a", "b", .{}, listener, 0);
    cancelled.cancel();
    service.waitForReply();
    try std.testing.expect(!service.dispatchReplies());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    _ = try WorkerBasedDocumentDiffProvider.computeDiff(&service, &cache, "a\nb", "a\nB", .{}, listener, 0);
    service.waitForReply();
    try std.testing.expect(service.dispatchReplies());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(!capture.cache_hit);
    _ = try WorkerBasedDocumentDiffProvider.computeDiff(&service, &cache, "a\nb", "a\nB", .{}, listener, 0);
    service.waitForReply();
    try std.testing.expect(service.dispatchReplies());
    try std.testing.expect(capture.cache_hit);
    _ = try WorkerBasedDocumentDiffProvider.computeDiff(&service, &cache, "a\nb", "a\nB", .{ .ignore_trim_whitespace = false }, listener, 0);
    service.waitForReply();
    try std.testing.expect(service.dispatchReplies());
    try std.testing.expect(!capture.cache_hit);
}

test "diffProviderFactory: worker line snapshots match text-model EOL and BOM boundaries" {
    const allocator = std.testing.allocator;
    const lines = try WorkerBasedDocumentDiffProvider.Request.splitLines(allocator, "\xef\xbb\xbfalpha\r\nbeta\rgamma\n");
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("alpha", lines[0]);
    try std.testing.expectEqualStrings("beta", lines[1]);
    try std.testing.expectEqualStrings("gamma", lines[2]);
    try std.testing.expectEqualStrings("", lines[3]);
}
