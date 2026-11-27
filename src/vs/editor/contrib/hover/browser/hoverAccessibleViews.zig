// Port of `src/vs/editor/contrib/hover/browser/hoverAccessibleViews.ts`.
// The accessible editor is a read-only retained terminal view. The provider
// listens to real hover content and model-detachment events; accessibility
// tree announcements and generic browser extension context-view HTML do not
// have a terminal equivalent.
const std = @import("std");
const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
const registry = @import("../../../../platform/accessibility/browser/accessibleViewRegistry.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const code_editors = @import("../../../browser/services/codeEditorService.zig");
const HoverController = @import("contentHoverController.zig").ContentHoverController;
const VerbosityAction = @import("../../../common/languages.zig").HoverVerbosityAction;
const ids = @import("hoverActionIds.zig");
const hover_focused = Expr{ .Defined = "hoverFocused" };
const hover_visible = Expr{ .Defined = "hoverVisible" };

pub const HoverAccessibleView = struct {
    pub const registration: registry.IAccessibleViewImplementation = .{ .kind = .View, .priority = 95, .name = "hover", .when = &hover_focused, .get_provider = getProvider };
    fn getProvider(allocator: std.mem.Allocator, accessor: ServicesAccessor) !?api.AccessibleContentProvider {
        return createProvider(allocator, accessor, .View);
    }
};

pub const HoverAccessibilityHelp = struct {
    pub const registration: registry.IAccessibleViewImplementation = .{ .kind = .Help, .priority = 100, .name = "hover", .when = &hover_visible, .get_provider = getProvider };
    fn getProvider(allocator: std.mem.Allocator, accessor: ServicesAccessor) !?api.AccessibleContentProvider {
        return createProvider(allocator, accessor, .Help);
    }
};

fn createProvider(allocator: std.mem.Allocator, accessor: ServicesAccessor, kind: api.AccessibleViewType) !?api.AccessibleContentProvider {
    const service = try accessor.get(code_editors.code_editor_service_id);
    // The terminal's active diff control projects the modified side. Ask for
    // the actual focused sub-editor first, including a focused original hover.
    const editor = service.getFocusedCodeEditor() orelse service.getActiveCodeEditor() orelse return null;
    const controller = editor.getInstantiatedContribution(HoverController) orelse return null;
    if (!controller.isVisible()) return null;
    const state = try allocator.create(BaseHoverAccessibleViewProvider);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator, .controller = controller, .focused_hover_part_index = controller.widget().focusedHoverPartIndex() };
    return .{
        .allocator = allocator,
        .id = .Hover,
        .kind = kind,
        .content = try allocator.dupe(u8, ""),
        .language = if (kind == .View) editor.model.getLanguageId() else null,
        .verbosity_setting_key = "accessibility.verbosity.hover",
        .on_close = .{ .context = state, .run = BaseHoverAccessibleViewProvider.restoreFocus },
        .live = state.interface(kind),
    };
}

const BaseHoverAccessibleViewProvider = struct {
    allocator: std.mem.Allocator,
    controller: ?*HoverController,
    focused_hover_part_index: isize,
    listener: ?api.ContentChangeListener = null,
    content_listener: ?usize = null,
    detach_listener: ?usize = null,

    fn interface(self: *BaseHoverAccessibleViewProvider, kind: api.AccessibleViewType) api.LiveProvider {
        return .{
            .context = self,
            .connect = connect,
            .provide_content = provideContent,
            .dispose = dispose,
            .action_count = if (kind == .View) 2 else 0,
            .get_action = getAction,
            .run_action = runAction,
            .custom_help = kind == .View,
        };
    }

    fn connect(context: *anyopaque, listener: api.ContentChangeListener) !void {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        const controller = self.controller orelse return error.HoverDetached;
        self.listener = listener;
        controller.should_keep_open_on_editor_mouse_move_or_leave = true;
        self.content_listener = try controller.on_hover_contents_changed.listen(self, onChanged);
        self.detach_listener = try controller.on_will_unbind.listen(self, onDetach);
    }

    fn onChanged(_: void, self: *BaseHoverAccessibleViewProvider) !void {
        if (self.listener) |listener| listener.changed(listener.context, true);
    }

    fn onDetach(_: void, self: *BaseHoverAccessibleViewProvider) !void {
        self.disconnect();
        self.controller = null;
        // The consumer may dispose this provider synchronously. No state is
        // accessed after delivering the final source-detached event.
        if (self.listener) |listener| listener.changed(listener.context, false);
    }

    fn disconnect(self: *BaseHoverAccessibleViewProvider) void {
        if (self.controller) |controller| {
            if (self.content_listener) |id| controller.on_hover_contents_changed.unlisten(id);
            if (self.detach_listener) |id| controller.on_will_unbind.unlisten(id);
            controller.should_keep_open_on_editor_mouse_move_or_leave = false;
        }
        self.content_listener = null;
        self.detach_listener = null;
    }

    fn restoreFocus(context: *anyopaque) void {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        const controller = self.controller orelse return;
        if (self.focused_hover_part_index == -1) controller.widget().focus() else controller.widget().focusHoverPartWithIndex(self.focused_hover_part_index);
    }

    fn provideContent(context: *anyopaque, allocator: std.mem.Allocator, kind: api.AccessibleViewType) ![]u8 {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        const controller = self.controller orelse return allocator.dupe(u8, "");
        const wrapper = controller.widget();
        const index = self.focused_hover_part_index;
        const value = if (index == -1) wrapper.getWidgetContent() else wrapper.getAccessibleWidgetContentAtIndex(index);
        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(allocator);
        if (kind == .Help and index != -1) {
            if (wrapper.doesHoverAtIndexSupportVerbosityAction(index, .Increase)) try content.appendSlice(allocator, "- The focused hover part verbosity level can be increased with the Increase Hover Verbosity command<keybinding:" ++ ids.INCREASE_HOVER_VERBOSITY_ACTION_ID ++ ">.\n");
            if (wrapper.doesHoverAtIndexSupportVerbosityAction(index, .Decrease)) try content.appendSlice(allocator, "- The focused hover part verbosity level can be decreased with the Decrease Hover Verbosity command<keybinding:" ++ ids.DECREASE_HOVER_VERBOSITY_ACTION_ID ++ ">.\n");
        }
        try content.appendSlice(allocator, value orelse "");
        return content.toOwnedSlice(allocator);
    }

    fn getAction(context: *anyopaque, index: usize) api.ProviderAction {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        const action: VerbosityAction = if (index == 0) .Increase else .Decrease;
        const enabled = if (self.controller) |controller| controller.widget().doesHoverAtIndexSupportVerbosityAction(self.focused_hover_part_index, action) else false;
        return if (action == .Increase)
            .{ .id = ids.INCREASE_HOVER_VERBOSITY_ACCESSIBLE_ACTION_ID, .label = ids.INCREASE_HOVER_VERBOSITY_ACTION_LABEL, .icon = '+', .enabled = enabled }
        else
            .{ .id = ids.DECREASE_HOVER_VERBOSITY_ACCESSIBLE_ACTION_ID, .label = ids.DECREASE_HOVER_VERBOSITY_ACTION_LABEL, .icon = '-', .enabled = enabled };
    }

    fn runAction(context: *anyopaque, index: usize) void {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        const controller = self.controller orelse return;
        if (!getAction(context, index).enabled) return;
        controller.widget().updateHoverVerbosityLevel(if (index == 0) .Increase else .Decrease, self.focused_hover_part_index, false);
    }

    fn dispose(context: *anyopaque) void {
        const self: *BaseHoverAccessibleViewProvider = @ptrCast(@alignCast(context));
        self.disconnect();
        self.allocator.destroy(self);
    }
};
