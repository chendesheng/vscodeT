// Port of the terminal subset of
// `src/vs/workbench/contrib/scm/browser/scmViewPane.ts`: the Source Control
// side bar's Changes view (the commit-message input, repository rows, resource
// groups and resource rows) plus the portable
// `SCMTreeSorter`/`SCMTreeFilter` behavior.
//
// Faithful pieces: single-repository tree input (groups directly below the
// root unless `scm.alwaysShowRepositories`), the commit-message input and its
// accept action, Merge/Staged/Changes groups with their inline count badges,
// list/tree view modes (`scm.defaultViewMode`), list sort keys
// (`scm.defaultViewSortKey`), compact folders (`scm.compactFolders`), file
// labels (name + dimmed relative directory), Git decoration letters/colors,
// strike-through for deleted resources and the faded row class. Selection,
// hover, wheel scrolling, Home/End/PageUp/PageDown and Left/Right/Space
// collapse behavior follow the tree widget contract.
//
// Terminal adaptations:
// - The commit message uses a single-line InputBox and scrolls with the Git
//   action button and resource rows. Named branches have a split commit menu.
// - The host commits the index when it has staged changes. With an empty
//   index it uses the terminal smart-commit behavior and stages the selected
//   working/untracked changes before committing.
// - File and folder icons use the shared workbench glyphs. Rows and the tree
//   scrollbar are one cell tall.
// - Multiline messages, input validation/history, multi-selection, tree
//   filtering and automatic reveal are unported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const menus = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../platform/contextkey/common/contextkey.zig");
const OverlayContext = @import("../../../../platform/contextkey/browser/contextKeyService.zig").OverlayContext;
const MenuService = @import("../../../../platform/actions/common/menuService.zig").MenuService;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;

const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const ui = @import("ui");
const theme_colors_mod = @import("../../../browser/themeColors.zig");
const views = @import("../../../common/views.zig");
const scm = @import("../common/scm.zig");
const resource_tree = @import("../../../../base/common/resourceTree.zig");
const comparers = @import("../../../../base/common/comparers.zig");
const file_icon = @import("../../../services/themes/browser/fileIconThemeData.zig");
const css = @import("./media/scm_css.zig");
const IndentGuides = @import("../../../../base/browser/ui/tree/abstractTree.zig").RenderIndentGuides;
const list_scrollbar = @import("../../../../base/browser/ui/list/listScrollbarTerminal.zig");

pub const SET_LIST_VIEW_MODE_ACTION_ID = "workbench.scm.action.setListViewMode";
pub const SET_TREE_VIEW_MODE_ACTION_ID = "workbench.scm.action.setTreeViewMode";
pub const SET_SORT_BY_NAME_ACTION_ID = "workbench.scm.action.setSortKey.name";
pub const SET_SORT_BY_PATH_ACTION_ID = "workbench.scm.action.setSortKey.path";
pub const SET_SORT_BY_STATUS_ACTION_ID = "workbench.scm.action.setSortKey.status";
pub const REFRESH_ACTION_ID = "git.refresh";
pub const CHANGES_MENU_ACTION_ID = "workbench.scm.action.showChangesMenu";
pub const COMMIT_ACTION_ID = "git.commit";
const view_sort_menu = menus.MenuId{ .id = "SCMViewSort" };
const in_view = keys.Expr{ .Equals = .{ .key = "view", .value = .{ .string = scm.VIEW_PANE_ID } } };
const has_repositories = keys.Expr{ .NotEquals = .{ .key = "scmRepositoryCount", .value = .{ .number = 0 } } };
const list_view = keys.Expr{ .Equals = .{ .key = "scmViewMode", .value = .{ .string = "list" } } };

pub fn registerMenus(registry: *menus.MenuRegistry) !void {
    try registry.appendSubmenuItem(menus.menu_ids.SCMTitle, .{
        .title = "View & Sort",
        .submenu = view_sort_menu,
        .when = &.{ .And = @constCast(&[_]*const keys.Expr{ &in_view, &has_repositories }) },
        .group = "0_view&sort",
        .order = 1,
    });
    for ([_]menus.IMenuItem{
        .{ .command = .{ .id = SET_LIST_VIEW_MODE_ACTION_ID, .title = "View as List", .toggled = &list_view }, .group = "1_viewmode" },
        .{ .command = .{ .id = SET_TREE_VIEW_MODE_ACTION_ID, .title = "View as Tree", .toggled = &.{ .Equals = .{ .key = "scmViewMode", .value = .{ .string = "tree" } } } }, .group = "1_viewmode" },
    }) |item| try registry.appendMenuItem(view_sort_menu, item);
    inline for (.{
        .{ SET_SORT_BY_NAME_ACTION_ID, "Sort Changes by Name", "name" },
        .{ SET_SORT_BY_PATH_ACTION_ID, "Sort Changes by Path", "path" },
        .{ SET_SORT_BY_STATUS_ACTION_ID, "Sort Changes by Status", "status" },
    }) |entry| try registry.appendMenuItem(view_sort_menu, .{
        .command = .{ .id = entry[0], .title = entry[1], .precondition = &list_view, .toggled = &.{ .Equals = .{ .key = "scmViewSortKey", .value = .{ .string = entry[2] } } } },
        .group = "2_sort",
    });
}

pub fn appendSecondary(menu: *Menu, service: *MenuService, parent: keys.IContext, view: *const SCMViewPane) !void {
    var context = OverlayContext{ .parent = parent, .overlay = &.{
        .{ .key = "view", .value = .{ .string = scm.VIEW_PANE_ID } },
        .{ .key = "scmRepositoryCount", .value = .{ .number = @floatFromInt(view.service.repositoryCount()) } },
        .{ .key = "scmViewMode", .value = .{ .string = @tagName(view.viewMode()) } },
        .{ .key = "scmViewSortKey", .value = .{ .string = @tagName(view.effectiveSortKey()) } },
    } };
    try menu.appendMenuActions(service, menus.menu_ids.SCMTitle, context.interface(), true);
}

pub const CommitAction = @import("../common/scm.zig").CommitAction;
pub const ResourceAction = scm.ResourceAction;
fn resourceActionGlyph(action: ResourceAction) u21 {
    return switch (action) {
        .open_file => '⇥',
        .open_change => '▤',
        .discard => '↶',
        .stage => '+',
        .unstage => '−',
    };
}
pub const BranchAction = scm.BranchAction;

pub const ISCMService = scm.ISCMService;
pub const ISCMRepository = scm.ISCMRepository;
pub const ISCMResource = scm.ISCMResource;
pub const ISCMResourceGroup = scm.ISCMResourceGroup;
pub const ISCMInput = scm.ISCMInput;

/// Upstream `ViewSortKey` (browser-only in `scmViewPane.ts`).
pub const ViewSortKey = enum { path, name, status };

/// `scm.providerCountBadge`; only the repository header row uses it.
pub const ProviderCountBadge = enum { hidden, auto, visible };

pub const Config = struct {
    default_view_mode: scm.ViewMode = .list,
    default_view_sort_key: ViewSortKey = .path,
    always_show_repositories: bool = false,
    provider_count_badge: ProviderCountBadge = .hidden,
    compact_folders: bool = true,
    show_action_button: bool = true,
    show_commit_action: bool = true,
    show_publish_action: bool = true,
    show_sync_action: bool = true,
    decoration_colors: bool = true,
    decoration_badges: bool = true,
    indent_guides: IndentGuides = .on_hover,
    always_show_actions: bool = false,
    inline_open_file_action: bool = true,
    open_diff_on_click: bool = true,
    /// `scm.showInputActionButton`: hide the commit toolbar while keeping the
    /// message box and its Enter shortcut.
    show_input_action_button: bool = true,

    pub fn read(service: IConfigurationService) Config {
        var config = Config{};
        config.default_view_mode = if (std.mem.eql(u8, service.getString("scm.defaultViewMode") orelse "list", "list")) .list else .tree;
        if (service.getString("scm.defaultViewSortKey")) |value| {
            config.default_view_sort_key = std.meta.stringToEnum(ViewSortKey, value) orelse .path;
        }
        if (service.getString("scm.providerCountBadge")) |value| {
            config.provider_count_badge = std.meta.stringToEnum(ProviderCountBadge, value) orelse .hidden;
        }
        if (service.getString("workbench.tree.renderIndentGuides")) |value| config.indent_guides = IndentGuides.fromString(value);
        config.always_show_repositories = service.getBool("scm.alwaysShowRepositories", config.always_show_repositories);
        config.compact_folders = service.getBool("scm.compactFolders", config.compact_folders);
        config.show_input_action_button = service.getBool("scm.showInputActionButton", config.show_input_action_button);
        config.show_action_button = service.getBool("scm.showActionButton", config.show_action_button);
        config.show_commit_action = service.getBool("git.showActionButton.commit", config.show_commit_action);
        config.show_publish_action = service.getBool("git.showActionButton.publish", config.show_publish_action);
        config.show_sync_action = service.getBool("git.showActionButton.sync", config.show_sync_action);
        const decorations = service.getBool("git.decorations.enabled", true);
        config.decoration_colors = decorations and service.getBool("explorer.decorations.colors", config.decoration_colors);
        config.decoration_badges = decorations and service.getBool("explorer.decorations.badges", config.decoration_badges);
        config.always_show_actions = service.getBool("scm.alwaysShowActions", config.always_show_actions);
        config.inline_open_file_action = service.getBool("git.showInlineOpenFileAction", config.inline_open_file_action);
        config.open_diff_on_click = service.getBool("git.openDiffOnClick", config.open_diff_on_click);
        return config;
    }
};

pub const Host = struct {
    context: *anyopaque,
    open_change: *const fn (context: *anyopaque, resource: *ISCMResource) anyerror!void,
    resource_action: ?*const fn (context: *anyopaque, action: ResourceAction, resource: *ISCMResource) anyerror!void = null,
    refresh: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
    /// Commits the typed message. The host owns staging policy (the terminal
    /// substitutes Git's smart-commit prompt by staging changed files when the
    /// index is empty) and reports failures through `status`.
    commit: *const fn (context: *anyopaque, message: []const u8, action: CommitAction) anyerror!void,
    commit_menu: ?*const fn (context: *anyopaque, event: *const ui.MouseEvent) anyerror!void = null,
    branch_action: ?*const fn (context: *anyopaque, action: BranchAction) void = null,
    /// Shows a one-line status hint, used for an empty commit message.
    status: *const fn (context: *anyopaque, message: []const u8) void,
};

const RowKind = enum { repository, group, folder, resource, welcome };

const Row = struct {
    kind: RowKind,
    repository: ?*const ISCMRepository = null,
    group: ?*const ISCMResourceGroup = null,
    /// View-owned identity used to preserve the selection across a refresh.
    /// Groups/folders include the repository id so multiple repositories do
    /// not share collapse state.
    key: []const u8 = "",
    /// Resource `source_path` (view-owned), used to look the resource up in
    /// its group when it is opened.
    path: []const u8 = "",
    /// Display label: repository name, group label, folder name or file name.
    label: []const u8 = "",
    /// Dimmed relative directory of a resource (list mode only).
    description: ?[]const u8 = null,
    /// Group/repository resource count.
    count: ?usize = null,
    depth: usize = 0,
    collapsible: bool = false,
    collapsed: bool = false,
    letter: ?[]const u8 = null,
    color: ?[]const u8 = null,
    strike_through: bool = false,
    faded: bool = false,
};

/// Selection identity captured before a rebuild so the row under the cursor
/// survives refreshes, collapse changes and view-mode switches.
const RowIdentity = struct {
    kind: RowKind,
    key: []u8,

    fn capture(allocator: Allocator, row: Row) !RowIdentity {
        return .{ .kind = row.kind, .key = try allocator.dupe(u8, row.key) };
    }

    fn deinit(self: *RowIdentity, allocator: Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }

    fn matches(self: RowIdentity, row: Row) bool {
        return self.kind == row.kind and std.mem.eql(u8, self.key, row.key);
    }
};

const list_service = @import("../../../../platform/list/browser/listService.zig");

pub const SCMViewPane = struct {
    pub const ID = scm.VIEW_PANE_ID;

    allocator: Allocator,
    service: *ISCMService,
    host: Host,
    config: Config = .{},
    view_mode: scm.ViewMode = .list,
    sort_key: ViewSortKey = .path,
    view_mode_overridden: bool = false,
    sort_key_overridden: bool = false,

    rows: std.array_list.Managed(Row),
    /// Selected row index into `rows`; null until the user interacts, like an
    /// unfocused browser tree.
    selection: ?usize = null,
    scroll: usize = 0,
    hovered_row: ?usize = null,
    hovered_col: ?usize = null,
    list_hovered: bool = false,
    list_focused: bool = false,
    pane_focused: bool = false,
    list_focus: list_service.ListFocus,
    fresh_repository: bool = false,
    visible_rows: usize = 0,
    /// Rows above the list: the section header plus its divider while the view
    /// paints them, zero when the side bar part paints the title.
    header_rows: usize = 0,

    theme: ?*const theme_colors_mod.ThemeColors = null,
    arena: std.heap.ArenaAllocator,
    /// The terminal projection of `SCMInputWidget` for the active repository.
    input_box: ui.InputBox,
    input_surface: ?ui.Surface = null,
    input_focused: bool = false,
    input_rows: usize = 0,
    branch_action: ?BranchAction = null,
    hovered_input_action: ?InputAction = null,
    collapsed_repositories: std.StringHashMap(void),
    collapsed_groups: std.StringHashMap(void),
    collapsed_folders: std.StringHashMap(void),
    actions: [3]views.TitleAction = undefined,

    pub fn init(allocator: Allocator, service: *ISCMService, host: Host) SCMViewPane {
        return .{
            .allocator = allocator,
            .list_focus = .init(allocator),
            .service = service,
            .host = host,
            .rows = std.array_list.Managed(Row).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .input_box = ui.InputBox.init(allocator),
            .collapsed_repositories = std.StringHashMap(void).init(allocator),
            .collapsed_groups = std.StringHashMap(void).init(allocator),
            .collapsed_folders = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *SCMViewPane) void {
        self.list_focus.deinit();
        self.rows.deinit();
        self.input_box.deinit();
        if (self.input_surface) |*surface| surface.deinit();
        self.arena.deinit();
        freeMapKeys(&self.collapsed_repositories, self.allocator);
        freeMapKeys(&self.collapsed_groups, self.allocator);
        freeMapKeys(&self.collapsed_folders, self.allocator);
        self.collapsed_repositories.deinit();
        self.collapsed_groups.deinit();
        self.collapsed_folders.deinit();
        self.* = undefined;
    }

    // ------------------------------------------------------------------
    // View state
    // ------------------------------------------------------------------

    pub fn setConfig(self: *SCMViewPane, config: Config) void {
        self.config = config;
        self.applyConfiguredViewState();
        self.refresh();
    }

    fn applyConfiguredViewState(self: *SCMViewPane) void {
        if (!self.view_mode_overridden) self.view_mode = self.config.default_view_mode;
        if (!self.sort_key_overridden) self.sort_key = self.config.default_view_sort_key;
    }

    pub fn setViewMode(self: *SCMViewPane, mode: scm.ViewMode) void {
        if (self.view_mode == mode) return;
        self.view_mode = mode;
        self.view_mode_overridden = true;
        self.refresh();
    }

    pub fn setViewSortKey(self: *SCMViewPane, key: ViewSortKey) void {
        if (self.sort_key == key) return;
        self.sort_key = key;
        self.sort_key_overridden = true;
        self.refresh();
    }

    pub fn viewMode(self: *const SCMViewPane) scm.ViewMode {
        return self.view_mode;
    }

    pub fn viewSortKey(self: *const SCMViewPane) ViewSortKey {
        return self.sort_key;
    }

    fn effectiveSortKey(self: *const SCMViewPane) ViewSortKey {
        return if (self.view_mode == .tree) .path else self.sort_key;
    }

    pub fn titleActions(self: *SCMViewPane) []const views.TitleAction {
        const has_repository = self.service.repositoryCount() > 0;
        self.actions[0] = .{
            .id = COMMIT_ACTION_ID,
            .label = "Commit",
            .glyph = '✓',
            .enabled = self.canCommit(),
        };
        self.actions[1] = .{
            .id = REFRESH_ACTION_ID,
            .label = "Refresh",
            .glyph = '↻',
            .enabled = has_repository,
        };
        self.actions[2] = .{
            .id = CHANGES_MENU_ACTION_ID,
            .label = "More Actions",
            .glyph = '…',
            .enabled = has_repository,
        };
        return &self.actions;
    }

    // ------------------------------------------------------------------
    // Row building
    // ------------------------------------------------------------------

    /// Rebuilds the row list from the SCM service, preserving the selected row
    /// by identity.
    pub fn refresh(self: *SCMViewPane) void {
        self.ensureInputConfigured();
        var previous: ?RowIdentity = null;
        if (self.selection) |index| {
            if (index < self.rows.items.len) {
                previous = RowIdentity.capture(self.allocator, self.rows.items[index]) catch null;
            }
        }
        defer if (previous) |*identity| identity.deinit(self.allocator);

        self.rows.clearRetainingCapacity();
        self.hovered_row = null;
        _ = self.arena.reset(.retain_capacity);
        self.buildRows() catch {};
        self.input_rows = self.inputRowCount();
        self.restoreSelection(previous);
        self.clampScroll();
        self.syncInput();
    }

    // ------------------------------------------------------------------
    // Commit input
    // ------------------------------------------------------------------

    fn ensureInputConfigured(self: *SCMViewPane) void {
        const context: ?*anyopaque = self;
        if (self.input_box.callback_context == context) return;
        self.input_box.callback_context = self;
        self.input_box.on_change = onInputChange;
        self.input_box.on_enter = onInputEnter;
        self.input_box.on_escape = onInputEscape;
        self.input_box.placeholder_when_focused = true;
    }

    fn activeRepository(self: *const SCMViewPane) ?*const ISCMRepository {
        const repositories = self.service.repositories();
        if (repositories.len == 0) return null;
        return &repositories[0];
    }

    fn activeInput(self: *const SCMViewPane) ?ISCMInput {
        const repository = self.activeRepository() orelse return null;
        return repository.input;
    }

    fn inputVisible(self: *const SCMViewPane) bool {
        const input = self.activeInput() orelse return false;
        return input.visible();
    }

    fn inputRowCount(self: *const SCMViewPane) usize {
        if (self.showActionButton()) return self.actionButtonRow() + 1;
        return if (self.inputVisible()) 2 else 0;
    }

    fn showActionButton(self: *const SCMViewPane) bool {
        const repository = self.activeRepository() orelse return false;
        return (repository.input.visible() or (self.host.commit_menu != null and repository.provider.detail != null)) and
            self.config.show_action_button and self.config.show_input_action_button and
            (self.config.show_commit_action or self.activeBranchAction() != null);
    }

    fn activeBranchAction(self: *const SCMViewPane) ?BranchAction {
        if (self.host.branch_action == null or (self.canCommit() and self.config.show_commit_action)) return null;
        const action = self.branch_action orelse return null;
        return switch (action) {
            .publish => if (self.config.show_publish_action) action else null,
            .sync => if (self.config.show_sync_action) action else null,
        };
    }

    fn showCommitDropdown(self: *const SCMViewPane, width: usize) bool {
        const repo = self.activeRepository() orelse return false;
        return repo.provider.detail != null and self.activeBranchAction() == null and
            self.host.commit_menu != null and width >= css.dropdown_width + 4;
    }

    fn repositoryHasChanges(repository: *const ISCMRepository) bool {
        for (repository.provider.groups()) |group| {
            if (group.resources().len > 0) return true;
        }
        return false;
    }

    fn canCommit(self: *const SCMViewPane) bool {
        const repository = self.activeRepository() orelse return false;
        const input = repository.input;
        return input.enabled() and repositoryHasChanges(repository);
    }

    fn syncInput(self: *SCMViewPane) void {
        const repository = self.activeRepository() orelse {
            self.setInputFocused(false);
            return;
        };
        const input = repository.input;
        self.input_box.setEnabled(input.enabled());
        self.input_box.placeholder = input.placeholder();
        self.input_box.setValue(input.value()) catch {};
        if (!input.visible() or !input.enabled()) self.setInputFocused(false);
    }

    /// Commits the current message through the host. The terminal has no
    /// modal smart-commit prompt, so the host stages changed files when the
    /// index is empty; successful commits clear the input and refresh the
    /// repository state.
    pub fn commitInput(self: *SCMViewPane) bool {
        return self.commitInputWithAction(.commit);
    }

    pub fn commitInputWithAction(self: *SCMViewPane, action: CommitAction) bool {
        self.ensureInputConfigured();
        const repository = self.activeRepository() orelse return false;
        const input = repository.input;
        if (!input.enabled()) return false;
        if (action != .amend and !repositoryHasChanges(repository)) {
            self.host.status(self.host.context, "No changes to commit");
            return false;
        }
        const message = std.mem.trim(u8, input.value(), " \t\r\n");
        if (action != .amend and message.len == 0) {
            self.host.status(self.host.context, "Commit message is required");
            return false;
        }
        self.host.commit(self.host.context, message, action) catch return false;
        self.input_box.clear() catch {};
        input.setValue("", true);
        self.host.refresh(self.host.context);
        return true;
    }

    fn onInputChange(context: ?*anyopaque, value: []const u8) void {
        const self: *SCMViewPane = @ptrCast(@alignCast(context orelse return));
        const input = self.activeInput() orelse return;
        input.setValue(value, true);
    }

    fn onInputEnter(context: ?*anyopaque) void {
        const self: *SCMViewPane = @ptrCast(@alignCast(context orelse return));
        _ = self.commitInput();
    }

    fn onInputEscape(context: ?*anyopaque) void {
        const self: *SCMViewPane = @ptrCast(@alignCast(context orelse return));
        self.setInputFocused(false);
        self.input_box.focused = false;
        self.host.focus_editor(self.host.context);
    }

    fn buildRows(self: *SCMViewPane) !void {
        const repositories = self.service.repositories();
        if (repositories.len == 0) {
            try self.rows.append(.{
                .kind = .welcome,
                .label = "No source control providers",
                .key = "",
            });
            return;
        }

        const show_repositories = self.config.always_show_repositories or repositories.len > 1;
        if (!show_repositories) {
            try self.appendGroups(&repositories[0], 0);
            return;
        }

        for (repositories) |*repository| {
            const count = repositoryResourceCount(repository);
            const collapsed = self.collapsed_repositories.contains(repository.id);
            try self.rows.append(.{
                .kind = .repository,
                .repository = repository,
                .key = try self.arena.allocator().dupe(u8, repository.id),
                .label = try self.arena.allocator().dupe(u8, repository.provider.name),
                .count = count,
                .depth = 0,
                .collapsible = true,
                .collapsed = collapsed,
            });
            if (collapsed) continue;
            try self.appendGroups(repository, 1);
        }
    }

    fn appendGroups(self: *SCMViewPane, repository: *const ISCMRepository, depth: usize) !void {
        const arena = self.arena.allocator();
        const provider = repository.provider;
        for (provider.groups()) |group| {
            const resources = group.resources();
            // `SCMTreeFilter`: an empty group is hidden when it opted into
            // `hideWhenEmpty`.
            if (resources.len == 0 and group.hide_when_empty) continue;
            const group_key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ repository.id, group.id });
            const collapsed = self.collapsed_groups.contains(group_key);
            try self.rows.append(.{
                .kind = .group,
                .repository = repository,
                .group = group,
                .key = group_key,
                .label = group.label,
                .count = resources.len,
                .depth = depth,
                .collapsible = true,
                .collapsed = collapsed,
            });
            if (collapsed) continue;

            if (self.view_mode == .tree) {
                try self.appendTreeGroup(repository.id, group, resources, depth + 1);
            } else {
                try self.appendListGroup(repository.id, group, resources, depth + 1);
            }
        }
    }

    fn appendListGroup(
        self: *SCMViewPane,
        repository_id: []const u8,
        group: *const ISCMResourceGroup,
        resources: []const ISCMResource,
        depth: usize,
    ) !void {
        const order = try self.sortedResourceIndices(resources);
        for (order) |resource_index| {
            const resource = &resources[resource_index];
            try self.appendResourceRow(repository_id, group, resource, depth);
        }
    }

    fn appendResourceRow(
        self: *SCMViewPane,
        repository_id: []const u8,
        group: *const ISCMResourceGroup,
        resource: *const ISCMResource,
        depth: usize,
    ) !void {
        const arena = self.arena.allocator();
        const root = group.provider.root_path;
        const relative = relativeLabel(resource.source_path, root);
        const split = std.fs.path.dirname(relative);
        const name = std.fs.path.basename(relative);
        // Upstream `hidePath` is true in tree mode: the folder rows already
        // describe the directory chain.
        const description: ?[]const u8 = if (self.view_mode == .list)
            if (split) |directory|
                if (directory.len == 0 or std.mem.eql(u8, directory, ".")) null else try arena.dupe(u8, directory)
            else
                null
        else
            null;
        try self.rows.append(.{
            .kind = .resource,
            .group = group,
            .key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ repository_id, resource.source_path }),
            .path = try arena.dupe(u8, resource.source_path),
            .label = try arena.dupe(u8, if (name.len > 0) name else relative),
            .description = description,
            .depth = depth,
            .letter = if (resource.decorations.letter) |letter| try arena.dupe(u8, letter) else null,
            .color = if (resource.decorations.color) |color| try arena.dupe(u8, color) else null,
            .strike_through = resource.decorations.strike_through,
            .faded = resource.decorations.faded,
        });
    }

    fn appendTreeGroup(
        self: *SCMViewPane,
        repository_id: []const u8,
        group: *const ISCMResourceGroup,
        resources: []const ISCMResource,
        depth: usize,
    ) !void {
        const arena = self.arena.allocator();
        var tree = try resource_tree.ResourceTree(usize, void).init(arena, {}, "/");
        const root_path = group.provider.root_path orelse "";
        for (resources, 0..) |resource, index| {
            const relative = relativeLabel(resource.source_path, root_path);
            if (relative.len == 0) continue;
            _ = tree.add(relative, index) catch continue;
        }
        try self.appendTreeChildren(repository_id, group, resources, depth, tree.root, false);
    }

    fn appendTreeChildren(
        self: *SCMViewPane,
        repository_id: []const u8,
        group: *const ISCMResourceGroup,
        resources: []const ISCMResource,
        depth: usize,
        node: *resource_tree.ResourceTree(usize, void).NodeType,
        compress_folders: bool,
    ) !void {
        const arena = self.arena.allocator();
        const TreeNode = resource_tree.ResourceTree(usize, void).NodeType;
        const children = node.childNodes();
        if (children.len == 0) return;
        const sorted = try arena.alloc(*TreeNode, children.len);
        @memcpy(sorted, children);
        std.mem.sort(*TreeNode, sorted, {}, treeChildLessThan);

        for (sorted) |child| {
            const is_folder = child.childrenCount() > 0;
            if (!is_folder) {
                if (child.element) |resource_index| {
                    if (resource_index < resources.len) {
                        try self.appendResourceRow(repository_id, group, &resources[resource_index], depth);
                    }
                }
                continue;
            }

            var current = child;
            var label = try arena.dupe(u8, child.name);
            // `SCMTreeCompressionDelegate.isIncompressible` treats a
            // top-level folder as incompressible (its parent is the resource
            // tree root); deeper single-child folder chains compress.
            if (self.config.compact_folders and compress_folders) {
                while (current.childrenCount() == 1) {
                    const only = current.childNodes()[0];
                    if (only.childrenCount() == 0) break;
                    label = try std.fmt.allocPrint(arena, "{s}/{s}", .{ label, only.name });
                    current = only;
                }
            }
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ repository_id, group.id, current.relative_path });
            const collapsed = self.collapsed_folders.contains(key);
            try self.rows.append(.{
                .kind = .folder,
                .group = group,
                .key = key,
                .label = label,
                .depth = depth,
                .collapsible = true,
                .collapsed = collapsed,
            });
            if (collapsed) continue;
            try self.appendTreeChildren(repository_id, group, resources, depth + 1, current, true);
        }
    }

    fn sortedResourceIndices(self: *SCMViewPane, resources: []const ISCMResource) ![]usize {
        const arena = self.arena.allocator();
        const order = try arena.alloc(usize, resources.len);
        for (order, 0..) |*value, index| value.* = index;
        std.mem.sort(usize, order, SortContext{
            .key = self.effectiveSortKey(),
            .resources = resources,
        }, resourceLessThan);
        return order;
    }

    const SortContext = struct {
        key: ViewSortKey,
        resources: []const ISCMResource,
    };

    fn resourceLessThan(context: SortContext, a: usize, b: usize) bool {
        const one = context.resources[a];
        const other = context.resources[b];
        const result: i32 = switch (context.key) {
            .name => comparers.compareFileNames(std.fs.path.basename(one.source_path), std.fs.path.basename(other.source_path)),
            .status => blk: {
                const one_text = one.decorations.tooltip orelse "";
                const other_text = other.decorations.tooltip orelse "";
                const order = std.mem.order(u8, one_text, other_text);
                if (order != .eq) break :blk if (order == .lt) -1 else 1;
                break :blk comparers.comparePaths(one.source_path, other.source_path);
            },
            .path => comparers.comparePaths(one.source_path, other.source_path),
        };
        if (result != 0) return result < 0;
        // Stable order for equal names/paths, like Array.prototype.sort.
        return a < b;
    }

    fn treeChildLessThan(_: void, a: *resource_tree.ResourceTree(usize, void).NodeType, b: *resource_tree.ResourceTree(usize, void).NodeType) bool {
        const a_folder = a.childrenCount() > 0;
        const b_folder = b.childrenCount() > 0;
        if (a_folder != b_folder) return a_folder;
        return comparers.compareFileNames(a.name, b.name) < 0;
    }

    fn restoreSelection(self: *SCMViewPane, previous: ?RowIdentity) void {
        if (self.rows.items.len == 0 or self.selection == null) {
            if (self.rows.items.len == 0) self.selection = null;
            self.ensureSelectionVisible();
            return;
        }
        if (previous) |identity| {
            for (self.rows.items, 0..) |row, index| {
                if (identity.matches(row)) {
                    self.selection = index;
                    self.ensureSelectionVisible();
                    return;
                }
            }
        }
        if (self.selection) |index| {
            if (index >= self.rows.items.len) self.selection = self.rows.items.len - 1;
        }
        self.ensureSelectionVisible();
    }

    // ------------------------------------------------------------------
    // Selection
    // ------------------------------------------------------------------

    pub fn resourceCount(self: *const SCMViewPane) usize {
        var count: usize = 0;
        for (self.rows.items) |row| {
            if (row.kind == .resource) count += 1;
        }
        return count;
    }

    pub fn selectedRowIndex(self: *const SCMViewPane) ?usize {
        const index = self.selection orelse return null;
        if (index >= self.rows.items.len) return null;
        return index;
    }

    pub fn selectedResource(self: *SCMViewPane) ?*ISCMResource {
        const index = self.selectedRowIndex() orelse return null;
        const row = &self.rows.items[index];
        if (row.kind != .resource) return null;
        return resolveResource(row);
    }

    /// Moves the selection by `delta` rows. With no selection a positive delta
    /// selects the first row and a negative delta the last, matching the tree
    /// widget's focus handling.
    pub fn moveSelection(self: *SCMViewPane, delta: isize) bool {
        if (self.rows.items.len == 0) return false;
        const count: isize = @intCast(self.rows.items.len);
        if (self.selection) |current| {
            const next = std.math.clamp(@as(isize, @intCast(current)) + delta, 0, count - 1);
            self.selection = @intCast(next);
        } else {
            self.selection = if (delta >= 0) 0 else self.rows.items.len - 1;
        }
        self.ensureSelectionVisible();
        return true;
    }

    fn selectFirst(self: *SCMViewPane) bool {
        if (self.rows.items.len == 0) return false;
        self.selection = 0;
        self.ensureSelectionVisible();
        return true;
    }

    fn selectLast(self: *SCMViewPane) bool {
        if (self.rows.items.len == 0) return false;
        self.selection = self.rows.items.len - 1;
        self.ensureSelectionVisible();
        return true;
    }

    fn ensureSelectionVisible(self: *SCMViewPane) void {
        const selected = (self.selection orelse return) + self.input_rows;
        if (self.visible_rows == 0) return;
        if (selected < self.scroll) {
            self.scroll = selected;
        } else if (selected >= self.scroll + self.visible_rows) {
            self.scroll = selected - self.visible_rows + 1;
        }
        self.clampScroll();
    }

    fn clampScroll(self: *SCMViewPane) void {
        const max_scroll = self.contentRowCount() -| self.visible_rows;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }

    fn contentRowCount(self: *const SCMViewPane) usize {
        return self.input_rows + self.rows.items.len;
    }

    fn toggleSelected(self: *SCMViewPane) bool {
        const index = self.selectedRowIndex() orelse return false;
        const row = self.rows.items[index];
        if (!row.collapsible) return false;
        self.setRowCollapsed(row) catch return false;
        return true;
    }

    fn setRowCollapsed(self: *SCMViewPane, row: Row) !void {
        const collapsed = !row.collapsed;
        switch (row.kind) {
            .repository => {
                _ = row.repository orelse return;
                try setMapOwned(&self.collapsed_repositories, self.allocator, row.key, collapsed);
            },
            .group => {
                _ = row.group orelse return;
                try setMapOwned(&self.collapsed_groups, self.allocator, row.key, collapsed);
            },
            .folder => {
                try setMapOwned(&self.collapsed_folders, self.allocator, row.key, collapsed);
            },
            .resource, .welcome => return,
        }
        self.refresh();
    }

    // ------------------------------------------------------------------
    // Interaction
    // ------------------------------------------------------------------

    pub fn registerList(self: *SCMViewPane, service: *list_service.ListService) !void {
        try service.register(.{ .context = self, .focus = &self.list_focus, .run = runListCommand });
    }

    pub fn setPaneFocused(self: *SCMViewPane, focused: bool) void {
        self.pane_focused = focused;
        self.list_focus.setFocused(focused and !self.input_focused);
    }

    fn setInputFocused(self: *SCMViewPane, focused: bool) void {
        self.input_focused = focused;
        self.list_focus.setFocused(self.pane_focused and !focused);
    }

    fn runListCommand(context: *anyopaque, operation: list_service.Navigation) !void {
        const self: *SCMViewPane = @ptrCast(@alignCast(context));
        self.blurInput();
        var event = ui.KeyEvent{ .key = operation.key() };
        _ = try self.handleKey(&event);
    }

    pub fn handleKey(self: *SCMViewPane, event: *ui.KeyEvent) !bool {
        self.ensureInputConfigured();

        // Ctrl-Enter is the upstream `scm.acceptInput` shortcut and commits
        // from the list as well as from the message box.
        if (event.mods.ctrl and event.key == .enter) return self.commitInput();

        if (self.input_focused and self.inputVisible()) {
            self.input_box.focused = true;
            if (self.input_box.handleKey(event)) return true;
            switch (event.key) {
                .up => {
                    self.setInputFocused(false);
                    self.input_box.focused = false;
                    return self.moveSelection(-1);
                },
                .down => {
                    self.setInputFocused(false);
                    self.input_box.focused = false;
                    return self.moveSelection(1);
                },
                .page_up, .page_down => {
                    self.setInputFocused(false);
                    self.input_box.focused = false;
                    return self.handleKey(event);
                },
                else => return false,
            }
        }

        switch (event.key) {
            .tab => {
                // Tab reveals and focuses the message row.
                if (self.inputVisible()) {
                    const input = self.activeInput() orelse return false;
                    if (!input.enabled()) return false;
                    self.scroll = 0;
                    self.setInputFocused(true);
                    self.input_box.focused = true;
                    return true;
                }
                return false;
            },
            .up => return self.moveSelection(-1),
            .down => return self.moveSelection(1),
            .home => return self.selectFirst(),
            .end => return self.selectLast(),
            .page_up => return self.moveSelection(-@as(isize, @intCast(@max(self.visible_rows, 1)))),
            .page_down => return self.moveSelection(@intCast(@max(self.visible_rows, 1))),
            .left => return self.collapseOrSelectParent(),
            .right => return self.expandOrSelectChild(),
            .enter => {
                if (self.selectedResource()) |resource| {
                    try self.openResource(resource);
                    return true;
                }
                return false;
            },
            .escape => {
                self.host.focus_editor(self.host.context);
                return true;
            },
            .char => |ch| {
                if (ch == ' ') return self.toggleSelected();
                if (ch == 'r' or ch == 'R') {
                    self.host.refresh(self.host.context);
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn collapseOrSelectParent(self: *SCMViewPane) bool {
        const index = self.selectedRowIndex() orelse return false;
        const row = self.rows.items[index];
        if (row.collapsible and !row.collapsed) {
            self.setRowCollapsed(row) catch return false;
            return true;
        }
        if (row.depth == 0) return false;
        var parent = index;
        while (parent > 0) {
            parent -= 1;
            if (self.rows.items[parent].depth < row.depth) {
                self.selection = parent;
                self.ensureSelectionVisible();
                return true;
            }
        }
        return false;
    }

    fn expandOrSelectChild(self: *SCMViewPane) bool {
        const index = self.selectedRowIndex() orelse return false;
        const row = self.rows.items[index];
        if (!row.collapsible) return false;
        if (row.collapsed) {
            self.setRowCollapsed(row) catch return false;
            return true;
        }
        if (index + 1 < self.rows.items.len and self.rows.items[index + 1].depth > row.depth) {
            self.selection = index + 1;
            self.ensureSelectionVisible();
            return true;
        }
        return false;
    }

    /// Mouse handling for the view body. A move tracks the hovered row, a
    /// wheel scrolls the list, and a press selects the row it lands on.
    pub fn handleMouse(self: *SCMViewPane, event: *ui.MouseEvent, rect: ui.Rect) !bool {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x or event.x >= x + width) return false;
        if (event.y < y or event.y >= y + height) return false;
        const list_top = y + self.header_rows;
        if (event.y < list_top) return false;
        const list_height = height -| self.header_rows;
        const list_width = list_scrollbar.contentWidth(width, list_height, self.contentRowCount());
        const col = event.x - x;
        const offset = event.y - list_top;
        const row = self.scroll + offset;
        if (col < list_width and row < self.input_rows and event.kind != .wheel) {
            var local = event.*;
            local.x = col;
            local.y = row;
            self.clearHover();
            return self.handleInputMouse(&local, list_width, event);
        }
        // A wheel scroll moves the viewport without changing keyboard focus.
        self.hovered_input_action = null;

        switch (event.kind) {
            .move => {
                const hovered = if (col < list_width) self.resourceRowAt(row) else null;
                const changed = !self.list_hovered or hovered != self.hovered_row or col != self.hovered_col;
                self.list_hovered = true;
                self.hovered_row = hovered;
                self.hovered_col = col;
                return changed;
            },
            .wheel => {
                if (!self.scrollBy(event.delta_y, list_height)) return false;
                self.list_hovered = true;
                self.hovered_row = if (col < list_width) self.resourceRowAt(self.scroll + offset) else null;
                self.hovered_col = col;
                return true;
            },
            .down, .click => {
                if (event.button != .left or col >= list_width) return false;
                self.setInputFocused(false);
                self.input_box.focused = false;
                const row_index = self.resourceRowAt(row) orelse {
                    const changed = self.selection != null;
                    self.selection = null;
                    return changed;
                };
                if (self.inlineActions(row_index, list_width).hit(col)) |action| {
                    if (resolveResource(&self.rows.items[row_index])) |resource| {
                        self.selection = row_index;
                        if (self.host.resource_action) |run| try run(self.host.context, action, resource);
                        return true;
                    }
                }
                self.selection = row_index;
                const resource_row = self.rows.items[row_index];
                if (resource_row.collapsible) {
                    try self.setRowCollapsed(resource_row);
                    return true;
                }
                if (resource_row.kind == .resource) {
                    if (resolveResource(&self.rows.items[row_index])) |resource| {
                        try self.openResource(resource);
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    fn openResource(self: *SCMViewPane, resource: *ISCMResource) !void {
        if (!self.config.open_diff_on_click) {
            if (self.host.resource_action) |run| return run(self.host.context, .open_file, resource);
        }
        try self.host.open_change(self.host.context, resource);
    }

    const InlineActions = struct {
        items: [3]ResourceAction = undefined,
        count: usize = 0,
        start: usize = 0,

        fn hit(self: InlineActions, col: usize) ?ResourceAction {
            if (col < self.start) return null;
            const slot = (col - self.start) / css.inline_action_width;
            return if (slot < self.count) self.items[slot] else null;
        }
    };

    fn inlineActions(self: *const SCMViewPane, index: usize, width: usize) InlineActions {
        const row = self.rows.items[index];
        var actions = InlineActions{};
        if (self.host.resource_action == null or row.kind != .resource) return actions;
        if (!self.config.always_show_actions and self.hovered_row != index and
            !(self.list_focused and self.selection == index)) return actions;
        const group = row.group orelse return actions;
        const staged = std.mem.eql(u8, group.id, "index");
        const working = std.mem.eql(u8, group.id, "working");
        if (self.config.inline_open_file_action) {
            actions.items[actions.count] = if (self.config.open_diff_on_click) .open_file else .open_change;
            actions.count += 1;
        }
        const untracked = if (row.letter) |letter| std.mem.eql(u8, letter, "U") else false;
        if (working and !(self.fresh_repository and untracked)) {
            actions.items[actions.count] = .discard;
            actions.count += 1;
        }
        actions.items[actions.count] = if (staged) .unstage else .stage;
        actions.count += 1;
        const end = self.resourceLabelEnd(row, width);
        const label_start = 3 + row.depth * 2;
        const fit = @min(actions.count, (end -| (label_start + 2)) / css.inline_action_width);
        if (fit < actions.count) {
            std.mem.copyForwards(ResourceAction, actions.items[0..fit], actions.items[actions.count - fit .. actions.count]);
            actions.count = fit;
        }
        actions.start = end - actions.count * css.inline_action_width;
        return actions;
    }

    pub fn pointerAt(self: *const SCMViewPane, event: *const ui.MouseEvent, rect: ui.Rect) ui.Pointer {
        const col = event.x -| ui.cell.snap(rect.x);
        const width = ui.cell.snap(rect.w);
        const list_width = list_scrollbar.contentWidth(width, self.visible_rows, self.contentRowCount());
        const top = ui.cell.snap(rect.y) + self.header_rows;
        if (event.y < top or col >= list_width) return .default;
        const row = self.scroll + event.y - top;
        if (row < self.input_rows) {
            if (self.actionAt(col, row, list_width) != null) return .pointer;
            return if (row == 0 and self.inputVisible()) .text else .default;
        }
        if (self.hovered_row) |index| {
            if (index < self.rows.items.len and self.inlineActions(index, list_width).hit(col) != null) return .pointer;
        }
        return .default;
    }

    const InputAction = enum { commit, dropdown };

    fn actionAt(self: *const SCMViewPane, x: usize, row: usize, width: usize) ?InputAction {
        if (!self.showActionButton() or row != self.actionButtonRow()) return null;
        const right = width -| css.right_inset;
        if (x < css.gutter or x >= right) return null;
        if (self.showCommitDropdown(right - css.gutter) and x >= right - css.dropdown_width) return .dropdown;
        return .commit;
    }

    fn actionButtonRow(self: *const SCMViewPane) usize {
        return if (self.inputVisible()) css.action_button_row else 0;
    }

    fn handleInputMouse(
        self: *SCMViewPane,
        local: *ui.MouseEvent,
        width: usize,
        event: *const ui.MouseEvent,
    ) !bool {
        const action = self.actionAt(local.x, local.y, width);
        const over_input = self.inputVisible() and local.y == 0 and
            local.x >= css.gutter and local.x < width -| css.right_inset;

        switch (local.kind) {
            .move => {
                self.hovered_input_action = action;
                if (over_input) _ = self.input_box.handleMouse(local);
            },
            .down, .click => {
                if (local.button != .left) return false;
                if (action) |target| {
                    switch (target) {
                        .commit => {
                            if (self.activeBranchAction()) |branch| {
                                if (self.host.branch_action) |run| run(self.host.context, branch);
                            } else if (self.canCommit()) {
                                _ = self.commitInput();
                            }
                        },
                        .dropdown => if (self.host.commit_menu) |menu| try menu(self.host.context, event),
                    }
                } else {
                    const enabled = if (self.activeInput()) |input| input.enabled() else false;
                    self.setInputFocused(over_input and enabled);
                    self.input_box.focused = self.input_focused;
                    if (self.input_focused) _ = self.input_box.handleMouse(local);
                }
            },
            else => {},
        }
        return true;
    }

    fn resourceRowAt(self: *const SCMViewPane, row: usize) ?usize {
        if (row < self.input_rows) return null;
        const index = row - self.input_rows;
        if (index >= self.rows.items.len) return null;
        return index;
    }

    fn scrollBy(self: *SCMViewPane, delta: i32, list_height: usize) bool {
        if (delta == 0 or self.contentRowCount() <= list_height) return false;
        const max_scroll: isize = @intCast(self.contentRowCount() - list_height);
        const current: isize = @intCast(self.scroll);
        const next = std.math.clamp(current + delta, 0, max_scroll);
        if (next == current) return false;
        self.scroll = @intCast(next);
        return true;
    }

    pub fn clearHover(self: *SCMViewPane) void {
        self.hovered_row = null;
        self.hovered_col = null;
        self.list_hovered = false;
        self.hovered_input_action = null;
    }

    /// Drops commit-message focus without touching the text. The workbench
    /// calls this when focus leaves the side bar so stale input focus cannot
    /// capture keys when the SCM view becomes active again.
    pub fn blurInput(self: *SCMViewPane) void {
        self.setInputFocused(false);
        self.input_box.focused = false;
        self.hovered_input_action = null;
    }

    pub fn setThemeColors(self: *SCMViewPane, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    const Colors = struct {
        background: ui.Color,
        foreground: ui.Color,
        dim: ui.Color,
        hover: ui.Color,
        active_selection: ui.Color,
        inactive_selection: ui.Color,
        selection_foreground: ui.Color,
        badge_background: ui.Color,
        badge_foreground: ui.Color,
        input_background: ui.Color,
        input_foreground: ui.Color,
        input_placeholder: ui.Color,
        input_border: ui.Color,
        focus_border: ui.Color,
        icon_foreground: ui.Color,
        toolbar_hover: ui.Color,
        button_background: ui.Color,
        button_foreground: ui.Color,
        button_hover: ui.Color,
        button_secondary: ui.Color,
        button_separator: ui.Color,
        disabled_foreground: ui.Color,
    };

    fn colors(self: *const SCMViewPane) Colors {
        var result = Colors{
            .background = .{ .r = 30, .g = 30, .b = 33 },
            .foreground = .{ .r = 190, .g = 190, .b = 190 },
            .dim = .{ .r = 150, .g = 150, .b = 150 },
            .hover = .{ .r = 42, .g = 45, .b = 46 },
            .active_selection = .{ .r = 4, .g = 57, .b = 94 },
            .inactive_selection = .{ .r = 55, .g = 55, .b = 61 },
            .selection_foreground = .{ .r = 255, .g = 255, .b = 255 },
            .badge_background = .{ .r = 77, .g = 77, .b = 77 },
            .badge_foreground = .{ .r = 255, .g = 255, .b = 255 },
            .input_background = .{ .r = 60, .g = 60, .b = 60 },
            .input_foreground = .{ .r = 204, .g = 204, .b = 204 },
            .input_placeholder = .{ .r = 150, .g = 150, .b = 150 },
            .input_border = .{ .r = 70, .g = 70, .b = 70 },
            .focus_border = .{ .r = 0, .g = 122, .b = 204 },
            .icon_foreground = .{ .r = 197, .g = 197, .b = 197 },
            .toolbar_hover = .{ .r = 90, .g = 93, .b = 94 },
            .button_background = .{ .r = 14, .g = 99, .b = 156 },
            .button_foreground = .{ .r = 255, .g = 255, .b = 255 },
            .button_hover = .{ .r = 17, .g = 119, .b = 187 },
            .button_secondary = .{ .r = 42, .g = 45, .b = 46 },
            .button_separator = .{ .r = 150, .g = 150, .b = 150 },
            .disabled_foreground = .{ .r = 120, .g = 120, .b = 120 },
        };
        if (self.theme) |palette| {
            result.background = palette.colorOr("sideBar.background", result.background);
            result.foreground = palette.colorOr("sideBar.foreground", result.foreground);
            result.dim = palette.colorOr("descriptionForeground", result.dim);
            result.hover = palette.colorOr("list.hoverBackground", result.hover);
            result.active_selection = palette.colorOr("list.activeSelectionBackground", result.active_selection);
            result.inactive_selection = palette.colorOr("list.inactiveSelectionBackground", result.inactive_selection);
            result.selection_foreground = palette.colorOr("list.activeSelectionForeground", result.selection_foreground);
            result.badge_background = palette.colorOr("badge.background", result.badge_background);
            result.badge_foreground = palette.colorOr("badge.foreground", result.badge_foreground);
            result.input_background = palette.colorOr("input.background", result.input_background);
            result.input_foreground = palette.colorOr("input.foreground", result.input_foreground);
            result.input_placeholder = palette.colorOr("input.placeholderForeground", result.input_placeholder);
            result.input_border = palette.colorOr("input.border", result.input_border);
            result.focus_border = palette.colorOr("focusBorder", result.focus_border);
            result.icon_foreground = palette.colorOr("icon.foreground", result.icon_foreground);
            result.toolbar_hover = palette.colorOr("toolbar.hoverBackground", result.toolbar_hover);
            result.button_background = palette.colorOr("button.background", result.button_background);
            result.button_foreground = palette.colorOr("button.foreground", result.button_foreground);
            result.button_separator = palette.colorOr("button.separator", result.button_separator);
            result.button_hover = palette.colorOr("button.hoverBackground", result.button_hover);
            result.button_secondary = palette.colorOr("button.secondaryBackground", result.button_secondary);
            result.disabled_foreground = palette.colorOr("disabledForeground", result.disabled_foreground);
        }
        return result;
    }

    /// Terminal view options. The side bar part owns the title area, so the
    /// workbench renders the content without the view's own section header.
    pub const RenderOptions = struct {
        show_header: bool = true,
        cell_borders: bool = false,
        border_capabilities: ui.cell_border.Capabilities = .{},
    };

    pub fn render(self: *SCMViewPane, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, options: RenderOptions) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        self.ensureInputConfigured();
        self.syncInput();
        const palette = self.colors();
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), .{
            .fg = ui.cell.packColor(palette.foreground),
            .bg = ui.cell.packColor(palette.background),
        });

        self.header_rows = if (options.show_header) 2 else 0;
        if (options.show_header) renderHeader(grid, x, y, width, height, focused, palette);

        self.input_rows = self.inputRowCount();
        const list_top = y + self.header_rows;
        const list_height = height -| self.header_rows;
        const total_rows = self.contentRowCount();
        const list_width = list_scrollbar.contentWidth(width, list_height, total_rows);
        const resized = self.visible_rows != list_height;
        self.visible_rows = list_height;
        self.list_focused = focused and !self.input_focused;
        self.clampScroll();
        if (resized) self.ensureSelectionVisible();

        const visible_input_rows = @min(list_height, self.input_rows -| self.scroll);
        if (visible_input_rows > 0) {
            try self.renderInput(grid, x, list_top, list_width, self.scroll, visible_input_rows, palette, options);
        }
        const guide = if (self.config.indent_guides != .none and self.list_focused) self.activeGuide() else null;
        const show_inactive = self.config.indent_guides == .always or
            (self.config.indent_guides == .on_hover and self.list_hovered);
        var screen_row = visible_input_rows;
        while (screen_row < list_height) : (screen_row += 1) {
            const row_index = self.resourceRowAt(self.scroll + screen_row) orelse break;
            self.renderRow(grid, row_index, x, list_top + screen_row, list_width, focused, palette);
            if (guide != null or show_inactive) {
                self.renderGuides(grid, row_index, x, list_top + screen_row, list_width, self.rowBackground(row_index, focused, palette), guide, show_inactive, options);
            }
        }

        list_scrollbar.paint(grid, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(list_top),
            .w = @floatFromInt(width),
            .h = @floatFromInt(list_height),
        }, total_rows, @floatFromInt(self.scroll));
    }

    const ActiveGuide = struct { depth: usize, first: usize, end: usize };

    fn activeGuide(self: *const SCMViewPane) ?ActiveGuide {
        var parent = self.selectedRowIndex() orelse return null;
        const rows = self.rows.items;
        if (parent + 1 >= rows.len or rows[parent + 1].depth <= rows[parent].depth) {
            const depth = rows[parent].depth;
            if (depth == 0) return null;
            while (parent > 0 and rows[parent].depth >= depth) parent -= 1;
        }
        const depth = rows[parent].depth;
        var end = parent + 1;
        while (end < rows.len and rows[end].depth > depth) : (end += 1) {}
        return .{ .depth = depth, .first = parent + 1, .end = end };
    }

    fn renderGuides(
        self: *const SCMViewPane,
        grid: *ui.CellGrid,
        index: usize,
        x: usize,
        y: usize,
        width: usize,
        background: ui.Color,
        guide: ?ActiveGuide,
        show_inactive: bool,
        options: RenderOptions,
    ) void {
        for (0..self.rows.items[index].depth) |depth| {
            const col = 1 + depth * 2;
            if (col >= width) break;
            const active = if (guide) |g| g.depth == depth and index >= g.first and index < g.end else false;
            if (!active and !show_inactive) continue;
            const fallback = if (active) ui.Color{ .r = 88, .g = 88, .b = 88 } else ui.Color{ .r = 57, .g = 57, .b = 57 };
            const token = if (active) "tree.indentGuidesStroke" else "tree.inactiveIndentGuidesStroke";
            const color = if (self.theme) |palette| palette.colorOr(token, fallback) else fallback;
            if (options.cell_borders and options.border_capabilities.has(.center)) {
                grid.addBorder(x + col, y, ui.cell_border.Segment.vertical, .{ .width = 16, .color = .{ .rgb = color } });
            } else {
                grid.putCodepoint(x + col, y, '│', 1, .{ .fg = ui.cell.packColor(color), .bg = ui.cell.packColor(background) });
            }
        }
    }

    fn renderHeader(
        grid: *ui.CellGrid,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        focused: bool,
        palette: Colors,
    ) void {
        const style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(palette.foreground),
            .bg = ui.cell.packColor(palette.background),
            .attrs = if (focused) ui.cell.Attr.bold else 0,
        };
        drawText(grid, x + 1, y, width -| 2, "SOURCE CONTROL", style);
        if (width > 0 and height > 1) {
            var divider: usize = 0;
            while (divider < width) : (divider += 1) {
                grid.putCodepoint(x + divider, y + 1, '\u{2500}', 1, .{
                    .fg = ui.cell.packColor(palette.dim),
                    .bg = ui.cell.packColor(palette.background),
                });
            }
        }
    }

    /// The input and Git action button use the same horizontal inset.
    fn renderInput(
        self: *SCMViewPane,
        grid: *ui.CellGrid,
        x: usize,
        y: usize,
        width: usize,
        first_row: usize,
        rows: usize,
        palette: Colors,
        options: RenderOptions,
    ) !void {
        const control_width = width -| (css.gutter + css.right_inset);
        if (control_width == 0) return;
        if (self.input_surface == null) {
            self.input_surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = rows });
            _ = try self.input_surface.?.document().registerSheet(css.sheet);
        }
        const surface = &self.input_surface.?;
        try surface.resize(width, rows);
        surface.setCellBorders(options.cell_borders);
        surface.border_capabilities = options.border_capabilities;
        const doc = surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
            .background = palette.background,
        });

        if (first_row == 0 and self.inputVisible()) {
            const editor = try doc.createElement(.div);
            try editor.addClass(css.Class.scm_editor);
            editor.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = css.gutter },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(control_width) },
                .background = palette.input_background,
                .border = if (options.cell_borders) ui.EdgeDecl.all(1) else null,
                .border_color = if (self.input_focused) palette.focus_border else palette.input_border,
            });
            self.input_box.color = palette.input_foreground;
            self.input_box.placeholder_color = palette.input_placeholder;
            self.input_box.selection_background = palette.active_selection;
            self.input_box.selection_foreground = palette.selection_foreground;
            self.input_box.focused = self.input_focused;
            const holder = try doc.createElement(.div);
            holder.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 1 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(control_width -| 2) },
                .height = .{ .cells = 1 },
            });
            const node = try self.input_box.build(doc, control_width -| 2);
            _ = try holder.appendChild(node);
            _ = try editor.appendChild(holder);
            _ = try root.appendChild(editor);
        }

        const button_row = self.actionButtonRow();
        if (self.showActionButton() and button_row >= first_row and button_row - first_row < rows) {
            const branch_action = self.activeBranchAction();
            const enabled = branch_action != null or self.canCommit();
            const background = if (enabled) palette.button_background else palette.button_secondary;
            var label_buffer: [96]u8 = undefined;
            const label = if (branch_action) |action| switch (action) {
                .publish => "⇧ Publish Branch",
                .sync => |counts| std.fmt.bufPrint(&label_buffer, "↻ Sync Changes {d}↓ {d}↑", .{ counts.behind, counts.ahead }) catch "↻ Sync Changes",
            } else "✓ Commit";
            const split = try doc.createElement(.div);
            try split.addClass(css.Class.button_container);
            split.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = css.gutter },
                .top = .{ .cells = @floatFromInt(button_row - first_row) },
                .width = .{ .cells = @floatFromInt(control_width) },
                .background = background,
                .color = if (enabled) palette.button_foreground else palette.disabled_foreground,
                .border = if (options.cell_borders) ui.EdgeDecl.all(1) else null,
                .border_color = background,
            });
            _ = try root.appendChild(split);
            const primary = try doc.createElement(.span);
            try primary.addClass(css.Class.primary_button);
            primary.setStyle(.{
                .pointer = if (enabled) .pointer else .default,
                .background = if (enabled and self.hovered_input_action == .commit) palette.button_hover else null,
            });
            _ = try primary.appendText(label);
            _ = try split.appendChild(primary);

            if (self.showCommitDropdown(control_width)) {
                const dropdown = try doc.createElement(.span);
                try dropdown.addClass(css.Class.dropdown_button);
                dropdown.setStyle(.{
                    .pointer = .pointer,
                    .background = if (self.hovered_input_action == .dropdown) palette.button_hover else null,
                });
                const divider = try doc.createElement(.span);
                divider.setStyle(.{ .position = .absolute, .left = .{ .cells = 0 }, .color = palette.button_separator });
                _ = try divider.appendText("│");
                _ = try dropdown.appendChild(divider);
                _ = try dropdown.appendText("⌄");
                _ = try split.appendChild(dropdown);
            }
        }
        doc.setRoot(root);
        try surface.paintFrame();
        try grid.blit(surface.grid(), x, y, width, rows);
    }

    fn renderRow(
        self: *SCMViewPane,
        grid: *ui.CellGrid,
        row_index: usize,
        x: usize,
        y: usize,
        width: usize,
        focused: bool,
        palette: Colors,
    ) void {
        const row = self.rows.items[row_index];
        const selected = self.selection != null and self.selection.? == row_index;
        const background = self.rowBackground(row_index, focused, palette);
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, .{
            .bg = ui.cell.packColor(background),
        });

        const active_foreground = if (selected and focused) palette.selection_foreground else palette.foreground;
        const base_fg = if (row.faded) mix(background, active_foreground, 0.7) else active_foreground;
        const dim_fg = if (selected)
            active_foreground
        else if (row.faded)
            mix(background, palette.dim, 0.7)
        else
            palette.dim;
        const text_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(base_fg),
            .bg = ui.cell.packColor(background),
            .attrs = if (row.strike_through) ui.cell.Attr.strikethrough else 0,
        };

        const label_col = x + 3 + row.depth * 2;
        switch (row.kind) {
            .welcome => {
                _ = drawTextEllipsis(grid, x + 1, y, width -| 2, row.label, .{
                    .fg = ui.cell.packColor(palette.dim),
                    .bg = ui.cell.packColor(background),
                });
            },
            .repository => {
                drawTwistie(grid, x, y, row.depth, row.collapsed, background, palette.dim);
                const badge = if (self.showProviderCount(row.count orelse 0)) row.count else null;
                const badge_start = if (badge) |count| countBadgeStart(x, width, count) else null;
                const right = if (badge_start) |start| start -| 1 else x + width -| 2;
                if (label_col < right) {
                    _ = drawTextEllipsis(grid, label_col, y, right - label_col, row.label, .{
                        .fg = ui.cell.packColor(base_fg),
                        .bg = ui.cell.packColor(background),
                        .attrs = ui.cell.Attr.bold,
                    });
                }
                if (badge) |count| drawCountBadge(grid, x, y, width, count, palette);
            },
            .group => {
                drawTwistie(grid, x, y, row.depth, row.collapsed, background, palette.dim);
                const count = row.count orelse 0;
                const badge_start = countBadgeStart(x, width, count) orelse (x + width -| 2);
                if (label_col < badge_start -| 1) {
                    _ = drawTextEllipsis(grid, label_col, y, (badge_start -| 1) - label_col, row.label, text_style);
                }
                drawCountBadge(grid, x, y, width, count, palette);
            },
            .folder => {
                drawTwistie(grid, x, y, row.depth, row.collapsed, background, palette.dim);
                const right = x + width -| 2;
                if (label_col < right) {
                    const icon = file_icon.folder(!row.collapsed);
                    grid.putCodepoint(label_col, y, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = text_style.bg });
                    _ = drawTextEllipsis(grid, label_col + 2, y, right -| (label_col + 2), row.label, text_style);
                }
            },
            .resource => self.renderResourceRow(grid, row_index, x, y, width, background, dim_fg, selected and focused, palette, text_style),
        }
    }

    fn rowBackground(self: *const SCMViewPane, row_index: usize, focused: bool, palette: Colors) ui.Color {
        if (self.selection != null and self.selection.? == row_index) {
            return if (focused) palette.active_selection else palette.inactive_selection;
        }
        if (self.hovered_row != null and self.hovered_row.? == row_index) return palette.hover;
        return palette.background;
    }

    fn renderResourceRow(
        self: *SCMViewPane,
        grid: *ui.CellGrid,
        index: usize,
        x: usize,
        y: usize,
        width: usize,
        background: ui.Color,
        dim_fg: ui.Color,
        active_selection: bool,
        palette: Colors,
        text_style: ui.cell.PaintStyle,
    ) void {
        const row = self.rows.items[index];
        const icon_col = x + 1 + row.depth * 2;
        const label_col = icon_col + 2;
        const badge_col: ?usize = if (self.resourceBadgeColumn(row, width)) |col| x + col else null;
        const actions = self.inlineActions(index, width);
        const right = x + (if (actions.count != 0) actions.start else self.resourceLabelEnd(row, width));
        if (label_col >= right) return;

        const icon = file_icon.file(row.label);
        grid.putCodepoint(icon_col, y, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = text_style.bg });
        var name_style = text_style;
        if (self.config.decoration_colors and !active_selection) {
            if (row.color) |id| {
                const color = self.decorationColor(id);
                name_style.fg = ui.cell.packColor(if (row.faded) mix(background, color, 0.7) else color);
            }
        }
        const name = drawTextEllipsis(grid, label_col, y, right - label_col, row.label, name_style);
        if (!name.truncated) {
            if (row.description) |description| {
                const description_col = label_col + name.used + 1;
                if (description_col < right) {
                    _ = drawTextEllipsis(grid, description_col, y, right - description_col, description, .{
                        .fg = ui.cell.packColor(dim_fg),
                        .bg = ui.cell.packColor(background),
                        .attrs = if (row.strike_through) ui.cell.Attr.strikethrough else 0,
                    });
                }
            }
        }

        for (actions.items[0..actions.count], 0..) |action, slot| {
            const start = actions.start + slot * css.inline_action_width;
            const hovered = self.hovered_row == index and if (self.hovered_col) |col|
                col >= start and col < start + css.inline_action_width
            else
                false;
            const bg = ui.cell.packColor(if (hovered) palette.toolbar_hover else background);
            if (hovered) grid.fillRect(@floatFromInt(x + start), @floatFromInt(y), css.inline_action_width, 1, .{ .bg = bg });
            grid.putCodepoint(x + start + css.inline_action_width / 2, y, resourceActionGlyph(action), 1, .{
                .fg = ui.cell.packColor(palette.icon_foreground),
                .bg = bg,
            });
        }

        if (badge_col) |column| {
            var color = if (row.color) |id|
                self.decorationColor(id)
            else
                ui.Color{ .r = 226, .g = 192, .b = 141 };
            if (active_selection) {
                color = palette.selection_foreground;
            } else {
                // `.monaco-icon-label::after { opacity: 0.75; }`.
                color = mix(background, color, 0.75);
            }
            if (row.faded) color = mix(background, color, 0.7);
            drawText(grid, column, y, 1, row.letter.?, .{
                .fg = ui.cell.packColor(color),
                .bg = ui.cell.packColor(background),
            });
        }
    }

    fn resourceBadgeColumn(self: *const SCMViewPane, row: Row, width: usize) ?usize {
        return if (self.config.decoration_badges and row.letter != null and width >= 5) width - 3 else null;
    }

    fn resourceLabelEnd(self: *const SCMViewPane, row: Row, width: usize) usize {
        return if (self.resourceBadgeColumn(row, width)) |column| column - 1 else width -| 2;
    }

    fn drawTwistie(
        grid: *ui.CellGrid,
        x: usize,
        y: usize,
        depth: usize,
        collapsed: bool,
        background: ui.Color,
        color: ui.Color,
    ) void {
        const column = x + 1 + depth * 2;
        const glyph = if (collapsed) "›" else "⌄";
        drawText(grid, column, y, 1, glyph, .{
            .fg = ui.cell.packColor(color),
            .bg = ui.cell.packColor(background),
        });
    }

    /// Resolves a resource decoration color id. The git extension contributes
    /// the `gitDecoration.*` defaults; the terminal theme bridge only sees the
    /// active color theme, so it carries the upstream dark defaults as its
    /// fallbacks instead of turning every badge into the modified color.
    fn decorationColor(self: *const SCMViewPane, id: []const u8) ui.Color {
        const fallback = if (std.mem.eql(u8, id, "gitDecoration.untrackedResourceForeground"))
            ui.Color{ .r = 115, .g = 201, .b = 145 }
        else if (std.mem.eql(u8, id, "gitDecoration.addedResourceForeground"))
            ui.Color{ .r = 129, .g = 184, .b = 139 }
        else if (std.mem.eql(u8, id, "gitDecoration.deletedResourceForeground") or
            std.mem.eql(u8, id, "gitDecoration.stageDeletedResourceForeground"))
            ui.Color{ .r = 199, .g = 78, .b = 57 }
        else if (std.mem.eql(u8, id, "gitDecoration.renamedResourceForeground"))
            ui.Color{ .r = 115, .g = 201, .b = 145 }
        else if (std.mem.eql(u8, id, "gitDecoration.conflictingResourceForeground"))
            ui.Color{ .r = 228, .g = 103, .b = 107 }
        else if (std.mem.eql(u8, id, "gitDecoration.ignoredResourceForeground"))
            ui.Color{ .r = 140, .g = 140, .b = 140 }
        else if (std.mem.eql(u8, id, "gitDecoration.submoduleResourceForeground"))
            ui.Color{ .r = 141, .g = 185, .b = 226 }
        else
            ui.Color{ .r = 226, .g = 192, .b = 141 };
        if (self.theme) |palette| return palette.colorOr(id, fallback);
        return fallback;
    }

    fn showProviderCount(self: *const SCMViewPane, count: usize) bool {
        return switch (self.config.provider_count_badge) {
            .hidden => false,
            .auto => count > 0,
            .visible => true,
        };
    }

    fn drawCountBadge(grid: *ui.CellGrid, x: usize, y: usize, width: usize, count: usize, palette: Colors) void {
        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch return;
        const badge_width = text.len + 2;
        if (width < badge_width + 2) return;
        const start = x + width - 2 - badge_width;
        grid.fillRect(@floatFromInt(start), @floatFromInt(y), @floatFromInt(badge_width), 1, .{
            .bg = ui.cell.packColor(palette.badge_background),
        });
        drawText(grid, start + 1, y, text.len, text, .{
            .fg = ui.cell.packColor(palette.badge_foreground),
            .bg = ui.cell.packColor(palette.badge_background),
        });
    }
};

fn countBadgeStart(x: usize, width: usize, count: usize) ?usize {
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch return null;
    const badge_width = text.len + 2;
    if (width < badge_width + 2) return null;
    return x + width - 2 - badge_width;
}

fn freeMapKeys(map: *std.StringHashMap(void), allocator: Allocator) void {
    var iterator = map.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
}

fn setMapOwned(map: *std.StringHashMap(void), allocator: Allocator, key: []const u8, present: bool) !void {
    if (present) {
        if (map.contains(key)) return;
        const owned = try allocator.dupe(u8, key);
        errdefer allocator.free(owned);
        try map.put(owned, {});
    } else {
        if (map.fetchRemove(key)) |entry| allocator.free(entry.key);
    }
}

fn resolveResource(row: *const Row) ?*ISCMResource {
    const group = row.group orelse return null;
    const resources = group.resources();
    for (resources) |*resource| {
        if (std.mem.eql(u8, resource.source_path, row.path)) return @constCast(resource);
    }
    return null;
}

fn repositoryResourceCount(repository: *const ISCMRepository) usize {
    if (repository.provider.count) |count| return count;
    var total: usize = 0;
    for (repository.provider.groups()) |group| total += group.resources().len;
    return total;
}

fn relativeLabel(path: []const u8, root: ?[]const u8) []const u8 {
    const base = root orelse return path;
    const trimmed = std.mem.trimEnd(u8, base, "/\\");
    if (trimmed.len == 0) return path;
    if (path.len <= trimmed.len + 1) return path;
    if (!std.mem.startsWith(u8, path, trimmed)) return path;
    if (path[trimmed.len] != '/' and path[trimmed.len] != '\\') return path;
    return path[trimmed.len + 1 ..];
}

fn mix(background: ui.Color, foreground: ui.Color, alpha: f32) ui.Color {
    return .{
        .r = mixChannel(background.r, foreground.r, alpha),
        .g = mixChannel(background.g, foreground.g, alpha),
        .b = mixChannel(background.b, foreground.b, alpha),
    };
}

fn mixChannel(background: u8, foreground: u8, alpha: f32) u8 {
    const blended = @as(f32, @floatFromInt(foreground)) * alpha +
        @as(f32, @floatFromInt(background)) * (1 - alpha);
    return @intFromFloat(@round(std.math.clamp(blended, 0, 255)));
}

const DrawnText = struct { used: usize, truncated: bool };

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        width += ui.dom.defaultMeasureWidth(decoded.cp);
        index += decoded.len;
    }
    return width;
}

fn drawTextEllipsis(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) DrawnText {
    if (width == 0 or text.len == 0) return .{ .used = 0, .truncated = text.len > 0 };
    var column: usize = 0;
    var index: usize = 0;
    var last_start: usize = 0;
    var last_width: usize = 1;
    while (index < text.len) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0) {
            index += decoded.len;
            continue;
        }
        if (column + cell_width > width) break;
        last_start = column;
        last_width = cell_width;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
        index += decoded.len;
    }
    if (index >= text.len) return .{ .used = column, .truncated = false };
    if (column > 0) {
        if (last_width > 1) {
            var cell: usize = 0;
            while (cell < last_width and last_start + cell < width) : (cell += 1) {
                grid.putSpace(x + last_start + cell, y, style);
            }
            grid.putCodepoint(x + last_start, y, '\u{2026}', 1, style);
            return .{ .used = last_start + 1, .truncated = true };
        }
        grid.putCodepoint(x + column - 1, y, '\u{2026}', 1, style);
        return .{ .used = column, .truncated = true };
    }
    grid.putCodepoint(x, y, '\u{2026}', 1, style);
    return .{ .used = 1, .truncated = true };
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) void {
    if (width == 0) return;
    var column: usize = 0;
    var index: usize = 0;
    while (index < text.len and column < width) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0) {
            index += decoded.len;
            continue;
        }
        if (column + cell_width > width) break;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
        index += decoded.len;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const scm_service_mod = @import("../common/scmService.zig");

const test_root = "/repo";

const ResourceSpec = struct {
    relative: []const u8,
    letter: u8 = 0,
    tooltip: []const u8 = "",
    color: ?[]const u8 = null,
    strike_through: bool = false,
    faded: bool = false,
};

const GroupSpec = struct {
    id: []const u8,
    label: []const u8,
    hide_when_empty: bool = false,
    resources: []const ResourceSpec = &.{},
};

const TestHost = struct {
    opened: usize = 0,
    last_action: ?ResourceAction = null,
    refreshed: usize = 0,
    focused: usize = 0,
    committed: usize = 0,
    statuses: usize = 0,
    commit_should_fail: bool = false,
    last_opened: ?[]const u8 = null,
    commit_buf: [128]u8 = undefined,
    last_commit: ?[]const u8 = null,
    status_buf: [128]u8 = undefined,
    last_status: ?[]const u8 = null,

    fn openChange(context: *anyopaque, resource: *ISCMResource) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened += 1;
        self.last_opened = resource.source_path;
    }

    fn runAction(context: *anyopaque, action: ResourceAction, _: *ISCMResource) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.last_action = action;
    }

    fn refresh(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.refreshed += 1;
    }

    fn focusEditor(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.focused += 1;
    }

    fn commit(context: *anyopaque, message: []const u8, _: CommitAction) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        const length = @min(message.len, self.commit_buf.len);
        @memcpy(self.commit_buf[0..length], message[0..length]);
        self.last_commit = self.commit_buf[0..length];
        if (self.commit_should_fail) return error.CommitFailed;
        self.committed += 1;
    }

    fn status(context: *anyopaque, message: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        const length = @min(message.len, self.status_buf.len);
        @memcpy(self.status_buf[0..length], message[0..length]);
        self.last_status = self.status_buf[0..length];
        self.statuses += 1;
    }
};

const TestGroup = struct {
    allocator: Allocator,
    base: scm.ISCMResourceGroup = undefined,
    provider: *TestProvider = undefined,
    resources: std.array_list.Managed(scm.ISCMResource),
    letters: [16]u8 = @splat(0),
    resources_changed: Emitter(void) = undefined,
    changed: Emitter(void) = undefined,

    fn init(self: *TestGroup, allocator: Allocator, provider: *TestProvider, spec: GroupSpec) !void {
        self.allocator = allocator;
        self.provider = provider;
        self.resources = std.array_list.Managed(scm.ISCMResource).init(allocator);
        self.resources_changed = Emitter(void).init(allocator);
        self.changed = Emitter(void).init(allocator);
        errdefer {
            for (self.resources.items) |resource| allocator.free(resource.source_path);
            self.resources.deinit();
        }
        for (spec.resources, 0..) |resource_spec, index| {
            const absolute = try std.fs.path.join(allocator, &.{ test_root, resource_spec.relative });
            errdefer allocator.free(absolute);
            const has_letter = resource_spec.letter != 0 and index < self.letters.len;
            if (has_letter) self.letters[index] = resource_spec.letter;
            try self.resources.append(.{
                .context = self,
                .resource_group = &self.base,
                .source_path = absolute,
                .decorations = .{
                    .tooltip = if (resource_spec.tooltip.len > 0) resource_spec.tooltip else null,
                    .strike_through = resource_spec.strike_through,
                    .faded = resource_spec.faded,
                    .letter = if (has_letter) self.letters[index..][0..1] else null,
                    .color = resource_spec.color,
                },
            });
        }
        self.base = .{
            .context = self,
            .id = spec.id,
            .provider = &provider.base,
            .label = spec.label,
            .hide_when_empty = spec.hide_when_empty,
            .resources_fn = resourcesThunk,
            .on_did_change_resources = &self.resources_changed,
            .on_did_change = &self.changed,
        };
    }

    fn deinit(self: *TestGroup) void {
        for (self.resources.items) |resource| self.allocator.free(resource.source_path);
        self.resources.deinit();
        self.resources_changed.deinit();
        self.changed.deinit();
    }

    fn interfaceResources(context: *anyopaque) []const scm.ISCMResource {
        const self: *TestGroup = @ptrCast(@alignCast(context));
        return self.resources.items;
    }

    fn resourcesThunk(context: *anyopaque) []const scm.ISCMResource {
        return interfaceResources(context);
    }
};

const TestProvider = struct {
    allocator: Allocator,
    base: scm.ISCMProvider = undefined,
    groups: [4]TestGroup = undefined,
    group_slice: [4]*scm.ISCMResourceGroup = undefined,
    group_count: usize = 0,
    groups_changed: Emitter(void) = undefined,
    resources_changed: Emitter(void) = undefined,

    fn init(self: *TestProvider, allocator: Allocator, specs: []const GroupSpec) !void {
        self.allocator = allocator;
        self.group_count = specs.len;
        self.groups_changed = Emitter(void).init(allocator);
        self.resources_changed = Emitter(void).init(allocator);
        errdefer {
            self.groups_changed.deinit();
            self.resources_changed.deinit();
        }
        self.base = .{
            .context = self,
            .id = "git",
            .provider_id = "git",
            .label = "Git",
            .name = "repo",
            .root_path = test_root,
            .detail = "main",
            .groups_fn = groupsThunk,
            .on_did_change_resource_groups = &self.groups_changed,
            .on_did_change_resources = &self.resources_changed,
        };
        errdefer {
            for (self.groups[0..self.group_count]) |*group| group.deinit();
        }
        for (specs, 0..) |spec, index| {
            try self.groups[index].init(allocator, self, spec);
            self.group_slice[index] = &self.groups[index].base;
        }
    }

    fn deinit(self: *TestProvider) void {
        for (self.groups[0..self.group_count]) |*group| group.deinit();
        self.groups_changed.deinit();
        self.resources_changed.deinit();
    }

    fn groupsThunk(context: *anyopaque) []const *scm.ISCMResourceGroup {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return self.group_slice[0..self.group_count];
    }
};

const Fixture = struct {
    allocator: Allocator,
    service: scm_service_mod.SCMService = undefined,
    provider: TestProvider = undefined,
    host: TestHost = .{},
    interface: ISCMService = undefined,
    view: SCMViewPane = undefined,

    fn init(self: *Fixture, allocator: Allocator, specs: []const GroupSpec, config: Config) !void {
        self.allocator = allocator;
        self.host = .{};
        self.service = scm_service_mod.SCMService.init(allocator);
        errdefer self.service.deinit();
        try self.provider.init(allocator, specs);
        errdefer self.provider.deinit();
        _ = try self.service.registerSCMProvider(&self.provider.base);
        const repositories = self.service.interfaces.items;
        if (repositories.len > 0) {
            var input = repositories[0].input;
            input.setVisible(false);
        }
        self.interface = self.service.interface();
        self.view = SCMViewPane.init(allocator, &self.interface, .{
            .context = &self.host,
            .open_change = TestHost.openChange,
            .refresh = TestHost.refresh,
            .focus_editor = TestHost.focusEditor,
            .commit = TestHost.commit,
            .status = TestHost.status,
        });
        self.view.setConfig(config);
    }

    fn deinit(self: *Fixture) void {
        self.view.deinit();
        self.service.deinit();
        self.provider.deinit();
        self.* = undefined;
    }
};

fn rowText(allocator: Allocator, grid: *ui.CellGrid, row: usize) ![]u8 {
    return grid.rowText(allocator, row);
}

fn resourceLabels(allocator: Allocator, view: *SCMViewPane) ![]const []const u8 {
    var labels = std.array_list.Managed([]const u8).init(allocator);
    errdefer labels.deinit();
    for (view.rows.items) |row| {
        if (row.kind == .resource) try labels.append(row.label);
    }
    return labels.toOwnedSlice();
}

fn clickAt(view: *SCMViewPane, rect: ui.Rect, x: usize, y: usize) !bool {
    var event = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    return view.handleMouse(&event, rect);
}

fn moveAt(view: *SCMViewPane, rect: ui.Rect, x: usize, y: usize) !bool {
    var event = ui.MouseEvent{ .kind = .move, .x = x, .y = y, .button = .none };
    return view.handleMouse(&event, rect);
}

test "scmView: hover reveals ancestor guides and resource actions" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "long-file-name-for-test.js", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "other.js", .letter = 'U', .tooltip = "Untracked" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;
    view.host.resource_action = TestHost.runAction;
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 5 };
    var grid = try ui.CellGrid.init(allocator, 30, 5);
    defer grid.deinit();
    try view.render(&grid, rect, false, .{ .show_header = false });
    try testing.expect(grid.cluster[grid.index(1, 1)] != '│');
    try testing.expect(view.inlineActions(1, 30).count == 0);

    try testing.expect(try moveAt(view, rect, 10, 1));
    try view.render(&grid, rect, false, .{ .show_header = false });
    try testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(1, 1)]);
    try testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(1, 2)]);
    const actions = view.inlineActions(1, 30);
    try testing.expectEqual(@as(usize, 3), actions.count);
    try testing.expectEqual(@as(u32, '+'), grid.cluster[grid.index(actions.start + 2 * css.inline_action_width + 1, 1)]);
    try testing.expectEqual(@as(u32, 'M'), grid.cluster[grid.index(27, 1)]);
    try testing.expect(try clickAt(view, rect, actions.start + 2 * css.inline_action_width, 1));
    try testing.expectEqual(ResourceAction.stage, fixture.host.last_action.?);
    try testing.expectEqual(@as(usize, 0), fixture.host.opened);

    view.config.indent_guides = .none;
    try view.render(&grid, rect, false, .{ .show_header = false });
    try testing.expect(grid.cluster[grid.index(1, 1)] != '│');
}

test "scmView: welcome text without providers" {
    const allocator = testing.allocator;
    var service = scm_service_mod.SCMService.init(allocator);
    defer service.deinit();
    var interface = service.interface();
    var host = TestHost{};
    var view = SCMViewPane.init(allocator, &interface, .{
        .context = &host,
        .open_change = TestHost.openChange,
        .refresh = TestHost.refresh,
        .focus_editor = TestHost.focusEditor,
        .commit = TestHost.commit,
        .status = TestHost.status,
    });
    defer view.deinit();
    view.refresh();
    try testing.expectEqual(@as(usize, 1), view.rows.items.len);
    try testing.expectEqual(RowKind.welcome, view.rows.items[0].kind);

    var grid = try ui.CellGrid.init(allocator, 30, 6);
    defer grid.deinit();
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 30, .h = 6 }, true, .{ .show_header = false });
    const text = try rowText(allocator, &grid, 0);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "No source control providers") != null);
}

test "scmView: list rows, labels, badges and file decorations" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "index", .label = "Staged Changes", .hide_when_empty = true, .resources = &.{
            .{ .relative = "src/a.zig", .letter = 'M', .tooltip = "Index Modified", .color = "gitDecoration.stageModifiedResourceForeground" },
        } },
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "b.zig", .letter = 'U', .tooltip = "Untracked", .color = "gitDecoration.untrackedResourceForeground" },
            .{ .relative = "src/a.zig", .letter = 'M', .tooltip = "Modified", .color = "gitDecoration.modifiedResourceForeground" },
            .{ .relative = "src/gone.zig", .letter = 'D', .tooltip = "Deleted", .color = "gitDecoration.deletedResourceForeground", .strike_through = true },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;

    // A single repository hides the repository header (upstream
    // `scm.alwaysShowRepositories` defaults to false). Groups sit at depth 0
    // and resources below them, sorted by path.
    try testing.expectEqual(@as(usize, 6), view.rows.items.len);
    try testing.expectEqual(RowKind.group, view.rows.items[0].kind);
    try testing.expectEqualStrings("Staged Changes", view.rows.items[0].label);
    try testing.expectEqual(@as(usize, 1), view.rows.items[0].count.?);
    try testing.expectEqual(@as(usize, 0), view.rows.items[0].depth);
    try testing.expectEqual(RowKind.resource, view.rows.items[1].kind);
    try testing.expectEqualStrings("a.zig", view.rows.items[1].label);
    try testing.expectEqualStrings("src", view.rows.items[1].description.?);
    try testing.expectEqual(@as(usize, 1), view.rows.items[1].depth);
    try testing.expectEqualStrings("Changes", view.rows.items[2].label);
    try testing.expectEqual(@as(usize, 3), view.rows.items[2].count.?);
    try testing.expectEqualStrings("b.zig", view.rows.items[3].label);
    try testing.expectEqualStrings("a.zig", view.rows.items[4].label);
    try testing.expectEqualStrings("gone.zig", view.rows.items[5].label);
    try testing.expectEqualStrings("src", view.rows.items[5].description.?);
    try testing.expect(view.rows.items[5].strike_through);
    try testing.expectEqual(@as(usize, 4), view.resourceCount());
    try testing.expect(view.selection == null);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });

    const group_row = try rowText(allocator, &grid, 0);
    defer allocator.free(group_row);
    try testing.expect(std.mem.indexOf(u8, group_row, "⌄ Staged Changes") != null);
    // Count badge: one digit, two cells of padding, two cells of right margin.
    const badge_start = 40 - 2 - 3;
    try testing.expectEqual(@as(u32, '1'), grid.cluster[badge_start + 1]);

    const resource_row = try rowText(allocator, &grid, 1);
    defer allocator.free(resource_row);
    try testing.expect(std.mem.indexOf(u8, resource_row, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, resource_row, "src") != null);
    try testing.expectEqual(@as(u32, 'M'), grid.cluster[40 + (40 - 3)]);

    // Deleted resources are struck through; untracked files use the upstream
    // `U` letter instead of porcelain's `?`.
    try testing.expect((grid.attrs[5 * 40 + 5] & ui.cell.Attr.strikethrough) != 0);
    try testing.expectEqual(@as(u32, 'U'), grid.cluster[3 * 40 + (40 - 3)]);
    // The decoration colors differ per Git status (modified, untracked,
    // deleted) instead of all falling back to the modified color.
    const modified_badge = grid.fg[1 * 40 + (40 - 3)];
    const untracked_badge = grid.fg[3 * 40 + (40 - 3)];
    const deleted_badge = grid.fg[5 * 40 + (40 - 3)];
    try testing.expect(modified_badge != untracked_badge);
    try testing.expect(modified_badge != deleted_badge);
    try testing.expect(untracked_badge != deleted_badge);

    // Keyboard: Down selects the first row, Enter opens a resource.
    const down = ui.KeyEvent{ .key = .down };
    try testing.expect(try view.handleKey(@constCast(&down)));
    try testing.expectEqual(@as(usize, 0), view.selection.?);
    try testing.expect(try view.handleKey(@constCast(&down)));
    try testing.expectEqual(@as(usize, 1), view.selection.?);
    const enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(try view.handleKey(@constCast(&enter)));
    try testing.expectEqual(@as(usize, 1), fixture.host.opened);
    const expected_a = try std.fs.path.join(allocator, &.{ test_root, "src/a.zig" });
    defer allocator.free(expected_a);
    try testing.expectEqualStrings(expected_a, fixture.host.last_opened.?);

    // Left on a resource selects its parent group; Left again collapses it;
    // Right expands it, matching the tree widget.
    const left = ui.KeyEvent{ .key = .left };
    try testing.expect(try view.handleKey(@constCast(&left)));
    try testing.expectEqual(@as(?usize, 0), view.selection);
    try testing.expectEqual(@as(usize, 4), view.resourceCount());
    try testing.expect(try view.handleKey(@constCast(&left)));
    try testing.expectEqual(@as(usize, 3), view.resourceCount());
    const right = ui.KeyEvent{ .key = .right };
    try testing.expect(try view.handleKey(@constCast(&right)));
    try testing.expectEqual(@as(usize, 4), view.resourceCount());

    // Clicking a group toggles it; clicking a resource selects and opens it.
    try testing.expect(try clickAt(view, rect, 4, 2));
    try testing.expectEqual(@as(usize, 1), view.resourceCount());
    try testing.expect(try clickAt(view, rect, 4, 2));
    try testing.expectEqual(@as(usize, 4), view.resourceCount());
    try testing.expect(try clickAt(view, rect, 4, 4));
    try testing.expectEqual(@as(usize, 2), fixture.host.opened);
    try testing.expectEqualStrings(expected_a, fixture.host.last_opened.?);
}

test "scmView: list sort keys follow scm.defaultViewSortKey" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "b.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "dir/a.zig", .letter = 'U', .tooltip = "Untracked" },
            .{ .relative = "c.zig", .letter = 'D', .tooltip = "Deleted" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;

    var labels = try resourceLabels(allocator, view);
    defer allocator.free(labels);
    try testing.expectEqualStrings("b.zig", labels[0]);
    try testing.expectEqualStrings("c.zig", labels[1]);
    try testing.expectEqualStrings("a.zig", labels[2]);

    allocator.free(labels);
    view.setConfig(.{ .default_view_sort_key = .name });
    labels = try resourceLabels(allocator, view);
    try testing.expectEqualStrings("a.zig", labels[0]);
    try testing.expectEqualStrings("b.zig", labels[1]);
    try testing.expectEqualStrings("c.zig", labels[2]);

    allocator.free(labels);
    view.setConfig(.{ .default_view_sort_key = .status });
    labels = try resourceLabels(allocator, view);
    try testing.expectEqualStrings("c.zig", labels[0]);
    try testing.expectEqualStrings("b.zig", labels[1]);
    try testing.expectEqualStrings("a.zig", labels[2]);

    allocator.free(labels);
    view.setViewSortKey(.path);
    labels = try resourceLabels(allocator, view);
    try testing.expectEqualStrings("b.zig", labels[0]);
    try testing.expectEqualStrings("c.zig", labels[1]);
    try testing.expectEqualStrings("a.zig", labels[2]);
}

test "scmView: tree mode groups folders, compacts chains and sorts folders first" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "b.zig", .letter = 'U', .tooltip = "Untracked" },
            .{ .relative = "lib/core/deep/a.zig", .letter = 'M', .tooltip = "Modified" },
        } },
    }, .{ .default_view_mode = .tree });
    defer fixture.deinit();
    const view = &fixture.view;
    try testing.expectEqual(scm.ViewMode.tree, view.viewMode());

    // Folders sort before files. A top-level folder stays uncompressed (its
    // parent is the resource tree root); the deeper `core/deep` chain is
    // compressed.
    try testing.expectEqual(@as(usize, 5), view.rows.items.len);
    try testing.expectEqual(RowKind.group, view.rows.items[0].kind);
    try testing.expectEqual(RowKind.folder, view.rows.items[1].kind);
    try testing.expectEqualStrings("lib", view.rows.items[1].label);
    try testing.expectEqual(@as(usize, 1), view.rows.items[1].depth);
    try testing.expectEqualStrings("core/deep", view.rows.items[2].label);
    try testing.expectEqual(@as(usize, 2), view.rows.items[2].depth);
    try testing.expectEqualStrings("a.zig", view.rows.items[3].label);
    try testing.expectEqual(@as(usize, 3), view.rows.items[3].depth);
    try testing.expectEqualStrings("b.zig", view.rows.items[4].label);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });
    const folder_row = try rowText(allocator, &grid, 1);
    defer allocator.free(folder_row);
    try testing.expect(std.mem.indexOf(u8, folder_row, "lib") != null);
    try testing.expectEqual(@as(u32, file_icon.folder(true).glyph), grid.cluster[grid.index(5, 1)]);
    const compressed_row = try rowText(allocator, &grid, 2);
    defer allocator.free(compressed_row);
    try testing.expect(std.mem.indexOf(u8, compressed_row, "core/deep") != null);

    // Collapsing the compressed folder keeps its header and hides the file.
    var folder_click = ui.MouseEvent{ .kind = .down, .x = 6, .y = 2, .button = .left };
    try testing.expect(try view.handleMouse(&folder_click, rect));
    try testing.expectEqual(@as(usize, 4), view.rows.items.len);
    try testing.expect(view.rows.items[2].collapsed);
    try testing.expectEqual(@as(usize, 1), view.resourceCount());
    try view.render(&grid, rect, true, .{ .show_header = false });
    const collapsed_row = try rowText(allocator, &grid, 2);
    defer allocator.free(collapsed_row);
    try testing.expect(std.mem.indexOf(u8, collapsed_row, "core/deep") != null);

    // Right expands, Left collapses, matching the tree widget.
    view.selection = 2;
    const right = ui.KeyEvent{ .key = .right };
    try testing.expect(try view.handleKey(@constCast(&right)));
    try testing.expectEqual(@as(usize, 5), view.rows.items.len);
    const left = ui.KeyEvent{ .key = .left };
    try testing.expect(try view.handleKey(@constCast(&left)));
    try testing.expectEqual(@as(usize, 4), view.rows.items.len);

    // Without compact folders each directory is its own row; the deep folder
    // keeps its collapse state.
    view.setConfig(.{ .default_view_mode = .tree, .compact_folders = false });
    try testing.expectEqual(@as(usize, 5), view.rows.items.len);
    try testing.expectEqualStrings("lib", view.rows.items[1].label);
    try testing.expectEqualStrings("core", view.rows.items[2].label);
    try testing.expectEqualStrings("deep", view.rows.items[3].label);
    try testing.expect(view.rows.items[3].collapsed);
}

test "scmView: repository header and provider count badges" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "a.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "b.zig", .letter = 'U', .tooltip = "Untracked" },
        } },
    }, .{ .always_show_repositories = true, .provider_count_badge = .visible });
    defer fixture.deinit();
    const view = &fixture.view;

    try testing.expectEqual(@as(usize, 4), view.rows.items.len);
    try testing.expectEqual(RowKind.repository, view.rows.items[0].kind);
    try testing.expectEqualStrings("repo", view.rows.items[0].label);
    try testing.expectEqual(@as(usize, 2), view.rows.items[0].count.?);
    try testing.expectEqual(RowKind.group, view.rows.items[1].kind);
    try testing.expectEqual(@as(usize, 1), view.rows.items[1].depth);
    try testing.expectEqual(RowKind.resource, view.rows.items[2].kind);
    try testing.expectEqual(@as(usize, 2), view.rows.items[2].depth);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });
    const repository_row = try rowText(allocator, &grid, 0);
    defer allocator.free(repository_row);
    try testing.expect(std.mem.indexOf(u8, repository_row, "repo") != null);
    try testing.expectEqual(@as(u32, '2'), grid.cluster[40 - 2 - 3 + 1]);

    // `hidden` paints no count badge; `auto` paints a non-zero count.
    view.setConfig(.{ .always_show_repositories = true, .provider_count_badge = .hidden });
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(@as(u32, ' '), grid.cluster[40 - 2 - 3 + 1]);
    view.setConfig(.{ .always_show_repositories = true, .provider_count_badge = .auto });
    try testing.expectEqual(@as(usize, 4), view.rows.items.len);
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(@as(u32, '2'), grid.cluster[40 - 2 - 3 + 1]);

    // Collapsing the repository hides its groups.
    try testing.expect(try clickAt(view, rect, 4, 0));
    try testing.expectEqual(@as(usize, 1), view.rows.items.len);
    try testing.expectEqual(@as(usize, 0), view.resourceCount());
}

test "scmView: hover, selection colors, wheel scrolling and paging" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "a.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "b.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "c.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "d.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "e.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "f.zig", .letter = 'M', .tooltip = "Modified" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 4 };

    var grid = try ui.CellGrid.init(allocator, 30, 4);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(@as(usize, 4), view.visible_rows);
    const scrollbar_thumb = ui.cell.packColor(.{ .r = 105, .g = 108, .b = 122 });
    const scrollbar_track = ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 });
    try testing.expectEqual(scrollbar_thumb, grid.bg[grid.index(29, 0)]);
    try testing.expectEqual(scrollbar_track, grid.bg[grid.index(29, 3)]);
    try testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(29, 3)]);

    // Hover paints `list.hoverBackground`; there is no selection yet.
    try testing.expect(try moveAt(view, rect, 3, 2));
    try testing.expectEqual(@as(?usize, 2), view.hovered_row);
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(ui.cell.packColor(.{ .r = 42, .g = 45, .b = 46 }), grid.bg[2 * 30]);

    // Pressing selects the row; focused and unfocused lists use the active and
    // inactive selection colors.
    try testing.expect(try clickAt(view, rect, 3, 2));
    try testing.expectEqual(@as(?usize, 2), view.selection);
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(ui.cell.packColor(.{ .r = 4, .g = 57, .b = 94 }), grid.bg[2 * 30]);
    try view.render(&grid, rect, false, .{ .show_header = false });
    try testing.expectEqual(ui.cell.packColor(.{ .r = 55, .g = 55, .b = 61 }), grid.bg[2 * 30]);

    // Wheel scrolling moves the window without moving the selection, and
    // re-tracks the row under the pointer.
    var wheel = ui.MouseEvent{ .kind = .wheel, .x = 3, .y = 2, .delta_y = 3 };
    try testing.expect(try view.handleMouse(&wheel, rect));
    try testing.expectEqual(@as(usize, 3), view.scroll);
    try testing.expectEqual(@as(?usize, 5), view.hovered_row);
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(@as(?usize, 2), view.selection);
    try testing.expectEqual(scrollbar_track, grid.bg[grid.index(29, 0)]);
    try testing.expectEqual(scrollbar_thumb, grid.bg[grid.index(29, 3)]);
    try testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(29, 0)]);

    // PageDown/PageUp move by the visible row count; Home/End jump.
    const page_down = ui.KeyEvent{ .key = .page_down };
    try testing.expect(try view.handleKey(@constCast(&page_down)));
    try testing.expectEqual(@as(?usize, 6), view.selection);
    const page_up = ui.KeyEvent{ .key = .page_up };
    try testing.expect(try view.handleKey(@constCast(&page_up)));
    try testing.expectEqual(@as(?usize, 2), view.selection);
    const end = ui.KeyEvent{ .key = .end };
    try testing.expect(try view.handleKey(@constCast(&end)));
    try testing.expectEqual(@as(?usize, 6), view.selection);
    const home = ui.KeyEvent{ .key = .home };
    try testing.expect(try view.handleKey(@constCast(&home)));
    try testing.expectEqual(@as(?usize, 0), view.selection);
    try testing.expectEqual(@as(usize, 0), view.scroll);
}

test "scmView: selection survives refresh and the title keeps its primary actions" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "a.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "b.zig", .letter = 'M', .tooltip = "Modified" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;

    view.selection = 2;
    view.refresh();
    try testing.expectEqual(@as(usize, 2), view.selection.?);
    try testing.expectEqualStrings("b.zig", view.rows.items[2].label);

    const actions = view.titleActions();
    try testing.expectEqual(@as(usize, 3), actions.len);
    try testing.expectEqualStrings(COMMIT_ACTION_ID, actions[0].id);
    try testing.expectEqualStrings(REFRESH_ACTION_ID, actions[1].id);
    try testing.expectEqualStrings(CHANGES_MENU_ACTION_ID, actions[2].id);

    // 'r' asks the host to refresh.
    var char_event = ui.KeyEvent{ .key = .{ .char = 'r' } };
    try testing.expect(try view.handleKey(&char_event));
    try testing.expectEqual(@as(usize, 1), fixture.host.refreshed);
}

test "scmView: long and wide labels are clipped with an ellipsis" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "b.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "a-very-long-file-name-that-does-not-fit.zig", .letter = 'M', .tooltip = "Modified" },
            .{ .relative = "文档文档文档文档.zig", .letter = 'U', .tooltip = "Untracked" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;

    var grid = try ui.CellGrid.init(allocator, 20, 6);
    defer grid.deinit();
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 20, .h = 6 }, true, .{ .show_header = false });

    var truncated = false;
    var saw_wide = false;
    var row: usize = 0;
    while (row < 6) : (row += 1) {
        const text = try rowText(allocator, &grid, row);
        defer allocator.free(text);
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        if (std.mem.indexOf(u8, text, "\u{2026}") != null) truncated = true;
        if (std.mem.indexOf(u8, text, "文档") != null) saw_wide = true;
    }
    try testing.expect(truncated);
    try testing.expect(saw_wide);
}

test "scmView: the message and commit rows are part of the scroll range" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "a.txt", .letter = 'M' },
            .{ .relative = "b.txt", .letter = 'M' },
            .{ .relative = "c.txt", .letter = 'M' },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;
    const input = fixture.service.interfaces.items[0].input;
    input.setVisible(true);
    input.setPlaceholder("Message");

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 4 };
    var grid = try ui.CellGrid.init(allocator, 30, 4);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });
    const scrollbar_thumb = ui.cell.packColor(.{ .r = 105, .g = 108, .b = 122 });
    const scrollbar_track = ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 });
    try testing.expectEqual(scrollbar_thumb, grid.bg[grid.index(29, 0)]);
    try testing.expectEqual(scrollbar_track, grid.bg[grid.index(29, 3)]);

    var wheel = ui.MouseEvent{ .kind = .wheel, .x = 5, .y = 0, .delta_y = 1 };
    try testing.expect(try view.handleMouse(&wheel, rect));
    try view.render(&grid, rect, true, .{ .show_header = false });
    const shifted_button = try rowText(allocator, &grid, 1);
    defer allocator.free(shifted_button);
    try testing.expect(std.mem.indexOf(u8, shifted_button, "✓ Commit") != null);
    input.setValue("scroll test", false);
    try testing.expect(try clickAt(view, rect, 8, 1));
    try testing.expectEqual(@as(usize, 1), fixture.host.committed);

    wheel.delta_y = 2;
    try testing.expect(try view.handleMouse(&wheel, rect));
    try view.render(&grid, rect, true, .{ .show_header = false });
    const first_row = try rowText(allocator, &grid, 0);
    defer allocator.free(first_row);
    try testing.expect(std.mem.indexOf(u8, first_row, "Changes") != null);
    try testing.expectEqual(scrollbar_track, grid.bg[grid.index(29, 0)]);
    try testing.expectEqual(scrollbar_thumb, grid.bg[grid.index(29, 3)]);

    var tab = ui.KeyEvent{ .key = .tab };
    try testing.expect(try view.handleKey(&tab));
    try testing.expectEqual(@as(usize, 0), view.scroll);
    try testing.expect(view.input_focused);
}

test "scmView: commit message input and commit button" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{
            .{ .relative = "a.zig", .letter = 'M', .tooltip = "Modified" },
        } },
    }, .{});
    defer fixture.deinit();
    const view = &fixture.view;

    const repositories = fixture.service.interfaces.items;
    var input = repositories[0].input;
    input.setVisible(true);
    input.setPlaceholder("Message (Enter to commit on \"main\")");
    view.refresh();

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 8 };
    var grid = try ui.CellGrid.init(allocator, 40, 8);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{ .show_header = false });

    // The message row shares an inset with the split action button.
    const input_row = try rowText(allocator, &grid, 0);
    defer allocator.free(input_row);
    try testing.expect(std.mem.indexOf(u8, input_row, "Message (Enter to commit on") != null);
    const border_row = try rowText(allocator, &grid, 1);
    defer allocator.free(border_row);
    try testing.expectEqualStrings("", std.mem.trim(u8, border_row, " "));
    const button_row = try rowText(allocator, &grid, 2);
    defer allocator.free(button_row);
    try testing.expect(std.mem.indexOf(u8, button_row, "\u{2713} Commit") != null);
    try testing.expectEqual(RowKind.group, view.rows.items[0].kind);
    try testing.expectEqual(@as(usize, 3), view.input_rows);

    // Clicking the box focuses it and typing edits the SCM input model.
    try testing.expect(try clickAt(view, rect, 6, 0));
    try testing.expect(view.input_focused);
    for ("hello") |ch| {
        var event = ui.KeyEvent{ .key = .{ .char = ch } };
        try testing.expect(try view.handleKey(&event));
    }
    try testing.expectEqualStrings("hello", input.value());
    try testing.expectEqualStrings("hello", view.input_box.getValue());

    // Hovering (and scrolling) the list must not blur the input; its text and
    // focus stay active.
    try testing.expect(try moveAt(view, rect, 6, 3));
    try testing.expect(view.input_focused);
    try testing.expect(view.input_box.focused);
    var typed = ui.KeyEvent{ .key = .{ .char = '!' } };
    try testing.expect(try view.handleKey(&typed));
    try testing.expectEqualStrings("hello!", input.value());

    // Enter commits through the host and clears the input.
    var enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(try view.handleKey(&enter));
    try testing.expectEqual(@as(usize, 1), fixture.host.committed);
    try testing.expectEqualStrings("hello!", fixture.host.last_commit.?);
    try testing.expectEqualStrings("", input.value());
    try testing.expectEqual(@as(usize, 1), fixture.host.refreshed);
    try testing.expect(try clickAt(view, rect, 6, 3));
    try testing.expect(!view.input_focused);

    // The button below the input commits the current model value too.
    input.setValue("second", false);
    view.refresh();
    try testing.expect(try clickAt(view, rect, 6, 2));
    try testing.expectEqual(@as(usize, 2), fixture.host.committed);
    try testing.expectEqualStrings("second", fixture.host.last_commit.?);
    try testing.expectEqualStrings("", input.value());

    // An empty message reports through the host status hint.
    try testing.expect(!view.commitInput());
    try testing.expectEqualStrings("Commit message is required", fixture.host.last_status.?);

    // A failed commit keeps the typed message so it can be retried.
    input.setValue("keep", false);
    view.refresh();
    fixture.host.commit_should_fail = true;
    try testing.expect(!view.commitInput());
    try testing.expectEqualStrings("keep", input.value());

    // `scm.showInputActionButton=false` hides only the button row.
    fixture.host.commit_should_fail = false;
    view.setConfig(.{ .show_input_action_button = false });
    try view.render(&grid, rect, true, .{ .show_header = false });
    try testing.expectEqual(@as(usize, 2), view.input_rows);
    const hidden_button_row = try rowText(allocator, &grid, 2);
    defer allocator.free(hidden_button_row);
    try testing.expect(std.mem.indexOf(u8, hidden_button_row, "Commit") == null);

    // Hiding the input (`git.showCommitInput=false` in the workbench) removes
    // its rows and gives the space back to the list.
    input.setVisible(false);
    view.refresh();
    try view.render(&grid, rect, true, .{ .show_header = false });
    const first_row = try rowText(allocator, &grid, 0);
    defer allocator.free(first_row);
    try testing.expect(std.mem.indexOf(u8, first_row, "Changes") != null);
}

test "scmView: commit without changes reports and does not call the host" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, &.{
        .{ .id = "working", .label = "Changes", .resources = &.{} },
    }, .{});
    defer fixture.deinit();
    const input = fixture.service.interfaces.items[0].input;
    input.setVisible(true);
    input.setValue("message", false);
    fixture.view.refresh();
    try testing.expect(!fixture.view.commitInput());
    try testing.expectEqualStrings("No changes to commit", fixture.host.last_status.?);
    try testing.expectEqual(@as(usize, 0), fixture.host.committed);
    try testing.expectEqualStrings("message", input.value());
}

// Port the upstream ViewMode/SortKey actions here. Their existing terminal
// palette labels, categories and visibility are preserved during extraction;
// the full upstream f1/toggled/precondition metadata is not yet ported.
const viewAction = @import("../../../browser/parts/views/viewPane.zig").viewAction;
pub const view_actions = [_]@import("../../../../platform/actions/common/actions.zig").Action2{
    viewAction(SCMViewPane, .registered, .{ .id = SET_LIST_VIEW_MODE_ACTION_ID, .title = "View as List", .category = "Source Control" }, true, SCMViewPane.setViewMode, .{@as(scm.ViewMode, .list)}),
    viewAction(SCMViewPane, .registered, .{ .id = SET_TREE_VIEW_MODE_ACTION_ID, .title = "View as Tree", .category = "Source Control" }, true, SCMViewPane.setViewMode, .{@as(scm.ViewMode, .tree)}),
    viewAction(SCMViewPane, .registered, .{ .id = SET_SORT_BY_NAME_ACTION_ID, .title = "Sort Changes by Name", .category = "Source Control" }, true, SCMViewPane.setViewSortKey, .{@as(ViewSortKey, .name)}),
    viewAction(SCMViewPane, .registered, .{ .id = SET_SORT_BY_PATH_ACTION_ID, .title = "Sort Changes by Path", .category = "Source Control" }, true, SCMViewPane.setViewSortKey, .{@as(ViewSortKey, .path)}),
    viewAction(SCMViewPane, .registered, .{ .id = SET_SORT_BY_STATUS_ACTION_ID, .title = "Sort Changes by Status", .category = "Source Control" }, true, SCMViewPane.setViewSortKey, .{@as(ViewSortKey, .status)}),
};

pub const changes_menu_action = @import("../../../browser/parts/sidebar/sidebarPart.zig").viewMenuAction(CHANGES_MENU_ACTION_ID, "Changes More Actions", "changes");
