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
    open_side_fn: *const fn (*anyopaque) anyerror!void,
    swap_fn: *const fn (*anyopaque) void,
    refresh_fn: *const fn (*anyopaque) anyerror!void,
    focus_fn: *const fn (*anyopaque, FocusSide) void,
    view_mode_fn: *const fn (*anyopaque, Configuration, ViewMode) anyerror!void,
    whitespace_fn: *const fn (*anyopaque, Configuration) anyerror!void,

    pub fn navigateInDiffEditor(self: IDiffEditorCommandsService, next: bool) void {
        self.navigate_fn(self.context, next);
    }

    pub fn openActiveDiffSide(self: IDiffEditorCommandsService) !void {
        try self.open_side_fn(self.context);
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
            .open_side_fn = openActiveDiffSide,
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

    fn openActiveDiffSide(context: *anyopaque) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        if (tab.multi_diff) |multi| {
            const item = multi.widget.getViewModel().?.activeDiffItem orelse return;
            const widget = multi.widget.activeControl() orelse return;
            for (multi.input.entries) |entry| if (entry.item == item.documentDiffItem) {
                const side = if (widget.focused == .original) entry.original else entry.modified;
                if (side) |input| try self.editor_service.openDiffSide(input);
                return;
            };
            return;
        }
        const diff = tab.diff orelse return;
        try self.editor_service.openDiffSide(if (diff.widget.focused == .original) diff.original_input else diff.modified_input);
    }

    fn swapDiffSides(context: *anyopaque) void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        if (self.editor_service.activeEditorPane()) |tab| tab.swapDiffSides();
    }

    fn focusInDiffEditor(context: *anyopaque, side: FocusSide) void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const widget = tab.activeDiffWidget() orelse return;
        widget.setFocus(switch (side) {
            .original => .original,
            .modified => .modified,
            .toggle => if (widget.focused == .original) .modified else .original,
        });
    }

    fn setViewMode(context: *anyopaque, configuration: Configuration, mode: ViewMode) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        if (tab.multi_diff) |multi| {
            const target: @import("../../../../editor/browser/widget/multiDiffEditor/diffEditorItemTemplate.zig").ViewMode = switch (mode) {
                .inline_view => .inline_view,
                .side_by_side => .side_by_side,
                .automatic => .automatic,
                .toggle => if (multi.widget.impl.config.render_side_by_side orelse true) .inline_view else .side_by_side,
            };
            return multi.widget.setDiffLayoutOptions(target, null);
        }
        const diff = tab.diff orelse return;
        switch (mode) {
            .toggle => try configuration.requestUpdateValue("diffEditor.renderSideBySide", .{ .bool = !diff.widget.options.render_side_by_side }, .USER),
            .inline_view => try configuration.requestUpdateValue("diffEditor.renderSideBySide", .{ .bool = false }, .USER),
            .side_by_side, .automatic => {
                try configuration.requestUpdateValue("diffEditor.renderSideBySide", .{ .bool = true }, .USER);
                try configuration.requestUpdateValue("diffEditor.useInlineViewWhenSpaceIsLimited", .{ .bool = mode == .automatic }, .USER);
                if (mode == .automatic) {
                    diff.widget.width_based_layout.resetWidthBasedLayout();
                    diff.widget.layout(diff.widget.width, diff.widget.height);
                }
            },
        }
    }

    fn toggleIgnoreTrimWhitespace(context: *anyopaque, configuration: Configuration) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        try configuration.requestUpdateValue("diffEditor.ignoreTrimWhitespace", .{ .bool = !diff.widget.options.ignore_trim_whitespace }, .USER);
    }

    fn refreshDiff(context: *anyopaque) !void {
        const self: *DiffEditorCommandsService = @ptrCast(@alignCast(context));
        const tab = self.editor_service.activeEditorPane() orelse return;
        const diff = tab.diff orelse return;
        try self.snapshot_provider.refresh(self.snapshot_provider.context, diff.model.modified_path, diff.model.original_label, diff.model.modified_label);
    }
};
