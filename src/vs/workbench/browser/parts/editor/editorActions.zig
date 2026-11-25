// Port of the portable editor actions in `src/vs/workbench/browser/parts/editor/editorActions.ts`.
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../../services/layout/browser/layoutService.zig");
const groups = @import("../../../services/editor/common/editorGroupsService.zig");

fn focusGroupAction(comptime id: []const u8, title: []const u8, comptime scope: ?groups.IFindGroupScope, comptime binding: ?u32) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .keybindings = if (binding) |primary| &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = primary } }} else &.{},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const active = service.activeGroup() orelse return;
                const target = if (scope) |find| try service.findGroup(find, active, true) orelse return else active;
                target.focus();
            }
        }.run,
    };
}

fn chord(comptime arrow: key_codes.KeyCode) u32 {
    const modifier = key_codes.KeyMod.CtrlCmd;
    return key_codes.KeyChord(modifier | @backingInt(key_codes.KeyCode.KeyK), modifier | @backingInt(arrow));
}

pub const focus_group_actions = [_]actions.Action2{
    focusGroupAction("workbench.action.focusActiveEditorGroup", "Focus Active Editor Group", null, null),
    focusGroupAction("workbench.action.focusFirstEditorGroup", "Focus First Editor Group", .{ .location = .first }, key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Digit1)),
    focusGroupAction("workbench.action.focusLastEditorGroup", "Focus Last Editor Group", .{ .location = .last }, null),
    focusGroupAction("workbench.action.focusNextGroup", "Focus Next Editor Group", .{ .location = .next }, null),
    focusGroupAction("workbench.action.focusPreviousGroup", "Focus Previous Editor Group", .{ .location = .previous }, null),
    focusGroupAction("workbench.action.focusLeftGroup", "Focus Left Editor Group", .{ .direction = .LEFT }, chord(.LeftArrow)),
    focusGroupAction("workbench.action.focusRightGroup", "Focus Right Editor Group", .{ .direction = .RIGHT }, chord(.RightArrow)),
    focusGroupAction("workbench.action.focusAboveGroup", "Focus Editor Group Above", .{ .direction = .UP }, chord(.UpArrow)),
    focusGroupAction("workbench.action.focusBelowGroup", "Focus Editor Group Below", .{ .direction = .DOWN }, chord(.DownArrow)),
};

// The palette retains these existing terminal labels and IDs.
pub const navigate_between_groups_action = focusGroupAction("workbench.action.navigateEditorGroups", "Cycle Editor Groups", .{ .location = .next }, null);

pub const reset_group_sizes_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.evenEditorWidths", .title = "Reset Editor Group Sizes", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = resetGroupSizes,
};

fn resetGroupSizes(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(groups.editor_groups_service_id);
    service.arrangeGroups(.EVEN);
}

// AbstractCreateEditorGroupAction: the new group becomes active, but a
// focused sidebar/list stays focused so it can open an input in that group.
fn newGroupAction(comptime id: []const u8, title: []const u8, comptime direction: groups.GroupDirection) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const layout_service = try accessor.get(layout.layout_service_id);
                const focus_new_group = layout_service.hasFocus(.editor);
                const source = service.activeGroup() orelse return;
                const group = try service.addGroup(source, direction);
                service.activateGroup(group);
                if (focus_new_group) group.focus();
            }
        }.run,
    };
}

pub const new_group_actions = [_]actions.Action2{
    newGroupAction("workbench.action.newGroupLeft", "New Editor Group to the Left", .LEFT),
    newGroupAction("workbench.action.newGroupRight", "New Editor Group to the Right", .RIGHT),
    newGroupAction("workbench.action.newGroupAbove", "New Editor Group Above", .UP),
    newGroupAction("workbench.action.newGroupBelow", "New Editor Group Below", .DOWN),
};

fn moveGroupAction(comptime id: []const u8, title: []const u8, comptime direction: groups.GroupDirection, comptime arrow: key_codes.KeyCode) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .keybindings = &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(arrow)) } }},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const source = service.activeGroup() orelse return;
                const directions: [3]groups.GroupDirection = switch (direction) {
                    .LEFT, .RIGHT => .{ direction, .UP, .DOWN },
                    .UP, .DOWN => .{ direction, .LEFT, .RIGHT },
                };
                for (directions) |candidate| {
                    const target = try service.findGroup(.{ .direction = candidate }, source, false) orelse continue;
                    if (target.id == source.id) continue;
                    const moved = try service.moveGroup(source, target, direction);
                    service.activateGroup(moved);
                    return;
                }
            }
        }.run,
    };
}

pub const move_group_actions = [_]actions.Action2{
    moveGroupAction("workbench.action.moveActiveEditorGroupLeft", "Move Editor Group Left", .LEFT, .LeftArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupRight", "Move Editor Group Right", .RIGHT, .RightArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupUp", "Move Editor Group Up", .UP, .UpArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupDown", "Move Editor Group Down", .DOWN, .DownArrow),
};

const std = @import("std");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const file_dialogs = @import("../../../services/dialogs/browser/abstractFileDialogService.zig");
const Tab = @import("editorPane.zig").Tab;
const GroupView = @import("editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("editorPart.zig").EditorPart(GroupView);

const HistoryService = @import("../../../services/history/browser/historyService.zig").HistoryService;
const Capabilities = @import("../../../common/editor.zig").EditorInputCapabilities;

/// Port of AbstractCloseAllAction's default file-confirmation bucket,
/// revealEditorsToConfirm, revertEditors and doCloseAll. Native callbacks
/// dispose mounted panes and restore focus. Autosave-on-focus and custom
/// async-confirm buckets are not yet ported.
pub const AbstractCloseAllAction = struct {
    const Mode = enum { all, others, window };
    const Target = struct { pane: *GroupView, tab: *Tab, confirm: bool };

    allocator: std.mem.Allocator,
    part: *EditorPart,
    host: GroupView.CloseHost,
    targets: []Target,
    history: ?*HistoryService = null,
    on_exit: ?*const fn (*anyopaque) void = null,

    fn run(part: *EditorPart, dialog_service: dialogs.IDialogService, host: GroupView.CloseHost, mode: Mode, history: ?*HistoryService, on_exit: ?*const fn (*anyopaque) void) !void {
        if (dialog_service.hasDialog()) return;
        const active = part.activeView();
        const except = if (mode == .others) if (active) |pane| pane.activeTab() else null else null;
        if (mode == .others and except == null) return;

        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(part.allocator);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(part.allocator);
        // groupsToClose: reverse grid appearance keeps the top-left group.
        const ordered = try part.orderedViews(part.allocator);
        defer part.allocator.free(ordered);
        var index = ordered.len;
        while (index > 0) {
            index -= 1;
            const pane = ordered[index];
            if (mode == .others and pane != active) continue;
            const editors = try pane.group.model.getEditors(part.allocator, .SEQUENTIAL, mode != .window);
            defer part.allocator.free(editors);
            for (editors) |input| {
                if (mode != .window and input.hasCapability(Capabilities.CannotClose)) continue;
                const tab = pane.tabForInput(input) orelse continue;
                if (tab == except) continue;
                const confirm = if (input.close_handler) |handler|
                    handler.show_confirm(handler.context)
                else
                    input.isDirty() and !input.isSaving();
                try targets.append(part.allocator, .{ .pane = pane, .tab = tab, .confirm = confirm });
                if (confirm) try names.append(part.allocator, input.getName());
            }
        }
        if (targets.items.len == 0) return;

        var state = AbstractCloseAllAction{
            .allocator = part.allocator,
            .part = part,
            .host = host,
            .targets = targets.items,
            .history = history,
            .on_exit = on_exit,
        };
        if (names.items.len == 0) {
            try state.doCloseAll();
            return;
        }

        host.prepare_dialog(host.context);
        // Reveal the first affected editor in each group, not every dirty tab.
        var reveal_pane: ?*GroupView = null;
        for (targets.items) |target| {
            if (!target.confirm or target.pane == reveal_pane) continue;
            try target.pane.activateTab(target.tab);
            reveal_pane = target.pane;
        }
        if (reveal_pane) |pane| part.service.activateGroup(pane.group);
        if (part.activeView()) |pane| if (pane.activeTab()) |tab| try tab.ensureControllers();
        host.focus_editor(host.context, null);

        const pending = try part.allocator.create(AbstractCloseAllAction);
        errdefer part.allocator.destroy(pending);
        state.targets = try targets.toOwnedSlice(part.allocator);
        errdefer part.allocator.free(state.targets);
        pending.* = state;
        _ = try file_dialogs.showSaveConfirm(part.allocator, dialog_service, names.items, .{
            .context = pending,
            .complete = complete,
            .dispose = dispose,
        });
    }

    fn complete(context: *anyopaque, result: dialogs.ConfirmResult) void {
        const self: *AbstractCloseAllAction = @ptrCast(@alignCast(context));
        self.resolve(result) catch |err| self.host.report_error(self.host.context, err);
    }

    fn dispose(context: *anyopaque) void {
        const self: *AbstractCloseAllAction = @ptrCast(@alignCast(context));
        self.allocator.free(self.targets);
        self.allocator.destroy(self);
    }

    fn resolve(self: *AbstractCloseAllAction, result: dialogs.ConfirmResult) !void {
        const host = self.host;
        if (result == .CANCEL) {
            host.focus_editor(host.context, null);
            return;
        }
        for (self.targets) |target| {
            if (!target.confirm or !host.is_alive(host.context, target.pane, target.tab)) continue;
            const tab = target.tab;
            if (!tab.input.isDirty() and tab.input.close_handler == null) continue;
            switch (result) {
                .SAVE => {
                    _ = tab.input.save(target.pane.group.id) catch |err| {
                        tab.editor.setMessage("Unable to save {s}: {s}", .{ tab.input.getName(), @errorName(err) });
                        try self.revealFailure(target.pane, tab);
                        return;
                    };
                    if (tab.input.isDirty()) {
                        try self.revealFailure(target.pane, tab);
                        return;
                    }
                },
                .DONT_SAVE => tab.input.revert(target.pane.group.id) catch {},
                .CANCEL => unreachable,
            }
        }
        try self.doCloseAll();
    }

    fn revealFailure(self: *AbstractCloseAllAction, pane: *GroupView, tab: *Tab) !void {
        self.part.service.activateGroup(pane.group);
        try pane.activateTab(tab);
        try tab.ensureControllers();
        self.host.focus_editor(self.host.context, tab);
    }

    fn doCloseAll(self: *AbstractCloseAllAction) !void {
        if (self.history) |history| history.beginClosedBatch();
        defer if (self.history) |history| history.endClosedBatch();
        for (self.targets) |target| {
            if (!self.host.is_alive(self.host.context, target.pane, target.tab)) continue;
            try self.host.close_tab(self.host.context, target.pane, target.tab);
        }
        self.host.focus_editor(self.host.context, null);
        if (self.on_exit) |on_exit| on_exit(self.host.context);
    }
};

/// Terminal-specific window quit uses the same confirmation flow but includes
/// sticky editors. The host owns the actual decision to leave the input loop.
pub const CloseAllEditorsForWindow = struct {
    pub fn hasDirtyEditors(part: *const EditorPart) bool {
        for (part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| if (tab.input.isDirty()) return true;
        }
        return false;
    }

    pub fn run(part: *EditorPart, dialog_service: dialogs.IDialogService, host: GroupView.CloseHost, on_exit: *const fn (*anyopaque) void) !void {
        try AbstractCloseAllAction.run(part, dialog_service, host, .window, null, on_exit);
    }
};

/// Action context for the terminal editor groups. The upstream actions use
/// IEditorGroupsService; the native group adapter carries the same part and
/// explicit view ownership hooks while the transfer vtable is being ported.
pub const GroupActions = struct {
    part: *EditorPart,
    transfer: EditorPart.TransferHost,
    configuration: *const ?*@import("../../../services/configuration/browser/configurationService.zig").ConfigurationService,
    report_status: *const fn (*anyopaque, []const u8) void,
    close_host: GroupView.CloseHost,
    dialog_service: *const dialogs.IDialogService,
    history: *HistoryService,

    pub const GroupTarget = enum { first, last, previous, next, left, right, up, down };

    pub fn preferredSideBySideDirection(self: *GroupActions) groups.GroupDirection {
        return groups.preferredSideBySideGroupDirection(if (self.configuration.*) |configuration| configuration.interface() else null);
    }

    fn focusPane(pane: *GroupView) !void {
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        pane.focus();
    }

    fn splitPreferred(self: *GroupActions) !void {
        try self.splitActiveInDirection(self.preferredSideBySideDirection());
    }

    fn splitOrthogonal(self: *GroupActions) !void {
        try self.splitActiveInDirection(if (self.preferredSideBySideDirection() == .RIGHT) .DOWN else .RIGHT);
    }

    fn action(self: *GroupActions, id: []const u8, title: []const u8, comptime run: anytype, comptime args: anytype) actions.Action2 {
        return .{
            .command = .{ .id = id, .title = title, .category = "View" },
            .f1 = true,
            .context = self,
            .run_fn = struct {
                fn invoke(context: *anyopaque, _: ServicesAccessor) !void {
                    const service: *GroupActions = @ptrCast(@alignCast(context));
                    const result: anyerror!void = @call(.auto, run, .{service} ++ args);
                    result catch |err| switch (err) {
                        error.SplitUnsupported => service.report_status(service.transfer.copy.context, "Split Editor is unavailable for this editor type"),
                        else => return err,
                    };
                }
            }.invoke,
        };
    }

    /// Port of `workbench.action.newGroupLeft/Right/Above/Below`: add an empty
    /// group and activate it.
    pub fn newEmptyGroup(self: *GroupActions, direction: groups.GroupDirection) !*GroupView {
        const source = self.part.activeView() orelse return error.NoActivePane;
        const view = try self.part.addGroup(source, direction);
        try focusPane(view);
        return view;
    }

    fn preferredOppositeDirection(self: *GroupActions) groups.GroupDirection {
        return if (self.preferredSideBySideDirection() == .RIGHT) .LEFT else .UP;
    }

    /// Resolves the target group for move/copy-editor commands. Directional
    /// commands create the missing group, matching `moveCopyEditorsToGroup`.
    pub fn resolveGroupTarget(
        self: *GroupActions,
        source: *GroupView,
        target: GroupTarget,
        create: bool,
    ) !?*GroupView {
        switch (target) {
            .left, .right, .up, .down => {
                const direction: groups.GroupDirection = switch (target) {
                    .left => .LEFT,
                    .right => .RIGHT,
                    .up => .UP,
                    else => .DOWN,
                };
                self.transfer.layout(self.transfer.copy.context);
                if (try self.part.findGroup(.{ .direction = direction }, source, false)) |pane| return pane;
                if (!create) return null;
                return try self.newEmptyGroup(direction);
            },
            .first, .last, .previous, .next => {
                const location: groups.GroupLocation = switch (target) {
                    .first => .first,
                    .last => .last,
                    .previous => .previous,
                    .next => .next,
                    else => unreachable,
                };
                if (try self.part.findGroup(.{ .location = location }, source, false)) |view| return view;
                if (!create) return null;
                return try self.newEmptyGroup(if (location == .next) self.preferredSideBySideDirection() else self.preferredOppositeDirection());
            },
        }
    }

    /// Port of `workbench.action.closeGroup`: move the active group's editors
    /// into the most recently active other group, then remove the group.
    pub fn closeActiveGroup(self: *GroupActions) !void {
        self.part.active_sash = null;
        const source = self.part.activeView() orelse return;
        if (self.part.count() <= 1) return;
        const ordered_groups = try self.part.service.getGroups(self.part.allocator, .MOST_RECENTLY_ACTIVE);
        defer self.part.allocator.free(ordered_groups);
        var destination: ?*GroupView = null;
        for (ordered_groups) |group| {
            if (group == source.group) continue;
            if (self.part.viewForGroup(group)) |pane| {
                destination = pane;
                break;
            }
        }
        const target = destination orelse return;
        try self.part.mergeGroup(source, target, self.transfer);
    }

    /// Port of `workbench.action.joinTwoGroups`: merge the active group into
    /// the nearest neighbour, searching right, down, left then up.
    pub fn joinTwoGroups(self: *GroupActions) !void {
        self.transfer.layout(self.transfer.copy.context);
        const source = self.part.activeView() orelse return;
        const directions = [_]groups.GroupDirection{ .RIGHT, .DOWN, .LEFT, .UP };
        for (directions) |direction| {
            if (try self.part.findGroup(.{ .direction = direction }, source, false)) |target| {
                try self.part.mergeGroup(source, target, self.transfer);
                return;
            }
        }
    }

    /// Port of `workbench.action.duplicateActiveEditorGroupLeft/Right/Up/Down`:
    /// create a group beside the active one and copy every editor into it.
    pub fn duplicateActiveGroup(self: *GroupActions, direction: groups.GroupDirection) !void {
        const source = self.part.activeView() orelse return;
        _ = try self.part.copyGroup(source, direction, self.transfer);
    }

    /// Port of `moveActiveEditor`/`copyActiveEditor` with `by: 'group'`, used
    /// by the moveEditorTo*Group and splitEditorTo*Group commands.
    pub fn moveOrSplitActiveEditor(self: *GroupActions, target: GroupTarget, copy: bool) !void {
        self.transfer.layout(self.transfer.copy.context);
        const source = self.part.activeView() orelse return;
        const tab = source.activeTab() orelse return;
        const destination = try self.resolveGroupTarget(source, target, true) orelse return;
        if (destination == source) return;
        if (copy) {
            _ = try destination.copyEditor(tab, .{ .pinned = true, .active = true }, self.transfer.copy);
        } else {
            _ = try source.moveEditor(destination, tab, .{ .pinned = true, .active = true }, self.transfer.move);
            if (source.tabs.items.len == 0) self.part.collapseGroup(source, self.transfer);
        }
        try focusPane(destination);
    }

    /// Port of `workbench.action.joinAllGroups`: move every tab into the
    /// active group, then drop the empty groups.
    pub fn joinAllGroups(self: *GroupActions) !void {
        const target = self.part.activeView() orelse return;
        try self.part.mergeAllGroups(target, self.transfer);
    }

    /// Port of upstream `splitEditor(editorGroupsService, direction, context)`:
    /// create a group beside the active one and copy the active editor into it.
    /// The original tab stays open; both panes share the document/model and
    /// keep independent view state.
    pub fn splitActiveInDirection(self: *GroupActions, direction: groups.GroupDirection) !void {
        const source = self.part.activeView() orelse return;
        try self.part.splitEditor(source, direction, self.transfer);
    }

    /// AbstractNavigateEditorAction: resolve an editor within the active
    /// group first, then traverse adjacent nonempty groups in grid order.
    pub fn navigateEditor(self: *GroupActions, previous: bool) !void {
        const service = self.part.interface();
        const active = service.activeGroup() orelse return;
        const index = active.activeEditorIndex();
        if (previous) {
            if (index) |i| if (i > 0) return self.openEditorAt(active, i - 1, true);
        } else {
            const next = if (index) |i| i + 1 else 0;
            if (next < active.count()) return self.openEditorAt(active, next, true);
        }
        var current = active;
        while (true) {
            current = (try service.findGroup(.{ .location = if (previous) .previous else .next }, current, true)) orelse return;
            if (current.count() != 0) return self.openEditorAt(current, if (previous) current.count() - 1 else 0, true);
            if (current.id == active.id) return;
        }
    }

    /// Terminal :tabnext/:tabprevious remain within the current group.
    pub fn switchTab(self: *GroupActions, delta: isize) !void {
        const group = self.part.interface().activeGroup() orelse return;
        if (group.count() == 0) return;
        const current: isize = @intCast(group.activeEditorIndex() orelse 0);
        const count: isize = @intCast(group.count());
        try self.openEditorAt(group, @intCast(@mod(current + delta, count)), true);
    }

    fn openEditorAt(self: *GroupActions, group: groups.IEditorGroup, index: usize, record_history: bool) !void {
        const input = group.getEditorByIndex(index) orelse return;
        try group.openEditor(input);
        if (record_history) if (self.part.activeView()) |pane| {
            if (pane.activeTab()) |tab| if (tab.terminal_input == null) try self.history.add(tab.editor.path);
        };
    }

    pub fn activateIndex(self: *GroupActions, index: usize) !void {
        const group = self.part.interface().activeGroup() orelse return;
        try self.openEditorAt(group, index, true);
    }

    pub fn lastEditorInGroup(self: *GroupActions) !void {
        const group = self.part.interface().activeGroup() orelse return;
        if (group.count() != 0) try self.openEditorAt(group, group.count() - 1, false);
    }

    pub fn previousEditor(self: *GroupActions) !void {
        try self.navigateEditor(true);
    }

    pub fn closeEditor(self: *GroupActions, pane: *GroupView, tab: *Tab) !void {
        if (self.dialog_service.hasDialog() or tab.input.hasCapability(Capabilities.CannotClose)) return;
        try pane.handleCloseConfirmation(tab, self.dialog_service.*, self.close_host);
    }

    pub fn closeActiveEditor(self: *GroupActions) !void {
        self.close_host.prepare_dialog(self.close_host.context);
        const pane = self.part.activeView() orelse return;
        if (pane.tabs.items.len == 0) return self.closeActiveGroup();
        const tab = pane.activeTab() orelse return;
        try self.closeEditor(pane, tab);
    }

    pub fn revertAndCloseActiveEditor(self: *GroupActions) !void {
        const pane = self.part.activeView() orelse return;
        const tab = pane.activeTab() orelse return;
        if (self.dialog_service.hasDialog() or tab.input.hasCapability(Capabilities.CannotClose)) return;
        self.close_host.prepare_dialog(self.close_host.context);
        // Normal revert first, soft-revert/close fallback when the disk
        // resource cannot be reloaded, matching RevertAndCloseEditorAction.
        tab.input.revert(pane.group.id) catch {
            try self.close_host.close_tab(self.close_host.context, pane, tab);
            return;
        };
        try self.closeEditor(pane, tab);
    }

    pub fn reopenLastClosedEditor(self: *GroupActions) !void {
        _ = self.history.reopenLastClosedEditor();
    }

    pub fn closeAndReopenActions(self: *GroupActions) [2]actions.Action2 {
        return .{
            self.action("workbench.action.closeActiveEditor", "Close Editor", closeActiveEditor, .{}),
            self.action("workbench.action.reopenClosedEditor", "Reopen Closed Editor", reopenLastClosedEditor, .{}),
        };
    }

    pub fn navigationActions(self: *GroupActions) [4]actions.Action2 {
        return .{
            self.action("workbench.action.lastEditorInGroup", "Last Editor in Group", lastEditorInGroup, .{}),
            self.action("workbench.action.previousEditor", "Previous Editor", previousEditor, .{}),
            self.action("workbench.action.openEditorAtIndex1", "Open Editor 1", activateIndex, .{0}),
            self.action("workbench.action.revertAndCloseActiveEditor", "Revert and Close Editor", revertAndCloseActiveEditor, .{}),
        };
    }

    pub fn closeAllEditors(self: *GroupActions) !void {
        try AbstractCloseAllAction.run(self.part, self.dialog_service.*, self.close_host, .all, self.history, null);
    }

    pub fn closeOtherEditors(self: *GroupActions) !void {
        try AbstractCloseAllAction.run(self.part, self.dialog_service.*, self.close_host, .others, self.history, null);
    }

    pub fn closeEditorsActions(self: *GroupActions) [2]actions.Action2 {
        return .{
            self.action("workbench.action.closeAllEditors", "Close All Editors", closeAllEditors, .{}),
            self.action("workbench.action.closeOtherEditors", "Close Other Editors", closeOtherEditors, .{}),
        };
    }

    pub fn splitActions(self: *GroupActions) [6]actions.Action2 {
        return .{
            self.action("workbench.action.splitEditor", "Split Editor", splitPreferred, .{}),
            self.action("workbench.action.splitEditorOrthogonal", "Split Editor Orthogonal", splitOrthogonal, .{}),
            self.action("workbench.action.splitEditorLeft", "Split Editor Left", splitActiveInDirection, .{.LEFT}),
            self.action("workbench.action.splitEditorRight", "Split Editor Right", splitActiveInDirection, .{.RIGHT}),
            self.action("workbench.action.splitEditorUp", "Split Editor Up", splitActiveInDirection, .{.UP}),
            self.action("workbench.action.splitEditorDown", "Split Editor Down", splitActiveInDirection, .{.DOWN}),
        };
    }

    pub fn joinActions(self: *GroupActions) [2]actions.Action2 {
        return .{
            self.action("workbench.action.closeGroup", "Close Editor Group", closeActiveGroup, .{}),
            self.action("workbench.action.joinTwoGroups", "Join Editor Group with Next Group", joinTwoGroups, .{}),
        };
    }

    pub fn transferActions(self: *GroupActions) [20]actions.Action2 {
        return .{
            self.action("workbench.action.duplicateActiveEditorGroupLeft", "Duplicate Editor Group Left", duplicateActiveGroup, .{.LEFT}),
            self.action("workbench.action.duplicateActiveEditorGroupRight", "Duplicate Editor Group Right", duplicateActiveGroup, .{.RIGHT}),
            self.action("workbench.action.duplicateActiveEditorGroupUp", "Duplicate Editor Group Up", duplicateActiveGroup, .{.UP}),
            self.action("workbench.action.duplicateActiveEditorGroupDown", "Duplicate Editor Group Down", duplicateActiveGroup, .{.DOWN}),
            self.action("workbench.action.moveEditorToPreviousGroup", "Move Editor into Previous Group", moveOrSplitActiveEditor, .{ .previous, false }),
            self.action("workbench.action.moveEditorToNextGroup", "Move Editor into Next Group", moveOrSplitActiveEditor, .{ .next, false }),
            self.action("workbench.action.moveEditorToAboveGroup", "Move Editor into Group Above", moveOrSplitActiveEditor, .{ .up, false }),
            self.action("workbench.action.moveEditorToBelowGroup", "Move Editor into Group Below", moveOrSplitActiveEditor, .{ .down, false }),
            self.action("workbench.action.moveEditorToLeftGroup", "Move Editor into Left Group", moveOrSplitActiveEditor, .{ .left, false }),
            self.action("workbench.action.moveEditorToRightGroup", "Move Editor into Right Group", moveOrSplitActiveEditor, .{ .right, false }),
            self.action("workbench.action.moveEditorToFirstGroup", "Move Editor into First Group", moveOrSplitActiveEditor, .{ .first, false }),
            self.action("workbench.action.moveEditorToLastGroup", "Move Editor into Last Group", moveOrSplitActiveEditor, .{ .last, false }),
            self.action("workbench.action.splitEditorToPreviousGroup", "Split Editor into Previous Group", moveOrSplitActiveEditor, .{ .previous, true }),
            self.action("workbench.action.splitEditorToNextGroup", "Split Editor into Next Group", moveOrSplitActiveEditor, .{ .next, true }),
            self.action("workbench.action.splitEditorToAboveGroup", "Split Editor into Group Above", moveOrSplitActiveEditor, .{ .up, true }),
            self.action("workbench.action.splitEditorToBelowGroup", "Split Editor into Group Below", moveOrSplitActiveEditor, .{ .down, true }),
            self.action("workbench.action.splitEditorToLeftGroup", "Split Editor into Left Group", moveOrSplitActiveEditor, .{ .left, true }),
            self.action("workbench.action.splitEditorToRightGroup", "Split Editor into Right Group", moveOrSplitActiveEditor, .{ .right, true }),
            self.action("workbench.action.splitEditorToFirstGroup", "Split Editor into First Group", moveOrSplitActiveEditor, .{ .first, true }),
            self.action("workbench.action.splitEditorToLastGroup", "Split Editor into Last Group", moveOrSplitActiveEditor, .{ .last, true }),
        };
    }

    pub fn joinAllAction(self: *GroupActions) actions.Action2 {
        return self.action("workbench.action.joinAllGroups", "Join All Editor Groups", joinAllGroups, .{});
    }
};

/// Terminal alias retained for the original palette inventory. The actual
/// group maximization is the EditorGroupsService arrangement operation.
pub const maximize_editor_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.maximizeEditor", .title = "Maximize Editor Group", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = maximizeEditorGroup,
};

fn maximizeEditorGroup(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(groups.editor_groups_service_id);
    service.arrangeGroups(.MAXIMIZE);
}
