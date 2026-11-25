// Port of the portable layout state exercised by
// `src/vs/workbench/test/browser/layout.test.ts`.
//
// The browser tests drive the real Grid and DOM sash endpoints. The terminal
// port tests the part-visibility/size state that the terminal workbench uses
// instead; grid composition stays in `src/vs/workbench/browser/workbench.zig`.

const std = @import("std");
const layout_mod = @import("../../browser/layout.zig");
const LayoutModel = layout_mod.Layout;
const Parts = layout_mod.Parts;
const Position = layout_mod.Position;

test "LayoutModel: defaults and part visibility" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    try std.testing.expect(layout.isVisible(.titlebar));
    try std.testing.expect(layout.isVisible(.activitybar));
    try std.testing.expect(layout.isVisible(.sidebar));
    try std.testing.expect(layout.isVisible(.editor));
    try std.testing.expect(layout.isVisible(.statusbar));
    try std.testing.expectEqual(Position.left, layout.sidebarPosition());

    try layout.setPartHidden(true, .sidebar);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setPartHidden(true, .sidebar);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setPartHidden(false, .sidebar);
    try std.testing.expect(layout.isVisible(.sidebar));
}

test "LayoutModel: sizes and sidebar position fire changes" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    var changes: usize = 0;
    try layout.on_did_change.event(&changes, struct {
        fn callback(_: void, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 28), layout.size(.sidebar));
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSidebarPosition(.right);
    try std.testing.expectEqual(Position.right, layout.sidebarPosition());
    try std.testing.expectEqual(@as(usize, 2), changes);
}

test "LayoutModel: zen mode and centered layout state fire their events" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    var zen_changes: usize = 0;
    try layout.on_did_change_zen_mode.event(&zen_changes, struct {
        fn callback(_: bool, context: *usize) !void {
            context.* += 1;
        }
    }.callback);
    var centered_changes: usize = 0;
    try layout.on_did_change_main_editor_centered.event(&centered_changes, struct {
        fn callback(_: bool, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try std.testing.expect(!layout.isZenModeActive());
    layout.setZenModeActive(true);
    try layout.fireZenModeChanged();
    try std.testing.expect(layout.isZenModeActive());
    try std.testing.expectEqual(@as(usize, 1), zen_changes);
    layout.setZenModeActive(false);
    try layout.fireZenModeChanged();
    try std.testing.expectEqual(@as(usize, 2), zen_changes);

    try std.testing.expect(!layout.isMainEditorCentered());
    try std.testing.expect(!layout.isMainEditorCenteredEffective());
    try layout.centerMainEditorLayout(true, .{}, false);
    try std.testing.expect(layout.isMainEditorCentered());
    try std.testing.expect(layout.isMainEditorCenteredEffective());
    try std.testing.expectEqual(@as(usize, 1), centered_changes);
}

test "registered panel changes reach layout listeners in grid notification order" {
    const PanelPart = @import("../../browser/parts/panel/panelPart.zig").PanelPart;
    const service = @import("../../services/layout/browser/layoutService.zig");
    var layout = layout_mod.Layout.init(std.testing.allocator);
    defer layout.deinit();
    const api = layout.interface();
    var panel = PanelPart.init(std.testing.allocator);
    var panel_alive = true;
    defer if (panel_alive) panel.deinit();
    try panel.base.register(api);
    try layout.createWorkbenchLayout();
    try std.testing.expectEqual(&panel.base, try layout.getPart(.panel));
    const Trace = struct {
        layout: *layout_mod.Layout,
        events: [4]u8 = undefined,
        count: usize = 0,
        fn visibility(event: service.IPartVisibilityChangeEvent, self: *@This()) !void {
            try std.testing.expectEqual(Parts.panel, event.part_id);
            try std.testing.expectEqual(event.visible, self.layout.isVisible(.panel));
            self.events[self.count] = if (event.visible) 'V' else 'H';
            self.count += 1;
        }
        fn changed(_: void, self: *@This()) !void {
            self.events[self.count] = 'L';
            self.count += 1;
        }
    };
    var trace = Trace{ .layout = &layout };
    _ = try api.on_did_change_part_visibility.listen(&trace, Trace.visibility);
    _ = try layout.on_did_change.listen(&trace, Trace.changed);
    try api.setPartHidden(false, .panel);
    try api.setPartHidden(false, .panel);
    try panel.setVisible(false);
    try std.testing.expectEqualStrings("VLHL", trace.events[0..trace.count]);
    panel.deinit();
    panel_alive = false;
    try std.testing.expectError(error.UnknownPart, layout.getPart(.panel));
}
