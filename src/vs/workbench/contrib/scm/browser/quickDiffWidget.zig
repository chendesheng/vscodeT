// Port of `src/vs/workbench/contrib/scm/browser/quickDiffWidget.ts`.
// The retained peek view mounts an embedded editor over the live modified
// resource and the provider's original resource. Cell rows replace pixels.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../../editor/browser/editorBrowser.zig");
const editor_mod = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const views = @import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig");
const EmbeddedDiffEditorWidget = @import("../../../../editor/browser/widget/diffEditor/embeddedDiffEditorWidget.zig").EmbeddedDiffEditorWidget;
const PeekViewWidget = @import("../../../../editor/contrib/peekView/browser/peekView.zig").PeekViewWidget;
const Position = @import("../../../../editor/common/core/position.zig").Position;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const ViewEventHandler = @import("../../../../editor/common/viewEventHandler.zig").ViewEventHandler;
const events = @import("../../../../editor/common/viewEvents.zig");
const quick = @import("../common/quickDiff.zig");
const model_mod = @import("quickDiffModel.zig");
const Worker = @import("../../../../editor/browser/services/editorWorkerService.zig").EditorWorkerService;
const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const QuickInputService = @import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const menu_service = @import("../../../../platform/actions/common/menuService.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const URI = @import("../../../../base/common/uri.zig").URI;
const CommandArgument = @import("../../../../platform/commands/common/commands.zig").CommandArgument;

/// The upstream SCMChangeContext action receives modified URI, provider
/// changes and the selected provider index. The native bridge additionally
/// borrows the resolved resource models for the duration of the command.
pub const QuickDiffActionContext = struct {
    modifiedUri: std.Uri,
    originalUri: std.Uri,
    changes: []const quick.IChange,
    index: usize,
    mappings: []const model_mod.DetailedLineRangeMapping,
    all_changes: []const model_mod.QuickDiffChange,
    baselines: []const quick.QuickDiff,
    original_model: *model_mod.TextModel,
    modified_editor: *editor_mod.Editor,
};

pub const MenuHost = struct { menus: *menu_service.MenuService, parent_context: contextkey.IContext };

pub const QuickDiffWidget = struct {
    controller: *QuickDiffEditorController,
    peek: PeekViewWidget = undefined,
    embedded: ?*EmbeddedDiffEditorWidget = null,
    provider_id: []u8 = &.{},
    index: usize = 0,
    change: ?quick.IChange = null,
    actions: [3]PeekViewWidget.Action = undefined,
    listener: ?usize = null,
    child_handler: ViewEventHandler = undefined,
    child_focused: bool = false,
    reveal_pending: bool = true,
    picker: ?*Picker = null,
    menu: ?*menu_service.Menu = null,
    original_uri: []u8 = &.{},
    original_schemes: []const contextkey.ContextKeyValue = &.{},
    menu_run: ?*MenuRun = null,

    fn create(controller: *QuickDiffEditorController) !*QuickDiffWidget {
        const self = try controller.allocator.create(QuickDiffWidget);
        errdefer controller.allocator.destroy(self);
        self.* = .{ .controller = controller };
        self.actions = .{
            .{ .id = "editor.action.dirtydiff.next", .label = "Show Next Change", .glyph = "↓", .context = self, .run = next },
            .{ .id = "editor.action.dirtydiff.previous", .label = "Show Previous Change", .glyph = "↑", .context = self, .run = previous },
            .{ .id = "peekview.close", .label = "Close", .glyph = "×", .context = self, .run = close },
        };
        self.child_handler = .init(self, .{
            .onCursorStateChanged = invalidateEvent(events.ViewCursorStateChangedEvent),
            .onScrollChanged = invalidateEvent(events.ViewScrollChangedEvent),
            .onLinesChanged = invalidateEvent(events.ViewLinesChangedEvent),
            .onLinesInserted = invalidateEvent(events.ViewLinesInsertedEvent),
            .onLinesDeleted = invalidateEvent(events.ViewLinesDeletedEvent),
            .onDecorationsChanged = invalidateEvent(events.ViewDecorationsChangedEvent),
            .onTokensChanged = invalidateEvent(events.ViewTokensChangedEvent),
            .onFlushed = invalidateEvent(events.ViewFlushedEvent),
        });
        try self.peek.init(controller.allocator, controller.view, &self.actions, .{ .context = self, .layout = layoutBody, .remove = removeBody, .position = positionBody });
        if (controller.quick_input != null) self.peek.picker_action = .{ .id = "quickDiff.base.switch", .label = "Switch Quick Diff Base", .glyph = "", .context = self, .run = pickBase };
        return self;
    }

    fn destroy(self: *QuickDiffWidget) void {
        if (self.menu_run) |run| run.owner = null;
        if (self.menu) |menu| {
            menu.deinit();
            self.controller.allocator.destroy(menu);
        }
        self.controller.allocator.free(self.original_uri);
        self.freeSchemes();
        if (self.picker) |picker| {
            picker.owner = null;
            self.controller.quick_input.?.hide();
            self.picker = null;
        }
        self.peek.deinit();
        self.disposeEmbedded();
        self.controller.allocator.free(self.provider_id);
        self.controller.allocator.destroy(self);
    }

    fn disposeEmbedded(self: *QuickDiffWidget) void {
        if (self.child_focused) self.controller.view.editor.setEmbeddedFocus(null);
        if (self.embedded) |embedded| {
            if (self.listener) |id| embedded.widget.on_did_update_diff.unlisten(id);
            embedded.widget.modified_editor.removeViewEventHandler(&self.child_handler);
            embedded.destroy();
        }
        self.embedded = null;
        self.listener = null;
        self.child_focused = false;
    }

    fn invalidateEvent(comptime T: type) *const fn (*anyopaque, *const T) bool {
        return struct {
            fn handle(context: *anyopaque, _: *const T) bool {
                const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
                self.invalidate();
                return false;
            }
        }.handle;
    }

    fn invalidate(self: *QuickDiffWidget) void {
        const view = self.controller.view;
        if (self.peek.zone.zone_id) |id| view.viewZones().invalidateZoneContent(id);
        view.invalidate();
    }

    fn onDiff(_: void, self: *QuickDiffWidget) !void {
        self.reveal_pending = true;
        self.invalidate();
    }

    fn ensureEmbedded(self: *QuickDiffWidget, provider_id: []const u8, refresh: bool) !void {
        const c = self.controller;
        const original = c.model.getDiffEditorModel(provider_id) orelse return error.OriginalUnavailable;
        if (self.embedded) |embedded| {
            if (std.mem.eql(u8, self.provider_id, provider_id)) {
                if (!refresh) return;
                var current = try embedded.widget.original_editor.model.getValue(null, true);
                defer current.deinit();
                if (std.mem.eql(u8, current.items, original.original_content)) return;
            }
        }
        const uri = if (original.resource_uri) |resource| try std.Uri.parse(resource) else std.Uri{ .scheme = "vscode-quickdiff", .path = .{ .raw = c.view.editor.path }, .query = .{ .raw = provider_id } };
        const document = try editor_mod.EditorDocument.createFromText(c.allocator, c.view.editor.io, c.view.editor.path, original.original_content, uri);
        defer document.release();
        var mappings: std.ArrayList(model_mod.DetailedLineRangeMapping) = .empty;
        defer mappings.deinit(c.allocator);
        if (!c.model.ignore_trim_whitespace and c.model.changes_version_id == c.view.editor.model.getVersionId()) {
            for (c.model.all_changes.items) |change| {
                if (std.mem.eql(u8, change.provider_id, provider_id)) try mappings.append(c.allocator, change.change2);
            }
        }
        const embedded = try EmbeddedDiffEditorWidget.create(c.allocator, c.view, c.factory, document, original.ref_label, .{ .ignore_trim_whitespace = false, .render_side_by_side = false, .render_gutter_menu = false, .render_indicators = false, .render_overview_ruler = false, .render_margin_revert_icon = false, .sticky_scroll_enabled = false, .read_only = c.view.editor.isReadOnly() }, if (mappings.items.len > 0) .{ .identical = false, .quitEarly = false, .changes = mappings.items, .moves = &.{} } else null, c.worker, c.queue);
        errdefer embedded.destroy();
        const id = try embedded.widget.on_did_update_diff.listen(self, onDiff);
        errdefer embedded.widget.on_did_update_diff.unlisten(id);
        const provider_copy = try c.allocator.dupe(u8, provider_id);
        self.disposeEmbedded();
        c.allocator.free(self.provider_id);
        self.provider_id = provider_copy;
        self.embedded = embedded;
        self.listener = id;
        embedded.widget.modified_editor.addViewEventHandler(&self.child_handler);
        self.reveal_pending = true;
    }

    fn showChange(self: *QuickDiffWidget, index: usize, use_position: bool) !void {
        const c = self.controller;
        if (index >= c.model.changes.items.len) return;
        const labeled = c.model.changes.items[index];
        try self.ensureEmbedded(labeled.provider_id, !use_position);
        self.index = index;
        self.change = labeled.change;
        self.reveal_pending = true;
        try self.updateMenu();
        const indices = c.model.quick_diff_changes.get(self.provider_id) orelse return;
        const ordinal = (std.mem.indexOfScalar(usize, indices.items, index) orelse 0) + 1;
        var label: []const u8 = "";
        for (c.model.quick_diffs) |provider| if (std.mem.eql(u8, provider.id, self.provider_id)) {
            label = provider.label;
            break;
        };
        var available: usize = 0;
        for (c.model.quick_diffs) |provider| if (self.providerContainsChange(provider.id)) {
            available += 1;
        };
        const show_picker = available > 1 and c.quick_input != null;
        const suffix = if (c.model.changes.items.len == 1) "" else "s";
        const detail = if (show_picker)
            try std.fmt.allocPrint(c.allocator, "{d} of {d} change{s}", .{ ordinal, indices.items.len, suffix })
        else
            try std.fmt.allocPrint(c.allocator, "{s} - {d} of {d} change{s}", .{ label, ordinal, indices.items.len, suffix });
        try self.peek.setPickerLabel(if (show_picker) label else "");
        defer c.allocator.free(detail);
        try self.peek.setTitle(std.fs.path.basename(c.view.editor.path), detail);
        const change_type = quick.getChangeType(labeled.change);
        const rgb = quick.getChangeTypeColor(change_type);
        const color_id = switch (change_type) {
            .add => "editorGutter.addedBackground",
            .delete => "editorGutter.deletedBackground",
            .modify => "editorGutter.modifiedBackground",
        };
        self.peek.style(if (c.view.themeColors()) |colors| colors.color(color_id, rgb) else .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] });
        if (use_position or self.peek.zone.zone_id == null) {
            const position = Position.init(quick.getModifiedEndLineNumber(labeled.change), 1);
            const height = @min(quick.getChangeHeight(labeled.change) + 8, @max(3, c.view.editor.textHeight() / 3));
            try self.peek.show(position, height);
            try c.view.editor.setCursorPosition(position);
            self.setChildFocus(false);
        }
        self.invalidate();
    }

    fn freeSchemes(self: *QuickDiffWidget) void {
        for (self.original_schemes) |scheme| self.controller.allocator.free(scheme.string);
        self.controller.allocator.free(self.original_schemes);
        self.original_schemes = &.{};
    }

    fn menuContext(self: *QuickDiffWidget) contextkey.IContext {
        return .{ .context = self, .get_value = contextValue };
    }

    fn contextValue(context: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, key, "originalResource")) return .{ .string = self.original_uri };
        if (std.mem.eql(u8, key, "originalResourceScheme")) return .{ .string = if (self.embedded) |value| value.widget.original_editor.model.uri().scheme else "" };
        if (std.mem.eql(u8, key, "originalResourceSchemes")) return .{ .array = self.original_schemes };
        return if (self.controller.menu_host) |host| host.parent_context.getValue(key) else .undefined_value;
    }

    fn updateMenu(self: *QuickDiffWidget) !void {
        const host = self.controller.menu_host orelse return;
        const embedded = self.embedded orelse return;
        const a = self.controller.allocator;
        var uri = try URI.fromStd(a, embedded.widget.original_editor.model.uri());
        defer uri.deinit();
        const encoded = try uri.toStringEncoded(a);
        a.free(self.original_uri);
        self.original_uri = encoded;
        self.freeSchemes();
        var schemes: std.ArrayList(contextkey.ContextKeyValue) = .empty;
        defer schemes.deinit(a);
        errdefer for (schemes.items) |scheme| a.free(scheme.string);
        for (self.controller.model.quick_diffs) |provider| {
            const scheme = if (provider.original.resource_uri) |resource| (std.Uri.parse(resource) catch continue).scheme else "vscode-quickdiff";
            try schemes.ensureUnusedCapacity(a, 1);
            schemes.appendAssumeCapacity(.{ .string = try a.dupe(u8, scheme) });
        }
        self.original_schemes = try schemes.toOwnedSlice(a);
        if (self.menu) |menu| {
            try menu.refresh();
        } else {
            const menu = try host.menus.createMenu(a, actions.menu_ids.SCMChangeContext, self.menuContext());
            self.menu = menu;
            _ = try menu.onDidChange.listen(self, onMenuChanged);
        }
        try self.updateActions();
    }

    fn onMenuChanged(_: void, self: *QuickDiffWidget) !void {
        try self.updateActions();
    }

    fn updateActions(self: *QuickDiffWidget) !void {
        const menu = self.menu orelse return;
        var entries: std.ArrayList(PeekViewWidget.Action) = .empty;
        defer entries.deinit(self.controller.allocator);
        for (menu.getActions()) |group| for (group.actions) |action| {
            const item = menu_service.MenuItemAction.from(action) orelse continue;
            const icon = item.item.icon orelse "";
            const glyph = if (std.mem.eql(u8, icon, "add") or std.mem.eql(u8, icon, "plus")) "+" else if (std.mem.eql(u8, icon, "discard")) "↶" else if (std.mem.eql(u8, icon, "remove")) "−" else "…";
            try entries.append(self.controller.allocator, .{ .id = action.id(), .label = action.label(), .glyph = glyph, .context = self, .run = noOp, .run_with_id = runMenuItem, .enabled = action.enabled() });
        };
        // Upstream ActionBar puts menu actions in reverse order, then next,
        // previous and close. The terminal keeps the same ordering.
        std.mem.reverse(PeekViewWidget.Action, entries.items);
        try self.peek.setExtraActions(entries.items);
    }

    fn noOp(_: *anyopaque) void {}

    const MenuRun = struct { owner: ?*QuickDiffWidget };

    fn runMenuItem(context: *anyopaque, id: []const u8) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        self.runMenu(id) catch {};
    }

    fn runMenu(self: *QuickDiffWidget, id: []const u8) !void {
        const c = self.controller;
        const host = c.menu_host orelse return;
        const embedded = self.embedded orelse return;
        const allocator = c.allocator;
        if (c.model.changes_version_id != c.view.editor.model.getVersionId()) return error.StaleDiff;
        var resolved = try host.menus.getMenuActionsWithOptions(c.allocator, actions.menu_ids.SCMChangeContext, self.menuContext(), .{ .should_forward_args = true });
        defer resolved.deinit();
        var changes: std.ArrayList(quick.IChange) = .empty;
        defer changes.deinit(allocator);
        var mappings: std.ArrayList(model_mod.DetailedLineRangeMapping) = .empty;
        defer mappings.deinit(allocator);
        var selected: ?usize = null;
        for (c.model.changes.items, 0..) |change, i| {
            if (!std.mem.eql(u8, self.provider_id, change.provider_id)) continue;
            if (i == self.index) selected = changes.items.len;
            try changes.append(c.allocator, change.change);
            try mappings.append(c.allocator, change.change2);
        }
        const argument: QuickDiffActionContext = .{ .modifiedUri = c.view.editor.model.uri(), .originalUri = embedded.widget.original_editor.model.uri(), .changes = changes.items, .index = selected orelse return error.InvalidDiff, .mappings = mappings.items, .all_changes = c.model.all_changes.items, .baselines = c.model.quick_diffs, .original_model = embedded.widget.original_editor.model, .modified_editor = c.view.editor };
        for (resolved.groups) |group| for (group.actions) |action| {
            if (!std.mem.eql(u8, action.id(), id) or !action.enabled()) continue;
            const item = menu_service.MenuItemAction.from(action) orelse continue;
            var run: MenuRun = .{ .owner = self };
            self.menu_run = &run;
            const result = item.runWithArgument(CommandArgument.from(QuickDiffActionContext, &argument));
            if (run.owner) |owner| owner.menu_run = null;
            result catch |err| {
                if (run.owner) |owner| owner.controller.view.editor.setMessage("Change action failed: {s}", .{@errorName(err)});
                return;
            };
            if (run.owner) |owner| owner.controller.close();
            return;
        };
    }

    fn providerContainsChange(self: *QuickDiffWidget, id: []const u8) bool {
        const model = self.controller.model;
        if (!model.service.isQuickDiffProviderVisible(id) or self.index >= model.changes.items.len) return false;
        const range = model.changes.items[self.index].change2.modified;
        for (model.changes.items) |change| {
            if (std.mem.eql(u8, change.provider_id, id) and range.intersectsOrTouches(change.change2.modified)) return true;
        }
        return false;
    }

    fn switchQuickDiff(self: *QuickDiffWidget, new_provider: []const u8) !void {
        if (std.mem.eql(u8, self.provider_id, new_provider)) return;
        const changes = self.controller.model.changes.items;
        if (self.index >= changes.len or !self.providerContainsChange(new_provider)) return;
        var lesser: ?usize = null;
        var greater: ?usize = null;
        for (1..changes.len) |distance| {
            const forward = (self.index + distance) % changes.len;
            const backward = (self.index + changes.len - distance) % changes.len;
            if (greater == null and std.mem.eql(u8, changes[forward].provider_id, new_provider)) greater = forward;
            if (lesser == null and std.mem.eql(u8, changes[backward].provider_id, new_provider)) lesser = backward;
            if (greater != null and lesser != null) break;
        }
        const high = greater orelse return;
        const low = lesser orelse return;
        const line = quick.getModifiedEndLineNumber(changes[self.index].change);
        const high_line = quick.getModifiedEndLineNumber(changes[high].change);
        const low_line = quick.getModifiedEndLineNumber(changes[low].change);
        const high_distance = @max(line, high_line) - @min(line, high_line);
        const low_distance = @max(line, low_line) - @min(line, low_line);
        try self.showChange(if (high_distance < low_distance) high else low, false);
    }

    const Picker = struct {
        owner: ?*QuickDiffWidget,
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        fn dispose(self: *Picker) void {
            self.arena.deinit();
            self.allocator.destroy(self);
        }
        fn selected(context: *anyopaque, item: ?*const quick_input.Item) !void {
            const self: *Picker = @ptrCast(@alignCast(context));
            defer self.dispose();
            const owner = self.owner orelse return;
            owner.picker = null;
            if (item) |choice| try owner.switchQuickDiff(choice.id);
        }
    };

    fn pickBase(context: *anyopaque) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        self.showPicker() catch {};
    }

    fn showPicker(self: *QuickDiffWidget) !void {
        const service = self.controller.quick_input orelse return;
        if (self.picker != null) return;
        const a = self.controller.allocator;
        const session = try a.create(Picker);
        session.* = .{ .owner = self, .allocator = a, .arena = .init(a) };
        var adopted = false;
        defer if (!adopted) session.dispose();
        const arena = session.arena.allocator();
        var items: std.ArrayList(quick_input.QuickPickItem) = .empty;
        for (self.controller.model.quick_diffs) |provider| {
            if (!self.providerContainsChange(provider.id)) continue;
            try items.append(arena, .{ .item = .{ .id = try arena.dupe(u8, provider.id), .label = try arena.dupe(u8, provider.label) } });
        }
        if (items.items.len < 2) return;
        self.picker = session;
        errdefer self.picker = null;
        try service.pick(items.items, .{ .placeholder = "Switch Quick Diff Base", .active_id = self.provider_id }, Picker.selected, session);
        adopted = true;
    }

    fn layoutBody(context: *anyopaque, node: *ui.Node, info: browser.IViewZone.RenderInfo, rows: usize) !void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        const embedded = self.embedded orelse return;
        const parent = self.controller.view;
        const origin = parent.surfaceContext();
        const y = @as(f64, @floatFromInt(origin.y + parent.editor.top_inset_rows + 1)) + info.viewport_top;
        if (self.reveal_pending) {
            embedded.widget.layout(info.width, rows);
            self.reveal_pending = false;
            if (self.change) |change| {
                const start = if (change.modifiedEndLineNumber == 0 or change.originalEndLineNumber == 0) change.modifiedStartLineNumber else change.modifiedStartLineNumber -| 1;
                const end = if (change.modifiedEndLineNumber == 0) change.modifiedStartLineNumber + 1 else if (change.originalEndLineNumber > 0) change.modifiedEndLineNumber + 1 else change.modifiedEndLineNumber;
                const child = embedded.widget.modified_editor;
                _ = child.revealRange(Range.init(@max(start, 1), 1, @min(@max(end, 1), child.model.getLineCount()), 1), .Center);
            }
        }
        try embedded.mount(node, origin.x + info.left, @intFromFloat(@max(0, y)), info.width, rows);
    }

    fn removeBody(context: *anyopaque) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        if (self.embedded) |embedded| embedded.unmount();
    }

    fn positionBody(context: *anyopaque, top: f64) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        const embedded = self.embedded orelse return;
        const body = self.peek.body orelse return;
        if (top < -100000 or !embedded.widget.modified_view.isMounted()) return;
        const parent = self.controller.view;
        const origin = parent.surfaceContext();
        const y = @as(f64, @floatFromInt(origin.y + parent.editor.top_inset_rows + 1)) + top;
        embedded.widget.mount(origin.surface, body, origin.x + self.peek.zone.left, @intFromFloat(@max(0, y))) catch {};
    }

    fn setChildFocus(self: *QuickDiffWidget, focused: bool) void {
        const embedded = self.embedded orelse return;
        self.child_focused = focused;
        self.controller.view.editor.setEmbeddedFocus(if (focused) .{ .view = embedded.widget.modified_view, .diff = embedded.widget.interface() } else null);
        embedded.widget.setEditorFocused(focused);
        if (focused) {
            embedded.widget.modified_view.focusEditor();
        } else self.controller.view.focusEditor();
        self.invalidate();
    }

    fn next(context: *anyopaque) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        self.controller.navigate(true, null) catch {};
    }
    fn previous(context: *anyopaque) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        self.controller.navigate(false, null) catch {};
    }
    fn close(context: *anyopaque) void {
        const self: *QuickDiffWidget = @ptrCast(@alignCast(context));
        self.controller.close();
    }
};

pub const QuickDiffEditorController = struct {
    pub const ID = "editor.contrib.quickdiff";
    allocator: std.mem.Allocator,
    view: *views.IEditorView,
    model: *model_mod.QuickDiffModel,
    factory: views.EditorViewFactory,
    worker: *Worker,
    queue: *Queue,
    quick_input: ?*QuickInputService = null,
    menu_host: ?MenuHost = null,
    widget: ?*QuickDiffWidget = null,
    mouse_listener: usize = undefined,
    key_listener: usize = undefined,
    model_listener: usize = undefined,
    mouse_down_line: ?usize = null,
    gutter_action: bool = true,

    pub fn create(allocator: std.mem.Allocator, view: *views.IEditorView, model: *model_mod.QuickDiffModel, factory: views.EditorViewFactory, worker: *Worker, queue: *Queue) !*QuickDiffEditorController {
        const self = try allocator.create(QuickDiffEditorController);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .view = view, .model = model, .factory = factory, .worker = worker, .queue = queue };
        try view.editor.registerContribution(QuickDiffEditorController, self);
        errdefer view.editor.unregisterContribution(QuickDiffEditorController, self);
        self.mouse_listener = try view.editor.on_did_mouse_event.listen(self, onMouse);
        errdefer view.editor.on_did_mouse_event.unlisten(self.mouse_listener);
        self.key_listener = try view.editor.on_did_key_down.listen(self, onKey);
        errdefer view.editor.on_did_key_down.unlisten(self.key_listener);
        self.model_listener = try model.on_did_change.listen(self, onModelChange);
        return self;
    }

    pub fn destroy(self: *QuickDiffEditorController) void {
        self.close();
        self.model.on_did_change.unlisten(self.model_listener);
        self.view.editor.on_did_key_down.unlisten(self.key_listener);
        self.view.editor.on_did_mouse_event.unlisten(self.mouse_listener);
        self.view.editor.unregisterContribution(QuickDiffEditorController, self);
        self.allocator.destroy(self);
    }

    pub fn close(self: *QuickDiffEditorController) void {
        if (self.widget) |widget| {
            self.widget = null;
            widget.destroy();
            self.view.editor.setDirtyDiffVisible(false);
            self.view.focusEditor();
        }
    }

    pub fn navigate(self: *QuickDiffEditorController, forward: bool, line: ?usize) !void {
        if (self.model.changes.items.len == 0) {
            self.close();
            return;
        }
        const widget = self.widget orelse blk: {
            const created = try QuickDiffWidget.create(self);
            self.widget = created;
            self.view.editor.setDirtyDiffVisible(true);
            break :blk created;
        };
        const provider = if (widget.provider_id.len != 0) widget.provider_id else null;
        const index = if (line != null or provider == null) blk: {
            const at = line orelse self.view.editor.modelCursorPosition().lineNumber;
            break :blk if (forward) self.model.findNextClosestChange(at, true, provider) else self.model.findPreviousClosestChange(at, true, provider);
        } else blk: {
            const indices = self.model.quick_diff_changes.get(provider.?) orelse break :blk 0;
            if (indices.items.len == 0) break :blk 0;
            const old = std.mem.indexOfScalar(usize, indices.items, widget.index) orelse if (forward) indices.items.len - 1 else 0;
            break :blk indices.items[if (forward) (old + 1) % indices.items.len else (old + indices.items.len - 1) % indices.items.len];
        };
        widget.showChange(index, true) catch |err| {
            self.close();
            return err;
        };
    }

    pub fn toggleFocus(self: *QuickDiffEditorController) void {
        if (self.widget) |widget| widget.setChildFocus(!widget.child_focused);
    }

    fn onModelChange(_: void, self: *QuickDiffEditorController) !void {
        const widget = self.widget orelse return;
        if (self.model.changes.items.len == 0) {
            self.close();
            return;
        }
        if (widget.child_focused) return;
        if (self.model.getDiffEditorModel(widget.provider_id) != null) try widget.ensureEmbedded(widget.provider_id, true);
        if (widget.index >= self.model.changes.items.len or !std.mem.eql(u8, widget.provider_id, self.model.changes.items[widget.index].provider_id) or quick.compareChanges(widget.change.?, self.model.changes.items[widget.index].change) != 0) {
            try self.navigate(true, null);
        } else try widget.showChange(widget.index, false);
    }

    fn onKey(event: *ui.KeyEvent, self: *QuickDiffEditorController) !void {
        const widget = self.widget orelse return;
        if (event.key == .escape and !event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
            self.close();
            event.preventDefault();
        } else if (widget.child_focused) {
            if (widget.embedded) |embedded| _ = embedded.widget.dispatchKey(event);
            widget.invalidate();
            event.preventDefault();
        }
    }

    fn onMouse(value: browser.EditorMouseEvent, self: *QuickDiffEditorController) !void {
        const event = value.event;
        if (self.widget) |widget| {
            var local = event.*;
            local.y -|= self.view.editor.top_inset_rows;
            if (try widget.peek.zone.handleResize(&local)) {
                event.preventDefault();
                return;
            }
            if (widget.peek.zone.relativeRow(local.x, local.y)) |row| {
                if (row > 0 and row + 1 < widget.peek.zone.height) {
                    if (widget.embedded) |embedded| {
                        local.x -= widget.peek.zone.left;
                        local.y = row - 1;
                        if (event.kind == .down) widget.setChildFocus(true);
                        _ = try embedded.widget.dispatchMouse(&local);
                        widget.invalidate();
                        event.preventDefault();
                        return;
                    }
                }
            } else if (event.kind == .down and widget.child_focused) widget.setChildFocus(false);
        }
        if (!self.gutter_action or self.view.editor.lineDecorationsWidth() == 0) return;
        if (event.kind == .down) {
            self.mouse_down_line = null;
            if (event.button != .left or event.x != self.view.editor.quickDiffCellColumn() or value.target.type != .gutter_line_decorations) return;
            const range = value.target.range orelse return;
            for (self.model.changes.items) |change| if (quick.lineIntersectsChange(range.startLineNumber, change.change)) {
                self.mouse_down_line = range.startLineNumber;
                event.preventDefault();
                break;
            };
        } else if (event.kind == .up) {
            const line = self.mouse_down_line orelse return;
            self.mouse_down_line = null;
            if (event.button != .left or event.x != self.view.editor.quickDiffCellColumn() or value.target.type != .gutter_line_decorations or (value.target.range orelse return).startLineNumber != line) return;
            for (self.model.changes.items, 0..) |change, index| if (quick.lineIntersectsChange(line, change.change)) {
                if (self.widget != null and self.widget.?.index == index) self.close() else try self.navigate(true, line);
                event.preventDefault();
                break;
            };
        }
    }
};

const actions = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const code_editor_service = @import("../../../../editor/browser/services/codeEditorService.zig");
const BindingWeight = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight;
const weight = @backingInt(BindingWeight.EditorContrib);
const not_compare = Expr{ .Not = "textCompareEditorActive" };
const has_changes = Expr{ .NotEquals = .{ .key = "quickDiffDecorationCount", .value = .{ .number = 0 } } };
const can_goto = Expr{ .And = @constCast(&[_]*const Expr{ &not_compare, &has_changes }) };
const text_focus = Expr{ .Defined = "editorTextFocus" };
const visible = Expr{ .Defined = "dirtyDiffVisible" };

pub const editor_actions = [_]actions.Action2{
    navigationAction("editor.action.dirtydiff.previous", "Show Previous Change", false, false),
    navigationAction("editor.action.dirtydiff.next", "Show Next Change", true, false),
    navigationAction("workbench.action.editor.previousChange", "Go to Previous Change", false, true),
    navigationAction("workbench.action.editor.nextChange", "Go to Next Change", true, true),
};

pub const widget_actions = [_]actions.Action2{
    .{ .command = .{ .id = "closeQuickDiff", .title = "Close Quick Diff" }, .keybindings = &.{.{ .id = "closeQuickDiff", .weight = weight + 50, .when = &visible, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape), .secondary = &.{keys.KeyMod.Shift | @backingInt(keys.KeyCode.Escape)} } }}, .context = @constCast(&{}), .run_fn = struct {
        fn run(_: *anyopaque, accessor: Accessor) !void {
            if (try getController(accessor)) |controller| controller.close();
        }
    }.run },
    .{ .command = .{ .id = "toggleQuickDiffWidgetFocus", .title = "Toggle Quick Diff Widget Focus" }, .keybindings = &.{.{ .id = "toggleQuickDiffWidgetFocus", .weight = weight, .when = &visible, .bindings = .{ .primary = keys.KeyChord(keys.KeyMod.CtrlCmd | @backingInt(keys.KeyCode.KeyK), @backingInt(keys.KeyCode.F2)) } }}, .context = @constCast(&{}), .run_fn = struct {
        fn run(_: *anyopaque, accessor: Accessor) !void {
            if (try getController(accessor)) |controller| controller.toggleFocus();
        }
    }.run },
};

fn getController(accessor: Accessor) !?*QuickDiffEditorController {
    const service = try accessor.get(code_editor_service.code_editor_service_id);
    const editor = service.getFocusedCodeEditor() orelse service.getActiveCodeEditor() orelse return null;
    return editor.getContribution(QuickDiffEditorController) orelse if (service.getActiveCodeEditor()) |outer| outer.getContribution(QuickDiffEditorController) else null;
}

fn navigationAction(comptime id: []const u8, title: []const u8, comptime forward: bool, comptime goto: bool) actions.Action2 {
    const code: keys.KeyCode = if (goto) .F5 else .F3;
    const mods = keys.KeyMod.Alt | if (forward) 0 else keys.KeyMod.Shift;
    return .{
        .command = .{ .id = id, .title = title, .precondition = if (goto) &can_goto else &not_compare },
        .f1 = true,
        .keybindings = &.{.{ .id = id, .weight = weight, .when = &text_focus, .bindings = .{ .primary = mods | @backingInt(code) } }},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: Accessor) !void {
                const controller = try getController(accessor) orelse return;
                if (goto) {
                    if (controller.model.changes.items.len == 0) return;
                    const editor = controller.view.editor;
                    const line = editor.modelCursorPosition().lineNumber;
                    const index = if (forward) controller.model.findNextClosestChange(line, false, null) else controller.model.findPreviousClosestChange(line, false, null);
                    const new_line = @max(1, controller.model.changes.items[index].change.modifiedStartLineNumber);
                    try editor.setCursorPosition(Position.init(new_line, 1));
                    _ = editor.revealLine(new_line, .Center);
                } else {
                    if (controller.widget == null or controller.model.changes.items.len > 1) try controller.navigate(forward, null);
                }
            }
        }.run,
    };
}

pub fn registerGoMenu(registry: *actions.MenuRegistry) !void {
    try registry.appendMenuItem(actions.menu_ids.MenubarGoMenu, .{ .command = .{ .id = "editor.action.dirtydiff.next", .title = "Next &&Change" }, .group = "7_change_nav", .order = 1 });
    try registry.appendMenuItem(actions.menu_ids.MenubarGoMenu, .{ .command = .{ .id = "editor.action.dirtydiff.previous", .title = "Previous &&Change" }, .group = "7_change_nav", .order = 2 });
}
