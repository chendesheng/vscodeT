// Port of `src/vs/workbench/services/textmodelResolver/test/browser/textModelResolverService.test.ts`.
// The native dispatcher is the promise-disposal boundary in these cases.
const std = @import("std");
const resolver = @import("../../common/textModelResolverService.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const std_uri = @import("../../../../../base/common/stdUri.zig");
const EditorDocument = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const IdentifiedSingleEditOperation = @import("../../../../../editor/common/model.zig").IdentifiedSingleEditOperation;
const String = @import("../../../../../base/common/strings.zig").String;

fn disposed(_: void, count: *usize) !void {
    count.* += 1;
}
fn flush(queue: *dispatch.Queue) void {
    while (true) {
        const now = @import("../../../../../base/common/timeCompat.zig").milliTimestamp();
        if (queue.nextTimeout(now, 1) != 0) break;
        _ = queue.dispatch(now);
    }
}

fn shareSyntheticDocument(creator_first: bool) !void {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const api = service.interface();
    var owner = try api.createSyntheticDocument("shared", null);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var count: usize = 0;
    _ = try owner.object.onWillDispose.listen(&count, disposed);
    var reference = try api.acquireModelReference(model.uri());
    defer reference.dispose();
    try std.testing.expectEqual(model, reference.object.textEditorModel);
    if (creator_first) owner.dispose() else reference.dispose();
    flush(&queue);
    try std.testing.expectEqualStrings("shared", try model.borrowLineContent(1));
    try std.testing.expectEqual(@as(usize, 0), count);
    owner.dispose();
    reference.dispose();
    try std.testing.expectEqual(@as(usize, 0), count);
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: synthetic document survives until both owners release (creator first: false)" {
    try shareSyntheticDocument(false);
}
test "TextModelResolverService: synthetic document survives until both owners release (creator first: true)" {
    try shareSyntheticDocument(true);
}

test "TextModelResolverService: synthetic document can be reacquired during pending resolver disposal" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var owner = try service.createSyntheticDocument("shared", null);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var count: usize = 0;
    _ = try owner.object.onWillDispose.listen(&count, disposed);
    owner.dispose();
    var second = try service.acquireModelReference(model.uri());
    defer second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(model, second.object.textEditorModel);
    try std.testing.expectEqualStrings("shared", try model.borrowLineContent(1));
    second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: synthetic documents have unique URIs and preserve content and language" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var first = try service.createSyntheticDocument("first", "json");
    defer first.dispose();
    var second = try service.createSyntheticDocument("second", "plaintext");
    defer second.dispose();
    const first_key = try std_uri.resourceKey(a, first.object.textEditorModel.uri());
    defer a.free(first_key);
    const second_key = try std_uri.resourceKey(a, second.object.textEditorModel.uri());
    defer a.free(second_key);
    try std.testing.expect(!std.mem.eql(u8, first_key, second_key));
    try std.testing.expect(std.mem.startsWith(u8, first_key, "inmemory:/synthetic/"));
    try std.testing.expectEqualStrings("first", try first.object.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqualStrings("second", try second.object.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqualStrings("json", first.object.getLanguageId());
    try std.testing.expectEqualStrings("plaintext", second.object.getLanguageId());
}

test "TextModelResolverService: resolve inMemory throws when model not found" {
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(std.testing.allocator, std.testing.io, &queue);
    defer service.deinit();
    try std.testing.expectError(error.UnableToResolveResource, service.acquireModelReference(try std.Uri.parse("inmemory:/missing")));
}

test "TextModelResolverService: resolved dirty file eventually disposes and can be reacquired while dirty" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("file:///path/file_resolver.txt");
    var reference = try service.createResolvedModelReference(uri, "/path/file_resolver.txt", "Hello Html", false);
    defer reference.dispose();
    const doc = resolver.TextModelResolverService.documentOf(reference);
    const model = doc.model;
    var count: usize = 0;
    _ = try reference.object.onWillDispose.listen(&count, disposed);
    var edits = [_]IdentifiedSingleEditOperation{.init(model.getFullModelRange(), String.initBorrowed("make dirty"))};
    _ = try model.applyEdits(&edits, false);
    try std.testing.expect(doc.isDirty());
    reference.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    var second = try service.acquireModelReference(uri);
    defer second.dispose();
    try std.testing.expectEqual(model, second.object.textEditorModel);
    _ = try doc.replaceGeneratedContents("Hello Html");
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: model registered by an editor input shares its URI and outlives the service reference" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("test:/resource?revision=one");
    const doc = try EditorDocument.createFromText(a, std.testing.io, "/resource", "Hello Test", uri);
    defer doc.release();
    try service.registerDocument(doc, true);
    var reference = try service.interface().acquireModelReference(try std.Uri.parse("test:/resource?revision=one"));
    defer reference.dispose();
    try std.testing.expectEqual(doc.model, reference.object.textEditorModel);
    try std.testing.expect(reference.object.isReadonly());
    reference.dispose();
    flush(&queue);
    try std.testing.expectEqualStrings("Hello Test", try doc.model.borrowLineContent(1));
}

const content = @import("../../../../../editor/common/services/resolverService.zig");
const TestProvider = struct {
    text: []const u8,
    calls: usize = 0,
    decline: bool = false,

    fn interface(self: *TestProvider) content.ITextModelContentProvider {
        return .{ .context = self, .capture = capture };
    }
    fn capture(context: *anyopaque, resource: std.Uri) !?content.TextContentRequest {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.decline) return null;
        const request = try std.heap.page_allocator.create(Request);
        errdefer std.heap.page_allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const uri = try std_uri.encodedResource(a, resource);
        const text = try a.dupe(u8, self.text);
        request.* = .{ .arena = arena, .uri = uri, .text = text };
        return .{ .context = request, .read = Request.read, .destroy = Request.destroy };
    }
    const Request = struct {
        arena: std.heap.ArenaAllocator,
        uri: []const u8,
        text: []const u8,
        fn read(context: *anyopaque, a: std.mem.Allocator) !content.TextContentRequest.Result {
            const self: *Request = @ptrCast(@alignCast(context));
            const uri = try std.Uri.parse(try a.dupe(u8, self.uri));
            return .{ .uri = uri, .path = try std_uri.path(uri, a), .text = try a.dupe(u8, self.text) };
        }
        fn destroy(context: *anyopaque) void {
            const self: *Request = @ptrCast(@alignCast(context));
            self.arena.deinit();
            std.heap.page_allocator.destroy(self);
        }
    };
};

test "TextModelResolverService: register providers in reverse order, decline and remove independently" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const api = service.interface();
    const uri = try std.Uri.parse("test:/thePath?ref=one");
    try std.testing.expect(!api.canHandleResource(uri));
    var first: TestProvider = .{ .text = "first" };
    var second: TestProvider = .{ .text = "second", .decline = true };
    const first_registration = try api.registerTextModelContentProvider("test", first.interface());
    defer first_registration.dispose();
    const second_registration = try api.registerTextModelContentProvider("test", second.interface());
    defer second_registration.dispose();
    try std.testing.expect(api.canHandleResource(uri));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    {
        const request = try service.captureContent(uri);
        defer request.destroy(request.context);
        const result = try request.read(request.context, arena.allocator());
        try std.testing.expectEqualStrings("first", result.text.?);
        try std.testing.expectEqualStrings("ref=one", try std_uri.query(result.uri, arena.allocator()));
    }
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    second.decline = false;
    {
        const request = try service.captureContent(uri);
        defer request.destroy(request.context);
        const result = try request.read(request.context, arena.allocator());
        try std.testing.expectEqualStrings("second", result.text.?);
    }
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    second_registration.dispose();
    first_registration.dispose();
    try std.testing.expect(!api.canHandleResource(uri));
    try std.testing.expectError(error.UnableToResolveResource, service.captureContent(uri));
}

const AsyncReference = struct {
    reference: ?content.ModelReference = null,
    failure: ?anyerror = null,
    completed: bool = false,

    fn listener(self: *AsyncReference) content.ModelReferenceListener {
        return .{ .context = self, .complete = complete };
    }
    fn complete(context: *anyopaque, result: content.ModelReferenceResult) void {
        const self: *AsyncReference = @ptrCast(@alignCast(context));
        self.completed = true;
        switch (result) {
            .resolved => |reference| self.reference = reference,
            .failure => |err| self.failure = err,
        }
    }
    fn deinit(self: *AsyncReference) void {
        if (self.reference) |*reference| reference.dispose();
        self.reference = null;
    }
};

test "TextModelResolverService: even loading documents should be refcounted" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var provider: TestProvider = .{ .text = "Hello Test" };
    const registration = try service.registerTextModelContentProvider("test", provider.interface());
    defer registration.dispose();
    const uri = try std.Uri.parse("test:/thePath");
    var first: AsyncReference = .{};
    defer first.deinit();
    var second: AsyncReference = .{};
    defer second.deinit();
    const request1 = try service.interface().createModelReference(uri, first.listener());
    defer request1.cancel();
    const request2 = try service.interface().createModelReference(uri, second.listener());
    defer request2.cancel();
    try std.testing.expect(!first.completed and !second.completed);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    service.worker.?.waitForReply();
    flush(&queue);
    try std.testing.expect(first.completed and second.completed);
    try std.testing.expect(first.failure == null and second.failure == null);
    const model = first.reference.?.object.textEditorModel;
    try std.testing.expectEqual(model, second.reference.?.object.textEditorModel);
    try std.testing.expectEqualStrings("Hello Test", try model.borrowLineContent(1));
    var count: usize = 0;
    _ = try first.reference.?.object.onWillDispose.listen(&count, disposed);
    first.deinit();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    second.deinit();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: synthetic document is retained while a resolver reference is still opening" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var owner = try service.createSyntheticDocument("shared", null);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var count: usize = 0;
    _ = try owner.object.onWillDispose.listen(&count, disposed);
    var result: AsyncReference = .{};
    defer result.deinit();
    const request = try service.createModelReference(model.uri(), result.listener());
    defer request.cancel();
    owner.dispose();
    try std.testing.expect(!result.completed);
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(model, result.reference.?.object.textEditorModel);
    result.deinit();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: canceling a loading reference detaches only that acquisition" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var provider: TestProvider = .{ .text = "shared" };
    const registration = try service.registerTextModelContentProvider("test", provider.interface());
    defer registration.dispose();
    const uri = try std.Uri.parse("test:/resource");
    var canceled: AsyncReference = .{};
    defer canceled.deinit();
    var active: AsyncReference = .{};
    defer active.deinit();
    const first = try service.createModelReference(uri, canceled.listener());
    first.cancel();
    const second = try service.createModelReference(uri, active.listener());
    defer second.cancel();
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    service.worker.?.waitForReply();
    flush(&queue);
    try std.testing.expect(!canceled.completed);
    try std.testing.expect(active.completed);
    try std.testing.expectEqualStrings("shared", try active.reference.?.object.textEditorModel.borrowLineContent(1));
}
