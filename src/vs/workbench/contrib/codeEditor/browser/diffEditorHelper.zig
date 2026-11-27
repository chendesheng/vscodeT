// Port of `src/vs/workbench/contrib/codeEditor/browser/diffEditorHelper.ts`.
// The diff widget publishes its upstream onDidUpdateDiff event. The helper
// owns the whitespace overlay and the notification prompt for this instance.
const std = @import("std");
const browser = @import("../../../../editor/browser/editorBrowser.zig");
const extensions = @import("../../../../editor/browser/editorExtensions.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const resource_config = @import("../../../../editor/common/services/textResourceConfiguration.zig");
const notification = @import("../../../../platform/notification/common/notification.zig");
const FloatingEditorClickWidget = @import("../../../browser/codeeditor.zig").FloatingEditorClickWidget;

pub const DiffEditorHelperContribution = struct {
    pub const id = "editor.contrib.diffEditorHelper";
    allocator: std.mem.Allocator,
    diff: browser.IDiffEditor,
    configuration: resource_config.ITextResourceConfigurationService,
    notifications: notification.INotificationService,
    widget: FloatingEditorClickWidget,
    listener: ?usize = null,
    prompt: ?notification.INotificationHandle = null,

    pub const registration: extensions.DiffEditorContributionRegistration = .{ .id = id, .create = create };

    fn create(allocator: std.mem.Allocator, diff: browser.IDiffEditor, accessor: instantiation.ServicesAccessor) !?extensions.DiffEditorContribution {
        if (diff.is_embedded) return null;
        const self = try allocator.create(DiffEditorHelperContribution);
        errdefer allocator.destroy(self);
        const configuration = try accessor.get(resource_config.text_resource_configuration_service_id);
        const notifications = try accessor.get(notification.notification_service_id);
        if (diff.set_accessibility_help_keybinding) |set| {
            const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
            if (accessor.get(api.accessible_view_service_id)) |accessible| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                try set(diff.context, try accessible.lookupKeybindingLabel(arena.allocator(), "editor.action.accessibilityHelp"));
            } else |_| {}
        }
        self.* = .{ .allocator = allocator, .diff = diff, .configuration = configuration.*, .notifications = notifications.*, .widget = .{ .floating = .{ .label = "Show Whitespace Differences", .context = self, .on_click = showWhitespace } } };
        const emitter = diff.on_did_update_diff orelse return error.DiffEventMissing;
        self.listener = try emitter.listen(self, onDidUpdateDiff);
        errdefer emitter.unlisten(self.listener.?);
        errdefer self.widget.dispose();
        try self.update();
        return .{ .id = id, .context = self, .dispose_fn = dispose };
    }

    fn dispose(context: *anyopaque) void {
        const self: *DiffEditorHelperContribution = @ptrCast(@alignCast(context));
        if (self.listener) |listener| self.diff.on_did_update_diff.?.unlisten(listener);
        self.widget.dispose();
        self.closePrompt();
        self.allocator.destroy(self);
    }

    fn onDidUpdateDiff(_: void, self: *DiffEditorHelperContribution) !void {
        try self.update();
    }

    fn update(self: *DiffEditorHelperContribution) !void {
        const result = self.diff.getDiffComputationResult();
        const control = self.diff.getModifiedControl() orelse return;
        if (result != null and !result.?.identical and result.?.changes2.len == 0) {
            try self.widget.render(control.overlays);
        } else self.widget.dispose();
        if (result != null and result.?.quit_early) {
            self.closePrompt();
            var buffer: [128]u8 = undefined;
            const message = try std.fmt.bufPrint(&buffer, "The diff algorithm was stopped early (after {d} ms.)", .{self.diff.maxComputationTime()});
            self.prompt = self.notifications.prompt(.Warning, .{ .text = message }, &.{.{ .label = "Remove Limit", .context = self, .run_fn = removeLimit }}, null);
        }
    }

    fn closePrompt(self: *DiffEditorHelperContribution) void {
        if (self.prompt) |prompt| {
            self.prompt = null;
            prompt.close();
            prompt.release();
        }
    }
    fn showWhitespace(context: *anyopaque) void {
        const self: *DiffEditorHelperContribution = @ptrCast(@alignCast(context));
        if (self.diff.getModifiedControl()) |control| self.configuration.updateValue(control.editor.model, "diffEditor.ignoreTrimWhitespace", .{ .bool = false }, null) catch |err| control.editor.setMessage("Configuration update failed: {s}", .{@errorName(err)});
    }
    fn removeLimit(context: *anyopaque) void {
        const self: *DiffEditorHelperContribution = @ptrCast(@alignCast(context));
        if (self.diff.getModifiedControl()) |control| self.configuration.updateValue(control.editor.model, "diffEditor.maxComputationTime", .{ .integer = 0 }, null) catch |err| control.editor.setMessage("Configuration update failed: {s}", .{@errorName(err)});
    }
};

/// Registered with the workbench's configuration migration registry alongside
/// the contribution, as in the upstream module.
pub const configuration_migrations = [_]@import("../../../common/configuration.zig").ConfigurationMigration{
    .{ .key = "diffEditor.experimental.collapseUnchangedRegions", .rename_to = "diffEditor.hideUnchangedRegions.enabled" },
};
