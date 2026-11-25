// Port of the portable visibility/selection cases of
// `src/vs/workbench/test/browser/parts/editor/breadcrumbsControl.test.ts`.
//
// Browser-only cases (context-view pickers, DOM focus, editor-type dropdown,
// untitled inputs) are replaced by the terminal host callbacks and the quick
// pick; this file covers item construction and the control's visibility.

const std = @import("std");
const WorkspaceContextService = @import("../../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const control_mod = @import("../../../../browser/parts/editor/breadcrumbsControl.zig");
const BreadcrumbsControl = control_mod.BreadcrumbsControl;
const Host = control_mod.Host;
const Selection = control_mod.Selection;
const SelectMode = control_mod.SelectMode;
const OutlineEditor = @import("../../../../services/outline/browser/outline.zig").OutlineEditor;
const IOutline = @import("../../../../services/outline/browser/outline.zig").IOutline;
const file_icon = @import("../../../../services/themes/browser/fileIconThemeData.zig");

test "BreadcrumbsControl: labels and item kinds from a path model" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();

    const HostImpl = struct {
        var resource: []const u8 = "/repo/src/file.ts";
        fn activeResource(_: *anyopaque) ?[]const u8 {
            return resource;
        }
        fn activeLanguage(_: *anyopaque) []const u8 {
            return "typescript";
        }
        fn outlineEditor(_: *anyopaque) ?OutlineEditor {
            return null;
        }
        fn fileIcon(_: *anyopaque) ?file_icon.Icon {
            return file_icon.file("file.ts");
        }
        fn symbol(_: *anyopaque, _: ?u32) []const u8 {
            return "ƒ";
        }
        fn open(_: *anyopaque, _: Selection, _: SelectMode, _: control_mod.Anchor) !void {}
        fn reveal(_: *anyopaque, _: *IOutline, _: *anyopaque) !void {}
        fn render(_: *anyopaque) void {}
        fn focus(_: *anyopaque) void {}
    };
    var host_context: HostImpl = .{};
    const host = Host{
        .context = @ptrCast(&host_context),
        .active_resource = HostImpl.activeResource,
        .active_language = HostImpl.activeLanguage,
        .outline_editor = HostImpl.outlineEditor,
        .file_icon = HostImpl.fileIcon,
        .symbol_icon = HostImpl.symbol,
        .open_element = HostImpl.open,
        .reveal_element = HostImpl.reveal,
        .request_render = HostImpl.render,
        .focus_editor = HostImpl.focus,
    };
    const control = try BreadcrumbsControl.init(allocator, host, workspace, null, null, null);
    defer control.deinit();

    try std.testing.expect(control.isVisible());
    try std.testing.expectEqual(@as(usize, 2), control.widget.itemCount());
    try std.testing.expectEqualStrings("src", control.widget.items.items[0].label);
    try std.testing.expectEqualStrings("file.ts", control.widget.items.items[1].label);
    const file_icon_item = switch (control.widget.items.items[1].icon) {
        .glyph => |glyph| glyph,
        else => return error.TestUnexpectedResult,
    };
    const expected = file_icon.file("file.ts");
    try std.testing.expectEqual(expected.glyph, file_icon_item.codepoint);
    try std.testing.expectEqual(expected.color, file_icon_item.color);

    const Counter = struct {
        var selected: ?usize = null;
        var focus_changed: ?bool = null;
        fn select(index: usize, ctx: *@This()) !void {
            _ = ctx;
            selected = index;
        }
        fn focus(focused: bool, ctx: *@This()) !void {
            _ = ctx;
            focus_changed = focused;
        }
    };
    var counter: Counter = .{};
    _ = try control.widget.on_did_select_item.listen(&counter, Counter.select);
    _ = try control.widget.on_did_change_focus.listen(&counter, Counter.focus);
    _ = try control.selectIndex(0);
    try std.testing.expectEqual(@as(?usize, 0), Counter.selected);
    control.setFocused(true);
    try std.testing.expectEqual(@as(?bool, true), Counter.focus_changed);
}

test "BreadcrumbsControl: focus, selection and escape return focus to the editor" {
    const allocator = std.testing.allocator;
    const State = struct {
        var focused_editor: usize = 0;
        var opened: usize = 0;
        fn activeResource(_: *anyopaque) ?[]const u8 {
            return "/repo/src/file.ts";
        }
        fn activeLanguage(_: *anyopaque) []const u8 {
            return "typescript";
        }
        fn outlineEditor(_: *anyopaque) ?OutlineEditor {
            return null;
        }
        fn fileIcon(_: *anyopaque) ?file_icon.Icon {
            return file_icon.file("file.ts");
        }
        fn symbol(_: *anyopaque, _: ?u32) []const u8 {
            return "ƒ";
        }
        fn open(_: *anyopaque, _: Selection, _: SelectMode, _: control_mod.Anchor) !void {
            opened += 1;
        }
        fn reveal(_: *anyopaque, _: *IOutline, _: *anyopaque) !void {}
        fn render(_: *anyopaque) void {}
        fn focusEditor(_: *anyopaque) void {
            focused_editor += 1;
        }
    };
    var context: u8 = 0;
    var workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();
    const host = Host{
        .context = @ptrCast(&context),
        .active_resource = State.activeResource,
        .active_language = State.activeLanguage,
        .outline_editor = State.outlineEditor,
        .file_icon = State.fileIcon,
        .symbol_icon = State.symbol,
        .open_element = State.open,
        .reveal_element = State.reveal,
        .request_render = State.render,
        .focus_editor = State.focusEditor,
    };
    const control = try BreadcrumbsControl.init(allocator, host, workspace, null, null, null);
    defer control.deinit();

    try std.testing.expect(control.focusAndSelect());
    try std.testing.expect(control.isFocused());
    try std.testing.expectEqual(@as(usize, 1), control.widget.getFocused().?);
    try std.testing.expect(control.escapeFocus());
    try std.testing.expect(!control.isFocused());
    try std.testing.expectEqual(@as(usize, 1), State.focused_editor);
}
