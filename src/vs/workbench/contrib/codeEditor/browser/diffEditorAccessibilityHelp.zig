// Port of `src/vs/workbench/contrib/codeEditor/browser/diffEditorAccessibilityHelp.ts`.
const std = @import("std");
const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
const registry = @import("../../../../platform/accessibility/browser/accessibleViewRegistry.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const editors = @import("../../../services/editor/common/editorService.zig");
const code_editors = @import("../../../../editor/browser/services/codeEditorService.zig");
const diff_input = @import("../../../common/editor/diffEditorInput.zig");
const setting = @import("../../accessibility/browser/accessibilityConfiguration.zig").AccessibilityVerbositySettingId;
const in_diff = Expr{ .Equals = .{ .key = "isInDiffEditor", .value = .{ .boolean = true } } };

pub const DiffEditorAccessibilityHelp = struct {
    pub const registration: registry.IAccessibleViewImplementation = .{ .kind = .Help, .priority = 105, .name = "diff-editor", .when = &in_diff, .get_provider = getProvider };

    fn getProvider(allocator: std.mem.Allocator, accessor: ServicesAccessor) !?api.AccessibleContentProvider {
        const editor_service = try accessor.get(editors.editor_service_id);
        const active = editor_service.activeEditor() orelse return null;
        if (!std.mem.eql(u8, active.type_id, diff_input.ID)) return null;
        const service = try accessor.get(code_editors.code_editor_service_id);
        if (service.getActiveCodeEditor() == null and service.getFocusedCodeEditor() == null) return null;
        const diff = service.getFocusedDiffEditor() orelse return null;
        // Comment commands have no terminal provider yet; the rest of the
        // upstream content is rendered with resolved shortcut labels.
        const content =
            \\You are in a diff editor.
            \\View the next<keybinding:editor.action.accessibleDiffViewer.next> or previous<keybinding:editor.action.accessibleDiffViewer.prev> diff in diff review mode, which is optimized for screen readers.
            \\Run the command Diff Editor: Switch Side<keybinding:diffEditor.switchSide> to toggle between the original and modified editors.
            \\Use Diff View in the editor title area's More Actions menu to select inline, side-by-side, or automatic layout.
            \\In compact diff presentations, use Tab to focus a hidden-lines disclosure, then Enter or Space to expand or collapse unchanged lines. Breadcrumbs are separate buttons that reveal their symbol.
            \\The setting, accessibility.verbosity.diffEditorActive, controls if a diff editor announcement is made when it becomes the active editor.
            \\To control which accessibility signals should be played, the following settings can be configured: accessibility.signals.diffLineDeleted, accessibility.signals.diffLineInserted, accessibility.signals.diffLineModified.
        ;
        return .{
            .allocator = allocator,
            .id = .DiffEditor,
            .kind = .Help,
            .content = try allocator.dupe(u8, content),
            .verbosity_setting_key = setting.DiffEditor,
            .on_close = if (diff.focus_modified) |focus| .{ .context = diff.context, .run = focus } else null,
        };
    }
};
