// Port of the input ownership and dirty-state contracts in
// `src/vs/workbench/contrib/multiDiffEditor/test/browser/multiDiffEditorInput.test.ts`.
const std = @import("std");
const testing = std.testing;
const input_mod = @import("../../browser/multiDiffEditorInput.zig");
const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const FileEditorInput = @import("../../../files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const TextResourceEditorInput = @import("../../../../../workbench/common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
const dispatch = @import("../../../../../base/common/windowDispatch.zig");

test "MultiDiffEditorInput: aggregate dirty events and save/revert retain both real file input references" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "working.txt", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "working.txt", testing.allocator);
    defer testing.allocator.free(path);
    const working = try Editor.createFromText(testing.allocator, testing.io, "old", path, 80, 10);
    var file = try FileEditorInput.init(testing.allocator, working);
    defer file.deinit();
    const original = try TextResourceEditorInput.init(testing.allocator, testing.io, path, "Original", "base", .{ .scheme = "git", .path = .{ .raw = path }, .query = .{ .raw = "HEAD" } });
    defer original.destroy();
    const input = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?commit", "Commit", false);
    defer input.destroy();
    try testing.expectEqualStrings("Commit", input.base.getName());
    try input.setResolvedItems(&.{.{
        .original = .{ .uri = original.document.model.uri(), .input = .{ .resource = original } },
        .modified = .{ .uri = working.model.uri(), .input = .{ .file = file } },
    }});
    try testing.expectEqualStrings("Commit (1 file)", input.base.getName());
    try testing.expect(input.base.isReadonly());
    try testing.expect(!input.base.isDirty());
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try input.getViewModel(testing.io, &queue, null);
    try testing.expectEqual(working.document, vm.items[0].modified);
    try testing.expectEqual(original.document, vm.items[0].original);
    try working.setCursorPosition(.{ .lineNumber = 1, .column = 4 });
    try working.insertText("!");
    try testing.expect(input.base.isDirty());
    _ = try input.base.save(1);
    try testing.expect(!input.base.isDirty());
    const saved = try tmp.dir.readFileAlloc(testing.io, "working.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("old!", saved);
    try working.insertText("?");
    try testing.expect(input.base.isDirty());
    try input.base.revert(1);
    try testing.expect(!input.base.isDirty());
    try testing.expectEqualStrings("old!", try working.model.borrowLineContent(1));
    try testing.expect(input.base.close_handler != null and !input.base.close_handler.?.show_confirm(input.base.close_handler.?.context));
}

test "MultiDiffEditorInput: input identity is the source URI and resource-only entries remain binary" {
    const a = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=first", null, false);
    defer a.destroy();
    const b = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=first", "Different label", true);
    defer b.destroy();
    const c = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=second", null, false);
    defer c.destroy();
    try testing.expect(a.base.matches(.{ .input = &b.base }));
    try testing.expect(!a.base.matches(.{ .input = &c.base }));
    try a.setResolvedItems(&.{.{
        .modified = .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/binary.png" } } },
    }});
    try testing.expectEqualStrings("Multi Diff Editor (1 file)", a.base.getName());
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try a.getViewModel(testing.io, &queue, null);
    try testing.expect(vm.items[0].isBinary());
    try testing.expect(vm.items[0].documentDiffItem.original == null);
}

test "MultiDiffEditorInput: live resource reorder preserves the document and view model identities" {
    const a = testing.allocator;
    const input = try input_mod.MultiDiffEditorInput.create(a, "scm-multi-diff-source:?group", null, false);
    defer input.destroy();
    const first: input_mod.ResolvedItem = .{ .modified = .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/first.png" } } } };
    const second: input_mod.ResolvedItem = .{ .original = .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/second.png" } } } };
    try input.setResolvedItems(&.{ first, second });
    const first_item = input.entries[0].item;
    const second_item = input.entries[1].item;
    var reordered = first;
    reordered.options.render_side_by_side = false;
    try input.setResolvedItems(&.{ second, reordered });
    try testing.expectEqual(second_item, input.entries[0].item);
    try testing.expectEqual(first_item, input.entries[1].item);
    try testing.expect(!first_item.options.render_side_by_side);
    try input.setResolvedItems(&.{reordered});
    try testing.expectEqual(first_item, input.entries[0].item);
}

test "MultiDiffEditorInput: serializer preserves source identity and only explicit resource declarations" {
    const a = testing.allocator;
    var serializer = input_mod.MultiDiffEditorSerializer.init(a);
    const api = serializer.interface();
    const input = try input_mod.MultiDiffEditorInput.create(a, "scm-history-item:/repo?revision", "History", false);
    defer input.destroy();
    try input.setResolvedItems(&.{.{ .modified = .{ .uri = try std.Uri.parse("file:///resolved.txt") } }});
    const encoded = (try api.serialize(api.context, input.interface(), a)).?;
    defer a.free(encoded);
    try testing.expectEqualStrings("{\"multiDiffSourceUri\":\"scm-history-item:/repo?revision\",\"label\":\"History\"}", encoded);
    const restored_base = (try api.deserialize(api.context, encoded)).?;
    defer api.discardDeserialized(restored_base);
    const restored = input_mod.MultiDiffEditorInput.is(restored_base).?;
    try testing.expectEqualStrings(input.source_uri, restored.source_uri);
    try testing.expectEqualStrings("History", restored.label);
    try testing.expect(restored.initial_resources == null);
    try testing.expectEqual(@as(usize, 0), restored.entries.len);

    const explicit = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:explicit", null, false);
    defer explicit.destroy();
    try explicit.setInitialResources(&.{
        .{ .originalUri = try std.Uri.parse("file:///old%20name.txt"), .modifiedUri = try std.Uri.parse("file:///new%23name.txt"), .goToFileUri = try std.Uri.parse("file:///new%23name.txt") },
        .{ .modifiedUri = try std.Uri.parse("file:///added.txt") },
    });
    const serialized = (try api.serialize(api.context, explicit.interface(), a)).?;
    defer a.free(serialized);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"label\"") == null);
    const restored_explicit_base = (try api.deserialize(api.context, serialized)).?;
    defer api.discardDeserialized(restored_explicit_base);
    const restored_explicit = input_mod.MultiDiffEditorInput.is(restored_explicit_base).?;
    const source_mod = @import("../../browser/multiDiffSourceResolverService.zig");
    var registry = source_mod.MultiDiffSourceResolverService.init(a);
    defer registry.deinit();
    const source = try restored_explicit.resolveSource(registry.interface());
    defer source.dispose(source.context);
    const resources = source.resources(source.context);
    try testing.expectEqual(@as(usize, 2), resources.len);
    try testing.expectEqualStrings("/old%20name.txt", resources[0].originalUri.?.path.percent_encoded);
    try testing.expectEqualStrings("/new%23name.txt", resources[0].goToFileUri.?.path.percent_encoded);
    try testing.expect(resources[1].originalUri == null);
    const transient = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:temporary", null, true);
    defer transient.destroy();
    try testing.expect(!api.canSerialize(api.context, transient.interface()));
    try testing.expect((try api.serialize(api.context, transient.interface(), a)) == null);
    try testing.expect((try api.deserialize(api.context, "{\"multiDiffSourceUri\":\"multi-diff-editor:bad\",\"resources\":[{}]}")) == null);
}

test "MultiDiffEditorInput: updates its name from the resolved source label" {
    const a = testing.allocator;
    const Source = @import("../../browser/multiDiffSourceResolverService.zig");
    const Emitter = @import("../../../../../base/common/event.zig").Emitter;
    const Mock = struct {
        label: []const u8 = "Current Turn Changes",
        label_changed: Emitter(void),
        resources_changed: Emitter(void),
        resource_requests: usize = 0,
        source_disposed: bool = false,
        binding_disposed: bool = false,

        fn getResources(_: *anyopaque) []const Source.MultiDiffEditorItem {
            return &.{};
        }
        fn getLabel(context: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.label;
        }
        fn resolveResources(context: *anyopaque, items: []const Source.MultiDiffEditorItem) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try testing.expectEqual(@as(usize, 0), items.len);
            self.resource_requests += 1;
        }
        fn disposeSource(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.source_disposed = true;
        }
        fn disposeBinding(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.binding_disposed = true;
        }
    };
    var mock: Mock = .{ .label_changed = .init(a), .resources_changed = .init(a) };
    defer mock.label_changed.deinit();
    defer mock.resources_changed.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Fallback", false);
    defer input.destroy();
    try input.attachResolvedSource(.{
        .context = &mock,
        .resources = Mock.getResources,
        .on_did_change_resources = &mock.resources_changed,
        .label = Mock.getLabel,
        .on_did_change_label = &mock.label_changed,
        .dispose = Mock.disposeSource,
    }, .{ .context = &mock, .resolve_resources = Mock.resolveResources, .dispose = Mock.disposeBinding });
    try testing.expectEqualStrings("Current Turn Changes (0 files)", input.base.getName());
    const Count = struct {
        fn onChange(_: void, counter: *usize) !void {
            counter.* += 1;
        }
    };
    var label_changes: usize = 0;
    const listener = try input.base.on_did_change_label.listenDisposable(&label_changes, Count.onChange);
    defer listener.dispose();
    mock.label = "Last Turn Changes";
    try mock.label_changed.fire({});
    try testing.expectEqualStrings("Last Turn Changes (0 files)", input.base.getName());
    try testing.expectEqual(@as(usize, 1), label_changes);
    try testing.expectEqual(@as(usize, 1), mock.resource_requests);
    input.detachSource();
    try testing.expect(mock.source_disposed and mock.binding_disposed);
    try testing.expectEqual(@as(usize, 0), mock.label_changed.listenerCount());
    try testing.expectEqual(@as(usize, 0), mock.resources_changed.listenerCount());
}

test "MultiDiffEditorInput: source and item context keys retain their own values across updates" {
    const a = testing.allocator;
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:context", null, false);
    defer input.destroy();
    const source_value = try a.dupe(u8, "working");
    try input.document_set.setContextKeys(&.{.{ .key = "scmResourceGroup", .value = .{ .string = source_value } }});
    a.free(source_value);
    const item_value = try a.dupe(u8, "first");
    const first: input_mod.ResolvedItem = .{
        .modified = .{ .uri = try std.Uri.parse("file:///first.png") },
        .context_keys = &.{.{ .key = "itemName", .value = .{ .string = item_value } }},
    };
    try input.setResolvedItems(&.{first});
    a.free(item_value);
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try input.getViewModel(testing.io, &queue, null);
    const item = vm.items[0].documentDiffItem;
    try testing.expectEqualStrings("working", vm.model.getContextKey("scmResourceGroup").?.string);
    try testing.expectEqualStrings("first", item.context_keys.get("itemName").?.string);
    try testing.expect(vm.model.getContextKey("itemName") == null);
    try input.setResourceOrder(.tree);
    try testing.expectEqual(item, vm.items[0].documentDiffItem);
    try testing.expectEqualStrings("first", item.context_keys.get("itemName").?.string);
    try input.document_set.setContextKeys(&.{.{ .key = "scmResourceGroup", .value = .{ .string = "index" } }});
    try testing.expectEqualStrings("index", vm.model.getContextKey("scmResourceGroup").?.string);
    try item.setContextKeys(&.{});
    try testing.expect(item.context_keys.get("itemName") == null);
    try input.document_set.setContextKeys(&.{});
    try testing.expect(vm.model.getContextKey("scmResourceGroup") == null);
}

const resolver_api = @import("../../../../../editor/common/services/resolverService.zig");
const resolver_mod = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig");
const source_api = @import("../../browser/multiDiffSourceResolverService.zig");
const std_uri = @import("../../../../../base/common/stdUri.zig");
const SideInput = @import("../../../../browser/parts/editor/textDiffEditor.zig").SideInput;
const DiffOptions = @import("../../../../../editor/browser/widget/diffEditor/diffEditorOptions.zig").Options;

/// A controllable native equivalent of the pinned upstream DeferredPromise
/// fixtures. It uses the real reference collection when settling a request;
/// cancellation detaches its callback and owns/disposes a later result.
const ManualResolver = struct {
    arena: std.heap.ArenaAllocator,
    models: *resolver_mod.TextModelResolverService,
    requests: std.ArrayList(Request) = .empty,
    released: std.ArrayList([]const u8) = .empty,
    const Request = struct { uri: std.Uri, listener: resolver_api.ModelReferenceListener, canceled: bool = false, completed: bool = false };
    const Probe = struct {
        owner: *ManualResolver,
        path: []const u8,
        fn disposed(_: void, self: *Probe) !void {
            try self.owner.released.append(self.owner.arena.allocator(), self.path);
        }
    };
    fn deinit(self: *ManualResolver) void {
        self.arena.deinit();
    }
    fn interface(self: *ManualResolver) resolver_api.ITextModelService {
        return .{ .context = self, .create_model_reference = request, .refresh_model_reference = request, .acquire_model_reference = acquire, .create_synthetic_document = synthetic, .can_handle_resource = canHandle, .register_provider = register };
    }
    fn request(context: *anyopaque, uri: std.Uri, listener: resolver_api.ModelReferenceListener) !resolver_api.ModelReferenceRequest {
        const self: *ManualResolver = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        const copy = try std.Uri.parse(try std_uri.encodedResource(a, uri));
        const index = self.requests.items.len;
        try self.requests.append(a, .{ .uri = copy, .listener = listener });
        return .{ .context = self, .id = @intCast(index), .cancel_fn = cancel };
    }
    fn cancel(context: *anyopaque, id: u64) void {
        const self: *ManualResolver = @ptrCast(@alignCast(context));
        if (id < self.requests.items.len and !self.requests.items[@intCast(id)].completed) self.requests.items[@intCast(id)].canceled = true;
    }
    fn acquire(context: *anyopaque, uri: std.Uri) !resolver_api.ModelReference {
        const self: *ManualResolver = @ptrCast(@alignCast(context));
        return self.models.acquireModelReference(uri);
    }
    fn synthetic(context: *anyopaque, value: []const u8, language: ?[]const u8) !resolver_api.ModelReference {
        const self: *ManualResolver = @ptrCast(@alignCast(context));
        return self.models.createSyntheticDocument(value, language);
    }
    fn canHandle(_: *anyopaque, _: std.Uri) bool {
        return true;
    }
    fn register(_: *anyopaque, _: []const u8, _: resolver_api.ITextModelContentProvider) !resolver_api.ContentProviderRegistration {
        return error.UnexpectedProviderRegistration;
    }
    fn settle(self: *ManualResolver, index: usize, failure: ?anyerror) !void {
        const pending = &self.requests.items[index];
        try testing.expect(!pending.completed);
        pending.completed = true;
        const canceled = pending.canceled;
        const listener = pending.listener;
        const uri = pending.uri;
        if (failure) |err| {
            if (!canceled) listener.complete(listener.context, .{ .failure = err });
            return;
        }
        const path = try std_uri.path(uri, self.arena.allocator());
        var reference = if (try self.models.acquireExisting(uri)) |value| value else blk: {
            var value = try self.models.createResolvedModelReference(uri, path, path, true);
            errdefer value.dispose();
            const probe = try self.arena.allocator().create(Probe);
            probe.* = .{ .owner = self, .path = try self.arena.allocator().dupe(u8, path) };
            _ = try value.object.onWillDispose.listen(probe, Probe.disposed);
            break :blk value;
        };
        if (canceled) reference.dispose() else listener.complete(listener.context, .{ .resolved = reference });
    }
};

const ResolutionHarness = struct {
    input: *input_mod.MultiDiffEditorInput,
    manual: *ManualResolver,
    publications: std.ArrayList([]const []const u8) = .empty,
    options: DiffOptions = .{},

    fn listener(self: *ResolutionHarness) input_mod.ResourceResolutionListener {
        return .{ .context = self, .run = publish };
    }
    fn publish(context: *anyopaque, resources: []const input_mod.ResolvedResourceItem) !void {
        const self: *ResolutionHarness = @ptrCast(@alignCast(context));
        try self.input.publishResolvedResources(resources, .{ .context = self, .create_side = createSide, .compute_options = computeOptions });
        const a = self.manual.arena.allocator();
        const paths = try a.alloc([]const u8, self.input.entries.len);
        for (self.input.entries, paths) |entry, *path| {
            const source = entry.item.modified orelse entry.item.original.?;
            path.* = try a.dupe(u8, try std_uri.path(source.uri, a));
        }
        try self.publications.append(a, paths);
    }
    fn createSide(context: *anyopaque, source: input_mod.ResolvedResourceSide, previous: ?SideInput, label: []const u8) !input_mod.ResolvedSide {
        const self: *ResolutionHarness = @ptrCast(@alignCast(context));
        const uri = source.uri.?;
        const model = source.reference().?.object.textEditorModel;
        if (previous) |input| if (input == .resource and input.resolve().model == model) return .{ .uri = uri, .input = .{ .resource = input.resource.retain() } };
        const reference = try self.manual.models.acquireModelReference(uri);
        return .{ .uri = uri, .input = .{ .resource = try TextResourceEditorInput.initFromReference(testing.allocator, reference, label) } };
    }
    fn computeOptions(context: *anyopaque, _: std.Uri, _: ?input_mod.ResolvedSide, _: ?input_mod.ResolvedSide) !DiffOptions {
        const self: *ResolutionHarness = @ptrCast(@alignCast(context));
        return self.options;
    }
};

fn flushResolution(queue: *dispatch.Queue) void {
    while (true) {
        const now = @import("../../../../../base/common/timeCompat.zig").milliTimestamp();
        if (queue.nextTimeout(now, 1) != 0) break;
        _ = queue.dispatch(now);
    }
}
fn pair(original: []const u8, modified: []const u8) source_api.MultiDiffEditorItem {
    return .{ .originalUri = std.Uri.parse(original) catch unreachable, .modifiedUri = std.Uri.parse(modified) catch unreachable };
}

const removed_resource = pair("inmemory:/original/removed.ts", "inmemory:/modified/removed.ts");
const slow_resource = pair("inmemory:/original/slow.ts", "inmemory:/modified/slow.ts");
const current_resource = pair("inmemory:/original/current.ts", "inmemory:/modified/current.ts");

test "MultiDiffEditorInput: disposes models that finish resolving after input disposal" {
    const a = testing.allocator;
    var queue: dispatch.Queue = .{ .io = testing.io };
    var models = resolver_mod.TextModelResolverService.init(a, testing.io, &queue);
    var manual: ManualResolver = .{ .arena = .init(a), .models = &models };
    defer manual.deinit();
    defer models.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Test", false);
    var harness: ResolutionHarness = .{ .input = input, .manual = &manual };
    try input.resolveResourceModels(manual.interface(), &.{.{ .modifiedUri = try std.Uri.parse("inmemory:/modified.ts") }}, harness.listener());
    try testing.expect(input.isResolvingDocuments);
    try testing.expectEqual(@as(usize, 1), manual.requests.items.len);
    input.destroy();
    try testing.expect(manual.requests.items[0].canceled);
    try manual.settle(0, null);
    flushResolution(&queue);
    try testing.expectEqual(@as(usize, 0), harness.publications.items.len);
    try testing.expectEqual(@as(usize, 1), manual.released.items.len);
    try testing.expectEqualStrings("/modified.ts", manual.released.items[0]);
}

fn staleResolution(update: enum { replace, remove, dispose }) !void {
    const a = testing.allocator;
    var queue: dispatch.Queue = .{ .io = testing.io };
    var models = resolver_mod.TextModelResolverService.init(a, testing.io, &queue);
    var manual: ManualResolver = .{ .arena = .init(a), .models = &models };
    defer manual.deinit();
    defer models.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Test", false);
    var alive = true;
    defer if (alive) input.destroy();
    var harness: ResolutionHarness = .{ .input = input, .manual = &manual };
    try input.resolveResourceModels(manual.interface(), &.{removed_resource}, harness.listener());
    try manual.settle(0, null);
    try manual.settle(1, null);
    const vm = try input.getViewModel(testing.io, &queue, null);
    try testing.expectEqual(@as(usize, 1), vm.items.len);
    try input.resolveResourceModels(manual.interface(), &.{ removed_resource, slow_resource }, harness.listener());
    try testing.expect(input.isResolvingDocuments);
    try manual.settle(2, null);
    try manual.settle(3, null);
    try testing.expectEqual(@as(usize, 1), vm.items.len);
    if (update == .dispose) {
        input.destroy();
        alive = false;
    } else if (update == .replace) {
        try input.resolveResourceModels(manual.interface(), &.{current_resource}, harness.listener());
        try manual.settle(6, null);
        try manual.settle(7, null);
        try testing.expectEqual(@as(usize, 1), vm.items.len);
    } else {
        try input.resolveResourceModels(manual.interface(), &.{}, harness.listener());
        try testing.expectEqual(@as(usize, 0), vm.items.len);
    }
    try testing.expect(manual.requests.items[4].canceled and manual.requests.items[5].canceled);
    try manual.settle(4, null);
    try manual.settle(5, null);
    flushResolution(&queue);
    try testing.expectEqual(@as(usize, if (update == .dispose) 1 else 2), harness.publications.items.len);
    try testing.expectEqualStrings("/modified/removed.ts", harness.publications.items[0][0]);
    if (update == .replace) try testing.expectEqualStrings("/modified/current.ts", harness.publications.items[1][0]);
    if (update == .remove) try testing.expectEqual(@as(usize, 0), harness.publications.items[1].len);
    try testing.expectEqual(@as(usize, 4), manual.released.items.len);
    std.mem.sort([]const u8, manual.released.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    for (manual.released.items, [_][]const u8{ "/modified/removed.ts", "/modified/slow.ts", "/original/removed.ts", "/original/slow.ts" }) |actual, expected| try testing.expectEqualStrings(expected, actual);
}

test "MultiDiffEditorInput: ignores stale document resolutions after replace" {
    try staleResolution(.replace);
}
test "MultiDiffEditorInput: ignores stale document resolutions after remove" {
    try staleResolution(.remove);
}
test "MultiDiffEditorInput: ignores stale document resolutions after dispose" {
    try staleResolution(.dispose);
}

fn settleAfterViewModel(failure: ?anyerror) !void {
    const a = testing.allocator;
    var queue: dispatch.Queue = .{ .io = testing.io };
    var models = resolver_mod.TextModelResolverService.init(a, testing.io, &queue);
    var manual: ManualResolver = .{ .arena = .init(a), .models = &models };
    defer manual.deinit();
    defer models.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Test", false);
    defer input.destroy();
    var harness: ResolutionHarness = .{ .input = input, .manual = &manual };
    try input.resolveResourceModels(manual.interface(), &.{}, harness.listener());
    const vm = try input.getViewModel(testing.io, &queue, null);
    try testing.expect(!vm.isLoading and !input.isResolvingDocuments);
    try input.resolveResourceModels(manual.interface(), &.{current_resource}, harness.listener());
    try testing.expect(input.isResolvingDocuments and !vm.isLoading);
    try testing.expectEqual(@as(usize, 0), vm.items.len);
    try manual.settle(0, null);
    try testing.expect(input.isResolvingDocuments);
    try testing.expectEqual(@as(usize, 1), harness.publications.items.len);
    try manual.settle(1, failure);
    try testing.expect(!input.isResolvingDocuments and !vm.isLoading);
    try testing.expectEqual(@as(usize, if (failure == null) 1 else 0), vm.items.len);
    try testing.expectEqual(failure, input.last_resolution_failure);
    try testing.expectEqual(@as(usize, 2), harness.publications.items.len);
    flushResolution(&queue);
    if (failure != null) {
        try testing.expectEqual(@as(usize, 1), manual.released.items.len);
        try testing.expectEqualStrings("/original/current.ts", manual.released.items[0]);
    }
}

test "MultiDiffEditorInput: resolves documents of resources set after its view model, until all of them settle (resolve)" {
    try settleAfterViewModel(null);
}
test "MultiDiffEditorInput: resolves documents of resources set after its view model, until all of them settle (fail)" {
    try settleAfterViewModel(error.UnableToResolveResource);
}

test "MultiDiffEditorInput: keeps binary resources in the multi diff model on actual resolution failure" {
    const a = testing.allocator;
    var queue: dispatch.Queue = .{ .io = testing.io };
    var models = resolver_mod.TextModelResolverService.init(a, testing.io, &queue);
    var manual: ManualResolver = .{ .arena = .init(a), .models = &models };
    defer manual.deinit();
    defer models.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Test", false);
    defer input.destroy();
    var harness: ResolutionHarness = .{ .input = input, .manual = &manual };
    const resources = pair("file:///original.png", "file:///modified.png");
    try input.resolveResourceModels(manual.interface(), &.{resources}, harness.listener());
    try manual.settle(0, error.BinaryFile);
    try manual.settle(1, error.BinaryFile);
    const vm = try input.getViewModel(testing.io, &queue, null);
    try testing.expectEqual(@as(usize, 1), vm.items.len);
    try testing.expect(vm.items[0].isBinary());
    try testing.expect(vm.items[0].documentDiffItem.original.?.textModel == null);
    try testing.expect(vm.items[0].documentDiffItem.modified.?.textModel == null);
    try testing.expectEqualStrings("/original.png", try std_uri.path(vm.items[0].documentDiffItem.original.?.uri, manual.arena.allocator()));
    try testing.expectEqualStrings("/modified.png", try std_uri.path(vm.items[0].documentDiffItem.modified.?.uri, manual.arena.allocator()));
    try testing.expect(!input.base.isDirty());
    _ = try input.base.save(1);
    try testing.expect(input.last_resolution_failure == null);
}

test "MultiDiffEditorInput: preserves explicit original line number setting values and updates" {
    const a = testing.allocator;
    var queue: dispatch.Queue = .{ .io = testing.io };
    var models = resolver_mod.TextModelResolverService.init(a, testing.io, &queue);
    var manual: ManualResolver = .{ .arena = .init(a), .models = &models };
    defer manual.deinit();
    defer models.deinit();
    const input = try input_mod.MultiDiffEditorInput.create(a, "multi-diff-editor:test", "Test", false);
    defer input.destroy();
    var harness: ResolutionHarness = .{ .input = input, .manual = &manual };
    try input.resolveResourceModels(manual.interface(), &.{pair("file:///original.ts", "file:///modified.ts")}, harness.listener());
    try manual.settle(0, error.BinaryFile);
    try manual.settle(1, error.BinaryFile);
    const vm = try input.getViewModel(testing.io, &queue, null);
    const item = vm.items[0].documentDiffItem;
    const Config = @import("../../../../../platform/configuration/common/configuration.zig");
    const Capture = struct {
        item: *@import("../../../../../editor/browser/widget/multiDiffEditor/model.zig").IDocumentDiffItem,
        values: std.ArrayList(?bool) = .empty,
        fn changed(_: void, self: *@This()) !void {
            try self.values.append(testing.allocator, self.item.hideOriginalLineNumbers);
        }
    };
    const Settings = struct {
        value: std.json.Value = .null,
        changed: @import("../../../../../base/common/event.zig").Emitter(Config.Change),
        item: *Capture,
        fn get(context: *anyopaque, key: []const u8) ?*const std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            return if (std.mem.eql(u8, key, "diffEditor.hideOriginalLineNumbers")) &self.value else null;
        }
        fn interface(self: *@This()) Config.IConfigurationService {
            return .{ .context = self, .get_value = get, .on_did_change_configuration = &self.changed };
        }
        fn onConfig(_: Config.Change, self: *@This()) !void {
            try self.item.item.updateOptions(@import("../../../../browser/parts/editor/textDiffEditor.zig").computeConfiguration(self.interface()));
        }
    };
    var capture: Capture = .{ .item = item };
    defer capture.values.deinit(a);
    try capture.values.append(a, item.hideOriginalLineNumbers);
    const option_listener = try item.onOptionsDidChange.listenDisposable(&capture, Capture.changed);
    defer option_listener.dispose();
    var settings: Settings = .{ .changed = .init(a), .item = &capture };
    defer settings.changed.deinit();
    const config_listener = try settings.changed.listenDisposable(&settings, Settings.onConfig);
    defer config_listener.dispose();
    for ([_]std.json.Value{ .{ .bool = false }, .{ .bool = true }, .null }) |value| {
        settings.value = value;
        try settings.changed.fire(.{ .source = .USER, .keys = &.{"diffEditor.hideOriginalLineNumbers"} });
    }
    try testing.expectEqualSlices(?bool, &.{ null, false, true, null }, capture.values.items);
}
