// Port of the portable group management and grid layout of
// `src/vs/workbench/browser/parts/editor/editorPart.ts`.
//
// The browser part owns the DOM grid widget, the group views and their sash
// controls. This port keeps the group registry, the oriented split tree from
// `src/vs/base/browser/ui/grid/grid.zig`, branch demotion when a group
// collapses, and the sash hit-test/resize math. Group rendering and tab
// interaction are adapted by the terminal host in `src/tui/workbench.zig`.
//
// `GroupView` is a comptime parameter with this contract:
//
//   group: *EditorGroup
//   rect: ui.Rect
//   init(allocator, group) GroupView
//   deinit() void
//   layout() void
//   on_did_focus: Emitter(*GroupView)
//
// The part owns the group views and destroys them in `deinit`; the TUI group
// view destroys its tab views there as well.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Emitter = @import("../../../../base/common/event.zig").Emitter;
const layout_service = @import("../../../services/layout/browser/layoutService.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const Part = @import("../../part.zig").Part;
const editor_panes = @import("editorPanes.zig");
const grid = @import("../../../../base/browser/ui/grid/grid.zig");
const sash_css = @import("../../../../base/browser/ui/sash/sash_css.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const editor_mod = @import("../../../common/editor.zig");

const GroupDirection = editor_groups.GroupDirection;
const Orientation = grid.Orientation;

/// Upstream's terminal-adapted minimum pane sizes. The browser uses pixel
/// minima on its grid views; cells are the terminal unit.
pub const min_pane_width = layout_service.widthInCells(editor_panes.default_min_dimensions.width);
pub const min_pane_height: usize = 3;

pub fn EditorPart(comptime GroupView: type) type {
    return struct {
        const Self = @This();
        const LayoutNode = grid.Node(*GroupView);
        const SerializableGrid = grid.SerializableGrid(*GroupView, editor_mod.GroupIdentifier);

        base: Part,
        when_restored: @import("../../../../base/common/async.zig").Barrier = .{},
        maximized_group: ?*GroupView = null,
        on_did_change_group_maximized: Emitter(bool),
        on_did_focus: Emitter(void),
        on_did_add_group: Emitter(*GroupView),
        on_did_remove_group: Emitter(*GroupView),
        on_did_move_group: Emitter(*GroupView),
        on_did_close_editor: Emitter(@import("../../../services/editor/common/editorService.zig").IEditorCloseEvent),
        visible: bool = true,
        part_options: struct { show_tabs: layout_service.EditorTabsMode = .multiple, breadcrumbs_enabled: bool = false } = .{},
        allocator: Allocator,
        service: *editor_groups.EditorGroupsService,
        group_views: std.array_list.Managed(*GroupView),
        root: *LayoutNode,
        grid_element: ?*ui.Node = null,
        /// Cell-border terminals draw dividers on cell edges. The glyph
        /// fallback needs a gutter cell.
        cell_borders: bool = false,
        cell_border_capabilities: ui.cell_border.Capabilities = .{},
        /// The split whose boundary is being dragged, if any.
        active_sash: ?*LayoutNode = null,
        /// Last viewport assigned by `layout`; sash resizes reuse it.
        viewport: ui.Rect = .{},
        window: ?*@import("../../../../base/common/windowDispatch.zig").Queue = null,
        title_host: ?@import("editorTitleControl.zig").Host = null,

        /// Creates the part and the group view for the service's first group.
        pub fn init(
            allocator: Allocator,
            service: *editor_groups.EditorGroupsService,
        ) !*Self {
            return initWithState(allocator, service, null);
        }

        pub fn initWithState(allocator: Allocator, service: *editor_groups.EditorGroupsService, saved: ?editor_groups.SerializedGrid) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .on_did_change_group_maximized = .init(allocator),
                .on_did_focus = .init(allocator),
                .on_did_add_group = .init(allocator),
                .on_did_remove_group = .init(allocator),
                .on_did_move_group = .init(allocator),
                .on_did_close_editor = .init(allocator),
                .base = Part.init(allocator, .editor, Self),
                .allocator = allocator,
                .service = service,
                .group_views = std.array_list.Managed(*GroupView).init(allocator),
                .root = undefined,
            };
            self.base.create_content_area = createContentArea;
            errdefer self.base.deinit();
            errdefer self.group_views.deinit();

            errdefer for (self.group_views.items) |view| {
                view.deinit();
                allocator.destroy(view);
            };
            for (service.groups.items) |group| _ = try self.createView(group);
            if (saved) |state| {
                var restore = GridDeserializer{ .part = self };
                defer restore.seen.deinit(allocator);
                self.root = try SerializableGrid.deserialize(allocator, state, &restore, GridDeserializer.fromJSON);
                errdefer grid.deinitRoot(*GroupView, allocator, self.root);
                if (restore.seen.count() != self.count()) return error.InvalidGrid;
            } else {
                self.root = try grid.initNode(*GroupView, allocator, self.group_views.items[0]);
                errdefer grid.deinitRoot(*GroupView, allocator, self.root);
                // Before serializedGrid, sessions stored only a group list.
                for (self.group_views.items[1..], 0..) |view, index| {
                    try grid.splitRoot(*GroupView, allocator, &self.root, self.group_views.items[index], .horizontal, view, false);
                }
            }
            return self;
        }

        fn createContentArea(base: *Part, parent: *ui.Node) !*ui.Node {
            const self: *Self = @fieldParentPtr("base", base);
            const css = @import("../../../../editor/browser/editorCss.zig");
            const container = try parent.document.createElement(.div);
            try container.addClass(css.editor_group.Class.grid_view_container);
            _ = try parent.appendChild(container);
            const grid_element = try parent.document.createElement(.div);
            try grid_element.addClass(css.gridview.Class.monaco_grid_view);
            _ = try container.appendChild(grid_element);
            self.grid_element = grid_element;
            return container;
        }

        pub fn setVisible(self: *Self, visible: bool) !void {
            if (self.visible == visible) return;
            self.visible = visible;
            try self.base.setVisible(visible);
        }

        pub fn restoreEditors(self: *Self, panes: anytype) !void {
            for (self.group_views.items) |group| try group.restoreEditors(panes);
            try self.when_restored.open(self.allocator);
        }

        /// The terminal destroys group models before tab inputs (their
        /// listeners refer to those inputs). Detach group-view listeners
        /// before the groups service releases the models.
        pub fn disposeGroupModelListeners(self: *Self) void {
            if (@hasDecl(GroupView, "disposeModelListeners")) {
                for (self.group_views.items) |view| view.disposeModelListeners();
            }
        }

        pub fn deinit(self: *Self) void {
            self.when_restored.deinit(self.allocator);
            self.on_did_change_group_maximized.deinit();
            self.on_did_focus.deinit();
            self.on_did_add_group.deinit();
            self.on_did_remove_group.deinit();
            self.on_did_move_group.deinit();
            self.on_did_close_editor.deinit();
            self.base.deinit();
            for (self.group_views.items) |view| {
                view.deinit();
                self.allocator.destroy(view);
            }
            self.group_views.deinit();
            grid.deinitRoot(*GroupView, self.allocator, self.root);
            self.allocator.destroy(self);
        }

        pub fn handleChangedPartOptions(self: *Self, config: ?*ConfigurationService, enforced: ?layout_service.EditorTabsMode) void {
            self.part_options.show_tabs = getTabsMode(config, enforced);
            self.part_options.breadcrumbs_enabled = @import("breadcrumbs.zig").Settings.load(config).enabled;
        }

        fn getTabsMode(config: ?*ConfigurationService, enforced: ?layout_service.EditorTabsMode) layout_service.EditorTabsMode {
            if (enforced) |mode| return mode;
            const service = config orelse return .multiple;
            const setting = service.getValue(layout_service.LayoutSettings.editor_tabs_mode, .{}) orelse return .multiple;
            return layout_service.editorTabsMode(setting.*, .multiple);
        }

        pub fn count(self: *const Self) usize {
            return self.group_views.items.len;
        }

        pub fn minimumWidth(self: *const Self, height: usize) usize {
            const width = self.root.minimumWidth(min_pane_width, @intFromBool(!self.cell_borders));
            // The glyph frame surrounds the grid only above its compact cutoff.
            return if (!self.cell_borders and width >= 24 and height >= 14) width + 2 else width;
        }

        /// Terminal adapter for EditorPart's DOM focus tracker. Invoke only
        /// for part focus, active-editor, or overlay focus events.
        pub fn setEditorFocus(self: *Self, focused: bool) void {
            const active = self.activeView();
            for (self.group_views.items) |pane| {
                const group_focused = focused and active == pane;
                if (!group_focused) {
                    if (pane.watermark) |*watermark| watermark.blur();
                }
                for (pane.tabs.items) |tab| {
                    const desired = group_focused and pane.activeTab() == tab and
                        tab.terminal_input == null and tab.markdown_preview == null and
                        (tab.search_editor_input == null or !tab.search_editor_input.?.search_editor.query_focused);
                    if (@hasDecl(@typeInfo(@TypeOf(tab)).pointer.child, "setEditorFocused")) tab.setEditorFocused(desired) else _ = tab.view.setFocused(desired);
                }
            }
        }

        pub fn activeView(self: *const Self) ?*GroupView {
            return self.viewForGroup(self.service.activeGroup());
        }

        pub fn interface(self: *Self) editor_groups.IEditorGroupsService {
            return .{ .context = self, .active_group = activeGroup, .find_group = findGroupView, .arrange_groups = arrangeGroupsContext, .add_group = addGroupContext, .activate_group = activateGroupContext, .move_group = moveGroupContext };
        }

        fn addGroupContext(context: *anyopaque, source: editor_mod.GroupIdentifier, direction: GroupDirection) !editor_groups.IEditorGroup {
            const self: *Self = @ptrCast(@alignCast(context));
            const group = self.service.getGroup(source) orelse return error.ViewNotFound;
            const view = self.viewForGroup(group) orelse return error.ViewNotFound;
            return (try self.addGroup(view, direction)).interface();
        }

        fn activateGroupContext(context: *anyopaque, id: editor_mod.GroupIdentifier) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const group = self.service.getGroup(id) orelse return;
            self.service.activateGroup(group);
        }

        fn moveGroupContext(context: *anyopaque, source: editor_mod.GroupIdentifier, target: editor_mod.GroupIdentifier, direction: GroupDirection) !editor_groups.IEditorGroup {
            const self: *Self = @ptrCast(@alignCast(context));
            const source_group = self.service.getGroup(source) orelse return error.ViewNotFound;
            const target_group = self.service.getGroup(target) orelse return error.ViewNotFound;
            const source_view = self.viewForGroup(source_group) orelse return error.ViewNotFound;
            const target_view = self.viewForGroup(target_group) orelse return error.ViewNotFound;
            self.setMaximizedGroup(null);
            self.active_sash = null;
            try self.moveGroupView(source_view, target_view, orientationForDirection(direction), direction == .LEFT or direction == .UP);
            return source_view.interface();
        }

        fn orientationForDirection(direction: GroupDirection) Orientation {
            return switch (direction) {
                .LEFT, .RIGHT => .horizontal,
                .UP, .DOWN => .vertical,
            };
        }

        /// Upstream addGroup: create the adjacent group in the shared grid.
        pub fn addGroup(self: *Self, source: *GroupView, direction: GroupDirection) !*GroupView {
            self.setMaximizedGroup(null);
            self.active_sash = null;
            return self.splitGroup(source, orientationForDirection(direction), direction == .LEFT or direction == .UP);
        }

        fn arrangeGroupsContext(context: *anyopaque, arrangement: editor_groups.GroupsArrangement) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.arrangeGroups(arrangement);
        }

        pub fn arrangeGroups(self: *Self, arrangement: editor_groups.GroupsArrangement) void {
            switch (arrangement) {
                .EVEN => {
                    if (self.count() < 2) return;
                    self.root.distributeViewSizes();
                    self.layout(self.viewport);
                },
                .MAXIMIZE => self.maximizeGroup(self.activeView() orelse return),
            }
        }

        fn activeGroup(context: *anyopaque) ?editor_groups.IEditorGroup {
            const self: *Self = @ptrCast(@alignCast(context));
            const view = self.activeView() orelse return null;
            return view.interface();
        }

        fn findGroupView(context: *anyopaque, scope: editor_groups.IFindGroupScope, source: editor_mod.GroupIdentifier, wrap: bool) !?editor_groups.IEditorGroup {
            const self: *Self = @ptrCast(@alignCast(context));
            const group = self.service.getGroup(source) orelse return error.ViewNotFound;
            const source_view = self.viewForGroup(group) orelse return error.ViewNotFound;
            const target = try self.findGroup(scope, source_view, wrap) orelse return null;
            return target.interface();
        }

        pub fn findGroup(self: *Self, scope: editor_groups.IFindGroupScope, source: *GroupView, wrap: bool) !?*GroupView {
            return switch (scope) {
                .direction => |direction| self.doFindGroupByDirection(direction, source, wrap),
                .location => |location| self.doFindGroupByLocation(location, source, wrap),
            };
        }

        fn doFindGroupByLocation(self: *Self, location: editor_groups.GroupLocation, source: *GroupView, wrap: bool) !?*GroupView {
            const groups = try self.orderedViews(self.allocator);
            defer self.allocator.free(groups);
            const index = std.mem.indexOfScalar(*GroupView, groups, source) orelse return error.ViewNotFound;
            return switch (location) {
                .first => groups[0],
                .last => groups[groups.len - 1],
                .next => if (index + 1 < groups.len) groups[index + 1] else if (wrap) groups[0] else null,
                .previous => if (index > 0) groups[index - 1] else if (wrap) groups[groups.len - 1] else null,
            };
        }

        fn doFindGroupByDirection(self: *Self, direction: GroupDirection, source: *GroupView, wrap: bool) !?*GroupView {
            const neighbours = try grid.getNeighborViews(*GroupView, self.allocator, self.root, source, switch (direction) {
                .UP => .up,
                .RIGHT => .right,
                .DOWN => .down,
                .LEFT => .left,
            }, wrap);
            defer self.allocator.free(neighbours);
            // Stable grid order breaks ties, as in the upstream stable MRU sort.
            var first: ?*GroupView = null;
            var best: isize = std.math.maxInt(isize);
            const recent = self.service.most_recent_active_groups.items;
            for (neighbours) |view| {
                const rank: isize = if (std.mem.indexOfScalar(*editor_groups.EditorGroup, recent, view.group)) |index| @intCast(index) else -1;
                if (rank < best) {
                    first = view;
                    best = rank;
                }
            }
            return first;
        }

        pub fn viewForGroup(self: *const Self, group: *editor_groups.EditorGroup) ?*GroupView {
            for (self.group_views.items) |view| {
                if (view.group == group) return view;
            }
            return null;
        }

        const GridDeserializer = struct {
            part: *Self,
            seen: std.AutoHashMapUnmanaged(editor_mod.GroupIdentifier, void) = .empty,

            fn fromJSON(context: *@This(), id: editor_mod.GroupIdentifier, maximized: bool) !*GroupView {
                const group = context.part.service.getGroup(id) orelse return error.InvalidGrid;
                const entry = try context.seen.getOrPut(context.part.allocator, id);
                if (entry.found_existing) return error.InvalidGrid;
                const view = context.part.viewForGroup(group) orelse return error.InvalidGrid;
                if (maximized) context.part.maximized_group = view;
                return view;
            }
        };

        fn groupToJSON(_: void, view: *GroupView) !editor_mod.GroupIdentifier {
            return view.group.id;
        }

        pub fn createState(self: *Self, allocator: Allocator, registry: *@import("../../../common/editor/editorFactory.zig").EditorFactoryRegistry) !editor_groups.SerializedEditorPart {
            var state = try self.service.serializePart(allocator, registry);
            errdefer state.deinit(allocator);
            state.serialized_grid = try SerializableGrid.serialize(allocator, self.root, self.maximized_group, {}, groupToJSON);
            return state;
        }

        /// Upstream `addGroup(location, direction)`: creates the group view and
        /// inserts it into the split tree beside `target`.
        pub fn splitGroup(
            self: *Self,
            target: *GroupView,
            direction: Orientation,
            new_first: bool,
        ) !*GroupView {
            const group_direction: GroupDirection = switch (direction) {
                .horizontal => if (new_first) .LEFT else .RIGHT,
                .vertical => if (new_first) .UP else .DOWN,
            };
            const group = try self.service.addGroup(target.group, group_direction);
            errdefer _ = self.service.removeGroup(group) catch {};

            const view = try self.createView(group);
            errdefer {
                _ = self.group_views.pop();
                view.deinit();
                self.allocator.destroy(view);
            }

            try grid.splitRoot(
                *GroupView,
                self.allocator,
                &self.root,
                target,
                direction,
                view,
                new_first,
            );
            self.on_did_add_group.fire(view) catch {};
            return view;
        }

        pub fn maximizeGroup(self: *Self, view: *GroupView) void {
            if (self.maximized_group == view) return;
            self.service.activateGroup(view.group);
            view.syncActivePane();
            self.setMaximizedGroup(view);
            self.layout(self.viewport);
        }

        pub fn restoreGroupSizes(self: *Self) void {
            if (self.maximized_group == null) return;
            self.setMaximizedGroup(null);
            self.layout(self.viewport);
        }

        pub fn toggleExpandGroup(self: *Self, view: *GroupView) void {
            if (self.maximized_group == view) self.restoreGroupSizes() else self.maximizeGroup(view);
        }

        pub fn setMaximizedGroup(self: *Self, view: ?*GroupView) void {
            const was_maximized = self.maximized_group != null;
            self.maximized_group = view;
            if (was_maximized != (view != null)) self.on_did_change_group_maximized.fire(view != null) catch {};
        }

        pub fn hasMoreThanOneColumn(self: *const Self) bool {
            return hasColumns(self.root);
        }

        fn hasColumns(node: *const LayoutNode) bool {
            return switch (node.kind) {
                .leaf => false,
                .split => |split| split.direction == .horizontal or hasColumns(split.first) or hasColumns(split.second),
            };
        }

        /// Upstream `removeGroup`: removes the view from the grid and the
        /// service, then disposes the view. The last group is kept.
        pub fn removeView(self: *Self, view: *GroupView) bool {
            if (self.group_views.items.len <= 1) return false;
            self.active_sash = null;
            if (!grid.removeRoot(*GroupView, self.allocator, &self.root, view)) return false;

            for (self.group_views.items, 0..) |candidate, index| {
                if (candidate == view) {
                    _ = self.group_views.orderedRemove(index);
                    break;
                }
            }
            // `removeGroup` unlistens the model from the group's inputs; run it
            // before the view (and its tabs) are disposed.
            if (self.maximized_group == view) self.setMaximizedGroup(null);
            self.on_did_remove_group.fire(view) catch {};
            self.service.on_did_visible_editors_change.fire({}) catch {};
            if (@hasDecl(GroupView, "disposeModelListeners")) view.disposeModelListeners();
            self.service.removeGroup(view.group) catch {};
            view.deinit();
            self.allocator.destroy(view);
            return true;
        }

        /// Collapses an empty group out of the grid, keeping the last group so
        /// the part always has a target for the next editor.
        pub fn collapseView(self: *Self, view: *GroupView) bool {
            if (view.group.model.count() != 0 or self.service.count() <= 1) return false;
            if (!self.removeView(view)) return false;
            self.layout(self.viewport);
            return true;
        }

        /// Terminal adapter for the native editor-pane lifecycle. The group
        /// operations themselves belong to EditorPart, while view disposal,
        /// PTY creation and input focus cross the window boundary.
        pub const TransferHost = struct {
            copy: GroupView.CopyEditorHost,
            move: GroupView.MoveEditorHost,
            invalidate_pane: *const fn (*anyopaque, *GroupView) void,
            clear_drag: *const fn (*anyopaque) void,
            layout: *const fn (*anyopaque) void,
            focus_editor: *const fn (*anyopaque) void,
        };

        fn focusGroupView(group: *GroupView) !void {
            if (group.activeTab()) |tab| try tab.ensureControllers();
            group.focus();
        }

        pub fn collapseGroup(self: *Self, pane: *GroupView, host: TransferHost) void {
            if (pane.group.model.count() != 0 or self.service.count() <= 1) return;
            host.invalidate_pane(host.copy.context, pane);
            if (self.maximized_group == pane) self.setMaximizedGroup(null);
            _ = self.collapseView(pane);
        }

        pub fn mergeGroup(self: *Self, source: *GroupView, target: *GroupView, host: TransferHost) !void {
            if (source == target) return;
            var ordered = std.array_list.Managed(*@import("editorPane.zig").Tab).init(self.allocator);
            defer ordered.deinit();
            try source.orderedTabs(self.allocator, &ordered);
            for (ordered.items) |tab| {
                _ = try source.moveEditor(target, tab, .{ .pinned = true, .active = true }, host.move);
            }
            self.service.activateGroup(target.group);
            target.syncActivePane();
            if (source.tabs.items.len == 0) self.collapseGroup(source, host);
            host.layout(host.copy.context);
            try focusGroupView(target);
        }

        /// EditorGroupView close: close the model, synchronize the mounted
        /// editor pane and publish the close event while its input is alive.
        /// A native callback releases the actual view and terminal resources.
        pub fn closeEditor(self: *Self, pane: *GroupView, tab: anytype, host: TransferHost) !void {
            try self.closeEditorWithContext(pane, tab, .UNKNOWN, host);
        }

        pub fn closeEditorWithContext(self: *Self, pane: *GroupView, tab: anytype, context: editor_mod.EditorCloseContext, host: TransferHost) !void {
            const pinned = pane.group.model.isPinned(.{ .editor = tab.input });
            const result = try pane.group.model.closeEditor(tab.input, context, true) orelse return;
            _ = pane.removeTab(tab);
            pane.syncActivePane();
            self.on_did_close_editor.fire(.{
                .editor = result.editor,
                .group_id = pane.group.id,
                .index = result.editor_index,
                .sticky = result.sticky,
                .pinned = pinned,
                .context = result.context,
            }) catch {};
            host.copy.discard(host.copy.context, tab);

            // A final empty group remains as the editor surface. Otherwise
            // close an empty group and activate the most recently used
            // nonempty group, before restoring its visible editor control.
            if (pane.tabs.items.len == 0) {
                const ordered = try self.service.getGroups(self.allocator, .MOST_RECENTLY_ACTIVE);
                defer self.allocator.free(ordered);
                for (ordered) |group| {
                    if (group == pane.group) continue;
                    const candidate = self.viewForGroup(group) orelse continue;
                    if (candidate.tabs.items.len == 0) continue;
                    if (self.maximized_group == pane) self.setMaximizedGroup(null);
                    self.service.activateGroup(group);
                    self.collapseGroup(pane, host);
                    break;
                }
            }
            if (self.activeView()) |view| if (view.activeTab()) |active| try active.ensureControllers();
        }

        pub fn destroyGroup(self: *Self, pane: *GroupView, host: TransferHost) void {
            host.invalidate_pane(host.copy.context, pane);
            while (pane.tabs.items.len > 0) {
                const tab = pane.tabs.items[0];
                _ = pane.group.model.closeEditor(tab.input, .UNKNOWN, true) catch {};
                _ = pane.removeTab(tab);
                host.copy.discard(host.copy.context, tab);
            }
            _ = self.removeView(pane);
        }

        pub fn copyGroup(self: *Self, source: *GroupView, direction: GroupDirection, host: TransferHost) !*GroupView {
            self.setMaximizedGroup(null);
            self.active_sash = null;
            host.layout(host.copy.context);
            for (source.tabs.items) |tab| {
                if (tab.diff != null) return error.SplitUnsupported;
            }
            const orientation: Orientation = switch (direction) {
                .LEFT, .RIGHT => .horizontal,
                .UP, .DOWN => .vertical,
            };
            const target = try self.splitGroup(source, orientation, direction == .LEFT or direction == .UP);
            errdefer self.destroyGroup(target, host);

            var ordered = std.array_list.Managed(*@import("editorPane.zig").Tab).init(self.allocator);
            defer ordered.deinit();
            try source.orderedTabs(self.allocator, &ordered);
            const active_index = source.activeIndex(ordered.items);
            var copies = std.array_list.Managed(*@import("editorPane.zig").Tab).init(self.allocator);
            defer copies.deinit();
            for (ordered.items) |tab| {
                try copies.append(try target.copyEditor(tab, .{ .pinned = true, .active = true }, host.copy));
            }
            if (copies.items.len > 0) {
                try target.activateTab(copies.items[@min(active_index, copies.items.len - 1)]);
            }
            try focusGroupView(target);
            return target;
        }

        pub fn mergeAllGroups(self: *Self, target: *GroupView, host: TransferHost) !void {
            for (self.group_views.items) |pane| {
                if (pane == target) continue;
                while (pane.tabs.items.len > 0) {
                    const tab = pane.tabs.items[0];
                    _ = try pane.group.model.closeEditor(tab.input, .MOVE, false);
                    _ = pane.removeTab(tab);
                    const opened = try target.group.model.openEditor(tab.input, .{ .pinned = true, .active = false });
                    if (!opened.is_new) {
                        // Target already shows this document (a split copy has a
                        // distinct input over the shared model); drop the moved view.
                        host.copy.discard(host.copy.context, tab);
                        continue;
                    }
                    try target.addTab(tab);
                }
                pane.syncActivePane();
            }
            var index: usize = 0;
            while (index < self.group_views.items.len) {
                const pane = self.group_views.items[index];
                if (pane == target or pane.tabs.items.len > 0) {
                    index += 1;
                    continue;
                }
                self.collapseGroup(pane, host);
            }
            target.syncActivePane();
            host.layout(host.copy.context);
            if (if (self.activeView()) |view| view.activeTab() else null) |tab| try tab.ensureControllers();
        }

        pub fn splitEditor(self: *Self, source: *GroupView, direction: GroupDirection, host: TransferHost) !void {
            self.active_sash = null;
            self.setMaximizedGroup(null);
            host.clear_drag(host.copy.context);
            const tab = source.activeTab() orelse return;

            const orientation: Orientation = switch (direction) {
                .LEFT, .RIGHT => .horizontal,
                .UP, .DOWN => .vertical,
            };
            const new_first = direction == .LEFT or direction == .UP;
            const new_pane = try self.splitGroup(source, orientation, new_first);
            var keep_view = false;
            defer {
                if (!keep_view) _ = self.removeView(new_pane);
            }

            const copied = try new_pane.copyEditor(tab, .{ .pinned = true, .active = true }, host.copy);
            keep_view = true;

            host.layout(host.copy.context);
            if (if (self.activeView()) |view| view.activeTab() else null) |active| {
                try active.ensureControllers();
                try active.refresh();
                active.focusEditor();
            }
            host.focus_editor(host.copy.context);
            _ = copied;
        }

        /// Update mounted editor panes after the native surface is sized.
        /// Only the visible group is laid out when the group is maximized.
        pub fn layoutEditorArea(self: *Self, surface: *ui.Surface, show_tips: bool, colors: @import("editorGroupWatermark.zig").Colors, shortcuts: @import("editorGroupView.zig").WatermarkShortcuts) !void {
            for (self.group_views.items) |pane| {
                const visible = self.maximized_group == null or self.maximized_group == pane;
                try pane.layoutEditorArea(self.grid_element.?, self.base.bounds.?, surface, visible, show_tips, colors, shortcuts);
            }
        }

        pub fn setCellBorders(self: *Self, enabled: bool) void {
            if (self.cell_borders == enabled) return;
            self.cell_borders = enabled;
            self.layout(self.viewport);
        }

        /// Assigns rectangles to every group view and lays out its title
        /// control and active editor pane.
        pub fn layout(self: *Self, rect: ui.Rect) void {
            self.viewport = rect;
            grid.layoutNode(*GroupView, self.root, self.contentRect(), self, gapCallback, min_pane_width);
            self.syncRects(self.root);
            for (self.group_views.items) |view| {
                if (@hasDecl(GroupView, "updatePartOptions")) view.updatePartOptions(self.part_options.show_tabs, self.part_options.breadcrumbs_enabled);
                view.layout();
            }
            if (self.maximized_group) |expanded| {
                expanded.rect = self.contentRect();
                expanded.layout();
            }
        }

        /// Groups in `GroupsOrder.GRID_APPEARANCE` order: depth-first over the
        /// binary split tree (first branch before second). The workbench uses
        /// this for first/last/next/previous group commands.
        pub fn orderedViews(self: *Self, allocator: Allocator) ![]*GroupView {
            var views = std.array_list.Managed(*GroupView).init(allocator);
            errdefer views.deinit();
            try collectOrdered(GroupView, self.root, &views);
            return views.toOwnedSlice();
        }

        /// Moves `source` beside `target` without destroying either view.
        /// Mirrors the terminal subset of `Grid.moveView`.
        pub fn moveGroupView(
            self: *Self,
            source: *GroupView,
            target: *GroupView,
            direction: Orientation,
            new_first: bool,
        ) !void {
            self.active_sash = null;
            try grid.moveRoot(*GroupView, self.allocator, &self.root, source, target, direction, new_first);
            self.layout(self.viewport);
            self.on_did_move_group.fire(source) catch {};
        }

        pub fn viewAt(self: *const Self, x: usize, y: usize) ?*GroupView {
            if (self.maximized_group) |view| {
                const rect = view.rect;
                if (x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right()) and y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom())) return view;
                return null;
            }
            for (self.group_views.items) |view| {
                const rect = view.rect;
                if (x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right()) and
                    y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom()))
                {
                    return view;
                }
            }
            return null;
        }

        /// The split boundary under a cell, if any. Cell-border terminals put
        /// the shared edge between two cells, so both adjacent columns/rows are
        /// in the hit zone.
        pub fn dividerAt(self: *const Self, x: usize, y: usize) ?*LayoutNode {
            return findDivider(self, self.root, x, y);
        }

        /// The resize pointer a split boundary asks for: horizontal splits put
        /// panes side by side, so their boundary is an east-west resize handle;
        /// vertical splits use the north-south shape.
        pub fn sashPointer(self: *const Self, node: *LayoutNode) ui.Pointer {
            _ = self;
            return switch (node.kind) {
                .split => |split| sash_css.pointer(if (split.direction == .horizontal) .vertical else .horizontal),
                .leaf => .default,
            };
        }

        /// Upstream EditorPart.getSize/setSize for the terminal binary grid.
        pub fn getSize(_: *const Self, group: *GroupView) layout_service.IViewSize {
            return .{ .width = ui.cell.snap(group.rect.w), .height = ui.cell.snap(group.rect.h) };
        }

        pub fn setSize(self: *Self, group: *GroupView, desired: layout_service.IViewSize) void {
            if (self.maximized_group != null) return;
            const before = self.getSize(group);
            self.resizeGroupDimension(group, .horizontal, @as(isize, @intCast(desired.width)) - @as(isize, @intCast(before.width)));
            const current = self.getSize(group);
            self.resizeGroupDimension(group, .vertical, @as(isize, @intCast(desired.height)) - @as(isize, @intCast(current.height)));
        }

        const ResizeBranch = struct { node: *LayoutNode, first: bool };
        fn findResizeBranch(node: *LayoutNode, group: *GroupView, direction: Orientation) ?ResizeBranch {
            if (node.kind != .split) return null;
            const split = node.kind.split;
            const first = grid.findLeaf(*GroupView, split.first, group) != null;
            const child = if (first) split.first else split.second;
            if (findResizeBranch(child, group, direction)) |branch| return branch;
            return if (split.direction == direction) .{ .node = node, .first = first } else null;
        }

        fn resizeGroupDimension(self: *Self, group: *GroupView, direction: Orientation, delta: isize) void {
            if (delta == 0) return;
            const branch = findResizeBranch(self.root, group, direction) orelse return;
            const split = branch.node.kind.split;
            const change = if (branch.first) delta else 0 -| delta;
            const boundary = if (direction == .horizontal) ui.cell.snap(split.first.rect.right()) else ui.cell.snap(split.first.rect.bottom());
            const target: usize = @intCast(@max(@as(isize, @intCast(boundary)) +| change, 0));
            self.resizeSash(branch.node, if (direction == .horizontal) target else 0, if (direction == .vertical) target else 0);
        }

        /// Starts, updates and ends a sash drag. Returns true while the pointer
        /// belongs to the sash.
        pub fn resizeSash(self: *Self, node: *LayoutNode, x: usize, y: usize) void {
            const split = switch (node.kind) {
                .split => |*value| value,
                .leaf => return,
            };
            const rect = node.rect;
            if (split.direction == .horizontal) {
                const available = rect.w - self.gap(.horizontal, rect);
                if (available < 2 * min_pane_width) return;
                const target = @as(f64, @floatFromInt(x)) - rect.x;
                const clamped = std.math.clamp(
                    target,
                    @as(f64, @floatFromInt(min_pane_width)),
                    available - @as(f64, @floatFromInt(min_pane_width)),
                );
                split.ratio = clamped / available;
            } else {
                const available = rect.h - self.gap(.vertical, rect);
                if (available < 2 * min_pane_height) return;
                const target = @as(f64, @floatFromInt(y)) - rect.y;
                const clamped = std.math.clamp(
                    target,
                    @as(f64, @floatFromInt(min_pane_height)),
                    available - @as(f64, @floatFromInt(min_pane_height)),
                );
                split.ratio = clamped / available;
            }
            self.layout(self.viewport);
        }

        /// Gutter cells between two panes. Cell borders need none.
        pub fn gap(self: *const Self, direction: Orientation, rect: ui.Rect) f64 {
            if (self.cell_borders) return 0;
            return switch (direction) {
                .horizontal => if (rect.w >= 6) 1 else 0,
                .vertical => if (rect.h >= 6) 1 else 0,
            };
        }

        /// Reserve edge cells only around the entire grid. Compact terminals
        /// keep those cells available for content.
        pub fn glyphFrame(self: *const Self) bool {
            return !self.cell_borders and self.viewport.w >= 24 and self.viewport.h >= 14;
        }

        pub fn contentRect(self: *const Self) ui.Rect {
            const rect = self.viewport;
            if (!self.glyphFrame()) return rect;
            return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 };
        }

        fn gapCallback(self: *const Self, direction: Orientation, rect: ui.Rect) f64 {
            return self.gap(direction, rect);
        }

        pub fn attachWindow(self: *Self, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
            self.window = window;
            if (@hasDecl(GroupView, "attachWindow")) for (self.group_views.items) |view| view.attachWindow(window);
        }

        pub fn attachTitleMenus(self: *Self, host: @import("editorTitleControl.zig").Host) !void {
            self.title_host = host;
            errdefer self.disposeTitleMenus();
            if (@hasDecl(GroupView, "attachTitleMenu")) for (self.group_views.items) |view| try view.attachTitleMenu(host);
        }

        pub fn disposeTitleMenus(self: *Self) void {
            self.title_host = null;
            if (@hasDecl(GroupView, "attachTitleMenu")) for (self.group_views.items) |view| view.title_control.deinit();
        }

        fn createView(self: *Self, group: *editor_groups.EditorGroup) !*GroupView {
            const view = try self.allocator.create(GroupView);
            errdefer self.allocator.destroy(view);
            view.* = GroupView.init(self.allocator, group);
            if (@hasDecl(GroupView, "attachWindow")) if (self.window) |window| view.attachWindow(window);
            errdefer view.deinit();
            if (@hasDecl(GroupView, "registerModelListeners")) try view.registerModelListeners();
            if (@hasDecl(GroupView, "attachTitleMenu")) if (self.title_host) |host| try view.attachTitleMenu(host);
            // Upstream `doCreateGroupView`: a focused group becomes the active
            // group (`doSetGroupActive`); the group view owns the focus event.
            _ = try view.on_did_focus.listen(self, onGroupDidFocus);
            try self.group_views.append(view);
            return view;
        }

        fn onGroupDidFocus(view: *GroupView, self: *Self) anyerror!void {
            self.service.activateGroup(view.group);
            try self.on_did_focus.fire({});
        }

        fn findDivider(
            self: *const Self,
            node: *LayoutNode,
            x: usize,
            y: usize,
        ) ?*LayoutNode {
            switch (node.kind) {
                .leaf => return null,
                .split => |split| {
                    const rect = node.rect;
                    if (split.direction == .horizontal) {
                        const edge = ui.cell.snap(split.first.rect.right());
                        const on_edge = x == edge or (self.gap(split.direction, rect) == 0 and x + 1 == edge);
                        if (on_edge and y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom())) {
                            return node;
                        }
                    } else {
                        const edge = ui.cell.snap(split.first.rect.bottom());
                        const on_edge = y == edge or (self.gap(split.direction, rect) == 0 and y + 1 == edge);
                        if (on_edge and x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right())) {
                            return node;
                        }
                    }
                    return self.findDivider(split.first, x, y) orelse
                        self.findDivider(split.second, x, y);
                },
            }
        }

        fn syncRects(self: *const Self, node: *LayoutNode) void {
            switch (node.kind) {
                .leaf => |view| view.rect = node.rect,
                .split => |split| {
                    self.syncRects(split.first);
                    self.syncRects(split.second);
                },
            }
        }
    };
}

fn collectOrdered(comptime T: type, node: *grid.Node(*T), views: *std.array_list.Managed(*T)) !void {
    switch (node.kind) {
        .leaf => |value| try views.append(value),
        .split => |split| {
            try collectOrdered(T, split.first, views);
            try collectOrdered(T, split.second, views);
        },
    }
}

const TestView = struct {
    group: *editor_groups.EditorGroup,
    rect: ui.Rect = .{},
    layouts: usize = 0,
    deinited: bool = false,
    on_did_focus: Emitter(*TestView),

    pub fn init(allocator: Allocator, group: *editor_groups.EditorGroup) TestView {
        return .{ .group = group, .on_did_focus = Emitter(*TestView).init(allocator) };
    }

    pub fn deinit(self: *TestView) void {
        self.deinited = true;
        self.on_did_focus.deinit();
    }

    pub fn layout(self: *TestView) void {
        self.layouts += 1;
    }

    pub fn focus(self: *TestView) void {
        self.on_did_focus.fire(self) catch {};
    }
};

const TestPart = EditorPart(TestView);

test "EditorPart: creates the first group view and lays it out" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    try std.testing.expectEqual(@as(usize, 1), part.count());
    try std.testing.expectEqual(part.group_views.items[0], part.activeView().?);

    part.layout(.{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try std.testing.expectEqual(@as(usize, 40), ui.cell.snap(part.group_views.items[0].rect.w));
    try std.testing.expectEqual(@as(usize, 1), part.group_views.items[0].layouts);
}

test "EditorPart: splitGroup inserts a view and removeView demotes the branch" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    const second = try part.splitGroup(first, .horizontal, false);
    try std.testing.expectEqual(@as(usize, 2), part.count());
    try std.testing.expectEqual(second, part.activeView().?);

    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try std.testing.expectEqual(@as(usize, 24), ui.cell.snap(first.rect.w));
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()) + 1, ui.cell.snap(second.rect.x));

    // The empty second group collapses and the first view is promoted.
    try std.testing.expect(part.collapseView(second));
    try std.testing.expectEqual(@as(usize, 1), part.count());
    switch (part.root.kind) {
        .leaf => |view| try std.testing.expectEqual(first, view),
        .split => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 50), ui.cell.snap(first.rect.w));
}

test "EditorPart: directional focus prefers the most recently active adjoining group" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();
    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const left = part.activeView().?;
    const upper_right = try part.splitGroup(left, .horizontal, false);
    const lower_right = try part.splitGroup(upper_right, .vertical, false);
    part.layout(.{ .x = 5, .y = 2, .w = 100, .h = 30 });

    service.activateGroup(upper_right.group);
    service.activateGroup(lower_right.group);
    service.activateGroup(left.group);
    try std.testing.expectEqual(lower_right, (try part.findGroup(.{ .direction = .RIGHT }, left, false)).?);
    service.activateGroup(upper_right.group);
    service.activateGroup(left.group);
    try std.testing.expectEqual(upper_right, (try part.findGroup(.{ .direction = .RIGHT }, left, false)).?);
    try std.testing.expectEqual(left, (try part.findGroup(.{ .direction = .RIGHT }, lower_right, true)).?);
}

test "EditorPart: findGroup by location follows the grid and wraps only when requested" {
    const service = try editor_groups.EditorGroupsService.init(std.testing.allocator, .{});
    defer service.deinit();
    const part = try TestPart.init(std.testing.allocator, service);
    defer part.deinit();
    const last = part.activeView().?;
    const first = try part.splitGroup(last, .horizontal, true);
    const middle = try part.splitGroup(first, .vertical, false);

    try std.testing.expectEqual(first, (try part.findGroup(.{ .location = .first }, middle, false)).?);
    try std.testing.expectEqual(last, (try part.findGroup(.{ .location = .last }, middle, false)).?);
    try std.testing.expectEqual(middle, (try part.findGroup(.{ .location = .next }, first, false)).?);
    try std.testing.expectEqual(middle, (try part.findGroup(.{ .location = .previous }, last, false)).?);
    try std.testing.expect(try part.findGroup(.{ .location = .next }, last, false) == null);
    try std.testing.expect(try part.findGroup(.{ .location = .previous }, first, false) == null);
    try std.testing.expectEqual(first, (try part.findGroup(.{ .location = .next }, last, true)).?);
    try std.testing.expectEqual(last, (try part.findGroup(.{ .location = .previous }, first, true)).?);
}

test "EditorPart: cell borders remove the gutter and expose both shared-edge cells" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    _ = try part.splitGroup(first, .horizontal, false);
    part.setCellBorders(true);
    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });

    const second = part.group_views.items[1];
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));
    const boundary = ui.cell.snap(first.rect.right());
    try std.testing.expectEqual(part.root, part.dividerAt(boundary, 2).?);
    try std.testing.expectEqual(part.root, part.dividerAt(boundary - 1, 2).?);
}

test "EditorPart: sash drag clamps the split ratio to the pane minimums" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    _ = try part.splitGroup(first, .horizontal, false);
    part.setCellBorders(true);
    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });

    part.resizeSash(part.root, 30, 2);
    try std.testing.expectEqual(@as(f64, 0.6), part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(first.rect.w));

    // Dragging past the minimum clamps to the minimum pane width.
    part.resizeSash(part.root, 1, 2);
    try std.testing.expectEqual(@as(usize, min_pane_width), ui.cell.snap(first.rect.w));
}

test "EditorPart: a focused group becomes the active group" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    const second = try part.splitGroup(first, .horizontal, false);
    try std.testing.expectEqual(second, part.activeView().?);

    const Observer = struct {
        part: *TestPart,
        seen: ?*TestView = null,

        fn didFocus(_: void, observer: *@This()) !void {
            observer.seen = observer.part.activeView();
        }
    };
    var observer = Observer{ .part = part };
    _ = try part.on_did_focus.listen(&observer, Observer.didFocus);
    first.focus();
    try std.testing.expectEqual(first, observer.seen.?);
    try std.testing.expectEqual(first.group, service.activeGroup());
    try std.testing.expectEqual(first, part.activeView().?);

    second.focus();
    try std.testing.expectEqual(second, observer.seen.?);
    try std.testing.expectEqual(second.group, service.activeGroup());
    try std.testing.expectEqual(second, part.activeView().?);
}
