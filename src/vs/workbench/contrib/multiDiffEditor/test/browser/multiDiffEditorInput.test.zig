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
