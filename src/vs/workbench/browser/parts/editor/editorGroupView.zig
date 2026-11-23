// Port of the portable group-view behavior of
// `src/vs/workbench/browser/parts/editor/editorGroupView.ts`.
//
// The browser group view owns the DOM container, the title/tabs control, editor
// panes and lifecycle events. This port keeps the group's model-facing state:
// the ordered tab views for the model's editors, the active tab, the group's
// cell rectangle and the terminal tab-strip hit cache. The editor pane area is
// delegated to the ported `editorPanes.zig`.
//
// Terminal adaptation: the title control is the one-cell tab strip, and each
// tab owns a persistent editor view (the pane) instead of the browser reusing
// one pane per editor type. `Tab` is therefore a comptime parameter with two
// methods:
//
//   editorInput(self: *Tab) *EditorInput
//   layoutCells(self: *Tab, width: usize, height: usize) void
//
// Tab rendering and input handling live in `editorPane.zig`, and the
// tab-strip layout/paint in `multiEditorTabsControl.zig`; this file only
// decides which tab is associated with which model editor and how the group's
// views are laid out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const editorPanes = @import("editorPanes.zig");
const tab_bar = @import("multiEditorTabsControl.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_mod = @import("../../../common/editor.zig");

const EditorInput = editor_input.EditorInput;
const EditorsOrder = editor_mod.EditorsOrder;

/// Hit rectangle of one visible tab in the terminal tab strip. The browser
/// derives the same information from DOM tab elements.
pub const TabHit = struct {
    start: usize,
    end: usize,
    index: usize,
    /// The close/dirty cell, when the tab paints one.
    close_start: ?usize = null,
    close_end: ?usize = null,
};

/// One cell row is the terminal title control.
pub const title_height: usize = 1;
/// One cell row is the terminal breadcrumb bar (upstream `BreadcrumbsControl.HEIGHT`).
pub const breadcrumbs_height: usize = 1;

pub fn EditorGroupView(comptime View: type) type {
    comptime {
        if (@typeInfo(View) != .pointer) @compileError("Tab must be a pointer type");
    }

    return struct {
        const Self = @This();

        allocator: Allocator,
        group: *editor_groups.EditorGroup,
        tabs: std.array_list.Managed(View),
        hits: std.array_list.Managed(TabHit),
        title_action_hit: ?tab_bar.TitleActionHit = null,
        rect: ui.Rect = .{},
        /// The workbench reserves a breadcrumb row when `breadcrumbs.enabled`.
        breadcrumbs_visible: bool = false,
        breadcrumbs_suppressed: bool = false,
        /// `workbench.editor.showTabs`: none/single can hide the title row.
        tabs_visible: bool = true,
        panes: editorPanes.EditorPanes(View) = .{},

        pub fn init(allocator: Allocator, group: *editor_groups.EditorGroup) Self {
            return .{
                .allocator = allocator,
                .group = group,
                .tabs = std.array_list.Managed(View).init(allocator),
                .hits = std.array_list.Managed(TabHit).init(allocator),
            };
        }

        /// Disposes the tab views, like upstream `EditorGroupView.dispose()`
        /// disposing the group's editors, then frees the registries.
        pub fn deinit(self: *Self) void {
            for (self.tabs.items) |tab| tab.deinit();
            self.panes.clearActive();
            self.hits.deinit();
            self.tabs.deinit();
        }

        pub fn count(self: *const Self) usize {
            return self.tabs.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.tabs.items.len == 0;
        }

        /// Upstream `get activeEditor`.
        pub fn activeEditor(self: *const Self) ?*EditorInput {
            return self.group.model.activeEditor();
        }

        /// Upstream `get activeEditorPane`, adapted to the tab's persistent view.
        pub fn activeTab(self: *const Self) ?View {
            const active = self.activeEditor() orelse return null;
            return self.tabForInput(active);
        }

        pub fn tabForInput(self: *const Self, input: *EditorInput) ?View {
            for (self.tabs.items) |tab| {
                if (tab.editorInput() == input) return tab;
            }
            return null;
        }

        pub fn indexOfTab(self: *const Self, tab: View) ?usize {
            for (self.tabs.items, 0..) |candidate, index| {
                if (candidate == tab) return index;
            }
            return null;
        }

        /// Upstream `getEditors(EditorsOrder.SEQUENTIAL)` projected onto the
        /// tab views.
        pub fn orderedTabs(
            self: *const Self,
            allocator: Allocator,
            out: *std.array_list.Managed(View),
        ) !void {
            const editors = try self.group.model.getEditors(allocator, .SEQUENTIAL, false);
            defer allocator.free(editors);
            for (editors) |input| {
                if (self.tabForInput(input)) |tab| try out.append(tab);
            }
        }

        /// Index of the active tab in `ordered`.
        pub fn activeIndex(self: *const Self, ordered: []const View) usize {
            const active = self.activeEditor() orelse return 0;
            for (ordered, 0..) |tab, index| {
                if (tab.editorInput() == active) return index;
            }
            return 0;
        }

        /// The tab at model order `index`.
        pub fn tabAtIndex(self: *const Self, allocator: Allocator, index: usize) ?View {
            var ordered = std.array_list.Managed(View).init(allocator);
            defer ordered.deinit();
            self.orderedTabs(allocator, &ordered) catch return null;
            if (index >= ordered.items.len) return null;
            return ordered.items[index];
        }

        /// Registers the view for an input that is already in the group model.
        /// A new active editor becomes the visible pane right away.
        pub fn addTab(self: *Self, tab: View) !void {
            try self.tabs.append(tab);
            if (self.group.model.isActive(.{ .input = tab.editorInput() })) {
                self.panes.setActive(tab);
            }
        }

        /// Unregisters and returns the view for `tab`; the caller owns it.
        pub fn removeTab(self: *Self, tab: View) ?View {
            const index = self.indexOfTab(tab) orelse return null;
            if (self.panes.activePane() == tab) self.panes.clearActive();
            return self.tabs.orderedRemove(index);
        }

        /// Upstream `setActive` plus switching the visible editor pane.
        pub fn activateTab(self: *Self, tab: View) !void {
            _ = try self.group.model.setActive(tab.editorInput());
            self.panes.setActive(tab);
        }

        /// Mirrors the model change after a close/move: the active pane follows
        /// the model's new active editor, or is cleared when the group empties.
        pub fn syncActivePane(self: *Self) void {
            self.panes.setActive(self.activeTab());
        }

        pub fn closeEditor(self: *Self, input: *EditorInput) void {
            self.panes.closeEditor(input);
        }

        /// Upstream `layout(pagePosition)`: assign the group rectangle and lay
        /// out the title control, the breadcrumb bar and the visible editor
        /// pane. Panes activated later re-use this position.
        pub fn layout(self: *Self) void {
            const width = @max(ui.cell.snap(self.rect.w), 1);
            const height = @max(ui.cell.snap(self.rect.h) -| self.chromeHeight(), 1);
            self.panes.layout(.{ .width = width, .height = height });
        }

        /// Rows owned by the title control above the editor content.
        pub fn titleHeight(self: *const Self) usize {
            return if (self.tabs_visible) title_height else 0;
        }

        pub fn chromeHeight(self: *const Self) usize {
            return self.titleHeight() + if (self.breadcrumbsVisible()) breadcrumbs_height else 0;
        }

        pub fn breadcrumbsVisible(self: *const Self) bool {
            return self.breadcrumbs_visible and !self.breadcrumbs_suppressed;
        }

        pub fn setTabsVisible(self: *Self, visible: bool) void {
            self.tabs_visible = visible;
        }

        pub fn setBreadcrumbsVisible(self: *Self, visible: bool) void {
            self.breadcrumbs_visible = visible;
        }
    };
}

const TestInput = struct {
    base: EditorInput,
    id: []const u8,

    fn create(allocator: Allocator, id: []const u8) !*TestInput {
        const input = try allocator.create(TestInput);
        input.* = .{
            .base = EditorInput.init(allocator, "test.editorInput"),
            .id = id,
        };
        input.base.impl = input;
        input.base.matches_fn = matches;
        return input;
    }

    fn deinit(self: *TestInput) void {
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *TestInput = @ptrCast(@alignCast(base.impl.?));
        const other_input: *TestInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, "test.editorInput", other.type_id) and
            std.mem.eql(u8, self.id, other_input.id);
    }
};

const TestTab = struct {
    input: *TestInput,
    layouts: usize = 0,
    width: usize = 0,
    height: usize = 0,

    pub fn editorInput(self: *TestTab) *EditorInput {
        return &self.input.base;
    }

    pub fn layoutCells(self: *TestTab, width: usize, height: usize) void {
        self.layouts += 1;
        self.width = width;
        self.height = height;
    }

    pub fn deinit(self: *TestTab) void {
        _ = self;
    }
};

fn testGroup(allocator: Allocator) !*editor_groups.EditorGroupsService {
    return editor_groups.EditorGroupsService.init(allocator, .{});
}

test "EditorGroupView: registers tabs in model order and tracks the active tab" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const first = try TestInput.create(allocator, "first");
    defer first.deinit();
    const second = try TestInput.create(allocator, "second");
    defer second.deinit();
    // The model unlistens from its inputs, so dispose it before the inputs.
    defer service.deinit();

    var first_tab = TestTab{ .input = first };
    var second_tab = TestTab{ .input = second };
    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&first.base, .{ .pinned = true, .active = true });
    try view.addTab(&first_tab);
    _ = try group.model.openEditor(&second.base, .{ .pinned = true, .active = false });
    try view.addTab(&second_tab);

    try std.testing.expectEqual(@as(usize, 2), view.count());
    try std.testing.expectEqual(&first_tab, view.activeTab().?);

    var ordered = std.array_list.Managed(*TestTab).init(allocator);
    defer ordered.deinit();
    try view.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expectEqual(&first_tab, ordered.items[0]);
    try std.testing.expectEqual(&second_tab, ordered.items[1]);
    try std.testing.expectEqual(@as(usize, 0), view.activeIndex(ordered.items));
    try std.testing.expectEqual(&second_tab, view.tabAtIndex(allocator, 1).?);
}

test "EditorGroupView: activation switches the visible pane and lays it out" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const input = try TestInput.create(allocator, "only");
    defer input.deinit();
    // The model unlistens from its inputs, so dispose it before the input.
    defer service.deinit();
    var tab = TestTab{ .input = input };
    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&input.base, .{ .pinned = true, .active = true });
    view.rect = .{ .x = 0, .y = 0, .w = 40, .h = 10 };
    view.layout();
    try view.addTab(&tab);

    // addTab lays out the pane once for the new active editor at the recorded
    // page position.
    try std.testing.expectEqual(@as(usize, 1), tab.layouts);
    try std.testing.expectEqual(@as(usize, 40), tab.width);
    try std.testing.expectEqual(@as(usize, 9), tab.height);

    view.layout();
    try std.testing.expectEqual(@as(usize, 2), tab.layouts);

    _ = try view.activateTab(&tab);
    try std.testing.expectEqual(@as(usize, 3), tab.layouts);
    try std.testing.expectEqual(&tab, view.panes.activePane().?);
}

test "EditorGroupView: removing the active tab clears the pane and sync follows the model" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const first = try TestInput.create(allocator, "first");
    defer first.deinit();
    const second = try TestInput.create(allocator, "second");
    defer second.deinit();
    // The model unlistens from its inputs, so dispose it before the inputs.
    defer service.deinit();
    var first_tab = TestTab{ .input = first };
    var second_tab = TestTab{ .input = second };

    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&first.base, .{ .pinned = true, .active = true });
    try view.addTab(&first_tab);
    _ = try group.model.openEditor(&second.base, .{ .pinned = true, .active = false });
    try view.addTab(&second_tab);
    try view.activateTab(&second_tab);
    try std.testing.expectEqual(&second_tab, view.panes.activePane().?);

    _ = try group.model.closeEditor(&second.base, .UNKNOWN, true);
    try std.testing.expectEqual(&second_tab, view.removeTab(&second_tab).?);
    try std.testing.expect(view.panes.activePane() == null);

    view.syncActivePane();
    try std.testing.expectEqual(&first_tab, view.panes.activePane().?);
}
