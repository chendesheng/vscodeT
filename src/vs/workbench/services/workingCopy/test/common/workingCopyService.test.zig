// Port of `src/vs/workbench/services/workingCopy/test/common/workingCopyService.test.ts`.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const working_copy = @import("../../common/workingCopy.zig");
const service_mod = @import("../../common/workingCopyService.zig");
const IWorkingCopy = working_copy.IWorkingCopy;
const WorkingCopyIdentifier = working_copy.WorkingCopyIdentifier;
const WorkingCopyListener = working_copy.WorkingCopyListener;
const WorkingCopyService = service_mod.WorkingCopyService;

const TestWorkingCopy = struct {
    allocator: Allocator,
    resource_path: []const u8,
    type_identifier: []const u8,
    label: []const u8,
    dirty: bool = false,
    modified: bool = false,
    dirty_listeners: std.array_list.Managed(WorkingCopyListener),
    content_listeners: std.array_list.Managed(WorkingCopyListener),
    save_listeners: std.array_list.Managed(WorkingCopyListener),

    fn create(allocator: Allocator, resource_path: []const u8, type_identifier: []const u8, dirty: bool) !*TestWorkingCopy {
        const self = try allocator.create(TestWorkingCopy);
        self.* = .{
            .allocator = allocator,
            .resource_path = try allocator.dupe(u8, resource_path),
            .type_identifier = try allocator.dupe(u8, type_identifier),
            .label = try allocator.dupe(u8, std.fs.path.basename(resource_path)),
            .dirty = dirty,
            .modified = dirty,
            .dirty_listeners = std.array_list.Managed(WorkingCopyListener).init(allocator),
            .content_listeners = std.array_list.Managed(WorkingCopyListener).init(allocator),
            .save_listeners = std.array_list.Managed(WorkingCopyListener).init(allocator),
        };
        return self;
    }

    fn destroy(self: *TestWorkingCopy) void {
        const allocator = self.allocator;
        allocator.free(self.resource_path);
        allocator.free(self.type_identifier);
        allocator.free(self.label);
        self.dirty_listeners.deinit();
        self.content_listeners.deinit();
        self.save_listeners.deinit();
        allocator.destroy(self);
    }

    fn emitDirty(self: *TestWorkingCopy) void {
        for (self.dirty_listeners.items) |listener| listener.callback(listener.context);
    }
    fn emitContent(self: *TestWorkingCopy) void {
        for (self.content_listeners.items) |listener| listener.callback(listener.context);
    }
    fn emitSave(self: *TestWorkingCopy) void {
        for (self.save_listeners.items) |listener| listener.callback(listener.context);
    }

    fn setDirty(self: *TestWorkingCopy, dirty: bool) void {
        self.dirty = dirty;
        self.modified = dirty or self.modified;
        self.emitDirty();
    }
    fn setContent(self: *TestWorkingCopy) void {
        self.modified = true;
        self.emitContent();
    }
    fn save(self: *TestWorkingCopy) void {
        self.emitSave();
    }

    fn resource(context: *anyopaque) []const u8 {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        return self.resource_path;
    }
    fn typeId(context: *anyopaque) []const u8 {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        return self.type_identifier;
    }
    fn name(context: *anyopaque) []const u8 {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        return self.label;
    }
    fn isDirty(context: *anyopaque) bool {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        return self.dirty;
    }
    fn isModified(context: *anyopaque) bool {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        return self.modified;
    }

    fn addListener(list: *std.array_list.Managed(WorkingCopyListener), listener: WorkingCopyListener) void {
        list.append(listener) catch {};
    }
    fn removeListener(list: *std.array_list.Managed(WorkingCopyListener), listener: WorkingCopyListener) void {
        var index: usize = 0;
        while (index < list.items.len) : (index += 1) {
            const current = list.items[index];
            if (current.context == listener.context and current.callback == listener.callback) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    fn addDirty(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        addListener(&self.dirty_listeners, listener);
    }
    fn removeDirty(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        removeListener(&self.dirty_listeners, listener);
    }
    fn addContent(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        addListener(&self.content_listeners, listener);
    }
    fn removeContent(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        removeListener(&self.content_listeners, listener);
    }
    fn addSave(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        addListener(&self.save_listeners, listener);
    }
    fn removeSave(context: *anyopaque, listener: WorkingCopyListener) void {
        const self: *TestWorkingCopy = @ptrCast(@alignCast(context));
        removeListener(&self.save_listeners, listener);
    }

    fn interface(self: *TestWorkingCopy) IWorkingCopy {
        return .{
            .context = self,
            .resource = TestWorkingCopy.resource,
            .type_id = TestWorkingCopy.typeId,
            .name = TestWorkingCopy.name,
            .is_dirty = TestWorkingCopy.isDirty,
            .is_modified = TestWorkingCopy.isModified,
            .add_dirty_listener = TestWorkingCopy.addDirty,
            .remove_dirty_listener = TestWorkingCopy.removeDirty,
            .add_content_listener = TestWorkingCopy.addContent,
            .remove_content_listener = TestWorkingCopy.removeContent,
            .add_save_listener = TestWorkingCopy.addSave,
            .remove_save_listener = TestWorkingCopy.removeSave,
        };
    }
};

const Counters = struct {
    dirty: usize = 0,
    content: usize = 0,
    saves: usize = 0,
    registered: usize = 0,
    unregistered: usize = 0,

    fn onDirty(_: *const IWorkingCopy, self: *Counters) anyerror!void {
        self.dirty += 1;
    }
    fn onContent(_: *const IWorkingCopy, self: *Counters) anyerror!void {
        self.content += 1;
    }
    fn onSave(_: service_mod.WorkingCopySaveEvent, self: *Counters) anyerror!void {
        self.saves += 1;
    }
    fn onRegister(_: *const IWorkingCopy, self: *Counters) anyerror!void {
        self.registered += 1;
    }
    fn onUnregister(_: *const IWorkingCopy, self: *Counters) anyerror!void {
        self.unregistered += 1;
    }
};

test "working copy service: registry basics" {
    const allocator = testing.allocator;
    var service = WorkingCopyService.init(allocator);
    defer service.deinit();
    var counters = Counters{};
    _ = try service.on_did_change_dirty.listen(&counters, Counters.onDirty);
    _ = try service.on_did_change_content.listen(&counters, Counters.onContent);
    _ = try service.on_did_save.listen(&counters, Counters.onSave);
    _ = try service.on_did_register.listen(&counters, Counters.onRegister);
    _ = try service.on_did_unregister.listen(&counters, Counters.onUnregister);

    try testing.expect(!service.hasDirty());
    try testing.expectEqual(@as(usize, 0), service.dirtyCount());

    const copy1 = try TestWorkingCopy.create(allocator, "/some/folder/file.txt", "testWorkingCopyType", false);
    defer copy1.destroy();
    try service.registerWorkingCopy(copy1.interface());
    try testing.expectEqual(@as(usize, 1), counters.registered);
    try testing.expect(service.hasResource("/some/folder/file.txt"));
    try testing.expect(service.has(.{ .resource = "/some/folder/file.txt", .type_id = "testWorkingCopyType" }));

    copy1.setDirty(true);
    copy1.save();
    try testing.expectEqual(@as(usize, 1), service.dirtyCount());
    try testing.expectEqual(@as(usize, 1), counters.dirty);
    try testing.expectEqual(@as(usize, 1), counters.saves);

    copy1.setContent();
    try testing.expectEqual(@as(usize, 1), counters.content);
    copy1.setDirty(false);
    try testing.expectEqual(@as(usize, 0), service.dirtyCount());
    try testing.expectEqual(@as(usize, 2), counters.dirty);

    _ = service.unregisterWorkingCopy(copy1.interface());
    try testing.expectEqual(@as(usize, 1), counters.unregistered);
    const all_copies = try service.workingCopies(allocator);
    defer allocator.free(all_copies);
    try testing.expectEqual(@as(usize, 0), all_copies.len);
    try testing.expect(!service.hasResource("/some/folder/file.txt"));

    const copy2 = try TestWorkingCopy.create(allocator, "/some/folder/dirty.txt", "testWorkingCopyType", true);
    defer copy2.destroy();
    try service.registerWorkingCopy(copy2.interface());
    try testing.expectEqual(@as(usize, 1), service.dirtyCount());
    try testing.expect(service.hasDirty());
    _ = service.unregisterWorkingCopy(copy2.interface());
    try testing.expectEqual(@as(usize, 0), service.dirtyCount());
}

test "working copy service: duplicate identifiers" {
    const allocator = testing.allocator;
    var service = WorkingCopyService.init(allocator);
    defer service.deinit();

    const copy1 = try TestWorkingCopy.create(allocator, "/file.txt", "type1", false);
    defer copy1.destroy();
    try service.registerWorkingCopy(copy1.interface());

    const duplicate = try TestWorkingCopy.create(allocator, "/file.txt", "type1", false);
    defer duplicate.destroy();
    try testing.expectError(error.AlreadyRegistered, service.registerWorkingCopy(duplicate.interface()));

    const different_type = try TestWorkingCopy.create(allocator, "/file.txt", "type2", false);
    defer different_type.destroy();
    try service.registerWorkingCopy(different_type.interface());
    const all_copies = try service.workingCopies(allocator);
    defer allocator.free(all_copies);
    try testing.expectEqual(@as(usize, 2), all_copies.len);
}
