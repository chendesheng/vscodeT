// Port of `src/vs/workbench/services/textfile/test/browser/textFileEditorModelManager.test.ts`.
// File-operation regressions exercise the live resource collection, provider,
// working-copy events and dirty snapshot restoration together.
const std = @import("std");
const FileService = @import("../../../../../platform/files/common/fileService.zig").ProviderFileService;
const Memory = @import("../../../../../platform/files/common/inMemoryFilesystemProvider.zig").InMemoryFileSystemProvider;
const working = @import("../../../workingCopy/common/workingCopyFileService.zig");
const Manager = @import("../../common/textFileEditorModelManager.zig").TextFileEditorModelManager;
const Resolver = @import("../../../textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
const Edit = @import("../../../../../editor/common/model.zig").IdentifiedSingleEditOperation;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const String = @import("../../../../../base/common/strings.zig").String;
const a = std.testing.allocator;
const Uri = std.Uri;

const Harness = struct {
    registry: FileService,
    memory: Memory,
    registration: @import("../../../../../base/common/lifecycle.zig").IDisposable,
    working_service: working.WorkingCopyFileService,
    model_manager: Manager,
    queue: Queue,
    resolver: Resolver,
    source: Uri = .{ .scheme = "inmemory", .path = .{ .raw = "/first.txt" } },
    target: Uri = .{ .scheme = "inmemory", .path = .{ .raw = "/second.txt" } },

    fn init() !*Harness {
        const self = try a.create(Harness);
        errdefer a.destroy(self);
        self.* = .{ .registry = FileService.init(a), .memory = try Memory.init(a), .registration = undefined, .working_service = undefined, .model_manager = undefined, .queue = .{ .io = std.testing.io }, .resolver = undefined };
        errdefer self.registry.deinit();
        errdefer self.memory.deinit();
        const file = self.registry.interface();
        self.registration = try file.registerProvider("inmemory", self.memory.interface());
        errdefer self.registration.dispose();
        self.working_service = .init(a, file, null);
        errdefer self.working_service.deinit();
        self.resolver = .init(a, std.testing.io, &self.queue);
        errdefer self.resolver.deinit();
        try self.resolver.bindFileService(file);
        self.model_manager = .init(a, file, (Resolver.FileModelAccessAdapter{ .service = &self.resolver }).interface());
        errdefer self.model_manager.deinit();
        try self.model_manager.bind(self.working_service.interface());
        try file.writeFile(self.source, "disk", .{ .create = true, .overwrite = false });
        return self;
    }
    fn deinit(self: *Harness) void {
        self.model_manager.deinit();
        self.resolver.deinit();
        self.queue.deinitWindowEvents();
        self.working_service.deinit();
        self.registration.dispose();
        self.memory.deinit();
        self.registry.deinit();
        a.destroy(self);
    }
    fn dirtySource(self: *Harness) !@import("../../../../../editor/common/services/resolverService.zig").ModelReference {
        var reference = try self.resolver.createResolvedModelReference(self.source, "/first.txt", "disk", false);
        errdefer reference.dispose();
        const model = reference.object.textEditorModel;
        var edits = [_]Edit{.init(Range.init(1, 1, 1, 5), String.initBorrowed("unsaved"))};
        _ = try model.pushEditOperations(null, &edits, null, null);
        try std.testing.expect(Resolver.documentOf(reference).isDirty());
        return reference;
    }
};

test "TextFileEditorModelManager: move restores unsaved source contents at the target" {
    const harness = try Harness.init();
    defer harness.deinit();
    var first = try harness.dirtySource();
    defer first.dispose();
    try harness.working_service.interface().move(&.{.{ .source = harness.source, .target = harness.target }}, .None, .{});
    try std.testing.expect(!Resolver.documentOf(first).isDirty());
    var moved = try harness.resolver.acquireModelReference(harness.target);
    defer moved.dispose();
    try std.testing.expect(Resolver.documentOf(moved).isDirty());
    try std.testing.expectEqualStrings("unsaved", try moved.object.textEditorModel.borrowLineContent(1));
    const bytes = try harness.registry.interface().readFile(a, harness.target);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("disk", bytes);
}

test "TextFileEditorModelManager: copy retains source dirtiness and restores a dirty target model" {
    const harness = try Harness.init();
    defer harness.deinit();
    var first = try harness.dirtySource();
    defer first.dispose();
    try harness.working_service.interface().copy(&.{.{ .source = harness.source, .target = harness.target }}, .None, .{});
    try std.testing.expect(Resolver.documentOf(first).isDirty());
    var copied = try harness.resolver.acquireModelReference(harness.target);
    defer copied.dispose();
    try std.testing.expect(Resolver.documentOf(copied).isDirty());
    try std.testing.expectEqualStrings("unsaved", try copied.object.textEditorModel.borrowLineContent(1));
}

test "TextFileEditorModelManager: failed move restores dirty state without changing source contents" {
    const harness = try Harness.init();
    defer harness.deinit();
    var first = try harness.dirtySource();
    defer first.dispose();
    harness.memory.setReadOnly(true);
    const reply = harness.working_service.interface().move(&.{.{ .source = harness.source, .target = harness.target }}, .None, .{});
    if (reply) |_| return error.ExpectedMoveFailure else |_| {}
    try std.testing.expect(Resolver.documentOf(first).isDirty());
    try std.testing.expectEqualStrings("unsaved", try first.object.textEditorModel.borrowLineContent(1));
    try std.testing.expect(harness.resolver.modelService().getModel(harness.target) == null);
}
