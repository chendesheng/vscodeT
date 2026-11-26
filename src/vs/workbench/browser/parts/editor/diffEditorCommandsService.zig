// Port of the navigation and swap subset of
// src/vs/workbench/browser/parts/editor/diffEditorCommandsService.ts.
// Terminal snapshot refresh is delegated to the provider owning the refs.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const Configuration = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;

pub const diff_editor_commands_service_id = instantiation.ServiceIdentifier(IDiffEditorCommandsService, "diffEditorCommandsService");

pub const FocusSide = enum { original, modified, toggle };
pub const ViewMode = enum { inline_view, side_by_side, automatic, toggle };

pub const IDiffEditorCommandsService = struct {
    context: *anyopaque,
    navigate_fn: *const fn (*anyopaque, bool) void,
    swap_fn: *const fn (*anyopaque) void,
    refresh_fn: *const fn (*anyopaque) anyerror!void,
    focus_fn: *const fn (*anyopaque, FocusSide) void,
    view_mode_fn: *const fn (*anyopaque, Configuration, ViewMode) anyerror!void,
    whitespace_fn: *const fn (*anyopaque, Configuration) anyerror!void,

    pub fn navigateInDiffEditor(self: IDiffEditorCommandsService, next: bool) void {
        self.navigate_fn(self.context, next);
    }

    pub fn swapDiffSides(self: IDiffEditorCommandsService) void {
        self.swap_fn(self.context);
    }

    pub fn focusInDiffEditor(self: IDiffEditorCommandsService, side: FocusSide) void {
        self.focus_fn(self.context, side);
    }

    pub fn setViewMode(self: IDiffEditorCommandsService, configuration: Configuration, mode: ViewMode) !void {
        try self.view_mode_fn(self.context, configuration, mode);
    }

    pub fn toggleIgnoreTrimWhitespace(self: IDiffEditorCommandsService, configuration: Configuration) !void {
        try self.whitespace_fn(self.context, configuration);
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
        return .{
            .context = self,
            .navigate_fn = navigateInDiffEditor,
            .swap_fn = swapDiffSides,
            .refresh_fn = refreshDiff,
            .focus_fn = focusInDiffEditor,
            .view_mode_fn = setViewMode,
            .whitespace_fn = toggleIgnoreTrimWhitespace,
        };
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

    fn focusInDiffEditor(context: *anyopaque, side: FocusSide) void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        diff.widget.setFocus(switch (side) {
            .original => .original,
            .modified => .modified,
            .toggle => if (diff.widget.focused == .original) .modified else .original,
        });
    }

    fn setViewMode(context: *anyopaque, configuration: Configuration, mode: ViewMode) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        switch (mode) {
            .toggle => try configuration.updateValue("diffEditor.renderSideBySide", .{ .bool = !diff.widget.options.render_side_by_side }, .USER),
            .inline_view => try configuration.updateValue("diffEditor.renderSideBySide", .{ .bool = false }, .USER),
            .side_by_side, .automatic => {
                try configuration.updateValue("diffEditor.renderSideBySide", .{ .bool = true }, .USER);
                try configuration.updateValue("diffEditor.useInlineViewWhenSpaceIsLimited", .{ .bool = mode == .automatic }, .USER);
            },
        }
    }

    fn toggleIgnoreTrimWhitespace(context: *anyopaque, configuration: Configuration) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        try configuration.updateValue("diffEditor.ignoreTrimWhitespace", .{ .bool = !diff.widget.options.ignore_trim_whitespace }, .USER);
    }

    fn refreshDiff(context: *anyopaque) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        try self.snapshot_provider.refresh(self.snapshot_provider.context, diff.model.modified_path, diff.model.original_label, diff.model.modified_label);
    }
};
