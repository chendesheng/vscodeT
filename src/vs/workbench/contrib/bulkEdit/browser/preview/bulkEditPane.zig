// Port of `src/vs/workbench/contrib/bulkEdit/browser/preview/bulkEditPane.ts`.
// The shared ObjectTree/List paints the native panel; model selection and
// checked-state changes remain owned by the preview session.
const std = @import("std");
const ui = @import("ui");
const preview = @import("bulkEditPreview.zig");
const tree = @import("bulkEditTree.zig");
const bulk = @import("../../../../../editor/browser/services/bulkEditService.zig");
const models = @import("../../../../../editor/common/services/modelService.zig");
const resolver = @import("../../../../../editor/common/services/resolverService.zig");
const files = @import("../../../../../platform/files/common/files.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
const contextkey = @import("../../../../../platform/contextkey/common/contextkey.zig");
const editor_service = @import("../../../../services/editor/common/editorService.zig");
const storage = @import("../../../../../platform/storage/common/storage.zig");
const dialogs = @import("../../../../../platform/dialogs/common/dialogs.zig");
const ThemeColors = @import("../../../../browser/themeColors.zig").ThemeColors;
const Allocator = std.mem.Allocator;

pub const BulkEditPane = struct {
    pub const ID = "refactorPreview";
    pub const Schema = "vscode-bulkeditpreview-multieditor";
    pub const Host = struct {
        context: *anyopaque,
        changed: *const fn (*anyopaque) void,
        finished: *const fn (*anyopaque) void,
    };
    pub const Services = struct {
        files: files.IFileService,
        models: models.IModelService,
        text: resolver.ITextModelService,
        editors: editor_service.IEditorService,
        window: *dispatch.Queue,
        dialogs: dialogs.IDialogService,
        storage: ?storage.IStorageService = null,
    };
    allocator: Allocator,
    services: Services,
    host: Host,
    session: ?*Session = null,
    group_by_file: bool = true,
    focused: bool = false,
    status: []const u8 = "",
    context_enabled: ?contextkey.IContextKey = null,
    context_categories: ?contextkey.IContextKey = null,
    context_checked: ?contextkey.IContextKey = null,
    context_grouping: ?contextkey.IContextKey = null,
    last_rect: ui.Rect = .{},

    const Session = struct {
        owner: *BulkEditPane,
        listener: bulk.PreviewListener,
        operations: *preview.BulkFileOperations,
        provider: *preview.BulkEditPreviewProvider,
        tree_view: ?*tree.BulkEditTree = null,
        ready_listener: ?usize = null,
        checked_listener: ?usize = null,
        conflict_dialog: ?dialogs.IDialogHandle = null,
        fn dispose(self: *Session) void {
            if (self.conflict_dialog) |handle| handle.cancel();
            if (self.ready_listener) |id| self.provider.on_did_ready.unlisten(id);
            if (self.checked_listener) |id| self.operations.checked.on_did_change.unlisten(id);
            if (self.tree_view) |value| value.dispose();
            self.provider.dispose();
            self.operations.dispose();
            self.owner.allocator.destroy(self);
        }
        fn cancel(self: *Session) void {
            if (self.owner.session == self) self.owner.finish(false, false);
        }
        fn ready(_: void, self: *Session) !void {
            self.owner.createTree(self);
        }
        fn checked(_: usize, self: *Session) !void {
            self.owner.updateContexts();
            self.owner.host.changed(self.owner.host.context);
        }
        fn conflictClosed(context: *anyopaque, _: ?usize) void {
            const self: *Session = @ptrCast(@alignCast(context));
            self.conflict_dialog = null;
            self.owner.finish(false, true);
        }
    };

    pub fn init(a: Allocator, services: Services, host: Host) BulkEditPane {
        const grouping = if (services.storage) |value| if (value.get("refactorPreview.groupByFile", .profile, null)) |stored| !std.mem.eql(u8, stored, "false") else true else true;
        return .{ .allocator = a, .services = services, .host = host, .group_by_file = grouping };
    }
    pub fn deinit(self: *BulkEditPane) void {
        self.finish(false, true);
        for ([_]?contextkey.IContextKey{ self.context_enabled, self.context_categories, self.context_checked, self.context_grouping }) |key| if (key) |value| value.dispose();
    }
    pub fn bindContextKeys(self: *BulkEditPane, service: contextkey.IContextKeyService) !void {
        self.context_enabled = try service.createKey("refactorPreview.enabled", .{ .boolean = false });
        self.context_categories = try service.createKey("refactorPreview.hasCategories", .{ .boolean = false });
        self.context_checked = try service.createKey("refactorPreview.hasCheckedChanges", .{ .boolean = false });
        self.context_grouping = try service.createKey("refactorPreview.groupByFile", .{ .boolean = self.group_by_file });
        self.updateContexts();
    }
    fn updateContexts(self: *BulkEditPane) void {
        const session = self.session;
        if (self.context_enabled) |key| key.set(.{ .boolean = session != null });
        if (self.context_categories) |key| key.set(.{ .boolean = if (session) |value| value.operations.categories.items.len > 1 else false });
        if (self.context_checked) |key| key.set(.{ .boolean = if (session) |value| value.operations.checked.checked_count > 0 else false });
        if (self.context_grouping) |key| key.set(.{ .boolean = self.group_by_file });
    }
    pub fn setFocus(self: *BulkEditPane, focused: bool) void {
        self.focused = focused;
        if (self.session) |session| if (session.tree_view) |view| view.setFocus(focused);
    }
    pub fn hasInput(self: *const BulkEditPane) bool {
        return self.session != null;
    }

    pub fn setInput(self: *BulkEditPane, edits: []const bulk.ResourceEdit, listener: bulk.PreviewListener) !Disposable {
        if (self.session != null) return error.PreviewAlreadyActive;
        const operations = try preview.BulkFileOperations.create(self.allocator, self.services.files, self.services.models, edits);
        errdefer operations.dispose();
        const provider = try preview.BulkEditPreviewProvider.create(self.allocator, operations, self.services.text, self.services.models, self.services.window);
        errdefer provider.dispose();
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{ .owner = self, .listener = listener, .operations = operations, .provider = provider };
        session.ready_listener = try provider.on_did_ready.listen(session, Session.ready);
        errdefer provider.on_did_ready.unlisten(session.ready_listener.?);
        session.checked_listener = try operations.checked.on_did_change.listen(session, Session.checked);
        self.session = session;
        self.status = "Loading refactoring preview...";
        if (operations.categories.items.len < 2) self.group_by_file = true;
        self.updateContexts();
        if (provider.remaining == 0) self.createTree(session);
        self.host.changed(self.host.context);
        return Disposable.from(Session, session, Session.cancel);
    }
    fn createTree(self: *BulkEditPane, session: *Session) void {
        if (self.session != session or session.tree_view != null) return;
        if (!session.provider.ready) {
            self.status = "Unable to prepare refactoring preview";
        } else {
            session.tree_view = tree.BulkEditTree.create(self.allocator, session.operations, self.services.models, self.group_by_file) catch {
                self.status = "Unable to prepare refactoring preview";
                self.host.changed(self.host.context);
                return;
            };
            session.tree_view.?.setActivateHandler(self, activate);
            session.tree_view.?.setFocus(self.focused);
            self.status = "";
        }
        self.host.changed(self.host.context);
    }
    pub fn accept(self: *BulkEditPane) !void {
        const session = self.session orelse return;
        if (session.provider.failure != null) return;
        if (session.operations.checked.checked_count == 0) return;
        if (session.operations.conflicts) |conflicts| if (conflicts.hasConflicts()) {
            if (session.conflict_dialog != null) return;
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const message = if (conflicts.list().len == 1) try std.fmt.allocPrint(a, "Cannot apply refactoring because '{s}' has changed in the meantime.", .{try @import("../../../../../base/common/stdUri.zig").fsPath(conflicts.list()[0], a)}) else try std.fmt.allocPrint(a, "Cannot apply refactoring because {d} other files have changed in the meantime.", .{conflicts.list().len});
            session.conflict_dialog = try self.services.dialogs.prompt(.{ .message = message, .buttons = &.{"OK"}, .severity = .Warning }, .{ .context = session, .complete = Session.conflictClosed });
            return;
        };
        self.finish(true, true);
    }
    pub fn discard(self: *BulkEditPane) void {
        self.finish(false, true);
    }
    fn finish(self: *BulkEditPane, accepted: bool, notify: bool) void {
        const session = self.session orelse return;
        self.session = null;
        const allocator = self.allocator;
        const listener = session.listener;
        const selection: preview.BulkFileOperations.WorkspaceSelection = if (accepted) session.operations.getWorkspaceEdit(allocator) catch .{ .edits = &.{}, .owned = false } else .{ .edits = &.{}, .owned = false };
        self.updateContexts();
        self.host.finished(self.host.context);
        session.dispose();
        self.host.changed(self.host.context);
        if (notify) listener.complete(listener.context, selection.edits);
        if (selection.owned) allocator.free(selection.edits);
    }
    pub fn toggleChecked(self: *BulkEditPane) void {
        if (self.session) |session| if (session.tree_view) |value| value.toggleChecked();
    }
    pub fn groupByFile(self: *BulkEditPane) !void {
        try self.setGrouping(true);
    }
    pub fn groupByType(self: *BulkEditPane) !void {
        try self.setGrouping(false);
    }
    fn setGrouping(self: *BulkEditPane, by_file: bool) !void {
        if (self.group_by_file == by_file) return;
        self.group_by_file = by_file;
        if (self.session) |session| if (session.tree_view) |value| try value.setGrouping(by_file);
        if (self.services.storage) |service| try service.store("refactorPreview.groupByFile", .{ .boolean = by_file }, .profile, .user);
        self.updateContexts();
        self.host.changed(self.host.context);
    }
    fn activate(context: ?*anyopaque, element: *tree.Element) void {
        const self: *BulkEditPane = @ptrCast(@alignCast(context orelse return));
        self.openElement(element) catch {
            self.status = "Unable to open refactoring preview";
            self.host.changed(self.host.context);
        };
    }
    fn openElement(self: *BulkEditPane, element: *tree.Element) !void {
        const session = self.session orelse return;
        const selected = element.fileOperation() orelse return;
        const operation = for (session.operations.file_operations.items) |item| {
            if (std.mem.eql(u8, item.key, selected.key)) break item;
        } else return;
        const resource = session.provider.resourceFor(operation) orelse return;
        const resources = try session.provider.resources(self.allocator);
        defer self.allocator.free(resources);
        try self.services.editors.openMultiDiffResources(.{ .multiDiffSource = .{ .scheme = Schema, .path = .{ .raw = "" } }, .label = "Refactor Preview", .resources = resources, .isTransient = true, .options = .{ .viewState = .{ .revealData = .{ .resource = .{ .original = resource.original, .modified = resource.modified }, .range = element.range() } } } });
    }
    pub fn render(self: *BulkEditPane, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, palette: ?*const ThemeColors) void {
        self.last_rect = rect;
        const height = ui.cell.snap(rect.h);
        const width = ui.cell.snap(rect.w);
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        if (height == 0 or width == 0) return;
        const bg: ui.Color = if (palette) |colors| colors.color("editor.background", .{ 30, 30, 33 }) else .{ .r = 30, .g = 30, .b = 33 };
        const fg: ui.Color = if (palette) |colors| colors.color("editor.foreground", .{ 204, 204, 204 }) else .{ .r = 204, .g = 204, .b = 204 };
        const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, style);
        const session = self.session orelse {
            drawText(grid, x + 1, y, width -| 1, "Invoke a refactoring to preview changes.", style);
            return;
        };
        if (session.tree_view) |view| view.render(grid, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(0, rect.h - 1) }, focused, palette) else drawText(grid, x + 1, y, width -| 1, self.status, style);
        const enabled = session.operations.checked.checked_count > 0 and session.provider.failure == null;
        const button_style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(if (palette) |colors| colors.color("button.background", .{ 0, 122, 204 }) else .{ .r = 0, .g = 122, .b = 204 }), .attrs = if (enabled) 0 else ui.cell.Attr.dim };
        drawText(grid, x + 1, y + height - 1, width -| 1, " Apply ", button_style);
        drawText(grid, x + 10, y + height - 1, width -| 10, " Discard ", style);
    }
    pub fn handleKey(self: *BulkEditPane, event: *const ui.KeyEvent) bool {
        const session = self.session orelse return false;
        if (event.key == .enter and event.mods.ctrl) {
            self.accept() catch {};
            return true;
        }
        return if (session.tree_view) |value| value.handleKey(event) else false;
    }
    pub fn handleMouse(self: *BulkEditPane, event: *const ui.MouseEvent) bool {
        const session = self.session orelse return false;
        const footer = ui.cell.snap(self.last_rect.y + self.last_rect.h) -| 1;
        if (event.y == footer and event.kind == .down and event.button == .left) {
            const relative = event.x -| ui.cell.snap(self.last_rect.x);
            if (relative >= 1 and relative < 8) self.accept() catch {} else if (relative >= 10 and relative < 19) self.discard();
            return true;
        }
        return if (session.tree_view) |value| value.handleMouse(event) else false;
    }
};

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) void {
    for (text[0..@min(text.len, width)], 0..) |character, index| grid.putCodepoint(x + index, y, character, 1, style);
}
