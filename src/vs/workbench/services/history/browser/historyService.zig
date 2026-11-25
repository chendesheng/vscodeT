// Port of the file history and navigation stack portions of
// `src/vs/workbench/services/history/browser/historyService.ts`.
// Terminal editor inputs identify local resources by their native paths.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_common = @import("../../../common/editor.zig");

const GoFilter = @import("../common/history.zig").GoFilter;
const GoScope = @import("../common/history.zig").GoScope;

pub const EditorNavigationStackEntry = struct {
    group_id: editor_common.GroupIdentifier,
    path: []u8,
    selection: ?editor_common.IEditorPaneSelection = null,
    top_view_line: usize = 1,

    fn deinit(self: *EditorNavigationStackEntry, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.selection) |selection| selection.dispose();
        allocator.destroy(self);
    }
};

pub const EditorNavigationStack = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(*EditorNavigationStackEntry),
    index: isize = -1,
    max: usize = 50,

    pub fn init(allocator: Allocator) EditorNavigationStack {
        return .{ .allocator = allocator, .entries = std.array_list.Managed(*EditorNavigationStackEntry).init(allocator) };
    }

    pub fn deinit(self: *EditorNavigationStack) void {
        self.entries.deinit();
    }

    pub fn clear(self: *EditorNavigationStack) void {
        self.entries.clearRetainingCapacity();
        self.index = -1;
    }

    pub fn canGoBack(self: *const EditorNavigationStack) bool {
        return self.index > 0;
    }

    pub fn canGoForward(self: *const EditorNavigationStack) bool {
        return self.index >= 0 and @as(usize, @intCast(self.index)) + 1 < self.entries.items.len;
    }

    pub fn goBack(self: *EditorNavigationStack) ?*EditorNavigationStackEntry {
        if (!self.canGoBack()) return null;
        self.index -= 1;
        return self.entries.items[@intCast(self.index)];
    }

    pub fn goForward(self: *EditorNavigationStack) ?*EditorNavigationStackEntry {
        if (!self.canGoForward()) return null;
        self.index += 1;
        return self.entries.items[@intCast(self.index)];
    }

    pub fn current(self: *const EditorNavigationStack) ?*EditorNavigationStackEntry {
        if (self.index < 0) return null;
        return self.entries.items[@intCast(self.index)];
    }

    fn sameEntry(a: *const EditorNavigationStackEntry, path: []const u8, group_id: editor_common.GroupIdentifier, selection: ?editor_common.IEditorPaneSelection) bool {
        if (a.group_id != group_id or !std.mem.eql(u8, a.path, path)) return false;
        if (a.selection == null and selection == null) return true;
        if (a.selection == null or selection == null) return false;
        return a.selection.?.compare(&selection.?) == .IDENTICAL;
    }

    pub fn record(self: *EditorNavigationStack, entry: *EditorNavigationStackEntry) void {
        if (self.index >= 0) {
            const current_entry = self.entries.items[@intCast(self.index)];
            if (sameEntry(current_entry, entry.path, entry.group_id, entry.selection)) {
                current_entry.top_view_line = entry.top_view_line;
                if (current_entry.selection) |old| old.dispose();
                current_entry.selection = entry.selection;
                entry.selection = null;
                return;
            }
        }
        const keep = if (self.index < 0) 0 else @as(usize, @intCast(self.index)) + 1;
        while (self.entries.items.len > keep) _ = self.entries.pop();
        if (self.entries.items.len >= self.max) {
            _ = self.entries.orderedRemove(0);
            if (self.index >= 0) self.index -= 1;
        }
        self.entries.append(entry) catch return;
        self.index = @intCast(self.entries.items.len - 1);
    }

    pub fn removePath(self: *EditorNavigationStack, path: []const u8) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[index].path, path)) {
                _ = self.entries.orderedRemove(index);
                if (self.index >= @as(isize, @intCast(index))) self.index -= 1;
            } else index += 1;
        }
    }
};

pub const ClosedEditor = struct {
    path: []u8,
    group_id: editor_common.GroupIdentifier,
    index: usize,
    sticky: bool,
    pinned: bool,
    batch_id: u64,
};

const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupPane = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupPane);
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const editor_widget = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const text_editor_selection_mod = @import("../../../browser/parts/editor/textEditor.zig");
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;
const text_files = @import("../../textfile/common/textFileService.zig");

pub const HistoryService = struct {
    allocator: Allocator,
    paths: std.array_list.Managed([]u8),
    max: usize = 50,
    /// All navigation entries are owned by this pool and shared by the
    /// default, group and editor scoped stacks.
    entries: std.array_list.Managed(*EditorNavigationStackEntry),
    default_stacks: EditorNavigationStacks,
    group_stacks: std.AutoHashMap(editor_common.GroupIdentifier, *EditorNavigationStacks),
    editor_stacks: std.StringHashMap(*EditorNavigationStacks),
    closed_editors: std.array_list.Managed(ClosedEditor),
    closed_batch_id: u64 = 0,

    editor_host: ?EditorHost = null,
    active_listener: ?usize = null,
    close_listener: ?usize = null,
    visible_listener: ?usize = null,
    history_tab: ?*Tab = null,
    history_selection_listener: ?Tab.SelectionListener = null,
    history_content_listener: ?editor_widget.ChangeListener = null,
    history_navigating: bool = false,
    in_closed_batch: bool = false,

    pub const EditorHost = struct {
        context: *anyopaque,
        part: *EditorPart,
        io: std.Io,
        open_path: *const fn (*anyopaque, []const u8) anyerror!void,
        focus_editor: *const fn (*anyopaque) void,
    };

    /// The editor service publishes both active model and mounted pane events;
    /// the latter guarantees that the pane exists before subscribing to its
    /// selection and working-copy change emitters.
    pub fn registerListeners(self: *HistoryService, host: EditorHost) !void {
        self.editor_host = host;
        errdefer self.disposeEditorListeners();
        self.active_listener = try host.part.service.on_did_active_editor_change.listen(self, onActiveHistoryEditor);
        self.visible_listener = try host.part.service.on_did_visible_editors_change.listen(self, onHistoryVisibleEditorsChanged);
        self.close_listener = try host.part.on_did_close_editor.listen(self, onDidCloseEditor);
        try onHistoryVisibleEditorsChanged({}, self);
    }

    fn disposeEditorListeners(self: *HistoryService) void {
        const host = self.editor_host orelse return;
        if (self.active_listener) |id| host.part.service.on_did_active_editor_change.unlisten(id);
        if (self.visible_listener) |id| host.part.service.on_did_visible_editors_change.unlisten(id);
        if (self.close_listener) |id| host.part.on_did_close_editor.unlisten(id);
        if (self.history_tab) |tab| self.detachHistoryTab(tab);
        self.active_listener = null;
        self.visible_listener = null;
        self.close_listener = null;
        self.editor_host = null;
    }

    fn activePane(self: *HistoryService) ?*GroupPane {
        const host = self.editor_host orelse return null;
        return host.part.activeView();
    }

    fn activeTab(self: *HistoryService) ?*Tab {
        const pane = self.activePane() orelse return null;
        return pane.activeTab();
    }

    /// Upstream handleEditorCloseEventInReopen ignores move/replacement
    /// events and records the sequential tab index before it disappears.
    fn onDidCloseEditor(event: @import("../../editor/common/editorService.zig").IEditorCloseEvent, self: *HistoryService) !void {
        if (event.context == .REPLACE or event.context == .MOVE) return;
        if (!self.in_closed_batch) self.closed_batch_id +%= 1;
        if (!event.editor.canReopen()) return;
        const resource = event.editor.resource orelse return;
        const path = try self.allocator.dupe(u8, resource);
        errdefer self.allocator.free(path);
        try self.recordClosedEditor(.{
            .path = path,
            .group_id = event.group_id,
            .index = event.index,
            .sticky = event.sticky,
            .pinned = event.pinned,
            .batch_id = self.closed_batch_id,
        });
    }

    fn onActiveHistoryEditor(_: ?*EditorInput, self: *HistoryService) !void {
        try onHistoryVisibleEditorsChanged({}, self);
    }

    fn onHistoryVisibleEditorsChanged(_: void, self: *HistoryService) !void {
        const pane = self.editor_host.?.part.activeView();
        self.syncHistorySelectionTab(if (pane) |group| group.panes.activePane() else null);
    }

    fn syncHistorySelectionTab(self: *HistoryService, active_tab: ?*Tab) void {
        const tab = if (active_tab != null and active_tab.?.terminal_input != null) null else active_tab;
        if (self.history_tab == tab) return;
        if (self.history_tab) |old_tab| {
            if (self.history_selection_listener) |listener| old_tab.removeSelectionListener(listener);
            if (self.history_content_listener) |listener| old_tab.editor.removeWorkingCopyContentListener(listener);
        }
        self.history_tab = tab;
        self.history_selection_listener = null;
        self.history_content_listener = null;
        const next = tab orelse return;
        const listener = Tab.SelectionListener{
            .context = self,
            .callback = onHistorySelectionChanged,
        };
        next.addSelectionListener(listener) catch return;
        self.history_selection_listener = listener;
        const content_listener = editor_widget.ChangeListener{ .context = self, .callback = onHistoryContentChanged };
        next.editor.addWorkingCopyContentListener(content_listener);
        self.history_content_listener = content_listener;
    }

    pub fn detachHistoryTab(self: *HistoryService, tab: *Tab) void {
        if (self.history_tab != tab) return;
        if (self.history_selection_listener) |listener| tab.removeSelectionListener(listener);
        if (self.history_content_listener) |listener| tab.editor.removeWorkingCopyContentListener(listener);
        self.history_tab = null;
        self.history_selection_listener = null;
        self.history_content_listener = null;
    }

    fn onHistoryContentChanged(context: *anyopaque) void {
        const self: *HistoryService = @ptrCast(@alignCast(context));
        self.recordActiveNavigation(.EDIT);
    }

    fn onHistorySelectionChanged(context: *anyopaque, reason: editor_common.EditorPaneSelectionChangeReason) void {
        const self: *HistoryService = @ptrCast(@alignCast(context));
        // Vim and other navigation sources record explicitly before moving.
        // A bare USER cursor move must not add a jump-list entry.
        if (reason == .USER) return;
        self.recordActiveNavigation(reason);
    }

    pub fn recordActiveNavigation(self: *HistoryService, reason: editor_common.EditorPaneSelectionChangeReason) void {
        if (self.history_navigating) return;
        const tab = self.activeTab() orelse return;
        const selections = tab.editor.getSelections() catch return;
        defer self.allocator.free(selections);
        if (selections.len == 0) return;
        const group_id = self.editor_host.?.part.service.activeGroup().id;
        const selection = text_editor_selection_mod.TextEditorPaneSelection.create(self.allocator, selections[0]) catch return;
        var iface = selection.interface();
        self.recordNavigation(group_id, tab.editor.path, iface, tab.editor.topViewLine(), reason) catch {
            iface.dispose();
        };
    }

    pub fn goBackInHistory(self: *HistoryService) bool {
        const tab = self.activeTab() orelse return false;
        const group_id = self.editor_host.?.part.service.activeGroup().id;
        // The active location is the destination of a forward navigation and
        // must be in the stack before stepping back.
        self.recordActiveNavigation(.NAVIGATION);
        const entry = self.goBack(.DEFAULT, .NONE, group_id, tab.editor.path) orelse return false;
        self.restoreNavigation(entry);
        return true;
    }

    pub fn goForwardInHistory(self: *HistoryService) bool {
        const tab = self.activeTab() orelse return false;
        const group_id = self.editor_host.?.part.service.activeGroup().id;
        const entry = self.goForward(.DEFAULT, .NONE, group_id, tab.editor.path) orelse return false;
        self.restoreNavigation(entry);
        return true;
    }

    fn restoreNavigation(self: *HistoryService, entry: *EditorNavigationStackEntry) void {
        if (self.history_navigating) return;
        self.history_navigating = true;
        defer self.history_navigating = false;

        var pane: ?*GroupPane = null;
        for (self.editor_host.?.part.group_views.items) |candidate| {
            if (candidate.group.id == entry.group_id) {
                pane = candidate;
                break;
            }
        }
        if (pane) |target_pane| self.editor_host.?.part.service.activateGroup(target_pane.group);

        if (self.activeTab() == null or !text_files.samePath(self.allocator, self.editor_host.?.io, self.activeTab().?.editor.path, entry.path)) {
            self.editor_host.?.open_path(self.editor_host.?.context, entry.path) catch |err| {
                if (self.activeTab()) |tab| tab.editor.setMessage("navigation restore failed: {s}", .{@errorName(err)});
                return;
            };
        } else if (pane) |target_pane| {
            if (target_pane.activeTab()) |target| {
                target_pane.activateTab(target) catch {};
                target.focusEditor();
            }
        }

        const tab = self.activeTab() orelse return;
        if (entry.selection) |selection| {
            const options = selection.restore(.{});
            if (options.selection) |restored| {
                tab.editor.setTextEditorSelectionSource(.PROGRAMMATIC);
                tab.editor.setSelections(&[_]Selection{restored}) catch {};
            }
        }
        _ = tab.editor.setTopViewLine(entry.top_view_line);
        self.editor_host.?.focus_editor(self.editor_host.?.context);
        tab.focusEditor();
    }

    pub fn beginClosedBatch(self: *HistoryService) void {
        if (self.in_closed_batch) return;
        self.in_closed_batch = true;
        self.closed_batch_id +%= 1;
    }

    pub fn endClosedBatch(self: *HistoryService) void {
        self.in_closed_batch = false;
    }

    pub fn reopenLastClosedEditor(self: *HistoryService) bool {
        if (self.editor_host == null or self.closed_editors.items.len == 0) return false;
        const batch_id = self.closed_editors.items[self.closed_editors.items.len - 1].batch_id;
        var reopened = false;
        while (self.closed_editors.items.len > 0) {
            const last = self.closed_editors.items[self.closed_editors.items.len - 1];
            if (last.batch_id != batch_id) break;
            const closed = self.closed_editors.pop().?;
            defer self.allocator.free(closed.path);
            self.editor_host.?.open_path(self.editor_host.?.context, closed.path) catch continue;
            if (self.activePane()) |pane| {
                if (pane.activeTab()) |tab| {
                    if (closed.index < pane.tabs.items.len) {
                        _ = pane.group.model.moveEditor(tab.input, @intCast(closed.index)) catch {};
                    }
                    if (closed.pinned) _ = pane.group.model.pin(tab.input) catch {};
                }
            }
            reopened = true;
        }
        return reopened;
    }

    pub fn init(allocator: Allocator) HistoryService {
        return .{
            .allocator = allocator,
            .paths = std.array_list.Managed([]u8).init(allocator),
            .entries = std.array_list.Managed(*EditorNavigationStackEntry).init(allocator),
            .default_stacks = EditorNavigationStacks.init(allocator),
            .group_stacks = std.AutoHashMap(editor_common.GroupIdentifier, *EditorNavigationStacks).init(allocator),
            .editor_stacks = std.StringHashMap(*EditorNavigationStacks).init(allocator),
            .closed_editors = std.array_list.Managed(ClosedEditor).init(allocator),
        };
    }

    pub fn deinit(self: *HistoryService) void {
        self.disposeEditorListeners();
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit();
        self.default_stacks.deinit();
        var group_values = self.group_stacks.valueIterator();
        while (group_values.next()) |stacks| {
            stacks.*.deinit();
            self.allocator.destroy(stacks.*);
        }
        self.group_stacks.deinit();
        var editor_keys = self.editor_stacks.keyIterator();
        while (editor_keys.next()) |key| self.allocator.free(key.*);
        var editor_values = self.editor_stacks.valueIterator();
        while (editor_values.next()) |stacks| {
            stacks.*.deinit();
            self.allocator.destroy(stacks.*);
        }
        self.editor_stacks.deinit();
        for (self.closed_editors.items) |closed| self.allocator.free(closed.path);
        self.closed_editors.deinit();
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit();
    }

    /// Moves `path` to the front, deduplicating by exact path.
    pub fn add(self: *HistoryService, path: []const u8) !void {
        for (self.paths.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, path)) {
                const owned = self.paths.orderedRemove(index);
                self.paths.insertAssumeCapacity(0, owned);
                break;
            }
        } else {
            const copy = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(copy);
            try self.paths.insert(0, copy);
        }
        while (self.paths.items.len > self.max) {
            const removed = self.paths.pop().?;
            self.allocator.free(removed);
        }
    }

    /// Opened editors already in history keep their order. Append the
    /// remaining stored entries in MRU order as HistoryService.loadHistory does.
    pub fn loadHistory(self: *HistoryService, stored: []const []const u8) !void {
        for (stored) |path| {
            if (self.paths.items.len >= self.max) break;
            for (self.paths.items) |existing| {
                if (std.mem.eql(u8, path, existing)) break;
            } else {
                const copy = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(copy);
                try self.paths.append(copy);
            }
        }
    }

    pub fn remove(self: *HistoryService, path: []const u8) void {
        for (self.paths.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry, path)) {
                const removed = self.paths.orderedRemove(index);
                self.allocator.free(removed);
                return;
            }
        }
    }

    pub fn getHistory(self: *const HistoryService) []const []u8 {
        return self.paths.items;
    }

    fn stacksForScope(self: *HistoryService, scope: GoScope, group_id: editor_common.GroupIdentifier, path: []const u8) !*EditorNavigationStacks {
        switch (scope) {
            .DEFAULT => return &self.default_stacks,
            .EDITOR_GROUP => {
                if (self.group_stacks.get(group_id)) |stacks| return stacks;
                const stacks = try self.allocator.create(EditorNavigationStacks);
                errdefer self.allocator.destroy(stacks);
                stacks.* = EditorNavigationStacks.init(self.allocator);
                errdefer stacks.deinit();
                try self.group_stacks.put(group_id, stacks);
                return stacks;
            },
            .EDITOR => {
                if (self.editor_stacks.get(path)) |stacks| return stacks;
                const key = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(key);
                const stacks = try self.allocator.create(EditorNavigationStacks);
                errdefer self.allocator.destroy(stacks);
                stacks.* = EditorNavigationStacks.init(self.allocator);
                errdefer stacks.deinit();
                try self.editor_stacks.put(key, stacks);
                return stacks;
            },
        }
    }

    pub fn recordNavigation(
        self: *HistoryService,
        group_id: editor_common.GroupIdentifier,
        path: []const u8,
        selection: ?editor_common.IEditorPaneSelection,
        top_view_line: usize,
        reason: editor_common.EditorPaneSelectionChangeReason,
    ) !void {
        const entry = try self.allocator.create(EditorNavigationStackEntry);
        errdefer self.allocator.destroy(entry);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        entry.* = .{ .group_id = group_id, .path = owned_path, .selection = selection, .top_view_line = top_view_line };
        const group_stacks = try self.stacksForScope(.EDITOR_GROUP, group_id, path);
        const editor_stacks = try self.stacksForScope(.EDITOR, group_id, path);
        try self.entries.append(entry);
        self.default_stacks.record(entry, reason);
        group_stacks.record(entry, reason);
        editor_stacks.record(entry, reason);
    }

    pub fn goBack(self: *HistoryService, scope: GoScope, filter: GoFilter, group_id: editor_common.GroupIdentifier, path: []const u8) ?*EditorNavigationStackEntry {
        const stacks = self.stacksForScope(scope, group_id, path) catch return null;
        return stacks.goBack(filter);
    }

    pub fn goForward(self: *HistoryService, scope: GoScope, filter: GoFilter, group_id: editor_common.GroupIdentifier, path: []const u8) ?*EditorNavigationStackEntry {
        const stacks = self.stacksForScope(scope, group_id, path) catch return null;
        return stacks.goForward(filter);
    }

    pub fn removeNavigationPath(self: *HistoryService, path: []const u8) void {
        self.default_stacks.removePath(path);
        var group_values = self.group_stacks.valueIterator();
        while (group_values.next()) |stacks| stacks.*.removePath(path);
        var editor_values = self.editor_stacks.valueIterator();
        while (editor_values.next()) |stacks| stacks.*.removePath(path);
    }

    pub fn recordClosedEditor(self: *HistoryService, closed: ClosedEditor) !void {
        if (self.closed_editors.items.len >= 20) {
            const old = self.closed_editors.orderedRemove(0);
            self.allocator.free(old.path);
        }
        try self.closed_editors.append(closed);
    }

    pub fn clear(self: *HistoryService) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.clearRetainingCapacity();
        self.default_stacks.clear();
        var group_values = self.group_stacks.valueIterator();
        while (group_values.next()) |stacks| stacks.*.clear();
        var editor_values = self.editor_stacks.valueIterator();
        while (editor_values.next()) |stacks| stacks.*.clear();
        for (self.closed_editors.items) |closed| self.allocator.free(closed.path);
        self.closed_editors.clearRetainingCapacity();
    }
};

pub const EditorNavigationStacks = struct {
    allocator: Allocator,
    selections: EditorNavigationStack,
    edits: EditorNavigationStack,
    navigations: EditorNavigationStack,

    pub fn init(allocator: Allocator) EditorNavigationStacks {
        return .{
            .allocator = allocator,
            .selections = EditorNavigationStack.init(allocator),
            .edits = EditorNavigationStack.init(allocator),
            .navigations = EditorNavigationStack.init(allocator),
        };
    }

    pub fn deinit(self: *EditorNavigationStacks) void {
        self.selections.deinit();
        self.edits.deinit();
        self.navigations.deinit();
    }

    pub fn clear(self: *EditorNavigationStacks) void {
        self.selections.clear();
        self.edits.clear();
        self.navigations.clear();
    }

    fn stackFor(self: *EditorNavigationStacks, filter: GoFilter) *EditorNavigationStack {
        return switch (filter) {
            .NONE => &self.selections,
            .EDITS => &self.edits,
            .NAVIGATION => &self.navigations,
        };
    }

    pub fn record(self: *EditorNavigationStacks, entry: *EditorNavigationStackEntry, reason: editor_common.EditorPaneSelectionChangeReason) void {
        self.selections.record(entry);
        switch (reason) {
            .EDIT => self.edits.record(entry),
            .NAVIGATION, .JUMP => self.navigations.record(entry),
            else => {},
        }
    }

    pub fn goBack(self: *EditorNavigationStacks, filter: GoFilter) ?*EditorNavigationStackEntry {
        return self.stackFor(filter).goBack();
    }

    pub fn goForward(self: *EditorNavigationStacks, filter: GoFilter) ?*EditorNavigationStackEntry {
        return self.stackFor(filter).goForward();
    }

    pub fn removePath(self: *EditorNavigationStacks, path: []const u8) void {
        self.selections.removePath(path);
        self.edits.removePath(path);
        self.navigations.removePath(path);
    }
};

test "HistoryService: most-recent-first, dedupe, remove and cap" {
    var history = HistoryService.init(std.testing.allocator);
    defer history.deinit();
    history.max = 3;

    try history.add("/a");
    try history.add("/b");
    try history.add("/a");
    try std.testing.expectEqual(@as(usize, 2), history.getHistory().len);
    try std.testing.expectEqualStrings("/a", history.getHistory()[0]);
    try std.testing.expectEqualStrings("/b", history.getHistory()[1]);

    try history.add("/c");
    try history.add("/d");
    try std.testing.expectEqual(@as(usize, 3), history.getHistory().len);
    try std.testing.expectEqualStrings("/d", history.getHistory()[0]);
    try std.testing.expectEqualStrings("/c", history.getHistory()[1]);

    history.remove("/c");
    try std.testing.expectEqual(@as(usize, 2), history.getHistory().len);
}
