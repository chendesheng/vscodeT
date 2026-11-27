// Port of the local-extension query handling and the Extensions list view in
// `src/vs/workbench/contrib/extensions/browser/extensionsViews.ts` (and the
// list wrapper from `extensionsViewer.ts`).
//
// Terminal adaptation: the combined list shows user-installed and built-in
// extensions (upstream's default Installed view lists only user extensions and
// exposes built-ins through `@builtin` views). User-installed rows sort first,
// then built-ins, each alphabetically by display name. The browser header's
// search box becomes one cell row at the top of the body; the body is the
// shared terminal `ListWidget`. Rows are two cell rows (name/version and
// origin/description) instead of a 72 px template. Gallery-only queries
// (`@updates`, `@outdated`, `@recommended`, `@popular`, …) have no local
// equivalent and fall through to text matching. `@enabled`/`@disabled` map to
// the local enablement state because the TUI has no running-extension list.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const list_mod = @import("../../../../base/browser/ui/list/list.zig");
const list_widget_mod = @import("../../../../base/browser/ui/list/listWidget.zig");
const list_scrollbar = @import("../../../../base/browser/ui/list/listScrollbarTerminal.zig");
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;
const views = @import("../../../common/views.zig");
const list_renderer = @import("extensionsList.zig");
const model = @import("../common/extensions.zig");
const query_mod = @import("../common/extensionQuery.zig");
const service_mod = @import("extensionsWorkbenchService.zig");
const IExtension = model.IExtension;
const EnablementState = model.EnablementState;
const IContextMenuService = @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService;
const Anchor = @import("../../../../platform/contextview/browser/contextMenuService.zig").Anchor;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;
const INotificationService = @import("../../../../platform/notification/common/notification.zig").INotificationService;

/// Host capability boundary for the TUI. `open_extension` receives the path of
/// the extension's `package.json`.
pub const Host = struct {
    context: *anyopaque,
    open_extension: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    request_frame: *const fn (context: *anyopaque) void,
    status: *const fn (context: *anyopaque, message: []const u8) void,
    context_menu: ?IContextMenuService = null,
    notifications: ?INotificationService = null,
    theme: list_renderer.ThemeGetter,
};

pub const refresh_action_id = "workbench.extensions.action.refreshExtension";
pub const clear_search_action_id = "workbench.extensions.action.clearExtensionsSearchResults";

const refresh_action = views.TitleAction{ .id = refresh_action_id, .label = "Refresh", .glyph = '\u{21BB}' };
const title_actions = [_]views.TitleAction{refresh_action};

pub const ExtensionsListView = struct {
    pub const ID = model.VIEW_ID;

    allocator: Allocator,
    service: ?*service_mod.ExtensionsWorkbenchService = null,
    host: Host,
    list: list_widget_mod.ListWidget,
    input_box: ui.InputBox,
    input_surface: ?ui.Surface = null,
    input_focused: bool = true,
    focused: bool = false,
    /// Filtered rows; the list elements point at these entries.
    rows: []const *const IExtension = &.{},
    selected_id: std.array_list.Managed(u8),
    listener: ?SignalSubscription = null,
    message_buffer: [256]u8 = undefined,

    pub fn init(allocator: Allocator, options: struct { service: ?*service_mod.ExtensionsWorkbenchService = null, host: Host }) !*ExtensionsListView {
        const self = try allocator.create(ExtensionsListView);
        errdefer allocator.destroy(self);
        var input_box = ui.InputBox.init(allocator);
        errdefer input_box.deinit();
        input_box.placeholder = "Search Extensions";
        input_box.placeholder_when_focused = true;
        input_box.callback_context = self;
        input_box.on_change = onInputChange;
        input_box.on_enter = onInputEnter;
        self.* = .{
            .allocator = allocator,
            .service = options.service,
            .host = options.host,
            .list = list_widget_mod.ListWidget.init(allocator, .{
                .context = self,
                .get_height = delegateHeight,
                .get_template_id = delegateTemplateId,
            }, .{ .context = self, .render = renderElement }),
            .input_box = input_box,
            .selected_id = std.array_list.Managed(u8).init(allocator),
        };
        errdefer self.deinitContents();
        try self.subscribe();
        // An empty inventory still opens the view.
        self.rebuild() catch {};
        return self;
    }

    pub fn deinit(self: *ExtensionsListView) void {
        self.deinitContents();
        self.allocator.destroy(self);
    }

    fn deinitContents(self: *ExtensionsListView) void {
        self.unsubscribe();
        self.list.deinit();
        self.input_box.deinit();
        if (self.input_surface) |*surface| surface.deinit();
        self.input_surface = null;
        self.allocator.free(self.rows);
        self.rows = &.{};
        self.selected_id.deinit();
    }

    pub fn setService(self: *ExtensionsListView, service: ?*service_mod.ExtensionsWorkbenchService) !void {
        self.unsubscribe();
        self.service = service;
        try self.subscribe();
        try self.rebuild();
    }

    fn subscribe(self: *ExtensionsListView) !void {
        const service = self.service orelse return;
        self.listener = try service.on_change.listenSignal(self, onServiceChange);
    }

    fn unsubscribe(self: *ExtensionsListView) void {
        if (self.listener) |listener| listener.dispose();
        self.listener = null;
    }

    fn onServiceChange(self: *ExtensionsListView) !void {
        try self.rebuild();
    }

    fn onInputChange(context: ?*anyopaque, _: []const u8) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context orelse return));
        self.rebuild() catch {};
        self.requestFrame();
    }

    fn onInputEnter(context: ?*anyopaque) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context orelse return));
        self.focusList();
    }

    pub fn queryText(self: *const ExtensionsListView) []const u8 {
        return self.input_box.getValue();
    }

    /// Recomputes the filtered rows and updates the list widget. Selection is
    /// preserved by extension identifier, falling back to the first row.
    pub fn rebuild(self: *ExtensionsListView) !void {
        if (self.list.selection()) |index| {
            if (index < self.rows.len) {
                self.selected_id.clearRetainingCapacity();
                try self.selected_id.appendSlice(self.rows[index].identifier);
            }
        }
        const local = if (self.service) |service| service.queryLocal() else &[_]IExtension{};
        const rows = try filterExtensions(self.allocator, local, self.queryText());
        self.allocator.free(self.rows);
        self.rows = rows;

        var elements = try self.allocator.alloc(list_mod.Element, rows.len);
        defer self.allocator.free(elements);
        for (rows, 0..) |extension, index| elements[index] = @ptrCast(extension);
        try self.list.replaceAll(elements);

        if (rows.len == 0) {
            self.list.setSelection(null);
        } else {
            var target: ?usize = null;
            if (self.selected_id.items.len > 0) {
                for (rows, 0..) |extension, index| {
                    if (!std.ascii.eqlIgnoreCase(extension.identifier, self.selected_id.items)) continue;
                    target = index;
                    break;
                }
            }
            self.list.setSelection(target orelse 0);
        }
        self.requestFrame();
    }

    /// Port of `ExtensionsViewPaneContainer.focus`: the search box owns focus
    /// when the view is focused.
    pub fn setFocused(self: *ExtensionsListView, focused: bool) void {
        self.focused = focused;
        if (focused) {
            self.setInputFocused(true);
        } else {
            self.input_box.focused = false;
            self.list.setFocus(false);
        }
        self.requestFrame();
    }

    fn setInputFocused(self: *ExtensionsListView, focused: bool) void {
        self.input_focused = focused;
        self.input_box.focused = focused and self.focused;
        self.list.setFocus(self.focused and !focused);
        self.requestFrame();
    }

    fn focusList(self: *ExtensionsListView) void {
        self.setInputFocused(false);
        if (self.rows.len > 0) self.list.setSelection(self.list.selection() orelse 0);
    }

    pub fn hasHoveredRow(self: *const ExtensionsListView) bool {
        return self.list.hasHoveredRow();
    }

    pub fn pointerAt(self: *const ExtensionsListView, event: *const ui.MouseEvent, rect: ui.Rect) ui.Pointer {
        const y = ui.cell.snap(rect.y);
        if (event.y == y) return .text;
        if (self.list.hasHoveredRow()) return .pointer;
        return .default;
    }

    /// Returns true when the view consumed Escape (cleared the query or moved
    /// focus back to the search input).
    pub fn handleEscape(self: *ExtensionsListView) bool {
        if (self.input_focused) {
            if (self.input_box.getValue().len == 0) return false;
            self.clearSearch();
            return true;
        }
        self.setInputFocused(true);
        return true;
    }

    pub fn clearSearch(self: *ExtensionsListView) void {
        self.input_box.setValue("") catch {};
        self.setInputFocused(true);
        self.rebuild() catch {};
        self.requestFrame();
    }

    pub fn refresh(self: *ExtensionsListView) !void {
        const service = self.service orelse return;
        service.refresh() catch |err| {
            if (self.host.notifications) |notifications| notifications.err(.{ .text = "Unable to refresh extensions." });
            self.host.status(self.host.context, "Unable to refresh extensions");
            return err;
        };
        self.requestFrame();
    }

    pub fn titleActions(self: *const ExtensionsListView) []const views.TitleAction {
        _ = self;
        return &title_actions;
    }

    fn requestFrame(self: *ExtensionsListView) void {
        self.host.request_frame(self.host.context);
    }

    fn theme(self: *const ExtensionsListView) ?*const @import("../../../browser/themeColors.zig").ThemeColors {
        return self.host.theme.palette();
    }

    // ------------------------------------------------------------------
    // Input
    // ------------------------------------------------------------------

    pub fn handleKey(self: *ExtensionsListView, event: *const ui.KeyEvent) !bool {
        if (!self.focused) return false;
        if (self.input_focused) {
            switch (event.key) {
                .down => {
                    self.focusList();
                    return true;
                },
                .enter => {
                    self.focusList();
                    return true;
                },
                .tab => {
                    self.focusList();
                    return true;
                },
                .backtab => return false,
                .escape => return self.handleEscape(),
                else => {},
            }
            self.input_box.focused = true;
            const handled = self.input_box.handleKey(@constCast(event));
            if (handled) self.requestFrame();
            return handled;
        }

        switch (event.key) {
            .tab, .backtab => {
                self.setInputFocused(true);
                return true;
            },
            .up => {
                if (self.list.selection() == null or self.list.selection().? == 0) {
                    self.setInputFocused(true);
                    return true;
                }
            },
            .escape => return self.handleEscape(),
            .enter => {
                try self.openSelected();
                return true;
            },
            else => {},
        }
        const handled = self.list.handleKey(@constCast(event));
        if (handled) self.requestFrame();
        return handled;
    }

    pub fn handleMouse(self: *ExtensionsListView, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return false;
        if (event.x < x or event.x >= x + width or event.y < y or event.y >= y + height) {
            self.list.clearHover();
            return false;
        }

        if (event.y == y) {
            self.list.clearHover();
            if (event.kind == .down and event.button == .left) self.setInputFocused(true);
            var local = event.*;
            local.x = event.x - x;
            local.y = 0;
            _ = self.input_box.handleMouse(&local);
            return true;
        }

        const list_top = y + 1;
        const list_height = height -| 1;
        const content_rows: usize = @intFromFloat(@max(0, self.list.view.range_map.size()));
        const list_width = list_scrollbar.contentWidth(width, list_height, content_rows);
        if (event.x >= x + list_width) {
            self.list.clearHover();
            return true;
        }

        if (event.kind == .down and event.button == .right) {
            const position = self.list.view.scroll_top + @as(f64, @floatFromInt(event.y - list_top));
            const index = self.list.view.indexAt(position);
            if (index >= 0 and index < @as(i64, @intCast(self.rows.len))) {
                self.list.setSelection(@intCast(index));
                try self.showRowMenu(self.rows[@intCast(index)], .mouse(event));
            }
            return true;
        }

        if (event.kind == .down and event.button == .left) {
            self.setInputFocused(false);
            _ = self.list.handleMouse(event);
            if (self.list.selection()) |index| {
                if (index < self.rows.len) try self.openExtension(self.rows[index]);
            }
            self.requestFrame();
            return true;
        }

        const handled = self.list.handleMouse(event);
        if (handled) self.requestFrame();
        return handled;
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    fn openSelected(self: *ExtensionsListView) !void {
        const index = self.list.selection() orelse return;
        if (index >= self.rows.len) return;
        try self.openExtension(self.rows[index]);
    }

    fn openExtension(self: *ExtensionsListView, extension: *const IExtension) !void {
        const path = try std.fs.path.join(self.allocator, &.{ extension.location, "package.json" });
        defer self.allocator.free(path);
        try self.host.open_extension(self.host.context, path);
    }

    fn showRowMenu(self: *ExtensionsListView, extension: *const IExtension, anchor: Anchor) !void {
        const service = self.host.context_menu orelse return;
        const menu = try Menu.init(self.allocator, @as(u8, 0), struct {
            fn run(_: *u8, _: []const u8) !void {}
        }.run);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();
        const Command = struct {
            view: *ExtensionsListView,
            identifier: []const u8 = "",
            enable: bool = false,
            open: bool = false,
            pub fn run(action: *@This()) !void {
                if (action.open) {
                    if (action.view.service) |view_service| {
                        if (view_service.find(action.identifier)) |found| {
                            return action.view.openExtension(found);
                        }
                    }
                    return;
                }
                try action.view.toggleEnablement(action.identifier, action.enable);
            }
        };
        const identifier = try arena.dupe(u8, extension.identifier);
        if (extension.isEnabled()) {
            try menu.addAction("extensions.disableGlobally", "Disable", null, Command{ .view = self, .identifier = identifier, .enable = false });
        } else {
            try menu.addAction("extensions.enableGlobally", "Enable", null, Command{ .view = self, .identifier = identifier, .enable = true });
        }
        try menu.addAction("workbench.extensions.action.openExtension", "Open Extension", null, Command{ .view = self, .identifier = identifier, .open = true });
        try service.showContextMenu(menu, anchor);
    }

    fn toggleEnablement(self: *ExtensionsListView, identifier: []const u8, enable: bool) !void {
        const service = self.service orelse return;
        const state: EnablementState = if (enable) .EnabledGlobally else .DisabledGlobally;
        _ = service.setEnablement(identifier, state) catch {
            if (self.host.notifications) |notifications| notifications.err(.{ .text = "Unable to change extension enablement." });
            self.host.status(self.host.context, "Unable to change extension enablement");
            return;
        };
        self.rebuild() catch {};
        const name = if (service.find(identifier)) |extension| extension.display_name else identifier;
        const message = std.fmt.bufPrint(&self.message_buffer, "Extension '{s}' {s}. Restart the editor to apply the change.", .{
            name,
            if (enable) "enabled" else "disabled",
        }) catch "Extension enablement changed. Restart the editor to apply the change.";
        if (self.host.notifications) |notifications| notifications.info(.{ .text = message });
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    pub fn render(self: *ExtensionsListView, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
        _ = focused;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;
        const palette = list_renderer.colors(self.theme());
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), .{
            .fg = ui.cell.packColor(palette.foreground),
            .bg = ui.cell.packColor(palette.background),
        });

        try self.renderInput(grid, x, y, width, palette);
        const list_top = y + 1;
        const list_height = height -| 1;
        if (list_height == 0) return;

        if (self.rows.len == 0) {
            var buffer: [256]u8 = undefined;
            const message = if (self.queryText().len == 0)
                "No extensions found."
            else
                std.fmt.bufPrint(&buffer, "No extensions match '{s}'.", .{self.queryText()}) catch "No extensions match.";
            _ = list_renderer.drawTextEllipsis(grid, x + 2, list_top, width -| 2, message, .{
                .fg = ui.cell.packColor(palette.dim),
                .bg = ui.cell.packColor(palette.background),
            });
            return;
        }

        const content_rows: usize = @intFromFloat(@max(0, self.list.view.range_map.size()));
        const list_width = list_scrollbar.contentWidth(width, list_height, content_rows);
        self.list.setFocus(self.focused and !self.input_focused);
        self.list.render(grid, .{ .x = @floatFromInt(x), .y = @floatFromInt(list_top), .w = @floatFromInt(list_width), .h = @floatFromInt(list_height) });
        list_scrollbar.paint(grid, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(list_top),
            .w = @floatFromInt(width),
            .h = @floatFromInt(list_height),
        }, content_rows, self.list.view.scroll_top);
    }

    fn renderInput(self: *ExtensionsListView, grid: *ui.CellGrid, x: usize, y: usize, width: usize, palette: list_renderer.Colors) !void {
        if (width == 0) return;
        if (self.input_surface == null) {
            self.input_surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = 1 });
        }
        const surface = &self.input_surface.?;
        try surface.resize(width, 1);
        const doc = surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
            .background = palette.input_background,
        });
        const inner = width -| 2;
        const holder = try doc.createElement(.div);
        holder.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(inner) },
            .height = .{ .cells = 1 },
        });
        self.input_box.color = palette.input_foreground;
        self.input_box.placeholder_color = palette.input_placeholder;
        self.input_box.selection_background = palette.active_selection;
        self.input_box.selection_foreground = palette.selection_foreground;
        self.input_box.focused = self.input_focused and self.focused;
        const node = try self.input_box.build(doc, inner);
        _ = try holder.appendChild(node);
        _ = try root.appendChild(holder);
        doc.setRoot(root);
        try surface.paintFrame();
        try grid.blit(surface.grid(), x, y, width, 1);
    }

    fn delegateHeight(_: *anyopaque, _: list_mod.Element) f64 {
        return 2;
    }

    fn delegateTemplateId(_: *anyopaque, _: list_mod.Element) usize {
        return 0;
    }

    fn renderElement(context: *anyopaque, row: *const list_mod.Row, element: list_mod.Element) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context));
        const extension: *const IExtension = @ptrCast(@alignCast(element));
        list_renderer.renderRow(row.grid, row, extension, list_renderer.colors(self.theme()));
    }
};

const ParsedFilter = struct {
    text: []const u8 = "",
    installed: bool = false,
    builtin: bool = false,
    enabled: bool = false,
    disabled: bool = false,
    ids: []const []const u8 = &.{},
    included_categories: []const []const u8 = &.{},
    excluded_categories: []const []const u8 = &.{},
};

fn parseFilter(arena: Allocator, value: []const u8) !ParsedFilter {
    var result = ParsedFilter{};
    var text: std.array_list.Managed(u8) = .init(arena);
    var ids: std.array_list.Managed([]const u8) = .init(arena);
    var included: std.array_list.Managed([]const u8) = .init(arena);
    var excluded: std.array_list.Managed([]const u8) = .init(arena);

    var index: usize = 0;
    while (index < value.len) {
        while (index < value.len and std.ascii.isWhitespace(value[index])) : (index += 1) {}
        if (index >= value.len) break;
        if (startsWithIgnoreCase(value[index..], "category:")) {
            index += "category:".len;
            var category: []const u8 = "";
            if (index < value.len and value[index] == '"') {
                index += 1;
                const start = index;
                while (index < value.len and value[index] != '"') : (index += 1) {}
                category = value[start..index];
                if (index < value.len) index += 1;
            } else {
                const start = index;
                while (index < value.len and !std.ascii.isWhitespace(value[index])) : (index += 1) {}
                category = value[start..index];
            }
            if (category.len == 0) continue;
            const is_excluded = category[0] == '-';
            const name = if (is_excluded) category[1..] else category;
            const owned = try std.ascii.allocLowerString(arena, name);
            if (is_excluded) {
                try excluded.append(owned);
            } else {
                try included.append(owned);
            }
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "@sort:")) {
            // The sort token is parsed by `Query`; local ordering always uses
            // the display-name order, so the token itself is dropped.
            index += "@sort:".len;
            while (index < value.len and !std.ascii.isWhitespace(value[index])) : (index += 1) {}
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "@id:")) {
            index += "@id:".len;
            const start = index;
            while (index < value.len and !std.ascii.isWhitespace(value[index])) : (index += 1) {}
            if (index > start) try ids.append(try std.ascii.allocLowerString(arena, value[start..index]));
            continue;
        }
        const word_end = blk: {
            var end = index;
            while (end < value.len and !std.ascii.isWhitespace(value[end])) : (end += 1) {}
            break :blk end;
        };
        const word = value[index..word_end];
        index = word_end;
        if (tokenEquals(word, "@installed")) {
            result.installed = true;
            continue;
        }
        if (tokenEquals(word, "@builtin")) {
            result.builtin = true;
            continue;
        }
        if (tokenEquals(word, "@enabled")) {
            result.enabled = true;
            continue;
        }
        if (tokenEquals(word, "@disabled")) {
            result.disabled = true;
            continue;
        }
        if (text.items.len > 0) try text.append(' ');
        try text.appendSlice(word);
    }

    result.text = try std.ascii.allocLowerString(arena, text.items);
    result.ids = try ids.toOwnedSlice();
    result.included_categories = try included.toOwnedSlice();
    result.excluded_categories = try excluded.toOwnedSlice();
    return result;
}

fn tokenEquals(word: []const u8, token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, token);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn matchesCategories(extension: *const IExtension, included: []const []const u8, excluded: []const []const u8) bool {
    for (excluded) |category| {
        if (extension.hasCategory(category)) return false;
    }
    if (included.len == 0) return true;
    if (extension.categories.len == 0) {
        for (included) |category| {
            if (std.ascii.eqlIgnoreCase(category, "none")) return true;
        }
        return false;
    }
    for (included) |category| {
        if (extension.hasCategory(category)) return true;
    }
    return false;
}

fn matchesId(extension: *const IExtension, ids: []const []const u8) bool {
    if (ids.len == 0) return true;
    for (ids) |id| {
        if (std.ascii.eqlIgnoreCase(extension.identifier, id)) return true;
    }
    return false;
}

fn matchesText(extension: *const IExtension, text: []const u8) bool {
    if (text.len == 0) return true;
    return containsIgnoreCase(extension.name, text) or
        containsIgnoreCase(extension.display_name, text) or
        containsIgnoreCase(extension.description, text);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn lessThanExtension(_: void, a: *const IExtension, b: *const IExtension) bool {
    if (a.is_builtin != b.is_builtin) return !a.is_builtin;
    const display_order = std.ascii.orderIgnoreCase(a.display_name, b.display_name);
    if (display_order != .eq) return display_order == .lt;
    return std.mem.order(u8, a.identifier, b.identifier) == .lt;
}

/// Port of the local filtered-query behavior: plain text, `@installed`,
/// `@builtin`, `@enabled`, `@disabled`, `category:` and `@id:` combine as
/// predicates. User-installed extensions sort before built-ins, then by
/// display name. Fixed allocation per call; the returned slice is owned by the
/// caller.
pub fn filterExtensions(allocator: Allocator, local: []const IExtension, query_text: []const u8) ![]const *const IExtension {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = try parseFilter(scratch, query_text);
    var result: std.array_list.Managed(*const IExtension) = .init(allocator);
    errdefer result.deinit();
    for (local) |*extension| {
        if (parsed.installed and extension.is_builtin) continue;
        if (parsed.builtin and !extension.is_builtin) continue;
        if (parsed.enabled and !extension.isEnabled()) continue;
        if (parsed.disabled and extension.isEnabled()) continue;
        if (!matchesId(extension, parsed.ids)) continue;
        if (!matchesCategories(extension, parsed.included_categories, parsed.excluded_categories)) continue;
        if (!matchesText(extension, parsed.text)) continue;
        try result.append(extension);
    }
    std.mem.sort(*const IExtension, result.items, {}, lessThanExtension);
    return result.toOwnedSlice();
}
