// Port of the navigation and swap subset of
// src/vs/workbench/browser/parts/editor/diffEditorCommandsService.ts.
// Terminal snapshot refresh is delegated to the provider owning the refs.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;

pub const diff_editor_commands_service_id = instantiation.ServiceIdentifier(IDiffEditorCommandsService, "diffEditorCommandsService");

pub const IDiffEditorCommandsService = struct {
    context: *anyopaque,
    navigate_fn: *const fn (*anyopaque, bool) void,
    swap_fn: *const fn (*anyopaque) void,
    refresh_fn: *const fn (*anyopaque) anyerror!void,

    pub fn navigateInDiffEditor(self: IDiffEditorCommandsService, next: bool) void {
        self.navigate_fn(self.context, next);
    }

    pub fn swapDiffSides(self: IDiffEditorCommandsService) void {
        self.swap_fn(self.context);
    }

    pub fn refreshDiff(self: IDiffEditorCommandsService) !void {
        try self.refresh_fn(self.context);
    }
};

pub const DiffEditorCommandsService = struct {
    editor_service: *EditorService,
    snapshot_provider: struct {
        context: *anyopaque,
        refresh: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    },

    pub fn interface(self: *DiffEditorCommandsService) IDiffEditorCommandsService {
        return .{ .context = self, .navigate_fn = navigateInDiffEditor, .swap_fn = swapDiffSides, .refresh_fn = refreshDiff };
    }

    fn navigateInDiffEditor(context: *anyopaque, next: bool) void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        if (next) _ = tab.nextDiffChange() else _ = tab.previousDiffChange();
    }

    fn swapDiffSides(context: *anyopaque) void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        if (self.editor_service.activeEditorPane()) |tab| tab.swapDiffSides();
    }

    fn refreshDiff(context: *anyopaque) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        try self.snapshot_provider.refresh(self.snapshot_provider.context, diff.model.modified_path, diff.model.original_label, diff.model.modified_label);
    }
};
