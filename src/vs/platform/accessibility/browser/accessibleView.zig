// Port of the accessible-view service and content-provider contracts in
// `src/vs/platform/accessibility/browser/accessibleView.ts`.
const std = @import("std");
const instantiation = @import("../../instantiation/common/instantiation.zig");

pub const AccessibleViewType = enum { Help, View };
pub const AccessibleViewProviderId = enum { DiffEditor, MultiDiffEditorFileList, Editor };
pub fn providerIdString(id: AccessibleViewProviderId) []const u8 {
    return switch (id) {
        .DiffEditor => "diffEditor",
        .MultiDiffEditorFileList => "multiDiffEditorFileList",
        .Editor => "editor",
    };
}

pub const AccessibleContentProvider = struct {
    allocator: std.mem.Allocator,
    id: AccessibleViewProviderId,
    kind: AccessibleViewType,
    content: []u8,
    verbosity_setting_key: []const u8,
    on_close: ?Close = null,

    pub const Close = struct { context: *anyopaque, run: *const fn (*anyopaque) void };

    pub fn deinit(self: *AccessibleContentProvider) void {
        self.allocator.free(self.content);
    }
};

pub const IAccessibleViewService = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, instantiation.ServicesAccessor, AccessibleViewType) anyerror!void,
    disable_hint_fn: *const fn (*anyopaque) anyerror!void,
    lookup_keybinding_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,

    pub fn open(self: IAccessibleViewService, accessor: instantiation.ServicesAccessor, kind: AccessibleViewType) !void {
        try self.open_fn(self.context, accessor, kind);
    }
    pub fn disableHint(self: IAccessibleViewService) !void {
        try self.disable_hint_fn(self.context);
    }
    pub fn lookupKeybindingLabel(self: IAccessibleViewService, allocator: std.mem.Allocator, id: []const u8) !?[]const u8 {
        return self.lookup_keybinding_fn(self.context, allocator, id);
    }
};
pub const accessible_view_service_id = instantiation.ServiceIdentifier(IAccessibleViewService, "accessibleViewService");
