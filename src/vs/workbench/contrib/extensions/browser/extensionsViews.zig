// Port of `src/vs/workbench/contrib/extensions/browser/extensionsViews.ts`
// and the list wrapper from `extensionsViewer.ts`.
// The view container owns the common search header, and the shared ListWidget
// renders the current query's rows. Gallery work uses a delayed, cancellable
// worker job; inventory and management events rebuild the list. Local
// enablement filters use persisted state rather than a running-host registry.
// Pages are fetched on scrolling. Search completions and some specialized
// query types remain unported.
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
const gallery = @import("../../../../platform/extensionManagement/common/extensionGalleryService.zig");
const paging = @import("../../../../base/common/paging.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const query_mod = @import("../common/extensionQuery.zig");
const service_mod = @import("extensionsWorkbenchService.zig");
const IExtension = model.IExtension;
const EnablementState = model.EnablementState;
const IContextMenuService = @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService;
const Anchor = @import("../../../../platform/contextview/browser/contextMenuService.zig").Anchor;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;
const INotificationService = @import("../../../../platform/notification/common/notification.zig").INotificationService;

/// Host capability boundary for opening a typed extension editor by identifier.
pub const Host = struct {
    context: *anyopaque,
    open_extension: *const fn (context: *anyopaque, identifier: []const u8) anyerror!void,
    request_frame: *const fn (context: *anyopaque) void,
    status: *const fn (context: *anyopaque, message: []const u8) void,
    context_menu: ?IContextMenuService = null,
    notifications: ?INotificationService = null,
    theme: list_renderer.ThemeGetter,
    window: ?*dispatch.Queue = null,
};

pub const refresh_action_id = "workbench.extensions.action.refreshExtension";
pub const clear_search_action_id = "workbench.extensions.action.clearExtensionsSearchResults";

const refresh_action = views.TitleAction{ .id = refresh_action_id, .label = "Refresh", .glyph = '\u{21BB}' };
const title_actions = [_]views.TitleAction{refresh_action};

const GalleryJob = struct {
    view: *ExtensionsListView,
    url: []u8,
    text: []u8,
    names: [][]u8,
    page: usize,
    completion: dispatch.Task,
    future: std.Io.Future(anyerror!gallery.Page),
};

fn runGallery(job: *GalleryJob) anyerror!gallery.Page {
    defer job.completion.post();
    const io = job.view.host.window.?.io;
    return dispatch.workerCall(io, queryGallery, .{ job.view.allocator, dispatch.backingIo(io), job.url, job.text, job.names, job.page });
}

fn queryGallery(allocator: Allocator, io: std.Io, url: []const u8, text: []const u8, names: []const []const u8, page: usize) !gallery.Page {
    var query = try query_mod.Query.parse(allocator, text);
    defer query.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try parseFilter(arena.allocator(), query.value);
    var criteria: std.ArrayList(gallery.Criterion) = .empty;
    defer criteria.deinit(allocator);
    if ((parsed.updates or parsed.recommended) and names.len == 0) return gallery.Page.parse(allocator, "{\"results\":[]}");
    for (names) |id| try criteria.append(allocator, .{ .filterType = @backingInt(gallery.FilterType.extension_name), .value = id });
    if (parsed.text.len > 0) try criteria.append(allocator, .{ .filterType = @backingInt(gallery.FilterType.search_text), .value = parsed.text });
    for (parsed.ids) |id| try criteria.append(allocator, .{ .filterType = @backingInt(gallery.FilterType.extension_name), .value = id });
    for (parsed.included_categories) |category| try criteria.append(allocator, .{ .filterType = @backingInt(gallery.FilterType.category), .value = category });
    const sort: gallery.SortBy = if (parsed.popular or query.value.len == 0 or std.ascii.eqlIgnoreCase(query.sort_by, "installs")) .installs else if (std.ascii.eqlIgnoreCase(query.sort_by, "rating")) .rating else if (std.ascii.eqlIgnoreCase(query.sort_by, "name")) .name else if (std.ascii.eqlIgnoreCase(query.sort_by, "publishedDate")) .published else if (std.ascii.eqlIgnoreCase(query.sort_by, "updateDate")) .updated else .relevance;
    return (gallery.ExtensionGalleryService{ .allocator = allocator, .io = io, .service_url = url }).query(.{ .criteria = criteria.items, .sort_by = sort, .page = page });
}

pub const BuiltinGroup = enum { all, features, themes, languages };

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
    recommendations_listener: ?SignalSubscription = null,
    message_buffer: [256]u8 = undefined,
    search_delayer: dispatch.Task = .{},
    gallery_job: ?*GalleryJob = null,
    gallery_loading: bool = false,
    gallery_error: bool = false,
    gallery_kind: service_mod.GalleryKind = .search,
    gallery_pages: paging.PageIterator = .{ .page_size = 50 },
    initial_gallery_search_started: bool = false,
    builtin_group: BuiltinGroup = .all,
    filter_override: ?[]u8 = null,
    query_changed: ?struct { context: *anyopaque, run: *const fn (*anyopaque) void } = null,

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
        self.search_delayer = .{ .queue = self.host.window, .context = self, .run = startGallery };
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
        self.cancelGallery();
        self.unsubscribe();
        if (self.filter_override) |query| self.allocator.free(query);
        self.list.deinit();
        self.input_box.deinit();
        if (self.input_surface) |*surface| surface.deinit();
        self.input_surface = null;
        self.allocator.free(self.rows);
        self.rows = &.{};
        self.selected_id.deinit();
    }

    pub fn setService(self: *ExtensionsListView, service: ?*service_mod.ExtensionsWorkbenchService) !void {
        self.cancelGallery();
        self.gallery_loading = false;
        self.gallery_error = false;
        self.gallery_pages = .{ .page_size = 50 };
        self.initial_gallery_search_started = false;
        self.unsubscribe();
        self.service = service;
        try self.subscribe();
        try self.rebuild();
    }

    fn subscribe(self: *ExtensionsListView) !void {
        const service = self.service orelse return;
        self.listener = try service.on_change.listenSignal(self, onServiceChange);
        self.recommendations_listener = try service.on_recommendations_change.listenSignal(self, onRecommendationsChange);
    }

    fn unsubscribe(self: *ExtensionsListView) void {
        if (self.listener) |listener| listener.dispose();
        self.listener = null;
        if (self.recommendations_listener) |listener| listener.dispose();
        self.recommendations_listener = null;
    }

    fn onServiceChange(self: *ExtensionsListView) !void {
        if (self.queryText().len == 0) if (self.query_changed) |callback| callback.run(callback.context);
        try self.rebuild();
    }

    fn onRecommendationsChange(self: *ExtensionsListView) !void {
        if (self.gallery_kind == .recommended or (self.filter_override == null and containsIgnoreCase(self.queryText(), "@recommended"))) {
            if (self.initial_gallery_search_started or self.gallery_kind == .search) self.searchChanged();
        }
    }

    fn onInputChange(context: ?*anyopaque, _: []const u8) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context orelse return));
        self.searchChanged();
    }

    fn onInputEnter(context: ?*anyopaque) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context orelse return));
        self.focusList();
    }

    fn searchesGallery(self: *const ExtensionsListView) bool {
        if (self.filter_override != null and self.gallery_kind == .search) return false;
        const service = self.service orelse return false;
        if (service.gallery_url == null or self.host.window == null) return false;
        const text = std.mem.trim(u8, self.queryText(), " \t");
        if (text.len == 0) return false;
        for ([_][]const u8{ "@installed", "@builtin", "@enabled", "@disabled", "@recentlyUpdated" }) |token| {
            if (containsIgnoreCase(text, token)) return false;
        }
        return true;
    }

    pub fn showDefaultPopular(self: *const ExtensionsListView) bool {
        const service = self.service orelse return false;
        if (service.gallery_url == null) return false;
        for (service.queryLocal()) |extension| if (!extension.is_builtin) return false;
        return true;
    }

    pub fn ensureGallery(self: *ExtensionsListView) void {
        if (self.initial_gallery_search_started or !self.searchesGallery()) return;
        self.initial_gallery_search_started = true;
        self.searchChanged();
    }

    fn galleryNames(self: *ExtensionsListView, text: []const u8) ![][]u8 {
        const service = self.service orelse return self.allocator.alloc([]u8, 0);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const filter = try parseFilter(arena.allocator(), text);
        if (filter.recommended) {
            const workspace = service.workspace orelse return self.allocator.alloc([]u8, 0);
            return @import("workspaceRecommendations.zig").read(self.allocator, service.io, workspace.getWorkspace());
        }
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        if (filter.updates) for (service.queryLocal()) |extension| {
            if (extension.is_builtin) continue;
            const copy = try self.allocator.dupe(u8, extension.identifier);
            errdefer self.allocator.free(copy);
            try names.append(self.allocator, copy);
        };
        return names.toOwnedSlice(self.allocator);
    }

    fn freeNames(self: *ExtensionsListView, names: [][]u8) void {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }

    fn searchChanged(self: *ExtensionsListView) void {
        self.cancelGallery();
        self.gallery_error = false;
        self.gallery_pages = .{ .page_size = 50 };
        self.gallery_loading = self.searchesGallery();
        if (self.query_changed) |callback| callback.run(callback.context);
        self.rebuild() catch {};
        if (self.gallery_loading) self.search_delayer.schedule(time.milliTimestamp(self.host.window.?.workerIo()) + 500);
        self.requestFrame();
    }

    fn cancelGallery(self: *ExtensionsListView) void {
        self.search_delayer.schedule(null);
        const job = self.gallery_job orelse return;
        self.gallery_job = null;
        const result = job.future.cancel(self.host.window.?.io);
        job.completion.schedule(null);
        if (result) |page| {
            var owned = page;
            owned.deinit();
        } else |_| {}
        self.freeNames(job.names);
        self.allocator.free(job.text);
        self.allocator.free(job.url);
        self.allocator.destroy(job);
    }

    fn startGallery(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context));
        self.startGalleryJob() catch {
            self.gallery_loading = false;
            self.gallery_error = true;
            self.rebuild() catch {};
        };
        return true;
    }

    fn startGalleryJob(self: *ExtensionsListView) !void {
        const service = self.service orelse return error.GalleryUnavailable;
        const window = self.host.window orelse return error.GalleryUnavailable;
        const page = self.gallery_pages.nextPage() orelse return;
        const url = try self.allocator.dupe(u8, service.gallery_url orelse return error.GalleryUnavailable);
        errdefer self.allocator.free(url);
        const text = try self.allocator.dupe(u8, self.queryText());
        errdefer self.allocator.free(text);
        const names = try self.galleryNames(text);
        errdefer self.freeNames(names);
        const job = try self.allocator.create(GalleryJob);
        job.* = .{ .view = self, .url = url, .text = text, .names = names, .page = page, .completion = .{ .queue = window, .context = self, .run = applyGallery, .progress = true }, .future = undefined };
        self.gallery_job = job;
        job.future = window.io.async(runGallery, .{job});
    }

    fn applyGallery(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context));
        const job = self.gallery_job orelse return false;
        self.gallery_job = null;
        defer self.allocator.destroy(job);
        defer self.allocator.free(job.url);
        defer self.allocator.free(job.text);
        defer self.freeNames(job.names);
        const result = job.future.await(self.host.window.?.io);
        self.gallery_loading = false;
        if (result) |page| {
            const count = page.extensions.len;
            const total = page.total;
            if (self.service) |service| {
                self.gallery_pages.accept(job.page, count, total) catch {};
                service.setGalleryPage(page, job.page > 1, self.gallery_kind) catch {
                    self.gallery_error = true;
                };
            } else {
                var owned = page;
                owned.deinit();
            }
        } else |_| self.gallery_error = true;
        self.rebuild() catch {};
        return true;
    }

    pub fn queryText(self: *const ExtensionsListView) []const u8 {
        return self.filter_override orelse self.input_box.getValue();
    }

    pub fn setFilter(self: *ExtensionsListView, query: []const u8, group: BuiltinGroup) !void {
        const text = try self.allocator.dupe(u8, query);
        if (self.filter_override) |previous| self.allocator.free(previous);
        self.filter_override = text;
        self.builtin_group = group;
        try self.rebuild();
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
        var rows = if (self.searchesGallery()) blk: {
            const entries = if (self.gallery_pages.page == 0) &[_]IExtension{} else self.service.?.galleryExtensionsFor(self.gallery_kind);
            var result: std.ArrayList(*const IExtension) = .empty;
            errdefer result.deinit(self.allocator);
            const updates = containsIgnoreCase(self.queryText(), "@updates") or containsIgnoreCase(self.queryText(), "@outdated");
            const recommended = containsIgnoreCase(self.queryText(), "@recommended");
            for (entries) |*entry| {
                if (updates and self.service.?.availableUpdate(entry.identifier) == null) continue;
                if (recommended and self.service.?.findLocal(entry.identifier) != null) continue;
                try result.append(self.allocator, entry);
            }
            break :blk try result.toOwnedSlice(self.allocator);
        } else try filterExtensions(self.allocator, local, if (self.queryText().len == 0) "@installed" else self.queryText());
        errdefer self.allocator.free(rows);
        if (containsIgnoreCase(self.queryText(), "@recentlyUpdated")) {
            const now = if (self.service) |service| time.milliTimestamp(service.io) else 0;
            var filtered: std.ArrayList(*const IExtension) = .empty;
            defer filtered.deinit(self.allocator);
            for (rows) |entry| {
                const timestamp = entry.installed_timestamp orelse continue;
                if (now -| timestamp >= 7 * 24 * 60 * 60 * 1000) continue;
                if (self.service) |service| if (service.availableUpdate(entry.identifier) != null) continue;
                try filtered.append(self.allocator, entry);
            }
            const result = try filtered.toOwnedSlice(self.allocator);
            self.allocator.free(rows);
            rows = result;
        }
        if (self.builtin_group != .all) {
            var filtered: std.ArrayList(*const IExtension) = .empty;
            defer filtered.deinit(self.allocator);
            for (rows) |extension| {
                const is_theme = extension.hasCategory("themes");
                const is_language = extension.hasCategory("programming languages");
                const include = switch (self.builtin_group) {
                    .features => !is_theme and !is_language,
                    .themes => is_theme,
                    .languages => is_language,
                    .all => true,
                };
                if (include) try filtered.append(self.allocator, extension);
            }
            const result = try filtered.toOwnedSlice(self.allocator);
            self.allocator.free(rows);
            rows = result;
        }
        var elements = try self.allocator.alloc(list_mod.Element, rows.len);
        defer self.allocator.free(elements);
        for (rows, 0..) |extension, index| elements[index] = @ptrCast(extension);
        try self.list.replaceAll(elements);
        self.allocator.free(self.rows);
        self.rows = rows;

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
            if (target) |index| self.list.selectOnly(index) else self.list.setSelection(0);
        }
        self.requestFrame();
    }

    pub fn setFocused(self: *ExtensionsListView, focused: bool) void {
        self.focused = focused;
        self.setInputFocused(false);
    }

    pub fn setSearchFocused(self: *ExtensionsListView, focused: bool) void {
        self.focused = focused;
        self.setInputFocused(focused);
        if (focused and self.queryText().len == 0) if (self.query_changed) |callback| callback.run(callback.context);
    }

    pub fn handleSearchKey(self: *ExtensionsListView, event: *ui.KeyEvent) bool {
        switch (event.key) {
            .down, .enter, .tab, .backtab => return false,
            else => {},
        }
        const handled = self.input_box.handleKey(event);
        if (handled) self.requestFrame();
        return handled;
    }

    pub fn handleSearchMouse(self: *ExtensionsListView, event: *const ui.MouseEvent, rect: ui.Rect) bool {
        var local = event.*;
        local.x -|= ui.cell.snap(rect.x);
        local.y = 0;
        const handled = self.input_box.handleMouse(&local);
        if (handled) self.requestFrame();
        return handled;
    }

    pub fn renderSearch(self: *ExtensionsListView, grid: *ui.CellGrid, rect: ui.Rect) !void {
        try self.renderInput(grid, ui.cell.snap(rect.x), ui.cell.snap(rect.y), ui.cell.snap(rect.w), list_renderer.colors(self.theme()));
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
        _ = event;
        _ = rect;
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
        self.searchChanged();
    }

    pub fn refresh(self: *ExtensionsListView) !void {
        const service = self.service orelse return;
        service.refresh() catch |err| {
            if (self.host.notifications) |notifications| notifications.err(.{ .text = "Unable to refresh extensions." });
            self.host.status(self.host.context, "Unable to refresh extensions");
            return err;
        };
        self.searchChanged();
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

    /// PagedList resolves a page when the visible range approaches its end.
    /// Terminal input/scroll events trigger that resolution, never paint.
    fn resolveVisiblePage(self: *ExtensionsListView) void {
        if (!self.searchesGallery() or self.gallery_loading or self.gallery_pages.page == 0 or !self.gallery_pages.hasNextPage()) return;
        const view = &self.list.view;
        if (view.scroll_top + view.viewport_height + 9 < view.range_map.size()) return;
        self.gallery_loading = true;
        self.gallery_error = false;
        self.startGalleryJob() catch {
            self.gallery_loading = false;
            self.gallery_error = true;
        };
    }

    pub fn handleKey(self: *ExtensionsListView, event: *const ui.KeyEvent) !bool {
        if (!self.focused) return false;
        switch (event.key) {
            .tab, .backtab => return false,
            .up => if (self.list.selection() == null or self.list.selection().? == 0) return false,
            .escape => return false,
            .enter => {
                try self.openSelected();
                return true;
            },
            else => {},
        }
        const handled = self.list.handleKey(@constCast(event));
        if (handled) {
            self.resolveVisiblePage();
            self.requestFrame();
        }
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

        const list_top = y;
        const list_height = height;
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
            const position = self.list.view.scroll_top + @as(f64, @floatFromInt(event.y - list_top));
            const hit = self.list.view.indexAt(position);
            if (hit >= 0 and hit < @as(i64, @intCast(self.rows.len))) {
                const index: usize = @intCast(hit);
                const extension = self.rows[index];
                const row_top = self.list.view.range_map.positionAt(hit);
                if (position - row_top >= 2 and list_width >= 10) {
                    if (extension.state == .Uninstalled and extension.vsix_url != null and event.x >= x + list_width - 9) {
                        if (self.service) |service| service.install(extension.*) catch {};
                        self.requestFrame();
                        return true;
                    }
                    if (extension.state == .Installed and event.x >= x + list_width - 3) {
                        try self.showRowMenu(extension, .mouse(event));
                        return true;
                    }
                }
                try self.openExtension(extension);
            }
            self.resolveVisiblePage();
            self.requestFrame();
            return true;
        }

        const handled = self.list.handleMouse(event);
        if (handled) {
            self.resolveVisiblePage();
            self.requestFrame();
        }
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
        try self.host.open_extension(self.host.context, extension.identifier);
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
            workspace: bool = false,
            open: bool = false,
            install: bool = false,
            uninstall: bool = false,
            versions: bool = false,
            restart: bool = false,
            pub fn run(action: *@This()) !void {
                if (action.restart) {
                    if (action.view.service) |view_service| try view_service.restartExtensions();
                    return;
                }
                if (action.versions) {
                    if (action.view.service) |view_service| try view_service.showVersions(action.identifier);
                    return;
                }
                if (action.install or action.uninstall) {
                    const view_service = action.view.service orelse return;
                    if (action.install) {
                        if (view_service.availableUpdate(action.identifier) orelse view_service.galleryInfo(action.identifier)) |entry| try view_service.install(entry.*);
                    } else try view_service.uninstall(action.identifier);
                    return;
                }
                if (action.open) {
                    if (action.view.service) |view_service| {
                        if (view_service.find(action.identifier)) |found| {
                            return action.view.openExtension(found);
                        }
                    }
                    return;
                }
                try action.view.toggleEnablement(action.identifier, action.enable, action.workspace);
            }
        };
        const identifier = try arena.dupe(u8, extension.identifier);
        if (extension.state == .Uninstalled) {
            if (extension.vsix_url != null) try menu.addAction("extensions.install", "Install", null, Command{ .view = self, .identifier = identifier, .install = true });
        } else if (extension.isEnabled()) {
            try menu.addAction("extensions.disableGlobally", "Disable", null, Command{ .view = self, .identifier = identifier, .enable = false });
        } else {
            try menu.addAction("extensions.enableGlobally", "Enable", null, Command{ .view = self, .identifier = identifier, .enable = true });
        }
        if (extension.state == .Installed) if (self.service) |workbench_service| {
            if (workbench_service.enablement.has_workspace) {
                const enable = !extension.isEnabled();
                try menu.addAction(if (enable) "extensions.enableForWorkspace" else "extensions.disableForWorkspace", if (enable) "Enable (Workspace)" else "Disable (Workspace)", null, Command{ .view = self, .identifier = identifier, .enable = enable, .workspace = true });
            }
        };
        if (extension.state == .Installed and !extension.is_builtin) {
            if (self.service) |view_service| if (view_service.availableUpdate(extension.identifier) != null) try menu.addAction("extensions.update", "Update", null, Command{ .view = self, .identifier = identifier, .install = true });
            try menu.addAction("extensions.uninstall", "Uninstall", null, Command{ .view = self, .identifier = identifier, .uninstall = true });
        }
        if (self.service) |view_service| if (view_service.runtimeState(identifier) == .RestartExtensions) try menu.addAction("extensions.runtimeState", "Restart Extensions", null, Command{ .view = self, .identifier = identifier, .restart = true });
        if (!extension.is_builtin) try menu.addAction("extensions.installAnotherVersion", "Install Another Version…", null, Command{ .view = self, .identifier = identifier, .versions = true });
        try menu.addAction("workbench.extensions.action.openExtension", "Open Extension", null, Command{ .view = self, .identifier = identifier, .open = true });
        try service.showContextMenu(menu, anchor);
    }

    fn toggleEnablement(self: *ExtensionsListView, identifier: []const u8, enable: bool, workspace: bool) !void {
        const service = self.service orelse return;
        const state: EnablementState = if (workspace) (if (enable) .EnabledWorkspace else .DisabledWorkspace) else if (enable) .EnabledGlobally else .DisabledGlobally;
        const changed = service.requestEnablement(identifier, state) catch {
            if (self.host.notifications) |notifications| notifications.err(.{ .text = "Unable to change extension enablement." });
            self.host.status(self.host.context, "Unable to change extension enablement");
            return;
        };
        if (!changed) return;
        self.rebuild() catch {};
        const name = if (service.find(identifier)) |extension| extension.display_name else identifier;
        const message = std.fmt.bufPrint(&self.message_buffer, "Extension '{s}' {s}.{s}", .{
            name,
            if (enable) "enabled" else "disabled",
            if (service.runtimeState(identifier)) |action| switch (action) {
                .RestartExtensions => " Restart Extensions to apply the change.",
                .ReloadWindow => " Restart the editor to apply the change.",
            } else "",
        }) catch "Extension enablement changed.";
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

        const list_top = y;
        const list_height = height;
        if (list_height == 0) return;

        if (self.rows.len == 0) {
            var buffer: [256]u8 = undefined;
            const message = if (self.gallery_loading) "Searching Marketplace…" else if (self.gallery_error) "Unable to search Marketplace." else if (self.queryText().len == 0)
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
        return 3;
    }

    fn delegateTemplateId(_: *anyopaque, _: list_mod.Element) usize {
        return 0;
    }

    fn renderElement(context: *anyopaque, row: *const list_mod.Row, element: list_mod.Element) void {
        const self: *ExtensionsListView = @ptrCast(@alignCast(context));
        const extension: *const IExtension = @ptrCast(@alignCast(element));
        var display = extension.*;
        if (self.service) |service| if (service.operationState(extension.identifier)) |state| {
            display.state = state;
        };
        list_renderer.renderRow(row.grid, row, &display, list_renderer.colors(self.theme()));
    }
};

const ParsedFilter = struct {
    text: []const u8 = "",
    installed: bool = false,
    builtin: bool = false,
    enabled: bool = false,
    disabled: bool = false,
    updates: bool = false,
    recommended: bool = false,
    popular: bool = false,
    recently_updated: bool = false,
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
        if (tokenEquals(word, "@updates") or tokenEquals(word, "@outdated")) {
            result.updates = true;
            continue;
        }
        if (tokenEquals(word, "@recommended")) {
            result.recommended = true;
            continue;
        }
        if (tokenEquals(word, "@recentlyUpdated")) {
            result.recently_updated = true;
            continue;
        }
        if (tokenEquals(word, "@popular")) {
            result.popular = true;
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

fn newerExtension(_: void, a: *const IExtension, b: *const IExtension) bool {
    const a_time = a.installed_timestamp orelse 0;
    const b_time = b.installed_timestamp orelse 0;
    if (a_time != b_time) return a_time > b_time;
    return lessThanExtension({}, a, b);
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
        if (parsed.recently_updated and (extension.is_builtin or !extension.updated or extension.installed_timestamp == null)) continue;
        if (parsed.builtin and !extension.is_builtin) continue;
        if (parsed.enabled and !extension.isEnabled()) continue;
        if (parsed.disabled and extension.isEnabled()) continue;
        if (!matchesId(extension, parsed.ids)) continue;
        if (!matchesCategories(extension, parsed.included_categories, parsed.excluded_categories)) continue;
        if (!matchesText(extension, parsed.text)) continue;
        try result.append(extension);
    }
    if (parsed.recently_updated) std.mem.sort(*const IExtension, result.items, {}, newerExtension) else std.mem.sort(*const IExtension, result.items, {}, lessThanExtension);
    return result.toOwnedSlice();
}
