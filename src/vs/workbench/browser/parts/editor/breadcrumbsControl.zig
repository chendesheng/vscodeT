// Port of the portable control behavior of
// `src/vs/workbench/browser/parts/editor/breadcrumbsControl.ts`.
//
// The browser control owns a `BreadcrumbsWidget`, builds `FileItem`/
// `OutlineItem` instances from the model, opens a tree picker on select and
// handles the upstream focus/navigation commands. The terminal control keeps
// that split: it builds items from `BreadcrumbsModel`, drives the cell widget,
// and delegates file opening, symbol reveal and picker display to a host. The
// host is the workbench; this file stays independent of `Tab` and the TUI.
//
// Not ported here (documented in README/docs/terminal-ui.md): the editor-type
// dropdown, drag data, hover tooltips, context-view anchoring and the symbol
// kind filters. Selection uses the existing terminal quick pick instead of the
// browser tree picker.
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
const file_icon_mod = @import("../../fileIcon.zig");

pub const SelectMode = enum { pick, reveal };

/// Geometry of the breadcrumb item that opened the picker. Upstream anchors
/// the context view to the item node and, for a mouse click, points the arrow
/// at the cursor within that item.
pub const Anchor = struct {
    start: usize,
    end: usize,
    cursor: ?usize = null,
};

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
