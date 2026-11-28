// Port of `src/vs/workbench/contrib/extensions/browser/extensionsViewlet.ts`.
// The query chooses registered panes; the container-level search header is
// shared across all panes. Local built-ins use the three upstream categories.
// Terminal adaptation: the generic ViewPaneContainer lays out retained cell
// panes and its fixed search header instead of browser elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const SidebarPart = @import("../../../browser/parts/sidebar/sidebarPart.zig").SidebarPart;
const ViewDescriptorService = @import("../../../services/views/browser/viewDescriptorService.zig").ViewDescriptorService;
const ViewContainerModel = @import("../../../services/views/common/viewContainerModel.zig").ViewContainerModel;
const pane_container = @import("../../../browser/parts/views/viewPaneContainer.zig");
const Pane = pane_container.Pane;
const view_mod = @import("extensionsViews.zig");
const ExtensionsListView = view_mod.ExtensionsListView;
const service_mod = @import("extensionsWorkbenchService.zig");
const model = @import("../common/extensions.zig");

const Mode = enum { installed, search_installed, marketplace, enabled, disabled, builtin_features, builtin_themes, builtin_languages, outdated, recently_updated, recommended, popular, search_recommended, restart_required };
const descriptors_list = [_]views.ViewDescriptor{
    .{ .id = "workbench.views.extensions.installed", .name = "Installed", .order = 1, .weight = 100, .can_toggle_visibility = false, .can_move = false },
    .{ .id = "workbench.views.extensions.searchInstalled", .name = "Installed", .order = 1, .weight = 100, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.marketplace", .name = "Marketplace", .order = 1, .weight = 100, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.enabled", .name = "Enabled", .order = 1, .weight = 100, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.disabled", .name = "Disabled", .order = 1, .weight = 100, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.builtinFeatureExtensions", .name = "Features", .order = 1, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.builtinThemeExtensions", .name = "Themes", .order = 2, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.builtinProgrammingLanguageExtensions", .name = "Programming Languages", .order = 3, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.outdated", .name = "Outdated", .order = 1, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.recentlyUpdated", .name = "Recently Updated", .order = 2, .available = false, .can_move = false },
    .{ .id = "extensions.recommendedList", .name = "Recommended", .order = 3, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.popular", .name = "Popular", .order = 2, .weight = 60, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.workspaceRecommendations", .name = "Workspace Recommendations", .order = 3, .available = false, .can_move = false },
    .{ .id = "workbench.views.extensions.restartRequired", .name = "Restart Required", .order = 1, .available = false, .can_move = false },
};

pub fn registerViews(registry: *views.ViewsRegistry) !void {
    try registry.registerViews(&descriptors_list, model.VIEW_ID);
}

pub const ExtensionsViewPaneContainer = struct {
    allocator: Allocator,
    sidebar: *SidebarPart,
    descriptors: *ViewDescriptorService,
    model: *ViewContainerModel,
    panes: []Pane,
    container: *pane_container.ViewPaneContainer,
    view: *ExtensionsListView,
    themes: *ExtensionsListView,
    languages: *ExtensionsListView,
    recent: *ExtensionsListView,
    popular: *ExtensionsListView,
    recommended: *ExtensionsListView,

    pub const Options = struct {
        service: ?*service_mod.ExtensionsWorkbenchService = null,
        host: view_mod.Host,
    };

    pub fn attach(allocator: Allocator, sidebar: *SidebarPart, descriptors: *ViewDescriptorService, options: Options) !*ExtensionsViewPaneContainer {
        const self = try allocator.create(ExtensionsViewPaneContainer);
        errdefer allocator.destroy(self);
        const view = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer view.deinit();
        const themes = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer themes.deinit();
        const languages = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer languages.deinit();
        const recent = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer recent.deinit();
        const popular = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer popular.deinit();
        popular.gallery_kind = .popular;
        try popular.setFilter("@popular", .all);
        const recommended = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer recommended.deinit();
        recommended.gallery_kind = .recommended;
        try recommended.setFilter("@recommended", .all);
        try recent.setFilter("@recentlyUpdated", .all);
        try themes.setFilter("@builtin", .themes);
        try languages.setFilter("@builtin", .languages);

        const view_model = try allocator.create(ViewContainerModel);
        errdefer allocator.destroy(view_model);
        view_model.* = ViewContainerModel.init(allocator, .{ .id = model.VIEW_ID, .title = "Extensions", .icon = "" });
        errdefer view_model.deinit();
        const panes = try allocator.alloc(Pane, descriptors_list.len);
        errdefer allocator.free(panes);
        for (descriptors_list, 0..) |descriptor, i| {
            const context = switch (@as(Mode, @fromBackingInt(@intCast(i)))) {
                .builtin_themes => themes,
                .builtin_languages => languages,
                .recently_updated => recent,
                .popular => popular,
                .recommended => recommended,
                else => view,
            };
            panes[i] = .{ .id = descriptor.id, .title = descriptor.name, .context = context, .render_body = renderBody, .handle_key = handleKey, .handle_mouse = handleMouse, .set_focused = setFocused, .title_actions = titleActions };
        }
        const container = try sidebar.createViewPaneContainer(descriptors, view_model, panes);
        self.* = .{ .allocator = allocator, .sidebar = sidebar, .descriptors = descriptors, .model = view_model, .panes = panes, .container = container, .view = view, .themes = themes, .languages = languages, .recent = recent, .popular = popular, .recommended = recommended };
        container.setFixedHeader(.{ .id = model.VIEW_ID, .title = "Search Extensions", .context = view, .render_body = renderSearch, .handle_key = handleSearchKey, .handle_mouse = handleSearchMouse, .set_focused = setSearchFocused, .title_actions = titleActions });
        view.query_changed = .{ .context = self, .run = queryChanged };
        return self;
    }

    pub fn deinit(self: *ExtensionsViewPaneContainer) void {
        const allocator = self.allocator;
        self.view.query_changed = null;
        self.sidebar.disposeViewPaneContainer(self.descriptors, self.container);
        self.view.deinit();
        self.themes.deinit();
        self.languages.deinit();
        self.recent.deinit();
        self.popular.deinit();
        self.recommended.deinit();
        self.model.deinit();
        allocator.destroy(self.model);
        allocator.free(self.panes);
        allocator.destroy(self);
    }

    pub fn setService(self: *ExtensionsViewPaneContainer, service: ?*service_mod.ExtensionsWorkbenchService) !void {
        try self.view.setService(service);
        try self.themes.setService(service);
        try self.languages.setService(service);
        try self.recent.setService(service);
        try self.popular.setService(service);
        try self.recommended.setService(service);
    }

    pub fn list(self: *ExtensionsViewPaneContainer) *ExtensionsListView {
        return self.view;
    }

    fn hasToken(query: []const u8, token: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (words.next()) |word| if (std.ascii.eqlIgnoreCase(word, token)) return true;
        return false;
    }

    fn hasPrefixToken(query: []const u8, prefix: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (words.next()) |word| if (word.len >= prefix.len and std.ascii.eqlIgnoreCase(word[0..prefix.len], prefix)) return true;
        return false;
    }

    fn queryChanged(context: *anyopaque) void {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        const text = std.mem.trim(u8, self.view.queryText(), " \t\r\n");
        const mode: Mode = if (text.len == 0) .installed else if (hasToken(text, "@builtin")) .builtin_features else if (hasToken(text, "@installed") or hasPrefixToken(text, "@contribute:")) .search_installed else if (hasToken(text, "@enabled")) .enabled else if (hasToken(text, "@disabled")) .disabled else if (hasToken(text, "@updates") or hasToken(text, "@outdated")) .outdated else if (hasToken(text, "@restartRequired")) .restart_required else if (hasToken(text, "@recentlyUpdated")) .recently_updated else if (hasToken(text, "@recommended")) .search_recommended else .marketplace;
        const default = mode == .installed;
        const has_gallery = if (self.view.service) |service| service.gallery_url != null else false;
        const popular = default and self.view.showDefaultPopular();
        const recommended = default and has_gallery and if (self.view.service) |service| if (service.update_configuration) |config| !config.getBool("extensions.showRecommendationsOnlyOnDemand", false) else true else false;
        if (popular) self.popular.ensureGallery();
        if (recommended) self.recommended.ensureGallery();
        const builtin = mode == .builtin_features;
        const updates = hasToken(text, "@updates");
        self.view.builtin_group = if (builtin) .features else .all;
        if (builtin) {
            self.themes.setFilter(text, .themes) catch {};
            self.languages.setFilter(text, .languages) catch {};
        }
        // Query visibility is an availability condition, not the user's
        // persisted visibility preference. Publish availability immediately.
        for (descriptors_list, 0..) |descriptor, i| {
            const candidate: Mode = @fromBackingInt(@intCast(i));
            self.descriptors.setViewAvailable(descriptor.id, candidate == mode or (popular and candidate == .popular) or (recommended and candidate == .recommended) or (builtin and (candidate == .builtin_themes or candidate == .builtin_languages)) or (updates and candidate == .recently_updated));
        }
    }

    pub fn handleEscape(self: *ExtensionsViewPaneContainer) bool {
        if (!self.container.fixed_header_focused) {
            self.container.focusFixedHeader(true);
            return true;
        }
        if (self.view.queryText().len == 0) return false;
        self.view.clearSearch();
        return true;
    }

    pub fn pointerAt(self: *ExtensionsViewPaneContainer, id: []const u8, event: *const ui.MouseEvent, rect: ui.Rect) ui.Pointer {
        if (std.mem.eql(u8, id, model.VIEW_ID)) return .text;
        for (self.panes) |pane| if (std.mem.eql(u8, id, pane.id)) {
            const view: *ExtensionsListView = @ptrCast(@alignCast(pane.context));
            return view.pointerAt(event, rect);
        };
        return .default;
    }

    fn renderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) anyerror!void {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        try view.render(grid, rect, focused);
    }
    fn handleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        return view.handleKey(event);
    }
    fn handleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        return view.handleMouse(event, rect);
    }
    fn setFocused(context: *anyopaque, focused: bool) void {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        view.setFocused(focused);
    }
    fn titleActions(context: *anyopaque) []const views.TitleAction {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        return view.titleActions();
    }
    fn renderSearch(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, _: bool) anyerror!void {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        try view.renderSearch(grid, rect);
    }
    fn handleSearchKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        return view.handleSearchKey(event);
    }
    fn handleSearchMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        return view.handleSearchMouse(event, rect);
    }
    fn setSearchFocused(context: *anyopaque, focused: bool) void {
        const view: *ExtensionsListView = @ptrCast(@alignCast(context));
        view.setSearchFocused(focused);
    }
};
