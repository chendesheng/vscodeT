// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorAccessibilityHelp.ts`.
// The standard workbench editor toolbar and command palette are available in
// the terminal. The separate browser Agents window and its header are not.
const std = @import("std");
const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
const registry = @import("../../../../platform/accessibility/browser/accessibleViewRegistry.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const editors = @import("../../../services/editor/common/editorService.zig");
const setting = @import("../../accessibility/browser/accessibilityConfiguration.zig").AccessibilityVerbositySettingId;

const focused: Expr = .{ .Defined = "multiDiffEditorFileListFocus" };

pub const MultiDiffEditorFileListAccessibilityHelp = struct {
    pub const registration: registry.IAccessibleViewImplementation = .{
        .kind = .Help,
        .priority = 105,
        .name = "multi-diff-editor-file-list",
        .when = &focused,
        .get_provider = getProvider,
    };

    fn getProvider(allocator: std.mem.Allocator, accessor: ServicesAccessor) !?api.AccessibleContentProvider {
        const service = try accessor.get(editors.editor_service_id);
        const pane = service.activeEditorPane() orelse return null;
        const host = pane.multi_diff_file_list_host orelse return null;
        const content =
            \\You are in the changed files list of a multi diff editor.
            \\Use the Up and Down Arrow keys to navigate files. In tree mode, use the Left and Right Arrow keys to collapse or expand folders.
            \\Press Enter to reveal the selected file and move focus to its diff.
            \\Use Toggle Files in the editor toolbar or Command Palette to show or hide the changed files. The Files View & Position submenu in the editor toolbar's More Actions menu switches between a list and a folder tree, and moves the files to the left or right of the diffs.
        ;
        return .{
            .allocator = allocator,
            .id = .MultiDiffEditorFileList,
            .kind = .Help,
            .content = try allocator.dupe(u8, content),
            .verbosity_setting_key = setting.MultiDiffEditorFileList,
            .on_close = if (host.restore_focus_file_list) |restore| .{ .context = host.context, .run = restore } else null,
        };
    }
};
