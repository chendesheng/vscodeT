// Port of the prompt/confirmation view boundary in
// src/vs/workbench/browser/parts/dialogs/dialogHandler.ts. The terminal
// replaces DOM/CSS, Markdown detail, checkboxes and input elements with the
// current ui.Dialog cell widget.
const std = @import("std");
const ui = @import("ui");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const ThemeColors = @import("../../themeColors.zig").ThemeColors;

pub const BrowserDialogHandler = struct {
    theme: ui.DialogTheme = .{},

    pub fn show(self: *const BrowserDialogHandler, allocator: std.mem.Allocator, args: dialogs.DialogPrompt) !*ui.Dialog {
        const dialog = try ui.Dialog.init(allocator, args.message, args.detail, args.buttons);
        dialog.theme = self.theme;
        dialog.severity = switch (args.severity) {
            .Warning => .warning,
            .Error => .err,
            else => .info,
        };
        dialog.focused = @min(args.initial_focus, args.buttons.len - 1);
        return dialog;
    }

    pub fn setThemeColors(self: *BrowserDialogHandler, palette: ?*const ThemeColors) void {
        self.theme = .{};
        if (palette) |colors| {
            self.theme = .{
                .background = colors.colorOr("dialog.background", self.theme.background),
                .border = colors.colorOr("dialog.border", self.theme.border),
                .text = colors.colorOr("foreground", self.theme.text),
                .detail = colors.colorOr("descriptionForeground", self.theme.detail),
                .warning = colors.colorOr("editorWarning.foreground", self.theme.warning),
                .information = colors.colorOr("editorInfo.foreground", self.theme.information),
                .err = colors.colorOr("editorError.foreground", self.theme.err),
                .primary_background = colors.colorOr("button.background", self.theme.primary_background),
                .primary_focused_background = colors.colorOr("button.hoverBackground", self.theme.primary_focused_background),
                .primary_foreground = colors.colorOr("button.foreground", self.theme.primary_foreground),
                .secondary_background = colors.colorOr("button.secondaryBackground", self.theme.secondary_background),
                .secondary_focused_background = colors.colorOr("button.secondaryHoverBackground", self.theme.secondary_focused_background),
                .secondary_foreground = colors.colorOr("button.secondaryForeground", self.theme.secondary_foreground),
            };
        }
    }
};
