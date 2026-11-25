// Port of `src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.ts`
// (read-only terminal subset).
//
// The portable view model, filter resolution, pagination, merge-base/ref-color
// map, incoming/outgoing nodes and list/tree change children keep the upstream
// shape. The browser tree/quick-pick/menu layer is replaced by a `ui` DOM list:
// rows are absolute 1-cell nodes, mouse/focus events go through the DOM, and the
// result is composited through `ui.Surface`. Terminal adaptations:
// - hover is plain text (no markdown/avatars/commands);
// - one click selects and a second click on the selected commit toggles
//   expansion. Open Changes uses the host's single-file diff and picker;
// - the page fetch is synchronous and capped; the terminal has no progress UI;
// - the tree mode compresses single-child folders like `scm.compactFolders`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const actions = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../platform/contextkey/common/contextkey.zig");
const OverlayContext = @import("../../../../platform/contextkey/browser/contextKeyService.zig").OverlayContext;
const MenuService = @import("../../../../platform/actions/common/menuService.zig").MenuService;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;

const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const ui = @import("ui");
const history = @import("../common/history.zig");
const scm_history = @import("./scmHistory.zig");
const resource_tree = @import("../../../../base/common/resourceTree.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const views = @import("../../../common/views.zig");
const css = @import("./media/scm_css.zig");
const file_icon = @import("../../../services/themes/browser/fileIconThemeData.zig");
const list_scrollbar = @import("../../../../base/browser/ui/list/listScrollbarTerminal.zig");
const theme_colors_mod = @import("../../../browser/themeColors.zig");

pub const HISTORY_VIEW_PANE_ID = "workbench.scm.history";
pub const PICK_HISTORY_ITEM_REFS_ACTION_ID = "workbench.scm.action.graph.pickHistoryItemRefs";
pub const REVEAL_CURRENT_HISTORY_ITEM_ACTION_ID = "workbench.scm.action.graph.revealCurrentHistoryItem";
pub const GRAPH_MENU_ACTION_ID = "workbench.scm.action.graph.showMenu";
pub const REFRESH_GRAPH_ACTION_ID = "workbench.scm.action.graph.refresh";
pub const SET_LIST_VIEW_MODE_ACTION_ID = "workbench.scm.action.graph.setListViewMode";
pub const SET_TREE_VIEW_MODE_ACTION_ID = "workbench.scm.action.graph.setTreeViewMode";
pub const fetch_glyph: u21 = '⇣';
pub const open_changes_glyph: u21 = '▤';

pub fn registerMenus(registry: *actions.MenuRegistry) !void {
    inline for (.{
        .{ SET_LIST_VIEW_MODE_ACTION_ID, "View as List", "list", 1 },
        .{ SET_TREE_VIEW_MODE_ACTION_ID, "View as Tree", "tree", 2 },
    }) |entry| try registry.appendMenuItem(actions.menu_ids.SCMHistoryTitle, .{
        .command = .{ .id = entry[0], .title = entry[1], .toggled = &.{ .Equals = .{ .key = "scmHistoryViewMode", .value = .{ .string = entry[2] } } } },
        .group = "9_viewmode",
        .order = entry[3],
    });
}

pub fn appendSecondary(menu: *Menu, service: *MenuService, parent: keys.IContext, view: *const SCMHistoryViewPane) !void {
    var context = OverlayContext{ .parent = parent, .overlay = &.{
        .{ .key = "view", .value = .{ .string = HISTORY_VIEW_PANE_ID } },
        .{ .key = "scmHistoryViewMode", .value = .{ .string = @tagName(view.viewMode()) } },
    } };
    try menu.appendMenuActions(service, actions.menu_ids.SCMHistoryTitle, context.interface(), true);
}

pub const ViewMode = enum { list, tree };

pub const Config = struct {
    page_size: usize = 50,
    page_on_scroll: bool = true,
    badges_all: bool = false,
    show_incoming_changes: bool = true,
    show_outgoing_changes: bool = true,
    default_view_mode: ViewMode = .list,
    compact_folders: bool = true,
    short_hash_length: usize = 7,
    always_show_actions: bool = false,

    pub fn read(service: IConfigurationService) Config {
        var config = Config{};
        if (service.getValue("scm.graph.pageSize")) |value| {
            if (value.* == .integer) config.page_size = @intCast(std.math.clamp(value.integer, 1, 1000));
        }
        if (service.getValue("git.commitShortHashLength")) |value| {
            if (value.* == .integer) config.short_hash_length = @intCast(@max(value.integer, 1));
        }
        config.page_on_scroll = service.getBool("scm.graph.pageOnScroll", config.page_on_scroll);
        config.badges_all = std.mem.eql(u8, service.getString("scm.graph.badges") orelse "filter", "all");
        config.show_incoming_changes = service.getBool("scm.graph.showIncomingChanges", config.show_incoming_changes);
        config.show_outgoing_changes = service.getBool("scm.graph.showOutgoingChanges", config.show_outgoing_changes);
        config.default_view_mode = if (std.mem.eql(u8, service.getString("scm.defaultViewMode") orelse "list", "list")) .list else .tree;
        config.compact_folders = service.getBool("scm.compactFolders", config.compact_folders);
        config.always_show_actions = service.getBool("scm.alwaysShowActions", config.always_show_actions);
        return config;
    }
};

pub const Host = struct {
    context: *anyopaque,
    open_change: *const fn (
        context: *anyopaque,
        history_item: *const history.ISCMHistoryItem,
        change: *const history.ISCMHistoryItemChange,
    ) anyerror!void,
    open_changes: ?*const fn (
        context: *anyopaque,
        item: *const history.ISCMHistoryItem,
        changes: []const history.ISCMHistoryItemChange,
    ) anyerror!void = null,
    focus_editor: *const fn (context: *anyopaque) void,
    status: ?*const fn (*anyopaque, []const u8) void = null,
};

const FilterKind = enum { auto, all, selected };

const LoadMore = union(enum) {
    no,
    yes,
    cursor: []const u8,
};

const Row = union(enum) {
    history_item: usize,
    change: struct { vm: usize, change: *const history.ISCMHistoryItemChange, depth: usize },
    folder: struct { name: []const u8, key: []const u8, depth: usize, vm: usize },
    load_more: struct { vm: usize },
    welcome,
};

const QuickInputService = @import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

pub const SCMHistoryViewPane = struct {
    pub const ID = HISTORY_VIEW_PANE_ID;

    quick_input: ?*QuickInputService = null,
    ref_picker: ?*RefPickState = null,

    allocator: Allocator,
    provider: ?*history.ISCMHistoryProvider = null,
    host: Host,
    config: Config = .{},
    storage: ?*storage_mod.InMemoryStorageService = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    arena: std.heap.ArenaAllocator,
    changes_arena: std.heap.ArenaAllocator,
    view_models: []const history.ISCMHistoryItemViewModel = &.{},
    filter_kind: FilterKind = .auto,
    filter_ids: std.array_list.Managed([]u8),
    filter_refs: []const history.ISCMHistoryItemRef = &.{},
    merge_base: ?[]const u8 = null,
    view_mode: ViewMode = .list,
    loaded_pages: usize = 1,
    load_more: LoadMore = .no,

    rows: std.array_list.Managed(Row),
    selection: usize = 0,
    selection_active: bool = false,
    scroll: usize = 0,
    visible_rows: usize = 0,

    expanded: std.StringHashMap(void),
    collapsed_folders: std.StringHashMap(void),
    changes: std.StringHashMap([]const history.ISCMHistoryItemChange),

    surface: ?ui.Surface = null,
    signature: u64 = 0,
    revision: u64 = 0,
    theme_ptr: usize = 0,

    outdated: bool = false,
    last_error: ?anyerror = null,
    filter_label_buf: [64]u8 = undefined,
    filter_label_len: usize = 0,
    actions: [7]views.TitleAction = undefined,

    hovered_row: ?usize = null,
    hovered_action: bool = false,
    list_focused: bool = false,
    hover_content: ?[]u8 = null,
    hover_surface: ?ui.Surface = null,
    last_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(allocator: Allocator, host: Host, storage: ?*storage_mod.InMemoryStorageService) !*SCMHistoryViewPane {
        const self = try allocator.create(SCMHistoryViewPane);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .storage = storage,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .changes_arena = std.heap.ArenaAllocator.init(allocator),
            .filter_ids = std.array_list.Managed([]u8).init(allocator),
            .rows = std.array_list.Managed(Row).init(allocator),
            .expanded = std.StringHashMap(void).init(allocator),
            .collapsed_folders = std.StringHashMap(void).init(allocator),
            .changes = std.StringHashMap([]const history.ISCMHistoryItemChange).init(allocator),
        };
        self.view_mode = self.loadViewMode();
        self.updateFilterLabel();
        return self;
    }

    pub fn deinit(self: *SCMHistoryViewPane) void {
        if (self.ref_picker != null) self.quick_input.?.hide();
        self.clearOwnedKeys(&self.expanded);
        self.clearOwnedKeys(&self.collapsed_folders);
        self.expanded.deinit();
        self.collapsed_folders.deinit();
        self.changes.deinit();
        for (self.filter_ids.items) |id| self.allocator.free(id);
        self.filter_ids.deinit();
        self.clearHover();
        if (self.surface) |*surface| surface.deinit();
        self.arena.deinit();
        self.changes_arena.deinit();
        self.rows.deinit();
        self.* = undefined;
    }

    const RefPickState = struct {
        view: *SCMHistoryViewPane,
        arena: std.heap.ArenaAllocator,
    };

    fn disposeRefPick(context: *anyopaque) void {
        const state: *RefPickState = @ptrCast(@alignCast(context));
        const view = state.view;
        if (view.ref_picker == state) view.ref_picker = null;
        state.arena.deinit();
        view.allocator.destroy(state);
    }

    /// Port of pickHistoryItemRef. The existing terminal quick input supports
    /// one selected reference at a time, plus Auto and All.
    pub fn pickHistoryItemRef(self: *SCMHistoryViewPane) !void {
        const input = self.quick_input orelse return;
        const provider = self.provider orelse return;
        const refs = try provider.provideHistoryItemRefs(self.allocator, null);
        defer history.freeHistoryItemRefs(self.allocator, refs);

        const state = try self.allocator.create(RefPickState);
        state.* = .{ .view = self, .arena = std.heap.ArenaAllocator.init(self.allocator) };
        errdefer disposeRefPick(state);
        const arena = state.arena.allocator();
        var items: std.ArrayList(QuickPickItem) = .empty;
        try items.append(arena, .{ .item = .{ .id = "all", .label = "All", .description = "All history item references" } });
        try items.append(arena, .{ .item = .{ .id = "auto", .label = "Auto", .description = "Current history item references" } });
        if (refs.len > 0) try items.append(arena, .{ .separator = .{ .label = "References" } });
        for (refs) |reference| {
            try items.append(arena, .{ .item = .{
                .id = try arena.dupe(u8, reference.id),
                .label = try arena.dupe(u8, reference.name),
                .description = if (reference.description) |value| try arena.dupe(u8, value) else "",
            } });
        }
        self.ref_picker = state;
        try input.showPick(items.items, .{
            .placeholder = "Select a history item reference to view",
            .cleanup = disposeRefPick,
            .cleanup_context = state,
        }, refPickAccepted, state);
    }

    fn refPickAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const state: *RefPickState = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        const view = state.view;
        if (std.mem.eql(u8, item.id, "all")) {
            view.setFilterAll();
        } else if (std.mem.eql(u8, item.id, "auto")) {
            view.setFilterAuto();
        } else try view.setFilterRefs(&.{item.id});
    }

    pub fn refreshAction(self: *SCMHistoryViewPane) !void {
        self.outdated = false;
        try self.refresh(.reload);
    }

    pub fn setProvider(self: *SCMHistoryViewPane, provider: ?*history.ISCMHistoryProvider) void {
        self.provider = provider;
        self.updateFilterLabel();
        self.refresh(.reload) catch {};
    }

    pub fn setConfig(self: *SCMHistoryViewPane, config: Config) void {
        const mode_changed = config.default_view_mode != self.config.default_view_mode;
        self.config = config;
        if (mode_changed) {
            self.view_mode = self.loadViewMode();
            self.rebuildRows() catch {};
        }
        self.revision += 1;
    }

    pub fn setThemeColors(self: *SCMHistoryViewPane, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
        self.theme_ptr = if (palette) |value| @intFromPtr(value) else 0;
        self.revision += 1;
    }

    pub fn setViewMode(self: *SCMHistoryViewPane, mode: ViewMode) void {
        if (self.view_mode == mode) return;
        self.view_mode = mode;
        self.storeViewMode(mode);
        self.rebuildRows() catch {};
        self.revision += 1;
    }

    pub fn viewMode(self: *const SCMHistoryViewPane) ViewMode {
        return self.view_mode;
    }

    pub fn setFilterAuto(self: *SCMHistoryViewPane) void {
        self.filter_kind = .auto;
        self.clearFilterIds();
        self.resetAndRefresh();
    }

    pub fn setFilterAll(self: *SCMHistoryViewPane) void {
        self.filter_kind = .all;
        self.clearFilterIds();
        self.resetAndRefresh();
    }

    pub fn setFilterRefs(self: *SCMHistoryViewPane, ids: []const []const u8) !void {
        self.clearFilterIds();
        for (ids) |id| try self.filter_ids.append(try self.allocator.dupe(u8, id));
        self.filter_kind = .selected;
        self.resetAndRefresh();
    }

    pub fn filterLabel(self: *const SCMHistoryViewPane) []const u8 {
        return self.filter_label_buf[0..self.filter_label_len];
    }

    pub fn filterKind(self: *const SCMHistoryViewPane) FilterKind {
        return self.filter_kind;
    }

    pub fn filterRefs(self: *const SCMHistoryViewPane) []const history.ISCMHistoryItemRef {
        return self.filter_refs;
    }

    pub fn isOutdated(self: *const SCMHistoryViewPane) bool {
        return self.outdated;
    }

    pub fn hasCurrentHistoryItem(self: *const SCMHistoryViewPane) bool {
        if (self.provider) |provider| {
            const current = provider.history_item_ref orelse return false;
            return self.isHistoryItemInFilter(current.id);
        }
        return false;
    }

    /// Background ref changes keep the scrolled view stable and show the
    /// upstream "Outdated" badge; explicit refreshes restart from the top.
    pub fn onHistoryItemRefsChanged(self: *SCMHistoryViewPane, silent: bool) void {
        if (silent and self.scroll > 0) {
            self.outdated = true;
            self.revision += 1;
            return;
        }
        self.refresh(.reload) catch {};
        self.outdated = false;
    }

    pub fn refresh(self: *SCMHistoryViewPane, kind: RefreshKind) !void {
        const provider = self.provider orelse {
            self.view_models = &.{};
            self.rows.clearRetainingCapacity();
            self.rows.append(.welcome) catch {};
            self.revision += 1;
            return;
        };
        self.last_error = null;
        self.clearHover();
        _ = self.arena.reset(.retain_capacity);
        _ = self.changes_arena.reset(.retain_capacity);
        self.changes.clearRetainingCapacity();
        self.view_models = &.{};
        self.filter_refs = &.{};
        self.merge_base = null;

        const arena = self.arena.allocator();
        const current = provider.history_item_ref;
        const remote = provider.history_item_remote_ref;
        const base = provider.history_item_base_ref;

        const filter_refs = self.resolveFilter(arena, provider) catch |err| blk: {
            self.last_error = err;
            break :blk &.{};
        };
        self.filter_refs = filter_refs;
        self.updateFilterLabel();

        var color_map = scm_history.ColorMap.init(arena);
        if (current) |ref| try color_map.put(ref.id, ref.color);
        if (remote) |ref| try color_map.put(ref.id, ref.color);
        if (base) |ref| try color_map.put(ref.id, ref.color);
        for (filter_refs) |ref| {
            if (!color_map.contains(ref.id)) try color_map.put(ref.id, null);
        }

        if (current != null and remote != null and self.merge_base == null) {
            self.merge_base = provider.resolveHistoryItemRefsCommonAncestor(
                arena,
                &.{ current.?.name, remote.?.name },
            ) catch |err| blk: {
                self.last_error = err;
                break :blk null;
            };
        }

        if (kind == .more) {
            if (self.loaded_pages < 20) self.loaded_pages += 1;
        } else if (kind == .reload) {
            self.loaded_pages = 1;
        }

        var ref_ids = std.array_list.Managed([]const u8).init(arena);
        for (filter_refs) |ref| {
            try ref_ids.append(ref.revision orelse ref.id);
        }
        const all_refs = self.filter_kind == .all;
        const page_size = @max(self.config.page_size, 1);
        const wanted = page_size * self.loaded_pages;

        var items = std.array_list.Managed(history.ISCMHistoryItem).init(arena);
        var pages: usize = 0;
        const cursor: ?[]const u8 = if (kind == .cursor) blk: {
            switch (self.load_more) {
                .cursor => |value| break :blk value,
                else => break :blk null,
            }
        } else null;

        while (pages < 20) : (pages += 1) {
            const options = history.ISCMHistoryOptions{
                .history_item_refs = ref_ids.items,
                .limit = .{ .count = wanted },
                .skip = if (kind == .cursor) items.items.len else null,
                .all_refs = all_refs,
            };
            const page = provider.provideHistoryItems(arena, options) catch |err| {
                self.last_error = err;
                break;
            };
            if (page.len == 0) break;
            try items.appendSlice(page);
            if (cursor) |needle| {
                var found = false;
                for (page) |item| {
                    if (std.mem.eql(u8, item.id, needle)) {
                        found = true;
                        break;
                    }
                }
                if (found) break;
                if (page.len < wanted) break;
            } else {
                break;
            }
        }

        const add_incoming = self.config.show_incoming_changes and
            self.filter_refs.len > 0 and remote != null and
            self.isHistoryItemInFilter(remote.?.id);
        const add_outgoing = self.config.show_outgoing_changes and
            self.filter_refs.len > 0 and current != null and
            self.isHistoryItemInFilter(current.?.id);
        const view_models = scm_history.toISCMHistoryItemViewModelArray(
            arena,
            items.items,
            &color_map,
            current,
            remote,
            base,
            add_incoming,
            add_outgoing,
            self.merge_base,
        ) catch |err| blk: {
            self.last_error = err;
            break :blk &.{};
        };
        self.view_models = view_models;
        self.load_more = .no;
        try self.rebuildRows();
        self.clampSelection();
        self.revision += 1;
    }

    pub const RefreshKind = enum { reload, more, cursor };

    fn resetAndRefresh(self: *SCMHistoryViewPane) void {
        self.loaded_pages = 1;
        self.refresh(.reload) catch {};
        self.selection = 0;
        self.scroll = 0;
    }

    fn resolveFilter(
        self: *SCMHistoryViewPane,
        arena: Allocator,
        provider: *history.ISCMHistoryProvider,
    ) ![]history.ISCMHistoryItemRef {
        switch (self.filter_kind) {
            .auto => {
                var refs = std.array_list.Managed(history.ISCMHistoryItemRef).init(arena);
                if (provider.history_item_ref) |ref| try refs.append(ref);
                if (provider.history_item_remote_ref) |ref| try refs.append(ref);
                if (provider.history_item_base_ref) |ref| try refs.append(ref);
                return refs.toOwnedSlice();
            },
            .all => {
                return provider.provideHistoryItemRefs(arena, null) catch &.{};
            },
            .selected => {
                const ids = try arena.alloc([]const u8, self.filter_ids.items.len);
                for (self.filter_ids.items, 0..) |id, index| ids[index] = id;
                const refs = try provider.provideHistoryItemRefs(arena, ids);
                if (refs.len == 0) {
                    self.filter_kind = .auto;
                    self.clearFilterIds();
                    var fallback = std.array_list.Managed(history.ISCMHistoryItemRef).init(arena);
                    if (provider.history_item_ref) |ref| try fallback.append(ref);
                    if (provider.history_item_remote_ref) |ref| try fallback.append(ref);
                    if (provider.history_item_base_ref) |ref| try fallback.append(ref);
                    return fallback.toOwnedSlice();
                }
                return refs;
            },
        }
    }

    fn isHistoryItemInFilter(self: *const SCMHistoryViewPane, id: []const u8) bool {
        switch (self.filter_kind) {
            .auto, .all => return true,
            .selected => for (self.filter_ids.items) |candidate| {
                if (std.mem.eql(u8, candidate, id)) return true;
            },
        }
        return false;
    }

    fn clearFilterIds(self: *SCMHistoryViewPane) void {
        for (self.filter_ids.items) |id| self.allocator.free(id);
        self.filter_ids.clearRetainingCapacity();
        self.updateFilterLabel();
    }

    fn updateFilterLabel(self: *SCMHistoryViewPane) void {
        const label: []const u8 = switch (self.filter_kind) {
            .all => "All",
            .auto => "Auto",
            .selected => if (self.filter_refs.len == 1)
                self.filter_refs[0].name
            else if (self.filter_ids.items.len == 1)
                self.filter_ids.items[0]
            else
                "",
        };
        if (self.filter_kind == .selected and self.filter_refs.len != 1 and self.filter_ids.items.len != 1) {
            const text: []const u8 = std.fmt.bufPrint(&self.filter_label_buf, "{d} Items", .{self.filter_ids.items.len}) catch "Items";
            self.filter_label_len = text.len;
            return;
        }
        const len = @min(label.len, self.filter_label_buf.len);
        @memcpy(self.filter_label_buf[0..len], label[0..len]);
        self.filter_label_len = len;
    }

    fn loadViewMode(self: *SCMHistoryViewPane) ViewMode {
        if (self.storage) |storage| {
            if (storage.get("scm.graphView.viewMode", .workspace, null)) |value| {
                if (std.mem.eql(u8, value, "tree")) return .tree;
                if (std.mem.eql(u8, value, "list")) return .list;
            }
        }
        return self.config.default_view_mode;
    }

    fn storeViewMode(self: *SCMHistoryViewPane, mode: ViewMode) void {
        const storage = self.storage orelse return;
        storage.store(
            "scm.graphView.viewMode",
            .{ .string = if (mode == .tree) "tree" else "list" },
            .workspace,
            .user,
        ) catch {};
    }

    fn ensureChanges(self: *SCMHistoryViewPane, vm_index: usize) []const history.ISCMHistoryItemChange {
        const provider = self.provider orelse return &.{};
        if (vm_index >= self.view_models.len) return &.{};
        const item = self.view_models[vm_index].history_item;
        if (self.changes.get(item.id)) |cached| return cached;
        const parent = if (item.parent_ids.len > 0) item.parent_ids[0] else null;
        const changes: []const history.ISCMHistoryItemChange = provider.provideHistoryItemChanges(
            self.changes_arena.allocator(),
            self.itemRevision(item),
            parent,
        ) catch |err| blk: {
            self.last_error = err;
            break :blk &.{};
        };
        self.changes.put(item.id, changes) catch {};
        return changes;
    }

    pub fn itemRevision(self: *const SCMHistoryViewPane, item: history.ISCMHistoryItem) []const u8 {
        const provider = self.provider orelse return item.id;
        const reference = if (std.mem.eql(u8, item.id, history.SCMIncomingHistoryItemId))
            provider.history_item_remote_ref
        else if (std.mem.eql(u8, item.id, history.SCMOutgoingHistoryItemId))
            provider.history_item_ref
        else
            null;
        return if (reference) |ref| ref.revision orelse ref.id else item.id;
    }

    fn rebuildRows(self: *SCMHistoryViewPane) !void {
        self.rows.clearRetainingCapacity();
        if (self.view_models.len == 0) {
            try self.rows.append(.welcome);
            return;
        }
        for (self.view_models, 0..) |view_model, vm_index| {
            try self.rows.append(.{ .history_item = vm_index });
            if (self.expanded.contains(view_model.history_item.id)) {
                const changes = self.ensureChanges(vm_index);
                if (self.view_mode == .list) {
                    for (changes) |*change| {
                        try self.rows.append(.{ .change = .{ .vm = vm_index, .change = change, .depth = 0 } });
                    }
                } else {
                    try self.appendTreeRows(vm_index, changes);
                }
            }
        }
        const last_index = self.view_models.len - 1;
        if (self.view_models[last_index].output_swimlanes.len > 0) {
            try self.rows.append(.{ .load_more = .{ .vm = last_index } });
        }
    }

    fn appendTreeRows(self: *SCMHistoryViewPane, vm_index: usize, changes: []const history.ISCMHistoryItemChange) !void {
        const arena = self.changes_arena.allocator();
        var tree = try resource_tree.ResourceTree(usize, void).init(arena, {}, "/");
        for (changes, 0..) |change, index| {
            _ = tree.add(change.path, index) catch continue;
        }
        for (tree.root.childNodes()) |child| {
            try self.appendTreeChild(vm_index, changes, child, 0);
        }
    }

    fn appendTreeChild(
        self: *SCMHistoryViewPane,
        vm_index: usize,
        changes: []const history.ISCMHistoryItemChange,
        node: *resource_tree.ResourceTree(usize, void).NodeType,
        depth: usize,
    ) !void {
        if (node.element) |change_index| {
            try self.rows.append(.{ .change = .{ .vm = vm_index, .change = &changes[change_index], .depth = depth } });
            return;
        }
        var current = node;
        var compressed = std.array_list.Managed(u8).init(self.changes_arena.allocator());
        try compressed.appendSlice(current.name);
        if (self.config.compact_folders) {
            while (current.childrenCount() == 1) {
                const only = current.childNodes()[0];
                if (only.element != null) break;
                try compressed.append('/');
                try compressed.appendSlice(only.name);
                current = only;
            }
        }
        const key = current.relative_path;
        const collapsed = self.collapsed_folders.contains(key);
        try self.rows.append(.{ .folder = .{
            .name = try self.changes_arena.allocator().dupe(u8, compressed.items),
            .key = try self.changes_arena.allocator().dupe(u8, key),
            .depth = depth,
            .vm = vm_index,
        } });
        if (collapsed) return;
        for (current.childNodes()) |child| {
            try self.appendTreeChild(vm_index, changes, child, depth + 1);
        }
    }

    fn clampSelection(self: *SCMHistoryViewPane) void {
        if (self.rows.items.len == 0) {
            self.selection = 0;
            self.scroll = 0;
            return;
        }
        if (self.selection >= self.rows.items.len) self.selection = self.rows.items.len - 1;
        self.ensureSelectionVisible();
    }

    fn ensureSelectionVisible(self: *SCMHistoryViewPane) void {
        if (self.visible_rows == 0) return;
        if (self.selection < self.scroll) self.scroll = self.selection;
        if (self.selection >= self.scroll + self.visible_rows) {
            self.scroll = self.selection - self.visible_rows + 1;
        }
        self.clampScroll();
    }

    fn clampScroll(self: *SCMHistoryViewPane) void {
        const max = self.rows.items.len -| self.visible_rows;
        if (self.scroll > max) self.scroll = max;
    }

    fn toggleSelected(self: *SCMHistoryViewPane) !void {
        if (self.selection >= self.rows.items.len) return;
        switch (self.rows.items[self.selection]) {
            .history_item => |vm_index| {
                const id = self.view_models[vm_index].history_item.id;
                if (self.expanded.fetchRemove(id)) |entry| {
                    self.allocator.free(entry.key);
                } else {
                    const key = try self.allocator.dupe(u8, id);
                    try self.expanded.put(key, {});
                }
                try self.rebuildRows();
                self.revision += 1;
            },
            .folder => |folder| {
                if (self.collapsed_folders.fetchRemove(folder.key)) |entry| {
                    self.allocator.free(entry.key);
                } else {
                    const key = try self.allocator.dupe(u8, folder.key);
                    try self.collapsed_folders.put(key, {});
                }
                try self.rebuildRows();
                self.revision += 1;
            },
            .load_more => try self.loadMoreFromRow(),
            .change => |change| try self.host.open_change(self.host.context, &self.view_models[change.vm].history_item, change.change),
            .welcome => {},
        }
    }

    fn loadMoreFromRow(self: *SCMHistoryViewPane) !void {
        try self.refresh(.more);
    }

    pub fn loadMore(self: *SCMHistoryViewPane) !void {
        try self.refresh(.more);
    }

    pub fn revealCurrentHistoryItem(self: *SCMHistoryViewPane) !void {
        const provider = self.provider orelse return;
        const current = provider.history_item_ref orelse return;
        const revision = current.revision orelse return;
        for (self.view_models, 0..) |vm, index| {
            if (!std.mem.eql(u8, vm.history_item.id, revision)) continue;
            self.selection = index;
            self.ensureSelectionVisible();
            self.revision += 1;
            return;
        }
        self.load_more = .{ .cursor = revision };
        try self.refresh(.cursor);
        for (self.view_models, 0..) |vm, index| {
            if (!std.mem.eql(u8, vm.history_item.id, revision)) continue;
            self.selection = index;
            self.ensureSelectionVisible();
            self.revision += 1;
            return;
        }
    }

    pub fn titleActions(self: *SCMHistoryViewPane) []const views.TitleAction {
        const provider = self.provider orelse return &.{};
        const has_remote = provider.history_item_remote_ref != null;
        self.actions = .{
            // The terminal uses the Nerd Font git-branch glyph.
            .{ .id = PICK_HISTORY_ITEM_REFS_ACTION_ID, .label = self.filterLabel(), .glyph = 0xf418, .show_label = true },
            .{ .id = REVEAL_CURRENT_HISTORY_ITEM_ACTION_ID, .label = "Go to Current History Item", .glyph = 0xebf8, .enabled = self.hasCurrentHistoryItem() },
            .{ .id = "git.fetchAll", .label = "Fetch From All Remotes", .glyph = fetch_glyph },
            .{ .id = "git.pullRef", .label = "Pull", .glyph = '↓', .enabled = has_remote },
            if (has_remote)
                .{ .id = "git.pushRef", .label = "Push", .glyph = '↑' }
            else
                .{ .id = "git.publish", .label = "Publish Branch", .glyph = 0xeac3 },
            .{ .id = REFRESH_GRAPH_ACTION_ID, .label = "Refresh", .glyph = '↻' },
            .{ .id = GRAPH_MENU_ACTION_ID, .label = "More Actions", .glyph = '…' },
        };
        return &self.actions;
    }

    pub fn handleKey(self: *SCMHistoryViewPane, event: *const ui.KeyEvent) !bool {
        switch (event.key) {
            .up => self.moveSelection(-1),
            .down => self.moveSelection(1),
            .home => self.selectFirst(),
            .end => self.selectLast(),
            .page_up => self.moveSelection(-@as(isize, @intCast(@max(self.visible_rows, 1)))),
            .page_down => self.moveSelection(@intCast(@max(self.visible_rows, 1))),
            .left => {
                if (self.selection < self.rows.items.len) {
                    switch (self.rows.items[self.selection]) {
                        .history_item => |vm| {
                            if (self.expanded.contains(self.view_models[vm].history_item.id)) try self.toggleSelected();
                        },
                        .folder => {
                            if (!self.collapsed_folders.contains(self.rows.items[self.selection].folder.key)) try self.toggleSelected();
                        },
                        else => {},
                    }
                }
            },
            .right => {
                if (self.selection < self.rows.items.len) {
                    switch (self.rows.items[self.selection]) {
                        .history_item => |vm| {
                            if (!self.expanded.contains(self.view_models[vm].history_item.id)) try self.toggleSelected();
                        },
                        .folder => {
                            if (self.collapsed_folders.contains(self.rows.items[self.selection].folder.key)) try self.toggleSelected();
                        },
                        else => {},
                    }
                }
            },
            .enter => try self.toggleSelected(),
            .escape => {
                self.host.focus_editor(self.host.context);
                return true;
            },
            .char => |ch| {
                if (ch == ' ') {
                    self.selection_active = true;
                    try self.toggleSelected();
                    return true;
                }
                if (ch == 'r' or ch == 'R') {
                    try self.refresh(.reload);
                    self.outdated = false;
                    return true;
                }
            },
            else => return false,
        }
        self.selection_active = true;
        self.ensureSelectionVisible();
        self.revision += 1;
        return true;
    }

    fn moveSelection(self: *SCMHistoryViewPane, delta: isize) void {
        if (self.rows.items.len == 0) return;
        const current: isize = @intCast(self.selection);
        const next = @max(0, @min(@as(isize, @intCast(self.rows.items.len - 1)), current + delta));
        self.selection = @intCast(next);
        self.ensureSelectionVisible();
        self.revision += 1;
    }

    fn selectFirst(self: *SCMHistoryViewPane) void {
        self.selection = 0;
        self.ensureSelectionVisible();
        self.revision += 1;
    }

    fn selectLast(self: *SCMHistoryViewPane) void {
        if (self.rows.items.len > 0) self.selection = self.rows.items.len - 1;
        self.ensureSelectionVisible();
        self.revision += 1;
    }

    pub fn handleMouse(self: *SCMHistoryViewPane, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x or event.x >= x + width) return false;
        if (event.y < y or event.y >= y + height) return false;
        const row_index = event.y - y + self.scroll;
        if (event.kind == .wheel) {
            if (event.delta_y < 0) {
                self.scroll = self.scroll -| @as(usize, @intCast(-event.delta_y));
            } else {
                self.scroll += @intCast(event.delta_y);
            }
            self.clampScroll();
            if (self.config.page_on_scroll and self.scroll + self.visible_rows >= self.rows.items.len and
                self.rows.items.len > 0 and std.meta.activeTag(self.rows.items[self.rows.items.len - 1]) == .load_more)
            {
                try self.loadMore();
            }
            self.revision += 1;
            return true;
        }
        const list_width = list_scrollbar.contentWidth(width, height, self.rows.items.len);
        const col = event.x - x;
        if (col >= list_width) {
            if (event.kind == .move) self.clearHover();
            return false;
        }
        const over_action = if (self.actionStart(row_index, list_width)) |start|
            col >= start and col < start + css.inline_action_width
        else
            false;
        if (event.kind != .down and event.kind != .click) {
            if (event.kind == .move) self.setHover(row_index, self.hitActionSlot(row_index, col, list_width));
            return false;
        }
        if (row_index >= self.rows.items.len or event.button != .left) return false;
        if (over_action) {
            const vm = self.rows.items[row_index].history_item;
            const changes = self.ensureChanges(vm);
            const item = &self.view_models[vm].history_item;
            if (self.host.open_changes) |run| {
                try run(self.host.context, item, changes);
            } else self.showHistoryChanges(item, changes) catch |err| {
                var buffer: [256]u8 = undefined;
                if (self.host.status) |status| status(self.host.context, std.fmt.bufPrint(&buffer, "Open Changes failed: {s}", .{@errorName(err)}) catch "Open Changes failed");
            };
            return true;
        }
        // Upstream opens the Load More element on click (`onDidOpen`), so the
        // first click must page in history instead of only moving the cursor.
        if (std.meta.activeTag(self.rows.items[row_index]) == .load_more) {
            try self.loadMoreFromRow();
            self.ensureSelectionVisible();
            return true;
        }
        if (self.selection_active and row_index == self.selection) {
            try self.toggleSelected();
        } else {
            self.selection_active = true;
            self.selection = row_index;
            self.revision += 1;
            if (std.meta.activeTag(self.rows.items[row_index]) == .change) {
                const change = self.rows.items[row_index].change;
                try self.host.open_change(self.host.context, &self.view_models[change.vm].history_item, change.change);
            }
        }
        self.ensureSelectionVisible();
        return true;
    }

    // The native Graph opens a picker for multiple changes instead of the
    // browser's multi-diff editor. Own the history item and revision until
    // the picker is accepted or dismissed; the graph can refresh meanwhile.
    const HistoryChangesPick = struct {
        host: Host,
        arena: std.heap.ArenaAllocator,
        item: history.ISCMHistoryItem,
        changes: []history.ISCMHistoryItemChange,
    };

    fn showHistoryChanges(self: *SCMHistoryViewPane, item: *const history.ISCMHistoryItem, changes: []const history.ISCMHistoryItemChange) !void {
        if (changes.len == 0) {
            if (self.host.status) |status| status(self.host.context, "No file changes in this history item");
            return;
        }
        if (changes.len == 1) return self.host.open_change(self.host.context, item, &changes[0]);
        const input = self.quick_input orelse return;
        const state = try self.allocator.create(HistoryChangesPick);
        errdefer self.allocator.destroy(state);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const saved_changes = try allocator.alloc(history.ISCMHistoryItemChange, changes.len);
        const items = try allocator.alloc(QuickPickItem, changes.len);
        for (changes, saved_changes, items, 0..) |change, *saved, *entry, index| {
            saved.* = try change.clone(allocator);
            entry.* = .{ .item = .{ .id = try std.fmt.allocPrint(allocator, "{d}", .{index}), .label = std.fs.path.basename(saved.path), .description = std.fs.path.dirname(saved.path) orelse "" } };
        }
        var saved_item = try item.clone(allocator);
        const revision = self.itemRevision(item.*);
        if (!std.mem.eql(u8, revision, item.id)) {
            saved_item.id = try allocator.dupe(u8, revision);
            saved_item.display_id = saved_item.id[0..@min(saved_item.id.len, 7)];
        }
        state.* = .{ .host = self.host, .arena = arena, .item = saved_item, .changes = saved_changes };
        try input.showPick(items, .{ .placeholder = "Open Changes", .cleanup = freeHistoryChangesPick, .cleanup_context = state }, onHistoryChangesPick, state);
    }

    fn freeHistoryChangesPick(context: *anyopaque) void {
        const state: *HistoryChangesPick = @ptrCast(@alignCast(context));
        const allocator = state.arena.child_allocator;
        state.arena.deinit();
        allocator.destroy(state);
    }

    fn onHistoryChangesPick(context: *anyopaque, picker: *QuickPick) !void {
        const state: *HistoryChangesPick = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        const index = try std.fmt.parseInt(usize, item.id, 10);
        if (index < state.changes.len) try state.host.open_change(state.host.context, &state.item, &state.changes[index]);
    }

    fn actionSlot(self: *const SCMHistoryViewPane, row_index: usize, width: usize) ?usize {
        if ((self.host.open_changes == null and self.quick_input == null) or row_index >= self.rows.items.len) return null;
        const row = self.rows.items[row_index];
        if (row != .history_item) return null;
        const graph_width = scm_history.graphWidth(&self.view_models[row.history_item]) + 1;
        const start = width -| (css.right_inset + css.inline_action_width);
        return if (start > graph_width + 2) start else null;
    }

    fn actionStart(self: *const SCMHistoryViewPane, row_index: usize, width: usize) ?usize {
        if (!self.config.always_show_actions and self.hovered_row != row_index and
            !(self.list_focused and self.selection_active and self.selection == row_index)) return null;
        return self.actionSlot(row_index, width);
    }

    fn hitActionSlot(self: *const SCMHistoryViewPane, row_index: usize, col: usize, width: usize) bool {
        const start = self.actionSlot(row_index, width) orelse return false;
        return col >= start and col < start + css.inline_action_width;
    }

    pub fn pointerAt(self: *const SCMHistoryViewPane) ui.Pointer {
        return if (self.hovered_action) .pointer else .default;
    }

    fn setHover(self: *SCMHistoryViewPane, row_index: usize, over_action: bool) void {
        if (self.hovered_row == row_index and self.hovered_action == over_action) return;
        self.clearHover();
        self.hovered_row = row_index;
        self.hovered_action = over_action;
        if (over_action or row_index >= self.rows.items.len) return;
        switch (self.rows.items[row_index]) {
            .history_item => |vm| {
                self.hover_content = scm_history.buildHistoryItemHover(
                    self.allocator,
                    self.view_models[vm].history_item,
                ) catch null;
            },
            else => {},
        }
    }

    pub fn hoverContent(self: *const SCMHistoryViewPane) ?[]const u8 {
        return self.hover_content;
    }

    pub fn hoveredRow(self: *const SCMHistoryViewPane) ?usize {
        return self.hovered_row;
    }

    /// Screen cell of the hovered row, for the workbench hover overlay.
    pub fn hoverRect(self: *const SCMHistoryViewPane) ?ui.Rect {
        const row = self.hovered_row orelse return null;
        if (row < self.scroll or row >= self.scroll + self.visible_rows) return null;
        const body = self.last_rect;
        return .{
            .x = body.x,
            .y = body.y + @as(f64, @floatFromInt(row - self.scroll)),
            .w = body.w,
            .h = 1,
        };
    }

    pub fn renderHover(
        self: *SCMHistoryViewPane,
        cells: *ui.CellGrid,
        column: ui.Rect,
        sidebar_position: @import("../../../services/layout/browser/layoutService.zig").Position,
        cell_borders: bool,
        caps: ui.cell_border.Capabilities,
    ) !void {
        const content = self.hoverContent() orelse return;
        const rect = self.hoverRect() orelse return;
        const y = ui.cell.snap(rect.y);
        const gap = @intFromBool(cell_borders);
        const max_width = ui.cell.snap(column.w) -| gap -| 1;
        if (max_width < 12) return;
        var lines: usize = 1;
        for (content) |ch| {
            if (ch == '\n') lines += 1;
        }
        const max_height = ui.cell.snap(column.bottom()) -| y -| 2;
        if (max_height < scm_history_hover_chrome + 1) return;
        const size = scmHistoryHoverSize(max_width, max_height, lines);
        const x = if (sidebar_position == .left) ui.cell.snap(column.x) + gap else ui.cell.snap(column.right()) - gap - size.width;

        if (self.hover_surface == null) self.hover_surface = try ui.Surface.init(self.allocator, .{ .cols = size.width, .rows = size.height });
        const surface = &self.hover_surface.?;
        try surface.resize(size.width, size.height);
        var background = ui.Color{ .r = 37, .g = 37, .b = 38 };
        var foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };
        var border = ui.Color{ .r = 69, .g = 69, .b = 69 };
        if (self.theme) |palette| {
            background = palette.color("editorHoverWidget.background", .{ 37, 37, 38 });
            foreground = palette.color("editorHoverWidget.foreground", .{ 204, 204, 204 });
            border = palette.color("editorHoverWidget.border", .{ 69, 69, 69 });
        }
        const frame = if (caps.has(.round)) ui.cell.RoundedCellFrame.capture(cells, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(size.width),
            .h = @floatFromInt(size.height),
        }) else null;
        try paintScmHistoryHover(surface, content, size, background, foreground, if (frame == null) border else null);
        try cells.blit(surface.grid(), x, y, size.width, size.height);
        if (frame) |rounded| rounded.paint(cells, caps, .{ .rgb = border });
    }

    pub fn clearHover(self: *SCMHistoryViewPane) void {
        if (self.hover_surface) |*surface| surface.deinit();
        self.hover_surface = null;
        self.hovered_row = null;
        self.hovered_action = false;
        if (self.hover_content) |content| self.allocator.free(content);
        self.hover_content = null;
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    pub fn render(self: *SCMHistoryViewPane, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;
        self.visible_rows = height;
        self.list_focused = focused;
        self.last_rect = rect;
        self.clampScroll();

        if (self.surface == null or self.surface.?.doc.cols != width or self.surface.?.doc.rows != height) {
            if (self.surface) |*surface| {
                try surface.resize(width, height);
            } else {
                self.surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = height });
                _ = try self.surface.?.document().registerSheet(css.sheet);
            }
        }
        const surface = &self.surface.?;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.revision));
        hasher.update(std.mem.asBytes(&self.scroll));
        hasher.update(std.mem.asBytes(&self.selection));
        const hovered = self.hovered_row orelse std.math.maxInt(usize);
        hasher.update(std.mem.asBytes(&hovered));
        hasher.update(std.mem.asBytes(&width));
        hasher.update(std.mem.asBytes(&height));
        hasher.update(&[_]u8{
            @intFromBool(focused),
            @intFromBool(self.hovered_action),
            @intFromBool(self.outdated),
            @intFromBool(self.view_mode == .tree),
        });
        hasher.update(std.mem.asBytes(&self.theme_ptr));
        const signature = hasher.final();
        if (self.signature != signature) {
            const colors = self.viewColors();
            const doc = surface.document();
            doc.clear();
            const root = try doc.createElement(.div);
            root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
                .background = colors.background,
                .color = colors.foreground,
                .white_space = .pre,
            });
            doc.setRoot(root);

            if (self.rows.items.len == 0) {
                const welcome = try doc.createElement(.div);
                welcome.setStyle(.{ .padding = .{ .left = 1, .right = 1 }, .color = colors.dim });
                _ = try welcome.appendText("The selected source control provider does not have any source control history items.");
                _ = try root.appendChild(welcome);
            } else {
                const list_width = list_scrollbar.contentWidth(width, height, self.rows.items.len);
                const end = @min(self.rows.items.len, self.scroll + height);
                var row_index = self.scroll;
                while (row_index < end) : (row_index += 1) {
                    try self.appendRow(doc, root, row_index, focused, colors, list_width);
                }
            }

            doc.setRoot(root);
            try surface.paintFrame();
            self.signature = signature;
        }
        try grid.blit(surface.grid(), x, y, width, height);
        list_scrollbar.paint(grid, rect, self.rows.items.len, @floatFromInt(self.scroll));
    }

    fn appendRow(
        self: *SCMHistoryViewPane,
        doc: *ui.Document,
        root: *ui.Node,
        row_index: usize,
        focused: bool,
        colors: Colors,
        width: usize,
    ) !void {
        const row = self.rows.items[row_index];
        const selected = self.selection_active and row_index == self.selection;
        const background = if (selected)
            (if (focused) colors.selection_background else colors.inactive_selection_background)
        else if (self.hovered_row != null and self.hovered_row.? == row_index)
            colors.hover_background
        else
            colors.background;
        const foreground = if (selected) colors.selection_foreground else colors.foreground;
        const line = try doc.createElement(.div);
        try line.addClass(css.Class.history_item);
        line.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = @floatFromInt(row_index - self.scroll) },
            .width = .{ .cells = @floatFromInt(width) },
            .height = .{ .cells = 1 },
            .display = .flex,
            .flex_direction = .row,
            .align_items = .center,
            .overflow = .hidden,
            .background = background,
        });
        _ = try root.appendChild(line);

        switch (row) {
            .history_item => |vm_index| {
                const vm = &self.view_models[vm_index];
                const glyphs = scm_history.renderSCMHistoryItemGraph(self.allocator, vm) catch &.{};
                defer if (glyphs.len > 0) self.allocator.free(glyphs);
                try appendGlyphs(doc, line, glyphs, self.theme);
                const graph_width = scm_history.graphWidth(vm) + 1;
                const action_start = self.actionStart(row_index, width);
                const label_end = action_start orelse (width -| css.right_inset);
                const label_area = label_end -| graph_width;
                const badges = try self.historyBadges(doc, vm.history_item, colors, label_area / 2);
                const label_width = label_area -| (badges.width + 1);
                const label = try doc.createElement(.span);
                try label.addClass(css.Class.history_label);
                label.setStyle(.{ .color = foreground, .bold = vm.kind == .head });
                const subject_text = try truncate(self.allocator, vm.history_item.subject, label_width);
                defer self.allocator.free(subject_text);
                _ = try label.appendText(subject_text);
                const left = label_width -| doc.measureText(subject_text);
                if (vm.history_item.author) |author| {
                    if (left > 2) {
                        const description = try doc.createElement(.span);
                        description.setStyle(.{
                            .color = if (selected) colors.selection_foreground else colors.dim,
                            .padding = .{ .left = 1 },
                        });
                        const author_text = try truncate(self.allocator, author, left - 1);
                        defer self.allocator.free(author_text);
                        _ = try description.appendText(author_text);
                        _ = try label.appendChild(description);
                    }
                }
                _ = try line.appendChild(label);
                _ = try line.appendChild(badges.node);
                if (action_start != null) {
                    const button = try doc.createElement(.span);
                    try button.addClass(css.Class.history_action);
                    button.setStyle(.{
                        .color = foreground,
                        .background = if (self.hovered_action and self.hovered_row == row_index) colors.hover_background else null,
                    });
                    _ = try button.appendText("▤");
                    _ = try line.appendChild(button);
                }
                const inset = try doc.createElement(.span);
                inset.setStyle(.{ .width = .{ .cells = css.right_inset }, .flex_shrink = 0 });
                _ = try line.appendChild(inset);
            },
            .change => |change| {
                const vm = &self.view_models[change.vm];
                const placeholder = scm_history.renderSCMHistoryGraphPlaceholder(
                    self.allocator,
                    vm.output_swimlanes,
                    scm_history.getHistoryItemIndex(vm),
                ) catch &.{};
                defer if (placeholder.len > 0) self.allocator.free(placeholder);
                try appendGlyphs(doc, line, placeholder, self.theme);
                const indent = try doc.createElement(.span);
                indent.setStyle(.{ .white_space = .pre, .flex_shrink = 0 });
                _ = try indent.appendText(try indentText(doc.arena.allocator(), 2 + change.depth * 2));
                _ = try line.appendChild(indent);
                const name = std.fs.path.basename(change.change.path);
                try appendFileIcon(doc, line, file_icon.file(name));
                const label = try doc.createElement(.span);
                try label.addClass(css.Class.history_label);
                label.setStyle(.{ .color = foreground });
                _ = try label.appendText(name);
                if (self.view_mode == .list) {
                    if (std.fs.path.dirname(change.change.path)) |dir| {
                        const description = try doc.createElement(.span);
                        description.setStyle(.{ .color = colors.dim, .padding = .{ .left = 1 } });
                        _ = try description.appendText(dir);
                        _ = try label.appendChild(description);
                    }
                }
                _ = try line.appendChild(label);
                if (change.change.status != 0) {
                    const status = try doc.createElement(.span);
                    status.setStyle(.{
                        .color = statusColor(change.change.status, self.theme),
                        .flex_shrink = 0,
                        .padding = .{ .left = 1, .right = css.right_inset },
                    });
                    _ = try status.appendText(&.{change.change.status});
                    _ = try line.appendChild(status);
                }
            },
            .folder => |folder| {
                const vm = &self.view_models[folder.vm];
                const placeholder = scm_history.renderSCMHistoryGraphPlaceholder(
                    self.allocator,
                    vm.output_swimlanes,
                    scm_history.getHistoryItemIndex(vm),
                ) catch &.{};
                defer if (placeholder.len > 0) self.allocator.free(placeholder);
                try appendGlyphs(doc, line, placeholder, self.theme);
                const indent = try doc.createElement(.span);
                indent.setStyle(.{ .white_space = .pre, .flex_shrink = 0 });
                _ = try indent.appendText(try indentText(doc.arena.allocator(), 2 + folder.depth * 2));
                _ = try line.appendChild(indent);
                const collapsed = self.collapsed_folders.contains(folder.key);
                _ = try line.appendText(if (collapsed) "› " else "⌄ ");
                try appendFileIcon(doc, line, file_icon.folder(!collapsed));
                const label = try doc.createElement(.span);
                try label.addClass(css.Class.history_label);
                label.setStyle(.{ .color = foreground });
                _ = try label.appendText(folder.name);
                _ = try line.appendChild(label);
            },
            .load_more => |load_more| {
                const vm = &self.view_models[load_more.vm];
                const placeholder = scm_history.renderSCMHistoryGraphPlaceholder(
                    self.allocator,
                    vm.output_swimlanes,
                    null,
                ) catch &.{};
                defer if (placeholder.len > 0) self.allocator.free(placeholder);
                try appendGlyphs(doc, line, placeholder, self.theme);
                const label = try doc.createElement(.span);
                label.setStyle(.{ .white_space = .pre, .color = colors.dim, .padding = .{ .left = 1 } });
                _ = try label.appendText("\u{25BE} Load More\u{2026}");
                _ = try line.appendChild(label);
            },
            .welcome => {
                const label = try doc.createElement(.span);
                label.setStyle(.{ .white_space = .pre, .color = colors.dim, .padding = .{ .left = 1 } });
                _ = try label.appendText("The selected source control provider does not have any source control history items.");
                _ = try line.appendChild(label);
            },
        }
    }

    fn historyBadges(
        self: *SCMHistoryViewPane,
        doc: *ui.Document,
        item: history.ISCMHistoryItem,
        colors: Colors,
        available: usize,
    ) !struct { node: *ui.Node, width: usize } {
        const badges = try doc.createElement(.span);
        try badges.addClass(css.Class.history_badges);
        var used: usize = 0;
        const refs = item.references;
        const first_named = refs.len > 0 and refs[0].color != null;
        for (refs, 0..) |reference, index| {
            if (available -| used < 3) break;
            if (!self.config.badges_all and reference.color == null) continue;
            const icon = reference.icon orelse continue;
            const show_name = first_named and index == 0;
            var count: usize = 1;
            if (!show_name) {
                const group_start: usize = @intFromBool(first_named);
                for (refs[group_start..index]) |other| {
                    if (other.icon == icon and optionalColorEql(other.color, reference.color)) {
                        count = 0;
                        break;
                    }
                }
                if (count == 0) continue;
                for (refs[index + 1 ..]) |other| {
                    if (other.icon == icon and optionalColorEql(other.color, reference.color)) count += 1;
                }
            }

            const glyph: []const u8 = switch (icon) {
                .head => "\u{ebf8}",
                .branch => "\u{ec6f}",
                .remote => "\u{ebaa}",
                .tag => "\u{ea66}",
            };
            const text = if (show_name)
                try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ glyph, reference.name })
            else if (count > 1)
                try std.fmt.allocPrint(self.allocator, "{d} {s}", .{ count, glyph })
            else
                try self.allocator.dupe(u8, glyph);
            defer self.allocator.free(text);
            const label = try truncate(self.allocator, text, available - used - 2);
            defer self.allocator.free(label);
            const badge = try doc.createElement(.span);
            badge.setStyle(.{
                .padding = .{ .left = 1, .right = 1 },
                .flex_shrink = 0,
                .background = if (reference.color) |color| resolveColorId(self.theme, color) else colors.badge_background,
                .color = if (reference.color != null)
                    (if (self.theme) |theme| theme.colorOr("scmGraph.historyItemHoverLabelForeground", colors.background) else colors.background)
                else
                    colors.badge_foreground,
            });
            _ = try badge.appendText(label);
            _ = try badges.appendChild(badge);
            used += doc.measureText(label) + 2;
        }
        return .{ .node = badges, .width = used };
    }

    const Colors = struct {
        background: ui.Color,
        foreground: ui.Color,
        dim: ui.Color,
        selection_background: ui.Color,
        inactive_selection_background: ui.Color,
        selection_foreground: ui.Color,
        hover_background: ui.Color,
        badge_background: ui.Color,
        badge_foreground: ui.Color,
    };

    fn viewColors(self: *const SCMHistoryViewPane) Colors {
        if (self.theme) |palette| {
            const background = palette.color("sideBar.background", .{ 30, 30, 33 });
            return .{
                .background = background,
                .foreground = palette.color("sideBar.foreground", .{ 204, 204, 204 }),
                .dim = palette.color("descriptionForeground", .{ 150, 150, 150 }),
                .selection_background = palette.color("list.activeSelectionBackground", .{ 4, 57, 94 }),
                .inactive_selection_background = palette.color("list.inactiveSelectionBackground", .{ 55, 55, 61 }),
                .selection_foreground = palette.color("list.activeSelectionForeground", .{ 255, 255, 255 }),
                .hover_background = palette.color("list.hoverBackground", .{ 45, 45, 45 }),
                .badge_background = palette.color("badge.background", .{ 97, 97, 97 }),
                .badge_foreground = palette.color("badge.foreground", .{ 255, 255, 255 }),
            };
        }
        return .{
            .background = .{ .r = 30, .g = 30, .b = 33 },
            .foreground = .{ .r = 204, .g = 204, .b = 204 },
            .dim = .{ .r = 150, .g = 150, .b = 150 },
            .selection_background = .{ .r = 4, .g = 57, .b = 94 },
            .inactive_selection_background = .{ .r = 55, .g = 55, .b = 61 },
            .selection_foreground = .{ .r = 255, .g = 255, .b = 255 },
            .hover_background = .{ .r = 45, .g = 45, .b = 45 },
            .badge_background = .{ .r = 97, .g = 97, .b = 97 },
            .badge_foreground = .{ .r = 255, .g = 255, .b = 255 },
        };
    }

    fn clearOwnedKeys(self: *SCMHistoryViewPane, map: *std.StringHashMap(void)) void {
        var iterator = map.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        map.clearRetainingCapacity();
    }
};

fn truncate(allocator: Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    var width: usize = 0;
    var index: usize = 0;
    var ellipsis_end: usize = 0;
    while (index < text.len) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cells = ui.dom.defaultMeasureWidth(decoded.cp);
        if (width + cells > max_width) {
            return std.fmt.allocPrint(allocator, "{s}…", .{text[0..ellipsis_end]});
        }
        width += cells;
        index += decoded.len;
        if (width < max_width) ellipsis_end = index;
    }
    return allocator.dupe(u8, text[0..index]);
}

fn indentText(allocator: Allocator, cells: usize) ![]u8 {
    const result = try allocator.alloc(u8, cells);
    @memset(result, ' ');
    return result;
}

fn appendFileIcon(doc: *ui.Document, parent: *ui.Node, icon: file_icon.Icon) !void {
    const node = try doc.createElement(.span);
    node.setStyle(.{ .color = icon.color, .flex_shrink = 0 });
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(icon.glyph, &buffer);
    _ = try node.appendText(buffer[0..len]);
    _ = try parent.appendChild(node);
}

fn appendGlyphs(
    doc: *ui.Document,
    parent: *ui.Node,
    glyphs: []const scm_history.GraphGlyph,
    theme: ?*const theme_colors_mod.ThemeColors,
) !void {
    const graph = try doc.createElement(.span);
    try graph.addClass(css.Class.graph_container);
    _ = try parent.appendChild(graph);
    var index: usize = 0;
    while (index < glyphs.len) {
        const color = glyphs[index].color;
        var run = std.array_list.Managed(u8).init(doc.allocator);
        defer run.deinit();
        while (index < glyphs.len and optionalColorEql(glyphs[index].color, color)) : (index += 1) {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(glyphs[index].cp, &buffer) catch 0;
            try run.appendSlice(buffer[0..len]);
        }
        const span = try doc.createElement(.span);
        span.setStyle(.{ .white_space = .pre, .color = if (color) |id| resolveColorId(theme, id) else null });
        _ = try span.appendText(run.items);
        _ = try graph.appendChild(span);
    }
}

fn optionalColorEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn resolveColorId(theme: ?*const theme_colors_mod.ThemeColors, id: []const u8) ui.Color {
    const default_color = if (std.mem.eql(u8, id, scm_history.history_item_ref_color))
        ui.Color{ .r = 117, .g = 190, .b = 255 }
    else if (std.mem.eql(u8, id, scm_history.history_item_remote_ref_color))
        ui.Color{ .r = 177, .g = 128, .b = 215 }
    else if (std.mem.eql(u8, id, scm_history.history_item_base_ref_color))
        ui.Color{ .r = 234, .g = 92, .b = 0 }
    else if (std.mem.eql(u8, id, "scmGraph.foreground1"))
        ui.Color{ .r = 255, .g = 176, .b = 0 }
    else if (std.mem.eql(u8, id, "scmGraph.foreground2"))
        ui.Color{ .r = 220, .g = 38, .b = 127 }
    else if (std.mem.eql(u8, id, "scmGraph.foreground3"))
        ui.Color{ .r = 153, .g = 79, .b = 0 }
    else if (std.mem.eql(u8, id, "scmGraph.foreground4"))
        ui.Color{ .r = 64, .g = 176, .b = 166 }
    else if (std.mem.eql(u8, id, "scmGraph.foreground5"))
        ui.Color{ .r = 182, .g = 109, .b = 255 }
    else
        ui.Color{ .r = 204, .g = 204, .b = 204 };
    if (theme) |palette| return palette.colorOr(id, default_color);
    return default_color;
}

fn statusColor(status: u8, theme: ?*const theme_colors_mod.ThemeColors) ui.Color {
    const default_color = switch (status) {
        'D', 'U' => ui.Color{ .r = 214, .g = 80, .b = 80 },
        'A', '?' => ui.Color{ .r = 90, .g = 170, .b = 90 },
        'R' => ui.Color{ .r = 200, .g = 160, .b = 70 },
        else => ui.Color{ .r = 200, .g = 180, .b = 90 },
    };
    if (theme) |palette| {
        const id = switch (status) {
            'D', 'U' => "gitDecoration.deletedResourceForeground",
            'A', '?' => "gitDecoration.addedResourceForeground",
            'R' => "gitDecoration.renamedResourceForeground",
            else => "gitDecoration.modifiedResourceForeground",
        };
        return palette.colorOr(id, default_color);
    }
    return default_color;
}

const scm_history_hover_chrome: usize = 4;
const scm_history_hover_max_width: usize = 60;
const scm_history_hover_max_height: usize = 12;

const ScmHistoryHoverSize = struct {
    /// Border-box size of the overlay surface.
    width: usize,
    height: usize,
    /// Content-box size of the DOM root inside border and padding.
    content_width: usize,
    content_height: usize,
};

fn scmHistoryHoverSize(max_width: usize, max_height: usize, lines: usize) ScmHistoryHoverSize {
    const width = @min(max_width, scm_history_hover_max_width);
    const height = @min(max_height, @min(lines + scm_history_hover_chrome, scm_history_hover_max_height));
    return .{
        .width = width,
        .height = height,
        .content_width = width -| scm_history_hover_chrome,
        .content_height = height -| scm_history_hover_chrome,
    };
}

fn paintScmHistoryHover(
    surface: *ui.Surface,
    content: []const u8,
    size: ScmHistoryHoverSize,
    background: ui.Color,
    foreground: ui.Color,
    glyph_border: ?ui.Color,
) !void {
    const border_width: f64 = if (glyph_border != null) 1 else 0;
    const doc = surface.document();
    const root = doc.root orelse root: {
        const element = try doc.createElement(.div);
        _ = try element.appendText(content);
        doc.setRoot(element);
        break :root element;
    };
    const style = ui.Style{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(size.content_width) },
        .height = .{ .cells = @floatFromInt(size.content_height) },
        .background = background,
        .color = foreground,
        .border = .all(border_width),
        .border_style = .rounded,
        .border_color = glyph_border,
        .padding = .all(2 - border_width),
        .white_space = .pre,
        .overflow = .hidden,
    };
    if (!std.meta.eql(root.asElement().style, style)) root.setStyle(style);
    try surface.paintFrame();
}

// Existing terminal palette metadata is preserved; upstream f1=false
// and additional action preconditions will be aligned separately.
const viewAction = @import("../../../browser/parts/views/viewPane.zig").viewAction;
pub const view_actions = [_]@import("../../../../platform/actions/common/actions.zig").Action2{
    viewAction(SCMHistoryViewPane, .registered, .{ .id = REFRESH_GRAPH_ACTION_ID, .title = "Source Control Graph: Refresh", .category = "Source Control" }, true, SCMHistoryViewPane.refreshAction, .{}),
    viewAction(SCMHistoryViewPane, .registered, .{ .id = PICK_HISTORY_ITEM_REFS_ACTION_ID, .title = "Source Control Graph: Select History Item References", .category = "Source Control" }, true, SCMHistoryViewPane.pickHistoryItemRef, .{}),
    viewAction(SCMHistoryViewPane, .registered, .{ .id = REVEAL_CURRENT_HISTORY_ITEM_ACTION_ID, .title = "Source Control Graph: Go to Current History Item", .category = "Source Control" }, true, SCMHistoryViewPane.revealCurrentHistoryItem, .{}),
    viewAction(SCMHistoryViewPane, .registered, .{ .id = SET_LIST_VIEW_MODE_ACTION_ID, .title = "Source Control Graph: View as List", .category = "Source Control" }, true, SCMHistoryViewPane.setViewMode, .{@as(ViewMode, .list)}),
    viewAction(SCMHistoryViewPane, .registered, .{ .id = SET_TREE_VIEW_MODE_ACTION_ID, .title = "Source Control Graph: View as Tree", .category = "Source Control" }, true, SCMHistoryViewPane.setViewMode, .{@as(ViewMode, .tree)}),
};
