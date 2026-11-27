// Port of the working-copy identity/event subset of
// `src/vs/workbench/services/workingCopy/common/workingCopy.ts`.
const std = @import("std");

pub const WorkingCopyIdentifier = struct {
    /// Terminal adaptation: resources are canonical path strings.
    resource: []const u8,
    type_id: []const u8,
};

pub const WorkingCopyListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

pub const SaveCompletion = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror!bool) void,
};

/// Mirrors upstream `IWorkingCopy` for the terminal working-copy service.
pub const IWorkingCopy = struct {
    context: *anyopaque,
    resource: *const fn (context: *anyopaque) []const u8,
    resource_uri: ?*const fn (context: *anyopaque) std.Uri = null,
    type_id: *const fn (context: *anyopaque) []const u8,
    name: *const fn (context: *anyopaque) []const u8,
    is_dirty: *const fn (context: *anyopaque) bool,
    is_modified: *const fn (context: *anyopaque) bool,
    request_save_fn: ?*const fn (*anyopaque, ?SaveCompletion) anyerror!void = null,
    save_fn: ?*const fn (context: *anyopaque) anyerror!void = null,
    add_dirty_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_dirty_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    add_content_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_content_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    add_save_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_save_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,

    pub fn getResource(self: IWorkingCopy) []const u8 {
        return self.resource(self.context);
    }
    pub fn getResourceUri(self: IWorkingCopy) std.Uri {
        if (self.resource_uri) |callback| return callback(self.context);
        return .{ .scheme = "file", .path = .{ .raw = self.getResource() } };
    }
    pub fn getTypeId(self: IWorkingCopy) []const u8 {
        return self.type_id(self.context);
    }
    pub fn getName(self: IWorkingCopy) []const u8 {
        return self.name(self.context);
    }
    pub fn getDirty(self: IWorkingCopy) bool {
        return self.is_dirty(self.context);
    }
    pub fn requestSave(self: IWorkingCopy, completion: ?SaveCompletion) !void {
        if (self.request_save_fn) |request| return request(self.context, completion);
        try self.save();
        if (completion) |callback| callback.complete(callback.context, true);
    }
    pub fn save(self: IWorkingCopy) !void {
        const callback = self.save_fn orelse return error.SaveUnsupported;
        try callback(self.context);
    }
    pub fn getModified(self: IWorkingCopy) bool {
        return self.is_modified(self.context);
    }
};
