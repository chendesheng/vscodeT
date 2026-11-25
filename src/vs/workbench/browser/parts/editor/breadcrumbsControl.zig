// Port of the portable control behavior of
// `src/vs/workbench/browser/parts/editor/breadcrumbsControl.ts`.
//
// The browser control owns a `BreadcrumbsWidget`, builds `FileItem`/
// `OutlineItem` instances from the model, opens a tree picker on select and
// handles the upstream focus/navigation commands. The terminal control keeps
// that split: it builds items from `BreadcrumbsModel`, drives the cell widget,
// and owns the anchored picker through the group control collection. Resource
// opening and native focus are supplied by the host.
//
// Not ported here (documented in README/docs/terminal-ui.md): the editor-type
// dropdown, drag data, hover tooltips and browser-only context-view geometry.
// The picker uses the terminal cell geometry and the ported async data tree.
//
// `update()` is called when the active editor/group changes or settings are
// reloaded. Focus/selection reset on update, matching upstream's new widget
// model lifecycle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const theme_colors_mod = @import("../../themeColors.zig");

const GroupIdentifier = @import("../../../common/editor.zig").GroupIdentifier;
const WorkspaceContextService = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const outline_mod = @import("../../../services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const IOutline = outline_mod.IOutline;
const outline_service_mod = @import("../../../services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const model_mod = @import("breadcrumbsModel.zig");
const BreadcrumbsModel = model_mod.BreadcrumbsModel;
const FileElement = model_mod.FileElement;
const OutlineElement2 = model_mod.OutlineElement2;
const Element = model_mod.Element;
const FileKind = @import("../../../../platform/files/common/files.zig").FileKind;
const breadcrumbs = @import("breadcrumbs.zig");
const Settings = breadcrumbs.Settings;
const widget_mod = @import("../../../../base/browser/ui/breadcrumbs/breadcrumbsWidget.zig");
const BreadcrumbsWidget = widget_mod.BreadcrumbsWidget;
const Item = widget_mod.Item;
const ItemKind = widget_mod.ItemKind;
const file_icon_mod = @import("../../../services/themes/browser/fileIconThemeData.zig");
const picker_mod = @import("breadcrumbsPicker.zig");

pub const SelectMode = enum { pick, reveal };

/// Geometry of the breadcrumb item that opened the picker. Upstream anchors
/// the context view to the item node and, for a mouse click, points the arrow
/// at the cursor within that item.
pub const Anchor = picker_mod.Anchor;

pub const Selection = union(enum) {
    file: *const FileElement,
    outline: OutlineElement2,
    placeholder,
};

pub const Host = struct {
    context: *anyopaque,
    active_resource: *const fn (context: *anyopaque) ?[]const u8,
    active_language: *const fn (context: *anyopaque) []const u8,
    outline_editor: *const fn (context: *anyopaque) ?OutlineEditor,
    file_icon: *const fn (context: *anyopaque) ?file_icon_mod.Icon,
    symbol_icon: *const fn (context: *anyopaque, kind: ?u32) []const u8,
    open_element: *const fn (context: *anyopaque, selection: Selection, mode: SelectMode, anchor: Anchor) anyerror!void,
    reveal_element: *const fn (context: *anyopaque, outline: *IOutline, element: *anyopaque) anyerror!void,
    request_render: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
};

const base_background = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 204, .g = 204, .b = 204 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_inactive_background = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_focused_style = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 255, .g = 255, .b = 255 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_focused_selected_style = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 255, .g = 255, .b = 255 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_hovered_style = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 255, .g = 255, .b = 255 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_separator_style = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 204, .g = 204, .b = 204 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_icon_style = ui.cell.PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 180, .g = 180, .b = 180 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};

pub const BreadcrumbsControl = struct {
    allocator: Allocator,
    host: Host,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    outline_service: ?*OutlineService,
    home: ?[]const u8,
    settings: Settings,
    model: ?*BreadcrumbsModel = null,
    model_listener: ?@import("../../../../base/common/event.zig").Emitter(void).ListenerId = null,
    widget: BreadcrumbsWidget,
    visible: bool = false,
    focused: bool = false,
    group_id: GroupIdentifier = 0,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(
        allocator: Allocator,
        host: Host,
        workspace: *WorkspaceContextService,
        configuration: ?*ConfigurationService,
        outline_service: ?*OutlineService,
        home: ?[]const u8,
    ) !*BreadcrumbsControl {
        const self = try allocator.create(BreadcrumbsControl);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .workspace = workspace,
            .configuration = configuration,
            .outline_service = outline_service,
            .home = home,
            .settings = Settings.load(configuration),
            .widget = BreadcrumbsWidget.init(allocator),
        };
        errdefer self.deinit();
        try self.update();
        return self;
    }

    pub fn deinit(self: *BreadcrumbsControl) void {
        self.disposeModel();
        self.widget.deinit();
        self.allocator.destroy(self);
    }

    pub fn setGroup(self: *BreadcrumbsControl, group: GroupIdentifier) void {
        self.group_id = group;
    }

    pub fn isVisible(self: *const BreadcrumbsControl) bool {
        return self.visible;
    }

    pub fn isFocused(self: *const BreadcrumbsControl) bool {
        return self.focused;
    }

    pub fn setFocused(self: *BreadcrumbsControl, focused: bool) void {
        self.focused = focused;
        if (!focused) {
            self.widget.setFocused(null);
            self.widget.setSelection(null);
        }
        self.widget.emitFocusChanged(focused) catch {};
    }

    pub fn setSettings(self: *BreadcrumbsControl, settings: Settings) !void {
        const was_visible = self.visible;
        self.settings = settings;
        if (settings.enabled) {
            if (self.model) |model| try model.setSettings(settings);
        }
        try self.update();
        if (was_visible != self.visible) self.host.request_render(self.host.context);
    }

    pub fn update(self: *BreadcrumbsControl) !void {
        if (!self.settings.enabled) {
            self.disposeModel();
            self.visible = false;
            return;
        }
        const resource = self.host.active_resource(self.host.context) orelse {
            self.disposeModel();
            self.visible = false;
            return;
        };

        const needs_model = self.model == null or !std.mem.eql(u8, self.model.?.resource, resource);
        if (needs_model) {
            self.disposeModel();
            const model = try BreadcrumbsModel.init(
                self.allocator,
                resource,
                self.workspace,
                self.settings,
                self.outline_service,
                self.host.outline_editor(self.host.context),
                self.home,
            );
            self.model = model;
            self.model_listener = try model.on_did_update.listen(self, onModelUpdated);
        } else if (self.model) |model| {
            try model.setSettings(self.settings);
        }

        try self.rebuildItems();
        self.visible = true;
    }

    pub fn rebuildItems(self: *BreadcrumbsControl) !void {
        const model = self.model orelse {
            try self.widget.setItems(&.{});
            self.widget.setEnabled(false);
            return;
        };
        var items = std.array_list.Managed(Item).init(self.allocator);
        defer items.deinit();
        for (model.getElements()) |element| {
            switch (element) {
                .file => |file| {
                    const label = if (file.label) |value| value else basenameAny(file.path);
                    const is_file = file.kind == .FILE;
                    var icon: widget_mod.Icon = .none;
                    if (self.settings.icons and is_file) {
                        if (self.host.file_icon(self.host.context)) |file_icon| {
                            icon = .{ .glyph = .{
                                .codepoint = file_icon.glyph,
                                .color = file_icon.color,
                            } };
                        }
                    }
                    try items.append(.{
                        .label = label,
                        .kind = if (is_file) .file else .folder,
                        .icon = icon,
                    });
                },
                .outline => |outline| {
                    try items.append(.{
                        .label = outline.label,
                        .kind = .symbol,
                        .icon = if (self.settings.icons)
                            .{ .text = self.host.symbol_icon(self.host.context, outline.symbol_kind) }
                        else
                            .none,
                    });
                },
                .placeholder => try items.append(.{ .label = "…", .kind = .placeholder }),
            }
        }
        try self.widget.setItems(items.items);
        self.widget.setEnabled(items.items.len > 0);
        if (self.focused) self.widget.setFocused(items.items.len -| 1) else self.widget.revealLast();
    }

    pub fn setThemeColors(self: *BreadcrumbsControl, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    /// Recomputes the item list without rebuilding the outline model or
    /// emitting `on_did_update`. The workbench calls this after a cursor move
    /// so the symbol chain follows the active element, matching upstream's
    /// `onDidChangeCursorPosition` refresh.
    pub fn refreshElements(self: *BreadcrumbsControl) !void {
        const model = self.model orelse return;
        try model.refreshElements();
        try self.rebuildItems();
        self.host.request_render(self.host.context);
    }

    pub fn draw(self: *BreadcrumbsControl, grid: *ui.CellGrid, rect: ui.Rect, active_group: bool) !void {
        if (!self.visible) return;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        if (width == 0) return;
        var background = base_background;
        var inactive_background = base_inactive_background;
        var focused_style = base_focused_style;
        var focused_selected_style = base_focused_selected_style;
        var hovered_style = base_hovered_style;
        var separator_style = base_separator_style;
        var icon_style = base_icon_style;
        if (self.theme) |colors| {
            background = .{
                .fg = ui.cell.packColor(colors.color("breadcrumb.foreground", .{ 204, 204, 204 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            inactive_background = .{
                .fg = ui.cell.packColor(colors.color("descriptionForeground", .{ 150, 150, 150 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            focused_style = .{
                .fg = ui.cell.packColor(colors.color("breadcrumb.focusForeground", .{ 255, 255, 255 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            focused_selected_style = .{
                .fg = ui.cell.packColor(colors.color("breadcrumb.activeSelectionForeground", .{ 255, 255, 255 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            hovered_style = .{
                .fg = ui.cell.packColor(colors.color("breadcrumb.focusForeground", .{ 255, 255, 255 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            separator_style = .{
                .fg = ui.cell.packColor(colors.color("breadcrumb.foreground", .{ 204, 204, 204 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
            icon_style = .{
                .fg = ui.cell.packColor(colors.color("symbolIcon.fileForeground", .{ 180, 180, 180 })),
                .bg = ui.cell.packColor(colors.color("breadcrumb.background", .{ 37, 37, 38 })),
            };
        }
        const base = if (active_group) background else inactive_background;
        const style = widget_mod.Style{
            .background = base,
            .item = base,
            .focused = if (active_group) focused_style else inactive_background,
            .focused_selected = if (active_group) focused_selected_style else inactive_background,
            .hovered = if (active_group) hovered_style else inactive_background,
            .separator = separator_style,
            .icon = icon_style,
        };
        try self.widget.draw(grid, x, y, width, style, self.focused);
    }

    pub fn hitAt(self: *const BreadcrumbsControl, x: usize) ?usize {
        return self.widget.hitAt(x);
    }

    pub fn hover(self: *BreadcrumbsControl, x: usize) void {
        const next = self.widget.hitAt(x);
        if (next == self.widget.hovered) return;
        self.widget.hovered = next;
        self.host.request_render(self.host.context);
    }

    pub fn clearHover(self: *BreadcrumbsControl) void {
        if (self.widget.hovered == null) return;
        self.widget.hovered = null;
        self.host.request_render(self.host.context);
    }

    pub fn click(self: *BreadcrumbsControl, x: usize) !bool {
        const index = self.widget.hitAt(x) orelse return false;
        return self.activateIndex(index, .pick, self.anchorFor(index, x));
    }

    pub fn selectIndex(self: *BreadcrumbsControl, index: usize) !bool {
        return self.activateIndex(index, .pick, self.anchorFor(index, null));
    }

    fn anchorFor(self: *const BreadcrumbsControl, index: usize, cursor: ?usize) Anchor {
        const start = self.widget.hitStart(index) orelse 0;
        return .{
            .start = start,
            .end = self.widget.hitEnd(index) orelse start,
            .cursor = cursor,
        };
    }

    fn activateIndex(self: *BreadcrumbsControl, index: usize, mode: SelectMode, anchor: Anchor) !bool {
        const model = self.model orelse return false;
        const elements = model.getElements();
        if (index >= elements.len) return false;
        try self.widget.selectItem(index);
        const selection: Selection = switch (elements[index]) {
            .file => |file| .{ .file = file },
            .outline => |outline| .{ .outline = outline },
            .placeholder => .placeholder,
        };
        try self.host.open_element(self.host.context, selection, mode, anchor);
        return true;
    }

    pub fn focusAndSelect(self: *BreadcrumbsControl) bool {
        const count = self.widget.itemCount();
        if (count == 0) return false;
        self.focused = true;
        self.widget.setSelection(count - 1);
        self.widget.emitFocus(count - 1) catch {};
        self.widget.emitFocusChanged(true) catch {};
        self.host.request_render(self.host.context);
        return true;
    }

    pub fn focusNext(self: *BreadcrumbsControl) void {
        if (!self.focused) return;
        if (self.widget.getFocused() == null) self.widget.setFocused(0);
        self.widget.focusNext();
        if (self.widget.getFocused()) |index| self.widget.emitFocus(index) catch {};
        self.host.request_render(self.host.context);
    }

    pub fn focusPrevious(self: *BreadcrumbsControl) void {
        if (!self.focused) return;
        if (self.widget.getFocused() == null) self.widget.setFocused(0);
        self.widget.focusPrev();
        if (self.widget.getFocused()) |index| self.widget.emitFocus(index) catch {};
        self.host.request_render(self.host.context);
    }

    pub fn selectFocused(self: *BreadcrumbsControl) !bool {
        const index = self.widget.getFocused() orelse return false;
        return self.selectIndex(index);
    }

    pub fn revealFocused(self: *BreadcrumbsControl) !bool {
        const index = self.widget.getFocused() orelse return false;
        const model = self.model orelse return false;
        const elements = model.getElements();
        if (index >= elements.len) return false;
        switch (elements[index]) {
            .outline => |outline| try self.host.reveal_element(self.host.context, outline.outline, outline.element),
            else => return self.activateIndex(index, .reveal, self.anchorFor(index, null)),
        }
        return true;
    }

    pub fn escapeFocus(self: *BreadcrumbsControl) bool {
        if (!self.focused) return false;
        self.focused = false;
        self.widget.setFocused(null);
        self.widget.setSelection(null);
        self.host.focus_editor(self.host.context);
        return true;
    }

    fn disposeModel(self: *BreadcrumbsControl) void {
        if (self.model) |model| {
            if (self.model_listener) |id| model.on_did_update.unlisten(id);
            self.model_listener = null;
            model.deinit();
            self.model = null;
        }
    }

    fn onModelUpdated(_: void, self: *BreadcrumbsControl) anyerror!void {
        try self.rebuildItems();
        self.host.request_render(self.host.context);
    }
};

fn basenameAny(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var index = end;
    while (index > 0) : (index -= 1) {
        if (path[index - 1] == '/' or path[index - 1] == '\\') return path[index..end];
    }
    return path[0..end];
}

const Tab = @import("editorPane.zig").Tab;
const GroupPane = @import("editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("editorPart.zig").EditorPart(GroupPane);
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const configuration_types = @import("../../../../platform/configuration/common/configuration.zig");

/// Zig composition of the per-group BreadcrumbsControlFactory instances.
/// The group pane's mounted-editor event replaces the browser editor-pane
/// transition. Configuration and group lifetime events own control creation;
/// rendering only looks up an already-created control.
pub const BreadcrumbsControlCollection = struct {
    allocator: Allocator,
    part: *EditorPart,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,
    outline_service: *OutlineService,
    home: ?[]const u8,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    settings: Settings,
    service: breadcrumbs.BreadcrumbsService,
    factories: std.AutoHashMapUnmanaged(GroupIdentifier, *BreadcrumbsControlFactory) = .empty,
    io: std.Io,
    picker_arena: std.heap.ArenaAllocator,
    picker: ?*picker_mod.Picker = null,
    add_listener: ?usize = null,
    remove_listener: ?usize = null,
    suspended: bool = false,
    host: CollectionHost,

    pub const CollectionHost = struct {
        context: *anyopaque,
        file_icon_theme: *const fn (*anyopaque) file_icon_mod.FileIconThemeData,
        open_file: *const fn (*anyopaque, []const u8) anyerror!void,
        request_render: *const fn (*anyopaque) void,
        focus_editor: *const fn (*anyopaque) void,
        focus_breadcrumbs: *const fn (*anyopaque) void,
        layout_changed: *const fn (*anyopaque) void,
    };

    pub fn init(self: *BreadcrumbsControlCollection, allocator: Allocator, io: std.Io, part: *EditorPart, workspace: *WorkspaceContextService, outline_service: *OutlineService, home: ?[]const u8, host: CollectionHost) !void {
        self.* = .{ .allocator = allocator, .part = part, .workspace = workspace, .outline_service = outline_service, .home = home, .settings = Settings.load(null), .service = breadcrumbs.BreadcrumbsService.init(allocator), .host = host, .io = io, .picker_arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.deinit();
        self.add_listener = try part.on_did_add_group.listen(self, onAddGroup);
        self.remove_listener = try part.on_did_remove_group.listen(self, onRemoveGroup);
        for (part.group_views.items) |pane| try self.addGroup(pane);
    }

    pub fn deinit(self: *BreadcrumbsControlCollection) void {
        if (self.add_listener) |id| self.part.on_did_add_group.unlisten(id);
        if (self.remove_listener) |id| self.part.on_did_remove_group.unlisten(id);
        self.detachServices();
        var it = self.factories.valueIterator();
        while (it.next()) |entry| entry.*.destroy();
        self.factories.deinit(self.allocator);
        self.service.deinit();
        if (self.picker) |picker| picker.deinit();
        self.picker_arena.deinit();
    }

    pub fn detachServices(self: *BreadcrumbsControlCollection) void {
        self.suspended = true;
        if (self.configuration_listener) |id| self.configuration.?.unlistenConfigurationChange(id);
        self.configuration_listener = null;
        self.configuration = null;
        self.closePicker();
        var it = self.factories.valueIterator();
        while (it.next()) |entry| entry.*.disposeControl();
    }

    pub fn attachServices(self: *BreadcrumbsControlCollection, workspace: *WorkspaceContextService, configuration: ?*ConfigurationService) !void {
        self.detachServices();
        self.workspace = workspace;
        self.configuration = configuration;
        self.settings = Settings.load(configuration);
        self.suspended = false;
        if (configuration) |config| self.configuration_listener = try config.listenConfigurationChange(self, onConfigurationChanged);
        var it = self.factories.valueIterator();
        while (it.next()) |entry| try entry.*.sync();
    }

    fn onConfigurationChanged(change: configuration_types.Change, self: *BreadcrumbsControlCollection) !void {
        if (!configuration_types.affectsConfiguration(change, "breadcrumbs")) return;
        self.settings = Settings.load(self.configuration);
        self.closePicker();
        var it = self.factories.valueIterator();
        while (it.next()) |entry| try entry.*.sync();
        self.host.layout_changed(self.host.context);
        self.host.request_render(self.host.context);
    }

    fn onAddGroup(pane: *GroupPane, self: *BreadcrumbsControlCollection) !void {
        try self.addGroup(pane);
    }

    fn addGroup(self: *BreadcrumbsControlCollection, pane: *GroupPane) !void {
        const factory = try self.allocator.create(BreadcrumbsControlFactory);
        factory.* = .{ .owner = self, .pane = pane };
        errdefer factory.destroy();
        factory.listener = try pane.on_did_change_active_editor_pane.listen(factory, BreadcrumbsControlFactory.onActivePaneChanged);
        try self.factories.put(self.allocator, pane.group.id, factory);
        errdefer _ = self.factories.remove(pane.group.id);
        try factory.sync();
    }

    fn onRemoveGroup(pane: *GroupPane, self: *BreadcrumbsControlCollection) !void {
        if (self.factories.fetchRemove(pane.group.id)) |entry| entry.value.destroy();
    }

    pub fn getControl(self: *const BreadcrumbsControlCollection, pane: *GroupPane) ?*BreadcrumbsControl {
        const factory = self.factories.get(pane.group.id) orelse return null;
        const control = factory.control orelse return null;
        return if (control.isVisible()) control else null;
    }

    pub fn activeControl(self: *const BreadcrumbsControlCollection) ?*BreadcrumbsControl {
        const pane = self.part.activeView() orelse return null;
        return self.getControl(pane);
    }

    pub fn setThemeColors(self: *BreadcrumbsControlCollection, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
        if (self.picker) |picker| picker.setThemeColors(palette);
        var it = self.factories.valueIterator();
        while (it.next()) |entry| if (entry.*.control) |control| {
            control.setThemeColors(palette);
            control.rebuildItems() catch {};
        };
    }

    // Upstream focusAndSelectHandler: resolve the active group's registered
    // widget, focus the final item, and select it with Payload_Pick when asked.
    pub fn focusAndSelectHandler(self: *BreadcrumbsControlCollection, select: bool) !void {
        const pane = self.part.activeView() orelse return;
        const control: *BreadcrumbsControl = @ptrCast(@alignCast(self.service.getWidget(pane.group.id) orelse return));
        if (!control.isVisible()) return;
        const count = control.widget.itemCount();
        if (count == 0) return;
        self.host.focus_breadcrumbs(self.host.context);
        control.setFocused(true);
        try control.widget.emitFocus(count - 1);
        if (select) _ = try control.selectIndex(count - 1);
        self.host.request_render(self.host.context);
    }

    const Action2 = @import("../../../../platform/actions/common/actions.zig").Action2;
    const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

    fn focusAction(self: *BreadcrumbsControlCollection, comptime select: bool, id: []const u8, label: []const u8) Action2 {
        return .{
            .command = .{ .id = id, .title = label, .category = "View" },
            .f1 = true,
            .context = self,
            .run_fn = struct {
                fn run(context: *anyopaque, _: Accessor) !void {
                    const collection: *BreadcrumbsControlCollection = @ptrCast(@alignCast(context));
                    try collection.focusAndSelectHandler(select);
                }
            }.run,
        };
    }

    pub fn focusActions(self: *BreadcrumbsControlCollection) [2]Action2 {
        return .{
            self.focusAction(true, "breadcrumbs.focusAndSelect", "Focus and Select Breadcrumbs"),
            self.focusAction(false, "breadcrumbs.focus", "Focus Breadcrumbs"),
        };
    }

    pub fn pickerVisible(self: *const BreadcrumbsControlCollection) bool {
        return if (self.picker) |picker| picker.isVisible() else false;
    }

    pub fn closePicker(self: *BreadcrumbsControlCollection) void {
        if (self.picker) |picker| picker.close();
    }

    /// The control selects the upstream file or outline tree. Dispose the old
    /// tree before reclaiming the arena that owns its data-source elements.
    fn showPicker(self: *BreadcrumbsControlCollection, pane: *GroupPane, selection: Selection, anchor: Anchor) !void {
        if (self.picker) |picker| picker.deinit();
        self.picker = null;
        _ = self.picker_arena.reset(.retain_capacity);
        const arena = self.picker_arena.allocator();
        const picker = try picker_mod.Picker.init(self.allocator, .{
            .context = self,
            .io = self.io,
            .arena = arena,
            .open_file = openFile,
            .file_icon = pickerFileIcon,
            .request_render = pickerRequestRender,
        }, .{
            .context = self,
            .arena = arena,
            .reveal = revealOutline,
            .request_render = pickerRequestRender,
        });
        self.picker = picker;
        picker.setThemeColors(self.theme);
        const anchor_y = ui.cell.snap(pane.rect.y) + pane.titleHeight();
        switch (selection) {
            .file => |file| if (file.kind == .ROOT_FOLDER) {
                var folders = std.array_list.Managed(picker_mod.FolderRef).init(arena);
                for (self.workspace.getWorkspace().folders.items) |folder| {
                    try folders.append(.{ .path = folder.resource, .name = folder.name });
                }
                try picker.showFileWorkspace(folders.items, file.path, anchor, anchor_y);
            } else {
                try picker.showFileDirectory(picker_mod.inputDirectory(file), file.path, anchor, anchor_y);
            },
            .outline => |outline| try picker.showOutline(outline.outline, outline.element, anchor, anchor_y),
            .placeholder => {},
        }
        self.host.request_render(self.host.context);
    }

    fn openFile(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *BreadcrumbsControlCollection = @ptrCast(@alignCast(context));
        try self.host.open_file(self.host.context, path);
        self.host.focus_editor(self.host.context);
    }

    fn revealOutline(context: *anyopaque, outline: *IOutline, element: *anyopaque) anyerror!void {
        const self: *BreadcrumbsControlCollection = @ptrCast(@alignCast(context));
        try outline.reveal(element, .{});
        self.host.focus_editor(self.host.context);
    }

    fn pickerFileIcon(context: *anyopaque, path: []const u8) file_icon_mod.Icon {
        const self: *BreadcrumbsControlCollection = @ptrCast(@alignCast(context));
        return self.host.file_icon_theme(self.host.context).forFile(std.fs.path.basename(path), null);
    }

    fn pickerRequestRender(context: *anyopaque) void {
        const self: *BreadcrumbsControlCollection = @ptrCast(@alignCast(context));
        self.host.request_render(self.host.context);
    }

    pub fn draw(self: *const BreadcrumbsControlCollection, grid: *ui.CellGrid, pane: *GroupPane, rect: ui.Rect, active_group: bool) !void {
        if (!self.settings.enabled or rect.w == 0) return;
        const background = if (self.theme) |theme| theme.color("breadcrumb.background", .{ 37, 37, 38 }) else ui.Color{ .r = 37, .g = 37, .b = 38 };
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .bg = ui.cell.packColor(background) });
        if (self.getControl(pane)) |control| try control.draw(grid, rect, active_group);
    }
};

/// Port of upstream BreadcrumbsControlFactory: one control per editor group,
/// enabled by configuration and updated by the mounted active editor event.
pub const BreadcrumbsControlFactory = struct {
    owner: *BreadcrumbsControlCollection,
    pane: *GroupPane,
    control: ?*BreadcrumbsControl = null,
    registration: ?IDisposable = null,
    input: ?*EditorInput = null,
    listener: ?usize = null,

    fn destroy(self: *BreadcrumbsControlFactory) void {
        if (self.listener) |id| self.pane.on_did_change_active_editor_pane.unlisten(id);
        self.disposeControl();
        self.owner.allocator.destroy(self);
    }

    fn disposeControl(self: *BreadcrumbsControlFactory) void {
        if (self.control != null and self.owner.part.activeView() == self.pane) self.owner.closePicker();
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
        if (self.control) |control| control.deinit();
        self.control = null;
        self.input = null;
    }

    fn currentTab(self: *BreadcrumbsControlFactory) ?*Tab {
        const tab = self.pane.panes.activePane() orelse return null;
        if (tab.isImage() or tab.terminal_input != null or tab.search_editor_input != null or tab.markdown_panel != null) return null;
        return tab;
    }

    fn onActivePaneChanged(_: ?*Tab, self: *BreadcrumbsControlFactory) !void {
        try self.sync();
    }

    fn sync(self: *BreadcrumbsControlFactory) !void {
        const owner = self.owner;
        if (owner.suspended or !owner.settings.enabled) {
            self.disposeControl();
            return;
        }
        const input = if (self.currentTab()) |tab| tab.editorInput() else null;
        if (self.control) |control| {
            if (self.input != input) {
                if (owner.part.activeView() == self.pane) owner.closePicker();
                control.disposeModel();
                control.setFocused(false);
                self.input = input;
                try control.update();
                owner.host.request_render(owner.host.context);
            }
            if (!std.meta.eql(control.settings, owner.settings)) try control.setSettings(owner.settings);
            return;
        }
        const control = try BreadcrumbsControl.init(owner.allocator, .{
            .context = self,
            .active_resource = activeResource,
            .active_language = activeLanguage,
            .outline_editor = outlineEditor,
            .file_icon = fileIcon,
            .symbol_icon = symbolIcon,
            .open_element = openElement,
            .reveal_element = revealElement,
            .request_render = requestRender,
            .focus_editor = focusEditor,
        }, owner.workspace, owner.configuration, owner.outline_service, owner.home);
        errdefer control.deinit();
        control.setGroup(self.pane.group.id);
        control.setThemeColors(owner.theme);
        self.registration = try owner.service.register(self.pane.group.id, control);
        self.control = control;
        self.input = input;
        owner.host.request_render(owner.host.context);
    }

    fn activeResource(context: *anyopaque) ?[]const u8 {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        const tab = self.currentTab() orelse return null;
        return tab.editor.path;
    }
    fn activeLanguage(context: *anyopaque) []const u8 {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        const tab = self.currentTab() orelse return "plaintext";
        return tab.editor.languageId();
    }
    fn outlineEditor(context: *anyopaque) ?OutlineEditor {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        const tab = self.currentTab() orelse return null;
        return .{ .context = tab, .control = tab.editor, .resource = tab.editor.path, .language_id = tab.editor.languageId() };
    }
    fn fileIcon(context: *anyopaque) ?file_icon_mod.Icon {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        const tab = self.currentTab() orelse return null;
        if (tab.editor.path.len == 0) return null;
        const icons = self.owner.host.file_icon_theme(self.owner.host.context);
        return if (icons.disabled) null else icons.forFile(std.fs.path.basename(tab.editor.path), tab.editor.languageId());
    }
    fn symbolIcon(_: *anyopaque, kind: ?u32) []const u8 {
        return switch (kind orelse return "◇") {
            1, 2, 3 => "N",
            4, 9, 10, 22 => "◇",
            5, 8, 11 => "ƒ",
            6, 7, 12, 13, 21 => "·",
            else => "◇",
        };
    }
    fn openElement(context: *anyopaque, selection: Selection, mode: SelectMode, anchor: Anchor) !void {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        self.pane.group.service.activateGroup(self.pane.group);
        self.pane.syncActivePane();
        switch (selection) {
            .file => |file| if (mode == .reveal and file.kind == .FILE) {
                try BreadcrumbsControlCollection.openFile(self.owner, file.path);
            } else try self.owner.showPicker(self.pane, selection, anchor),
            .outline => |outline| if (mode == .pick) {
                try self.owner.showPicker(self.pane, selection, anchor);
            } else try BreadcrumbsControlCollection.revealOutline(self.owner, outline.outline, outline.element),
            .placeholder => {},
        }
    }
    fn revealElement(context: *anyopaque, outline: *IOutline, element: *anyopaque) !void {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        try BreadcrumbsControlCollection.revealOutline(self.owner, outline, element);
    }
    fn requestRender(context: *anyopaque) void {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        self.owner.host.request_render(self.owner.host.context);
    }
    fn focusEditor(context: *anyopaque) void {
        const self: *BreadcrumbsControlFactory = @ptrCast(@alignCast(context));
        self.owner.host.focus_editor(self.owner.host.context);
    }
};
