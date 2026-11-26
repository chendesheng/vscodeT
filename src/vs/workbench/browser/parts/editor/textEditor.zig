// Port of the portable editor configuration and `TextEditorPaneSelection` portions of
// `src/vs/workbench/browser/parts/editor/textEditor.ts`.
const std = @import("std");
const editor = @import("../../../common/editor.zig");
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;

/// Upstream's `TEXT_EDITOR_SELECTION_THRESHOLD`.
const selection_threshold = 10;

pub const TextEditorPaneSelection = struct {
    allocator: std.mem.Allocator,
    selection: Selection,
    log_buf: [128]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, selection: Selection) TextEditorPaneSelection {
        return .{ .allocator = allocator, .selection = selection };
    }

    pub fn create(allocator: std.mem.Allocator, selection: Selection) !*TextEditorPaneSelection {
        const self = try allocator.create(TextEditorPaneSelection);
        self.* = init(allocator, selection);
        return self;
    }

    fn dispose(context: *anyopaque) void {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    pub fn interface(self: *TextEditorPaneSelection) editor.IEditorPaneSelection {
        return .{
            .context = self,
            .kind = "text",
            .compare_fn = compare,
            .restore_fn = restore,
            .log_fn = log,
            .dispose_fn = dispose,
        };
    }

    fn compare(context: *anyopaque, other: *const editor.IEditorPaneSelection) editor.EditorPaneSelectionCompareResult {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, other.kind, "text")) return .DIFFERENT;
        const other_text: *const TextEditorPaneSelection = @ptrCast(@alignCast(other.context));
        const this_line = @min(self.selection.selectionStartLineNumber, self.selection.positionLineNumber);
        const other_line = @min(other_text.selection.selectionStartLineNumber, other_text.selection.positionLineNumber);
        if (this_line == other_line) return .IDENTICAL;
        const distance = if (this_line > other_line) this_line - other_line else other_line - this_line;
        if (distance < selection_threshold) return .SIMILAR;
        return .DIFFERENT;
    }

    fn restore(context: *anyopaque, options: editor.EditorOptions) editor.EditorOptions {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        var restored = options;
        restored.selection = self.selection;
        restored.center_selection_if_outside_viewport = true;
        return restored;
    }

    fn log(context: *anyopaque) []const u8 {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        return std.fmt.bufPrint(&self.log_buf, "line: {d}-{d}, col: {d}-{d}", .{
            self.selection.startLineNumber,
            self.selection.endLineNumber,
            self.selection.startColumn,
            self.selection.endColumn,
        }) catch "";
    }
};

test "TextEditorPaneSelection compares by line proximity" {
    var a = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(1, 1, 2, 2));
    var a_interface = a.interface();
    var b = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(1, 5, 3, 2));
    const b_interface = b.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.IDENTICAL, a_interface.compare(&b_interface));

    var c = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(5, 1, 6, 2));
    const c_interface = c.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.SIMILAR, a_interface.compare(&c_interface));

    var d = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(50, 1, 60, 2));
    const d_interface = d.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.DIFFERENT, a_interface.compare(&d_interface));

    const restored = a_interface.restore(.{});
    try std.testing.expect(restored.center_selection_if_outside_viewport);
    try std.testing.expect(restored.selection != null);
}

const Tab = @import("editorPane.zig").Tab;
const GroupPane = @import("editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("editorPart.zig").EditorPart(GroupPane);
const ConfigurationServiceBinding = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationServiceBinding;
const config = @import("../../../../platform/configuration/common/configuration.zig");
const terminal_config = @import("../../../../editor/browser/config/terminalEditorConfiguration.zig");
const RenderLineNumbersType = @import("../../../../editor/common/config/editorOptions.zig").RenderLineNumbersType;
const ThemeColors = @import("../../themeColors.zig").ThemeColors;
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;

/// TextEditor configuration listener. The terminal keeps a mounted control
/// for every tab, so the collection applies the resource/language-aware
/// options to those controls directly rather than deferring hidden DOM panes.
/// Zen Mode is a temporary override delivered by Layout, never a setting
/// written back to IConfigurationService.
pub const TextEditorConfiguration = struct {
    part: *EditorPart,
    configuration: *ConfigurationServiceBinding,
    theme: *const ?*ThemeColors,
    listener: ?SignalSubscription = null,
    zen_hide_line_numbers: bool = false,

    pub fn attach(self: *TextEditorConfiguration) !void {
        self.listener = try self.configuration.on_did_change_configuration.listenDisposable(self, onConfigurationChanged);
    }

    pub fn deinit(self: *TextEditorConfiguration) void {
        if (self.listener) |listener| listener.dispose();
        self.listener = null;
    }

    fn onConfigurationChanged(change: config.Change, self: *TextEditorConfiguration) !void {
        if (self.configuration.service == null) return;
        if (config.affectsConfiguration(change, "editor") or config.affectsConfiguration(change, "diffEditor") or
            (change.source == .DEFAULT and change.keys.len == 0))
            self.applyToAllTabs();
    }

    fn readSetting(context: *anyopaque, key: []const u8, language_id: ?[]const u8, resource: ?[]const u8) ?*const config.Value {
        const self: *TextEditorConfiguration = @ptrCast(@alignCast(context));
        const service = self.configuration.service orelse return null;
        return service.getValue(key, .{ .override_identifier = language_id, .resource = resource });
    }

    fn reader(self: *TextEditorConfiguration) terminal_config.Reader {
        return .{ .context = self, .get_value = readSetting };
    }

    pub fn applyToTab(self: *TextEditorConfiguration, tab: *Tab) void {
        if (tab.diff) |diff| {
            if (self.configuration.service) |service| {
                const options = @import("textDiffEditor.zig").computeConfiguration(service.interface());
                if (diff.updateOptions(options) catch false) tab.syncDiffViews();
            }
            const settings = self.reader();
            for ([_]*@import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor{ diff.widget.original_editor, diff.widget.modified_editor }, [_]@TypeOf(tab.view){ diff.widget.original_view, diff.widget.modified_view }) |control, view| {
                _ = control.applyEditorSettings(settings, control.languageId(), control.path) catch false;
                _ = view.applyEditorSettings(settings, control.languageId(), control.path) catch false;
                control.setLineDecorationsWidth(if (diff.widget.options.render_indicators) 1 else 0);
            }
            if (self.zen_hide_line_numbers) applyLineNumbers(tab, .Off);
            tab.setThemeColors(self.theme.*);
            return;
        }
        const settings = self.reader();
        const language_id = tab.editor.languageId();
        const resource = tab.editor.path;
        _ = tab.editor.applyEditorSettings(settings, language_id, resource) catch false;
        _ = tab.view.applyEditorSettings(settings, language_id, resource) catch false;
        if (tab.search_editor_input) |input| {
            if (self.configuration.service) |service| input.search_editor.configure(service);
            tab.view.applyLineNumbersOverride(.Off) catch {};
        } else if (self.zen_hide_line_numbers and !tab.isImage()) {
            tab.view.applyLineNumbersOverride(.Off) catch {};
        }
        if (self.theme.*) |palette| {
            tab.view.setThemeColors(palette);
            if (tab.image_preview) |pane| pane.setThemeColors(palette);
        }
    }

    fn applyToAllTabs(self: *TextEditorConfiguration) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| self.applyToTab(tab);
        }
    }

    pub fn setZenLineNumbers(self: *TextEditorConfiguration, hidden: bool) void {
        self.zen_hide_line_numbers = hidden;
        self.applyToAllTabs();
        if (hidden) return;
        // Restore the configured value (or the upstream default) even when
        // the key was absent. Search result editors keep their own override.
        const settings = self.reader();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.isImage()) continue;
                const value = if (tab.search_editor_input != null) .Off else terminal_config.lineNumbersSetting(settings, tab.editor.languageId(), tab.editor.path) orelse .On;
                applyLineNumbers(tab, value);
            }
        }
    }

    fn applyLineNumbers(tab: *Tab, value: RenderLineNumbersType) void {
        if (tab.diff) |diff| {
            diff.widget.original_view.applyLineNumbersOverride(value) catch {};
            diff.widget.modified_view.applyLineNumbersOverride(value) catch {};
        } else if (!tab.isImage()) {
            tab.view.applyLineNumbersOverride(value) catch {};
        }
    }
};
