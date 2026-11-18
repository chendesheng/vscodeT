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

/// Mirrors upstream `IWorkingCopy` for the terminal working-copy service.
pub const IWorkingCopy = struct {
    context: *anyopaque,
    resource: *const fn (context: *anyopaque) []const u8,
    type_id: *const fn (context: *anyopaque) []const u8,
    name: *const fn (context: *anyopaque) []const u8,
    is_dirty: *const fn (context: *anyopaque) bool,
    is_modified: *const fn (context: *anyopaque) bool,
    add_dirty_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_dirty_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    add_content_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_content_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    add_save_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,
    remove_save_listener: *const fn (context: *anyopaque, listener: WorkingCopyListener) void,

    pub fn getResource(self: IWorkingCopy) []const u8 {
        return self.resource(self.context);
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
    pub fn getModified(self: IWorkingCopy) bool {
        return self.is_modified(self.context);
    }
};
