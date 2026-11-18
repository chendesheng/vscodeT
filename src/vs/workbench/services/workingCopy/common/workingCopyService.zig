// Port of `src/vs/workbench/services/workingCopy/common/workingCopyService.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const working_copy = @import("./workingCopy.zig");
const IWorkingCopy = working_copy.IWorkingCopy;
const WorkingCopyIdentifier = working_copy.WorkingCopyIdentifier;
const WorkingCopyListener = working_copy.WorkingCopyListener;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const WorkingCopySaveEvent = struct {
    workingCopy: *const IWorkingCopy,
};

pub const WorkingCopyService = struct {
    allocator: Allocator,
    registrations: std.array_list.Managed(*Registration),
    on_did_register: Emitter(*const IWorkingCopy),
    on_did_unregister: Emitter(*const IWorkingCopy),
    on_did_change_dirty: Emitter(*const IWorkingCopy),
    on_did_change_content: Emitter(*const IWorkingCopy),
    on_did_save: Emitter(WorkingCopySaveEvent),

    const Registration = struct {
        service: *WorkingCopyService,
        copy: IWorkingCopy,
        dirty_listener: WorkingCopyListener,
        content_listener: WorkingCopyListener,
        save_listener: WorkingCopyListener,
    };

    pub fn init(allocator: Allocator) WorkingCopyService {
        return .{
            .allocator = allocator,
            .registrations = std.array_list.Managed(*Registration).init(allocator),
            .on_did_register = Emitter(*const IWorkingCopy).init(allocator),
            .on_did_unregister = Emitter(*const IWorkingCopy).init(allocator),
            .on_did_change_dirty = Emitter(*const IWorkingCopy).init(allocator),
            .on_did_change_content = Emitter(*const IWorkingCopy).init(allocator),
            .on_did_save = Emitter(WorkingCopySaveEvent).init(allocator),
        };
    }

    pub fn deinit(self: *WorkingCopyService) void {
        // Working copies own their listener lists and must outlive the service
        // (or be unregistered explicitly); freeing registrations here avoids
        // touching destroyed copies.
        for (self.registrations.items) |registration| self.allocator.destroy(registration);
        self.registrations.deinit();
        self.on_did_register.deinit();
        self.on_did_unregister.deinit();
        self.on_did_change_dirty.deinit();
        self.on_did_change_content.deinit();
        self.on_did_save.deinit();
    }

    fn unsubscribe(self: *WorkingCopyService, registration: *Registration) void {
        _ = self;
        registration.copy.remove_dirty_listener(registration.copy.context, registration.dirty_listener);
        registration.copy.remove_content_listener(registration.copy.context, registration.content_listener);
        registration.copy.remove_save_listener(registration.copy.context, registration.save_listener);
    }

    pub fn registerWorkingCopy(self: *WorkingCopyService, copy: IWorkingCopy) !void {
        for (self.registrations.items) |registration| {
            if (std.mem.eql(u8, registration.copy.getResource(), copy.getResource()) and
                std.mem.eql(u8, registration.copy.getTypeId(), copy.getTypeId()))
            {
                return error.AlreadyRegistered;
            }
        }
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        registration.* = .{
            .service = self,
            .copy = copy,
            .dirty_listener = .{ .context = registration, .callback = onDirty },
            .content_listener = .{ .context = registration, .callback = onContent },
            .save_listener = .{ .context = registration, .callback = onSave },
        };
        copy.add_dirty_listener(copy.context, registration.dirty_listener);
        copy.add_content_listener(copy.context, registration.content_listener);
        copy.add_save_listener(copy.context, registration.save_listener);
        try self.registrations.append(registration);
        try self.on_did_register.fire(&registration.copy);
        if (copy.getDirty()) try self.on_did_change_dirty.fire(&registration.copy);
    }

    pub fn unregisterWorkingCopy(self: *WorkingCopyService, copy: IWorkingCopy) bool {
        var index: usize = 0;
        while (index < self.registrations.items.len) : (index += 1) {
            const registration = self.registrations.items[index];
            if (std.mem.eql(u8, registration.copy.getResource(), copy.getResource()) and
                std.mem.eql(u8, registration.copy.getTypeId(), copy.getTypeId()))
            {
                const was_dirty = copy.getDirty();
                self.unsubscribe(registration);
                _ = self.registrations.orderedRemove(index);
                self.allocator.destroy(registration);
                self.on_did_unregister.fire(&copy) catch {};
                if (was_dirty) self.on_did_change_dirty.fire(&copy) catch {};
                return true;
            }
        }
        return false;
    }

    pub fn has(self: *const WorkingCopyService, identifier: WorkingCopyIdentifier) bool {
        return self.get(identifier) != null;
    }

    pub fn hasResource(self: *const WorkingCopyService, resource: []const u8) bool {
        for (self.registrations.items) |registration| {
            if (std.mem.eql(u8, registration.copy.getResource(), resource)) return true;
        }
        return false;
    }

    pub fn get(self: *const WorkingCopyService, identifier: WorkingCopyIdentifier) ?*const IWorkingCopy {
        for (self.registrations.items) |registration| {
            if (std.mem.eql(u8, registration.copy.getResource(), identifier.resource) and
                std.mem.eql(u8, registration.copy.getTypeId(), identifier.type_id))
            {
                return &registration.copy;
            }
        }
        return null;
    }

    pub fn getAll(self: *const WorkingCopyService, resource: []const u8, allocator: Allocator) ?[]const *const IWorkingCopy {
        var result = std.array_list.Managed(*const IWorkingCopy).init(allocator);
        errdefer result.deinit();
        for (self.registrations.items) |registration| {
            if (std.mem.eql(u8, registration.copy.getResource(), resource)) result.append(&registration.copy) catch return null;
        }
        if (result.items.len == 0) {
            result.deinit();
            return null;
        }
        return result.toOwnedSlice() catch null;
    }

    pub fn workingCopies(self: *const WorkingCopyService, allocator: Allocator) ![]const *const IWorkingCopy {
        const result = try allocator.alloc(*const IWorkingCopy, self.registrations.items.len);
        for (self.registrations.items, 0..) |registration, index| result[index] = &registration.copy;
        return result;
    }

    pub fn dirtyWorkingCopies(self: *const WorkingCopyService, allocator: Allocator) ![]const *const IWorkingCopy {
        var result = std.array_list.Managed(*const IWorkingCopy).init(allocator);
        defer result.deinit();
        for (self.registrations.items) |registration| {
            if (registration.copy.getDirty()) try result.append(&registration.copy);
        }
        return result.toOwnedSlice();
    }

    pub fn modifiedWorkingCopies(self: *const WorkingCopyService, allocator: Allocator) ![]const *const IWorkingCopy {
        var result = std.array_list.Managed(*const IWorkingCopy).init(allocator);
        defer result.deinit();
        for (self.registrations.items) |registration| {
            if (registration.copy.getModified()) try result.append(&registration.copy);
        }
        return result.toOwnedSlice();
    }

    pub fn dirtyCount(self: *const WorkingCopyService) usize {
        var count: usize = 0;
        for (self.registrations.items) |registration| {
            if (registration.copy.getDirty()) count += 1;
        }
        return count;
    }

    pub fn modifiedCount(self: *const WorkingCopyService) usize {
        var count: usize = 0;
        for (self.registrations.items) |registration| {
            if (registration.copy.getModified()) count += 1;
        }
        return count;
    }

    pub fn hasDirty(self: *const WorkingCopyService) bool {
        return self.dirtyCount() > 0;
    }

    pub fn isDirty(self: *const WorkingCopyService, resource: []const u8, type_id: ?[]const u8) bool {
        for (self.registrations.items) |registration| {
            if (!std.mem.eql(u8, registration.copy.getResource(), resource)) continue;
            if (type_id) |value| {
                if (!std.mem.eql(u8, registration.copy.getTypeId(), value)) continue;
            }
            if (registration.copy.getDirty()) return true;
        }
        return false;
    }

    fn onDirty(context: *anyopaque) void {
        const registration: *Registration = @ptrCast(@alignCast(context));
        registration.service.on_did_change_dirty.fire(&registration.copy) catch {};
    }

    fn onContent(context: *anyopaque) void {
        const registration: *Registration = @ptrCast(@alignCast(context));
        registration.service.on_did_change_content.fire(&registration.copy) catch {};
    }

    fn onSave(context: *anyopaque) void {
        const registration: *Registration = @ptrCast(@alignCast(context));
        registration.service.on_did_save.fire(.{ .workingCopy = &registration.copy }) catch {};
    }
};
