// Port of `src/vs/workbench/services/workingCopy/test/browser/workingCopyEditorService.test.ts`.
//
// Terminal adaptation: `findEditor` takes the open editors directly instead
// of querying an injected editor service.
const std = @import("std");
const testing = std.testing;

const service_mod = @import("../../common/workingCopyEditorService.zig");
const working_copy = @import("../../common/workingCopy.zig");
const EditorInput = @import("../../../../common/editor/editorInput.zig").EditorInput;

const TestCopy = struct {
    resource_path: []const u8,
    type_identifier: []const u8,

    fn resource(context: *anyopaque) []const u8 {
        const self: *TestCopy = @ptrCast(@alignCast(context));
        return self.resource_path;
    }
    fn typeId(context: *anyopaque) []const u8 {
        const self: *TestCopy = @ptrCast(@alignCast(context));
        return self.type_identifier;
    }
    fn name(context: *anyopaque) []const u8 {
        const self: *TestCopy = @ptrCast(@alignCast(context));
        return self.resource_path;
    }
    fn isDirty(_: *anyopaque) bool {
        return false;
    }
    fn addListener(_: *anyopaque, _: working_copy.WorkingCopyListener) void {}
    fn removeListener(_: *anyopaque, _: working_copy.WorkingCopyListener) void {}

    fn interface(self: *TestCopy) working_copy.IWorkingCopy {
        return .{
            .context = self,
            .resource = resource,
            .type_id = typeId,
            .name = name,
            .is_dirty = isDirty,
            .is_modified = isDirty,
            .add_dirty_listener = addListener,
            .remove_dirty_listener = removeListener,
            .add_content_listener = addListener,
            .remove_content_listener = removeListener,
            .add_save_listener = addListener,
            .remove_save_listener = removeListener,
        };
    }
};

test "working copy editor service: registers handlers and finds open editors" {
    const allocator = testing.allocator;
    var service = service_mod.WorkingCopyEditorService.init(allocator);
    defer service.deinit();

    var handler_events: usize = 0;
    _ = try service.on_did_register_handler.listen(&handler_events, struct {
        fn onRegister(_: *const service_mod.WorkingCopyEditorHandler, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.onRegister);

    var editor1 = EditorInput.init(allocator, "testEditor");
    defer editor1.deinit();
    var editor2 = EditorInput.init(allocator, "testEditor");
    defer editor2.deinit();

    var copy = TestCopy{ .resource_path = "/some/folder/file.txt", .type_identifier = "testWorkingCopyType" };
    const editors = [_]*EditorInput{ &editor1, &editor2 };
    try testing.expect(service.findEditor(copy.interface(), &editors) == null);

    const Handler = struct {
        target: *TestCopy,
        target_editor: *EditorInput,

        fn handles(_: *anyopaque, _: working_copy.WorkingCopyIdentifier) bool {
            return false;
        }
        fn isOpen(context: *anyopaque, identifier: working_copy.WorkingCopyIdentifier, editor: *EditorInput) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return std.mem.eql(u8, identifier.resource, self.target.resource_path) and
                std.mem.eql(u8, identifier.type_id, self.target.type_identifier) and
                editor == self.target_editor;
        }
        fn createEditor(_: *anyopaque, _: working_copy.WorkingCopyIdentifier) ?*EditorInput {
            return null;
        }
    };
    var handler = Handler{ .target = &copy, .target_editor = &editor2 };
    var handler_interface = service_mod.WorkingCopyEditorHandler{
        .context = &handler,
        .handles = Handler.handles,
        .is_open = Handler.isOpen,
        .create_editor = Handler.createEditor,
    };
    try service.registerHandler(&handler_interface);
    try testing.expectEqual(@as(usize, 1), handler_events);
    try testing.expect(service.findEditor(copy.interface(), &editors) == &editor2);

    service.unregisterHandler(&handler_interface);
    try testing.expect(service.findEditor(copy.interface(), &editors) == null);
}
