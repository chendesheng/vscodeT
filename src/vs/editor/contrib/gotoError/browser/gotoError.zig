// Port of `src/vs/editor/contrib/gotoError/browser/gotoError.ts`.
// Model/list subscriptions and the real PeekViewWidget belong to one marker
// navigation session; cross-resource navigation uses the editor service's
// asynchronous open continuation rather than a retained initiating editor.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const code_editors = @import("../../../browser/services/codeEditorService.zig");
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const markers = @import("../../../../platform/markers/common/markers.zig");
const Opener = @import("../../../../platform/opener/common/opener.zig").IOpenerService;
const navigation = @import("markerNavigationService.zig");
const MarkerNavigationWidget = @import("gotoErrorWidget.zig").MarkerNavigationWidget;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib);

pub const Services = struct {
    marker_navigation: navigation.IMarkerNavigationService,
    editors: code_editors.ICodeEditorService,
    opener: Opener,
    window: *dispatch.Queue,
    menus: *@import("../../../../platform/actions/common/menuService.zig").MenuService,
    context_keys: contextkey.IContext,
};

pub const MarkerController = struct {
    pub const ID = "editor.contrib.markerController";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    services: ?Services = null,
    model: ?*navigation.MarkerList = null,
    widget: ?*MarkerNavigationWidget = null,
    list_listener: ?usize = null,
    cursor_listener: ?usize = null,
    model_listener: ?usize = null,
    pending_action: ?MarkerNavigationWidget.Action = null,
    pending_menu_action: ?[]u8 = null,
    action_task: dispatch.Task = .{},

    pub fn getOrCreate(editor: *Editor, view: *View, services: Services) !*MarkerController {
        if (editor.getInstantiatedContribution(MarkerController)) |existing| {
            try existing.bind(view, services);
            return existing;
        }
        const self = try editor.allocator.create(MarkerController);
        self.* = .{ .allocator = editor.allocator, .editor = editor };
        errdefer self.dispose();
        try self.bind(view, services);
        try editor.registerOwnedContribution(MarkerController, self, dispose);
        return self;
    }

    pub fn registerFactory(editor: *Editor, context: *anyopaque, instantiate: *const fn (*anyopaque) anyerror!void) !void {
        try editor.registerContributionFactory(.{ .id = ID, .context = context, .instantiate = instantiate, .instantiation = .lazy });
    }

    fn bind(self: *MarkerController, view: *View, services: Services) !void {
        if (self.view == view and self.services != null) return;
        self.unbind();
        self.view = view;
        self.services = services;
        errdefer self.unbind();
        self.model_listener = try self.editor.on_will_change_model.listen(self, onWillChangeModel);
        self.action_task = .{ .queue = services.window, .context = self, .run = dispatchAction };
    }

    pub fn unbind(self: *MarkerController) void {
        self.cleanUp();
        if (self.model_listener) |id| self.editor.on_will_change_model.unlisten(id);
        self.model_listener = null;
        self.view = null;
        self.services = null;
    }

    pub fn dispose(self: *MarkerController) void {
        self.unbind();
        self.allocator.destroy(self);
    }

    fn onWillChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *MarkerController) !void {
        self.cleanUp();
    }

    fn cleanUp(self: *MarkerController) void {
        self.action_task.schedule(null);
        self.pending_action = null;
        if (self.pending_menu_action) |id| self.allocator.free(id);
        self.pending_menu_action = null;
        self.editor.setMarkersNavigationVisible(false);
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_position.unlisten(id);
        self.cursor_listener = null;
        if (self.model) |model| {
            if (self.list_listener) |id| model.on_did_change.unlisten(id);
        }
        self.list_listener = null;
        if (self.widget) |widget| widget.deinit();
        self.widget = null;
        if (self.model) |model| model.deinit();
        self.model = null;
    }

    pub fn close(self: *MarkerController, focus_editor: bool) void {
        self.cleanUp();
        if (focus_editor) if (self.view) |view| view.focusEditor();
    }

    fn getOrCreateModel(self: *MarkerController, resource: ?markers.Resource) !*navigation.MarkerList {
        const services = self.services orelse return error.MarkerNavigationUnavailable;
        const view = self.view orelse return error.MarkerNavigationUnavailable;
        const key = if (resource) |value| try value.key(self.allocator) else null;
        defer if (key) |value| self.allocator.free(value);
        if (self.model) |existing| if (existing.matches(key)) return existing;
        const reuse_position = self.model != null;
        self.cleanUp();
        errdefer self.cleanUp();
        self.model = try services.marker_navigation.getMarkerList(resource);
        if (reuse_position) _ = try self.model.?.move(true, self.editor.model, self.editor.modelCursorPosition());
        self.widget = try MarkerNavigationWidget.create(self.allocator, view, .{ .context = self, .action = widgetAction, .menu_action = widgetMenuAction, .opener = services.opener, .menus = services.menus, .context_keys = services.context_keys });
        self.editor.setMarkersNavigationVisible(true);
        self.cursor_listener = try self.editor.on_did_change_cursor_position.listen(self, cursorChanged);
        self.list_listener = try self.model.?.on_did_change.listen(self, listChanged);
        return self.model.?;
    }

    fn cursorChanged(event: @import("../../../common/cursorEvents.zig").ICursorPositionChangedEvent, self: *MarkerController) !void {
        const list = self.model orelse return;
        if (list.selected()) |selected| if (navigation.markerRange(selected.marker).containsPosition(&event.position)) return;
        list.resetIndex();
    }

    fn listChanged(_: void, self: *MarkerController) !void {
        const widget = self.widget orelse return;
        const position = widget.position() orelse return;
        const list = self.model orelse return;
        const key = try uri_util.resourceKey(self.allocator, self.editor.model.uri());
        defer self.allocator.free(key);
        if (list.find(key, position)) |info| try widget.updateMarker(info.marker) else widget.showStale();
    }

    pub fn showAtMarker(self: *MarkerController, range: Range) !void {
        if (!self.editor.hasModel()) return;
        var resource = try markers.Resource.fromUri(self.allocator, self.editor.model.uri());
        defer resource.deinit(self.allocator);
        const list = try self.getOrCreateModel(resource);
        list.resetIndex();
        _ = try list.move(true, self.editor.model, range.getStartPosition());
        if (list.selected()) |selected| try self.widget.?.showAtMarker(selected);
    }

    pub fn navigate(self: *MarkerController, next: bool, multi_file: bool) !void {
        if (!self.editor.hasModel()) return;
        const services = self.services orelse return;
        var resource = try markers.Resource.fromUri(self.allocator, self.editor.model.uri());
        defer resource.deinit(self.allocator);
        const list = try self.getOrCreateModel(if (multi_file) null else resource);
        _ = try list.move(next, self.editor.model, self.editor.modelCursorPosition());
        const selected = list.selected() orelse return;
        const key = try resource.key(self.allocator);
        defer self.allocator.free(key);
        if (std.mem.eql(u8, selected.marker.key, key)) {
            try self.widget.?.showAtMarker(selected);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const target = selected.marker.resource;
        var uri = try @import("../../../../base/common/uri.zig").URI.from(a, .{ .scheme = target.scheme, .authority = target.authority, .path = target.path, .query = target.query, .fragment = target.fragment }, false);
        defer uri.deinit();
        const encoded = try uri.toStringEncoded(a);
        const selection = navigation.markerRange(selected.marker);
        self.cleanUp();
        try services.editors.openCodeEditor(.{ .resource = try std.Uri.parse(encoded), .selection = selection, .on_opened = if (next) resumeNext else resumePrevious });
    }

    fn resumeNext(editor: *Editor) void {
        if (editor.getContribution(MarkerController)) |controller| {
            controller.close(true);
            controller.navigate(true, true) catch {};
        }
    }
    fn resumePrevious(editor: *Editor) void {
        if (editor.getContribution(MarkerController)) |controller| {
            controller.close(true);
            controller.navigate(false, true) catch {};
        }
    }

    fn widgetAction(context: *anyopaque, action: MarkerNavigationWidget.Action) void {
        const self: *MarkerController = @ptrCast(@alignCast(context));
        self.pending_action = action;
        self.action_task.post();
    }
    fn widgetMenuAction(context: *anyopaque, id: []const u8) void {
        const self: *MarkerController = @ptrCast(@alignCast(context));
        const owned = self.allocator.dupe(u8, id) catch return;
        if (self.pending_menu_action) |previous| self.allocator.free(previous);
        self.pending_menu_action = owned;
        self.action_task.post();
    }
    fn dispatchAction(context: *anyopaque, _: i64, _: bool) bool {
        const self: *MarkerController = @ptrCast(@alignCast(context));
        if (self.pending_menu_action) |id| {
            self.pending_menu_action = null;
            const allocator = self.allocator;
            defer allocator.free(id);
            if (self.widget) |widget| widget.executeTitleAction(id);
            return true;
        }
        const action = self.pending_action orelse return false;
        self.pending_action = null;
        switch (action) {
            .next => self.navigate(true, false) catch {},
            .previous => self.navigate(false, false) catch {},
            .close => self.close(true),
        }
        return true;
    }
};

pub const next_marker_id = "editor.action.marker.next";
pub const previous_marker_id = "editor.action.marker.prev";
const editor_focus = contextkey.Expr{ .Defined = "editorFocus" };
const navigation_visible = contextkey.Expr{ .Defined = "markersNavigationVisible" };
const title_menu = @import("gotoErrorWidget.zig").title_menu;

pub const marker_actions = [_]actions.Action2{
    markerAction(next_marker_id, "Go to Next Problem (Error, Warning, Info)", true, false, keys.KeyMod.Alt | @backingInt(keys.KeyCode.F8)),
    markerAction(previous_marker_id, "Go to Previous Problem (Error, Warning, Info)", false, false, keys.KeyMod.Shift | keys.KeyMod.Alt | @backingInt(keys.KeyCode.F8)),
    markerAction("editor.action.marker.nextInFiles", "Go to Next Problem in Files (Error, Warning, Info)", true, true, @backingInt(keys.KeyCode.F8)),
    markerAction("editor.action.marker.prevInFiles", "Go to Previous Problem in Files (Error, Warning, Info)", false, true, keys.KeyMod.Shift | @backingInt(keys.KeyCode.F8)),
    blk: {
        var command = EditorCommand.action(.{ .id = "closeMarkersNavigation", .title = "Close Problems Navigation", .precondition = &navigation_visible }, false, struct {
            fn run(editor: *Editor) !void {
                if (editor.getInstantiatedContribution(MarkerController)) |controller| controller.close(true);
            }
        }.run);
        command.f1 = false;
        command.keybindings = &.{.{ .id = "closeMarkersNavigation", .weight = weight + 50, .when = &editor_focus, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape), .secondary = &.{keys.KeyMod.Shift | @backingInt(keys.KeyCode.Escape)} } }};
        break :blk command;
    },
};

fn markerAction(comptime id: []const u8, comptime title: []const u8, comptime next: bool, comptime multi_file: bool, comptime key: u32) actions.Action2 {
    var command = EditorCommand.action(.{ .id = id, .title = title, .icon = if (multi_file) null else if (next) "arrowDown" else "arrowUp" }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getContribution(MarkerController)) |controller| try controller.navigate(next, multi_file);
        }
    }.run);
    command.keybindings = &.{.{ .id = id, .weight = weight, .when = &editor_focus, .bindings = .{ .primary = key } }};
    command.menus = if (multi_file) &.{.{ .id = actions.menu_ids.MenubarGoMenu, .group = "6_problem_nav", .order = if (next) 1 else 2 }} else &.{.{ .id = title_menu, .group = "navigation", .order = if (next) 1 else 2 }};
    return command;
}
