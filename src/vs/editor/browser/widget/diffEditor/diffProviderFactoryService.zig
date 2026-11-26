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

        pub fn cancel(self: *Request) void {
            self.listener = null;
        }

        fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
            var lines: std.ArrayList([]const u8) = .empty;
            var iterator = std.mem.splitScalar(u8, text, '\n');
            while (iterator.next()) |line| try lines.append(allocator, line);
            return lines.toOwnedSlice(allocator);
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
            const original = splitLines(allocator, self.original) catch return;
            const modified = splitLines(allocator, self.modified) catch return;
            var provider = document.LineDiffProvider.init(self.options.diff_algorithm);
            self.result = provider.computeDiffFromLines(allocator, original, modified, .{
                .ignoreTrimWhitespace = self.options.ignore_trim_whitespace,
                .maxComputationTimeMs = self.options.max_computation_time_ms,
                .computeMoves = self.options.show_moves,
            }) catch null;
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
        };
        service.computeDiff(&request.message, now_ms);
        return request;
    }

    pub fn computeDiff(
        service: *worker.EditorWorkerService,
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
        };
        service.computeDiff(&request.message, now_ms);
        return request;
    }
};

test "diffProviderFactory: worker replies with detached snapshot result" {
    var service = worker.EditorWorkerService.init();
    defer service.deinit();
    const Capture = struct {
        count: usize = 0,
        fn receive(context: *anyopaque, _: *WorkerBasedDocumentDiffProvider.Request, result: ?Result) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (result) |value| self.count = value.changes.len;
            return true;
        }
    };
    var capture = Capture{};
    const listener: WorkerBasedDocumentDiffProvider.Listener = .{ .context = &capture, .run = Capture.receive };
    const cancelled = try WorkerBasedDocumentDiffProvider.computeDiff(&service, "a", "b", .{}, listener, 0);
    cancelled.cancel();
    service.waitForReply();
    try std.testing.expect(!service.dispatchReplies());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    _ = try WorkerBasedDocumentDiffProvider.computeDiff(&service, "a\nb", "a\nB", .{}, listener, 0);
    service.waitForReply();
    try std.testing.expect(service.dispatchReplies());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}
