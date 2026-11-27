// Port of `src/vs/workbench/contrib/bulkEdit/browser/preview/bulkEdit.contribution.ts`.
// The preview handler opens the registered view, owns one session's previous
// panel state, and closes its transient multi-diff editors through IEditorService.
const std = @import("std");
const bulk = @import("../../../../../editor/browser/services/bulkEditService.zig");
const views = @import("../../../../common/views.zig");
const views_service = @import("../../../../services/views/common/viewsService.zig");
const panes = @import("../../../../services/panecomposite/browser/panecomposite.zig");
const layout = @import("../../../../services/layout/browser/layoutService.zig");
const editor_service = @import("../../../../services/editor/common/editorService.zig");
const dialogs = @import("../../../../../platform/dialogs/common/dialogs.zig");
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
const actions = @import("../../../../../platform/actions/common/actions.zig");
const contexts = @import("../../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../../base/common/keyCodes.zig");
const weights = @import("../../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight;
const view_action = @import("../../../../browser/parts/views/viewPane.zig").viewAction;
const BulkEditPane = @import("bulkEditPane.zig").BulkEditPane;

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{ .id = BulkEditPane.ID, .title = "Refactor Preview", .glyph = '≋', .hide_if_empty = true, .order = 100 }, .panel, .{});
}

pub const BulkEditPreviewContribution = struct {
    pub const ID = "workbench.contrib.bulkEditPreview";
    allocator: std.mem.Allocator,
    views_service: views_service.IViewsService,
    panes: panes.IPaneCompositePartService,
    layout: layout.IWorkbenchLayoutService,
    editors: editor_service.IEditorService,
    dialogs: dialogs.IDialogService,
    registration: ?Disposable = null,
    previous_panel: ?[]u8 = null,
    active: bool = false,
    preserve_panel: bool = false,

    pub fn register(self: *BulkEditPreviewContribution, service: bulk.IBulkEditService) !void {
        if (self.registration == null) self.registration = try service.setPreviewHandler(.{ .context = self, .preview = showPreview });
    }
    pub fn deinit(self: *BulkEditPreviewContribution) void {
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
        if (self.previous_panel) |id| self.allocator.free(id);
        self.previous_panel = null;
        self.active = false;
    }
    fn showPreview(context: *anyopaque, edits: []const bulk.ResourceEdit, _: bulk.IBulkEditOptions, listener: bulk.PreviewListener) !?Disposable {
        const self: *BulkEditPreviewContribution = @ptrCast(@alignCast(context));
        if (self.views_service.getViewWithId(BulkEditPane)) |view| if (view.hasInput()) return Overlap.start(self, view, edits, listener);
        return self.begin(edits, listener);
    }
    fn begin(self: *BulkEditPreviewContribution, edits: []const bulk.ResourceEdit, listener: bulk.PreviewListener) !?Disposable {
        if (!self.active) {
            if (self.layout.isVisible(.panel)) if (self.panes.getActivePaneComposite(.panel)) |panel| {
                self.previous_panel = try self.allocator.dupe(u8, panel.id);
            };
            self.active = true;
        }
        errdefer self.restore();
        const pane = (try self.views_service.openView(BulkEditPane, true)) orelse {
            self.restore();
            listener.complete(listener.context, edits);
            return null;
        };
        return try pane.setInput(edits, listener);
    }

    pub fn onPaneFinished(self: *BulkEditPreviewContribution) void {
        self.closePreviewEditors();
        if (!self.preserve_panel) self.restore();
    }
    fn restore(self: *BulkEditPreviewContribution) void {
        if (!self.active) return;
        self.active = false;
        const previous = self.previous_panel;
        self.previous_panel = null;
        defer if (previous) |id| self.allocator.free(id);
        if (previous) |id| {
            _ = self.panes.openPaneComposite(id, .panel, false) catch false;
        } else self.layout.setPartHidden(true, .panel) catch {};
    }
    fn closePreviewEditors(self: *BulkEditPreviewContribution) void {
        const opened = self.editors.getEditors(self.allocator) catch return;
        defer self.allocator.free(opened);
        for (opened) |entry| {
            const resource = entry.editor.resource orelse continue;
            const uri = std.Uri.parse(resource) catch continue;
            if (!std.mem.eql(u8, uri.scheme, BulkEditPane.Schema)) continue;
            self.editors.requestCloseEditor(entry.group_id, entry.editor, true) catch {};
        }
    }

    const Overlap = struct {
        owner: *BulkEditPreviewContribution,
        allocator: std.mem.Allocator,
        previous: *BulkEditPane,
        edits: []const bulk.ResourceEdit,
        listener: bulk.PreviewListener,
        dialog: ?dialogs.IDialogHandle = null,
        inner: ?Disposable = null,
        depth: usize = 0,
        completed: bool = false,
        detached: bool = false,

        fn start(owner: *BulkEditPreviewContribution, previous: *BulkEditPane, edits: []const bulk.ResourceEdit, listener: bulk.PreviewListener) !?Disposable {
            const self = try owner.allocator.create(Overlap);
            self.* = .{ .owner = owner, .allocator = owner.allocator, .previous = previous, .edits = edits, .listener = listener };
            errdefer owner.allocator.destroy(self);
            self.dialog = try owner.dialogs.confirm(.{ .message = "Another refactoring is being previewed.", .detail = "Press 'Continue' to discard the previous refactoring and continue with the current refactoring.", .primary_button = "Continue" }, .{ .context = self, .complete = confirmed });
            return Disposable.from(Overlap, self, cancel);
        }
        fn confirmed(context: *anyopaque, result: dialogs.IConfirmationResult) void {
            const self: *Overlap = @ptrCast(@alignCast(context));
            if (self.completed) return;
            self.dialog = null;
            self.depth += 1;
            defer self.leave();
            if (!result.confirmed) {
                self.finish(&.{});
                return;
            }
            self.owner.preserve_panel = true;
            self.previous.discard();
            self.owner.preserve_panel = false;
            self.inner = self.owner.begin(self.edits, .{ .context = self, .complete = completedPreview }) catch |err| {
                self.finish(err);
                return;
            };
        }
        fn completedPreview(context: *anyopaque, value: anyerror![]const bulk.ResourceEdit) void {
            const self: *Overlap = @ptrCast(@alignCast(context));
            self.inner = null;
            self.finish(value);
        }
        fn finish(self: *Overlap, value: anyerror![]const bulk.ResourceEdit) void {
            if (self.completed) return;
            self.completed = true;
            const listener = self.listener;
            const notify = !self.detached;
            if (self.depth == 0) self.allocator.destroy(self);
            if (notify) listener.complete(listener.context, value);
        }
        fn leave(self: *Overlap) void {
            self.depth -= 1;
            if (self.depth == 0 and self.completed) self.allocator.destroy(self);
        }
        fn cancel(self: *Overlap) void {
            if (self.completed) return;
            self.depth += 1;
            defer self.leave();
            self.completed = true;
            self.detached = true;
            if (self.dialog) |handle| handle.cancel();
            if (self.inner) |handle| handle.dispose();
        }
    };
};

const enabled = contexts.Expr{ .Defined = "refactorPreview.enabled" };
const checked = contexts.Expr{ .Defined = "refactorPreview.hasCheckedChanges" };
const categories = contexts.Expr{ .Defined = "refactorPreview.hasCategories" };
const by_file = contexts.Expr{ .Defined = "refactorPreview.groupByFile" };
const by_type = contexts.Expr{ .Not = "refactorPreview.groupByFile" };
const can_apply = contexts.Expr{ .And = @constCast(&[_]*const contexts.Expr{ &enabled, &checked }) };
const can_group_file = contexts.Expr{ .And = @constCast(&[_]*const contexts.Expr{ &enabled, &categories, &by_type }) };
const can_group_type = contexts.Expr{ .And = @constCast(&[_]*const contexts.Expr{ &enabled, &categories, &by_file }) };
const focused_view = contexts.Expr{ .Equals = .{ .key = "focusedView", .value = .{ .string = BulkEditPane.ID } } };
const apply_focus = contexts.Expr{ .And = @constCast(&[_]*const contexts.Expr{ &enabled, &focused_view }) };
const list_focus = contexts.Expr{ .Defined = "listFocus" };

pub const view_actions = [_]actions.Action2{
    make("refactorPreview.apply", "Apply Refactoring", "check", &can_apply, BulkEditPane.accept, &.{.{ .id = actions.menu_ids.BulkEditContext, .order = 1 }}, keys.KeyMod.CtrlCmd | @backingInt(keys.KeyCode.Enter), &apply_focus, @backingInt(weights.EditorContrib) - 10),
    make("refactorPreview.discard", "Discard Refactoring", "clear-all", &enabled, BulkEditPane.discard, &.{.{ .id = actions.menu_ids.BulkEditContext, .order = 2 }}, null, null, 0),
    make("refactorPreview.toggleCheckedState", "Toggle Change", null, &enabled, BulkEditPane.toggleChecked, &.{.{ .id = actions.menu_ids.BulkEditContext, .group = "navigation" }}, @backingInt(keys.KeyCode.Space), &list_focus, @backingInt(weights.WorkbenchContrib)),
    make("refactorPreview.groupByFile", "Group Changes By File", "ungroup-by-ref-type", &can_group_file, BulkEditPane.groupByFile, &.{.{ .id = actions.menu_ids.BulkEditTitle, .group = "navigation", .order = 3, .when = &can_group_file }}, null, null, 0),
    make("refactorPreview.groupByType", "Group Changes By Type", "group-by-ref-type", &can_group_type, BulkEditPane.groupByType, &.{.{ .id = actions.menu_ids.BulkEditTitle, .group = "navigation", .order = 3, .when = &can_group_type }}, null, null, 0),
};
fn make(comptime id: []const u8, comptime title: []const u8, comptime icon: ?[]const u8, comptime condition: *const contexts.Expr, comptime run: anytype, comptime menus: []const actions.MenuRegistration, comptime key: ?u32, comptime when: ?*const contexts.Expr, comptime weight: i64) actions.Action2 {
    var action = view_action(BulkEditPane, .active, .{ .id = id, .title = title, .category = "Refactor Preview", .icon = icon, .precondition = condition }, false, run, .{});
    action.menus = menus;
    if (key) |primary| action.keybindings = &.{.{ .id = id, .weight = weight, .when = when, .bindings = .{ .primary = primary } }};
    return action;
}
