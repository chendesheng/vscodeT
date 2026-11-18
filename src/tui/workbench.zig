//! The multi-file terminal workbench: the TUI adapter over the ported
//! workbench editor part, group views, panes and split grid.
//!
//! The portable counterparts are ported to their upstream paths:
//! `editorPart.zig` (group registry, grid, branch demotion and sash math),
//! `editorGroupView.zig` (tab-to-model mapping, active tab, pane activation)
//! and `editorPanes.zig` (active pane and page position), plus
//! `src/vs/base/browser/ui/grid/grid.zig` and `editorDropTarget.zig`. This file
//! keeps only the terminal shell: rendering, input routing, the sidebar/search
//! chrome and the CLI/editor services.
//!
//! Every group gets a tab row and an editor pane, groups are arranged in an
//! oriented split tree, and the workbench composites all visible panes into one
//! frame before encoding a single ANSI diff. Each
//! tab owns a persistent `View`, so switching tabs or groups keeps scroll
//! position and decorations. The port keeps Grid's branch-demotion behavior
//! when a group empties, its sash resize, and tab drag/drop into a group or
//! onto a pane edge; the full N-ary branch model is not ported yet.
//!
//! With cell-border support the panes use the article's chrome: each pane is
//! outlined on its own cell edges, the active pane's outline has priority 1,
//! and adjacent outlines merge into shared dividers. The glyph fallback keeps
//! the one-cell gutter and box-drawing divider instead.
//!
//! A split currently moves the active tab into the new group (the terminal
//! equivalent of "move editor to group"); upstream `splitEditor` duplicates the
//! active input and gives each pane independent view state. Duplicating an
//! `Editor` would duplicate the text model, so the move preserves the one
//! model until the editor is split into model/view state.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const grid_mod = @import("../vs/base/browser/ui/grid/grid.zig");
const editor_drop_target = @import("../vs/workbench/browser/parts/editor/editorDropTarget.zig");
const editor_group_view = @import("../vs/workbench/browser/parts/editor/editorGroupView.zig");
const editor_part = @import("../vs/workbench/browser/parts/editor/editorPart.zig");
const tui = @import("./tui.zig");
const Tab = @import("./tab.zig").Tab;
const FileEditorInput = @import("./editorInput.zig").FileEditorInput;
const FileEditorSerializer = @import("./editorInput.zig").FileEditorSerializer;
const editor_factory = @import("../vs/workbench/common/editor/editorFactory.zig");
const Editor = @import("./editor.zig").Editor;
const TextEdit = @import("./editor.zig").TextEdit;
const View = @import("./view.zig").View;
const ViewCell = @import("./view.zig").Cell;
const tab_bar = @import("./tabBar.zig");
const Sidebar = @import("./explorerTreeSidebar.zig").Sidebar;
const activity_bar_mod = @import("./activityBar.zig");
const ActivityBarPart = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig").ActivityBarPart;
const SidebarPart = @import("../vs/workbench/browser/parts/sidebar/sidebarPart.zig").SidebarPart;
const LayoutModel = @import("../vs/workbench/browser/layout.zig").LayoutModel;
const statusbar_mod = @import("../vs/workbench/browser/parts/statusbar/statusbarPart.zig");
const StatusbarService = statusbar_mod.StatusbarService;
const EntryAccessor = statusbar_mod.EntryAccessor;
const statusbar_types = @import("../vs/workbench/services/statusbar/browser/statusbar.zig");
const ActivityService = @import("../vs/workbench/services/activity/browser/activityService.zig").ActivityService;
const history_mod = @import("../vs/workbench/services/history/common/history.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const quick_access_mod = @import("./quickAccess.zig");
const QuickAccessService = quick_access_mod.QuickAccessService;
const editor_status_mod = @import("../vs/workbench/browser/parts/editor/editorStatus.zig");
const EditorStatus = editor_status_mod.EditorStatus;
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../vs/workbench/services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const settings_watcher_mod = @import("./settingsWatcher.zig");
const universal_watcher_mod = @import("../vs/platform/files/node/watcher/watcher.zig");
const UniversalWatcher = universal_watcher_mod.UniversalWatcher;
const watch_common = @import("../vs/platform/files/common/watcher.zig");
const WatchRequest = watch_common.WatchRequest;
const languages_associations = @import("../vs/editor/common/services/languagesAssociations.zig");
const working_copy_mod = @import("./workingCopy.zig");
const working_copy_service_mod = @import("../vs/workbench/services/workingCopy/common/workingCopyService.zig");
const WorkingCopyService = working_copy_service_mod.WorkingCopyService;
const keybinding_service = @import("./keybindingService.zig");
const key_codes = @import("../vs/base/common/keyCodes.zig");
const keybinding_registry = @import("../vs/platform/keybinding/common/keybindingsRegistry.zig");
const SettingsWatcher = settings_watcher_mod.SettingsWatcher;
const lifecycle_mod = @import("../vs/base/common/lifecycle.zig");
const IDisposable = lifecycle_mod.IDisposable;
const breadcrumbs_mod = @import("../vs/workbench/browser/parts/editor/breadcrumbs.zig");
const BreadcrumbsService = breadcrumbs_mod.BreadcrumbsService;
const BreadcrumbsSettings = breadcrumbs_mod.Settings;
const breadcrumbs_model = @import("../vs/workbench/browser/parts/editor/breadcrumbsModel.zig");
const breadcrumbs_picker = @import("../vs/workbench/browser/parts/editor/breadcrumbsPicker.zig");
const breadcrumbs_control_mod = @import("../vs/workbench/browser/parts/editor/breadcrumbsControl.zig");
const BreadcrumbsControl = breadcrumbs_control_mod.BreadcrumbsControl;
const BreadcrumbsSelection = breadcrumbs_control_mod.Selection;
const BreadcrumbsSelectMode = breadcrumbs_control_mod.SelectMode;
const BreadcrumbsHost = breadcrumbs_control_mod.Host;
const outline_service_mod = @import("../vs/workbench/services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const outline_mod = @import("../vs/workbench/services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const file_icon = @import("./fileIcon.zig");
const quick_input_common = @import("../vs/platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input_common.QuickPickItem;
const QuickPick = @import("../vs/platform/quickinput/browser/quickInput.zig").QuickPick;

const search_view_mod = @import("./searchView.zig");
const SearchView = search_view_mod.SearchView;
const search_service_mod = @import("../vs/workbench/services/search/common/searchService.zig");
const SearchService = search_service_mod.SearchService;
const search_types = @import("../vs/workbench/services/search/common/search.zig");
const FileContentProvider = search_types.FileContentProvider;
const replace_service_mod = @import("../vs/workbench/contrib/search/browser/replaceService.zig");
const replace_types = replace_service_mod;
const search_configuration = @import("../vs/workbench/contrib/search/common/searchConfiguration.zig");
const tree = @import("../vs/workbench/contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");
const editor_groups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");
const editor_input = @import("../vs/workbench/common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const EOL = @import("../vs/editor/common/core/misc/eolCounter.zig").EOL;
const encoding_mod = @import("../vs/workbench/services/textfile/common/encoding.zig");
const SearchOption = @import("./searchWidget.zig").Option;

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = grid_mod.Orientation;
pub const Focus = enum { editor, sidebar, statusbar, breadcrumbs };

/// Pane chrome for the terminal editor part. The active pane's outline uses
/// the focused border colour and priority 1, so it wins a shared edge in a
/// terminal that implements cell-border priority merging; inactive panes are
/// dim. The stroke width is 1/8 cell, matching the article's thin outlines.
const inactive_pane_border = ui.Color{ .r = 70, .g = 70, .b = 70 };
const active_pane_border = ui.Color{ .r = 0x4d, .g = 0x9b, .b = 0xd6 };
const pane_border_width: u8 = 32;

/// A tab drag can drop in the middle of a pane (move into that group) or on an
/// edge (split that pane and move into the new group), mirroring the drop
/// locations of VS Code's grid.
const DropZone = editor_drop_target.Zone;
const DropTarget = editor_drop_target.Target(*GroupPane);
const PendingTabDrag = struct { pane: *GroupPane, tab: *Tab, x: usize, y: usize };
const TabClick = struct {
    pane: *GroupPane,
    tab: *Tab,
    at_ms: i64,
    x: usize,
    y: usize,
    /// Geometry of the clicked tab in the frame the click was recorded in.
    /// The strip can scroll when the click activates a partially visible tab,
    /// so the second click is matched against the old rectangle instead of
    /// trusting the new frame's hit.
    start: usize,
    end: usize,
};

const LayoutNode = grid_mod.Node(*GroupPane);

/// One editor group in the terminal editor part: the ported group view holds
/// the group model, the tabs (views/controllers), the tab-strip hit cache and
/// the cell rectangle it occupies.
pub const GroupPane = editor_group_view.EditorGroupView(*Tab);

const editor_mod = @import("../vs/workbench/common/editor.zig");

pub const Workbench = struct {
    allocator: Allocator,
    io: Io,
    cols: usize,
    rows: usize,

    service: *editor_groups.EditorGroupsService,
    part: *editor_part.EditorPart(GroupPane),
    frame: ui.Frame,
    /// Tab drag state: pending until the pointer moves, then a live drop target.
    pending_tab_drag: ?PendingTabDrag = null,
    drag_tab: ?*Tab = null,
    drag_source_pane: ?*GroupPane = null,
    drag_target: ?DropTarget = null,
    sidebar: ?*Sidebar = null,
    search_view: ?*SearchView = null,
    search_service: ?*SearchService = null,
    layout_model: LayoutModel,
    activity_bar_part: ActivityBarPart,
    sidebar_part: SidebarPart,
    statusbar: StatusbarService,
    activity_service: ActivityService,
    editor_status: ?*EditorStatus = null,
    status_hint_accessor: ?EntryAccessor = null,
    search_badge_buf: [32]u8 = undefined,
    search_badge_count: usize = 0,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    settings_watcher: ?*SettingsWatcher = null,
    /// Workspace file watcher. Kept separate from the settings watcher so a
    /// workspace change never triggers a settings reload.
    files_watcher: ?*UniversalWatcher = null,
    user_settings_path: ?[]u8,
    history: HistoryService,
    commands: CommandRegistry,
    working_copy_service: WorkingCopyService,
    tab_service: ?*keybinding_service.KeybindingService,
    tab_command_result: ?TabKeyResult = null,
    global_service: ?*keybinding_service.KeybindingService,
    statusbar_service: ?*keybinding_service.KeybindingService,
    quick_access: *QuickAccessService,
    outline_service: OutlineService,
    breadcrumbs_service: BreadcrumbsService,
    breadcrumbs_settings: BreadcrumbsSettings,
    breadcrumbs_control: ?*BreadcrumbsControl = null,
    breadcrumbs_registration: ?IDisposable = null,
    breadcrumbs_group: ?u32 = null,
    breadcrumbs_pane: ?*GroupPane = null,
    breadcrumbs_input: ?*EditorInput = null,
    breadcrumbs_host_context: BreadcrumbContext = undefined,
    breadcrumbs_arena: std.heap.ArenaAllocator,
    breadcrumbs_dirty: bool = false,
    hovered_tab: ?*Tab = null,
    hovered_pane: ?*GroupPane = null,
    last_tab_click: ?TabClick = null,
    expanded_pane: ?*GroupPane = null,
    focus: Focus = .editor,
    is_pasting: bool = false,
    quit_armed: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        paths: []const []const u8,
        cols: usize,
        rows: usize,
    ) !*Workbench {
        const self = try allocator.create(Workbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.cols = @max(cols, 1);
        self.tab_service = null;
        self.global_service = null;
        self.statusbar_service = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        try self.initShellModels();
        errdefer self.deinitShellModels();
        self.outline_service = OutlineService.init(allocator);
        errdefer self.outline_service.deinit();
        self.breadcrumbs_service = BreadcrumbsService.init(allocator);
        errdefer self.breadcrumbs_service.deinit();
        self.breadcrumbs_settings = BreadcrumbsSettings.load(null);
        self.breadcrumbs_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.breadcrumbs_arena.deinit();
        self.breadcrumbs_control = null;
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.last_tab_click = null;
        self.expanded_pane = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();
        self.part = try editor_part.EditorPart(GroupPane).init(allocator, self.service);
        errdefer self.part.deinit();

        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();

        try self.initQuickAccess();
        errdefer self.history.deinit();
        errdefer self.commands.deinit();
        errdefer self.quick_access.deinit();
        self.layoutAll();

        for (paths) |path| {
            try self.openPath(path);
        }

        return self;
    }

    /// Restores a single serialized group. Multi-group session serialization is
    /// a follow-up; the group model/serializer already support it.
    pub fn initFromSerialized(
        allocator: Allocator,
        io: Io,
        data: group_mod.SerializedEditorGroupModel,
        registry: *editor_factory.EditorFactoryRegistry,
        cols: usize,
        rows: usize,
    ) !*Workbench {
        const self = try allocator.create(Workbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.cols = @max(cols, 1);
        self.tab_service = null;
        self.global_service = null;
        self.statusbar_service = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        try self.initShellModels();
        errdefer self.deinitShellModels();
        self.outline_service = OutlineService.init(allocator);
        errdefer self.outline_service.deinit();
        self.breadcrumbs_service = BreadcrumbsService.init(allocator);
        errdefer self.breadcrumbs_service.deinit();
        self.breadcrumbs_settings = BreadcrumbsSettings.load(null);
        self.breadcrumbs_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.breadcrumbs_arena.deinit();
        self.breadcrumbs_control = null;
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.last_tab_click = null;
        self.expanded_pane = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();

        const group = self.service.activeGroup();
        group.model.deinit();
        group.model = try group_mod.EditorGroupModel.initFromSerialized(allocator, .{}, data, registry);
        group.id = group.model.id;

        self.part = try editor_part.EditorPart(GroupPane).init(allocator, self.service);
        errdefer self.part.deinit();

        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();

        try self.initQuickAccess();
        errdefer self.history.deinit();
        errdefer self.commands.deinit();
        errdefer self.quick_access.deinit();
        self.layoutAll();

        const pane = self.part.group_views.items[0];
        const editors = try group.model.getEditors(allocator, .SEQUENTIAL, false);
        defer allocator.free(editors);
        for (editors) |input| {
            if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
            const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
            const tab = try Tab.initFromInput(allocator, file_input);
            try tab.view.setStatusBarVisible(false);
            try pane.addTab(tab);
            self.registerWorkingCopy(tab);
            try self.history.add(file_input.editor.path);
        }

        return self;
    }

    /// Restores every serialized group and rebuilds the terminal split tree.
    /// Upstream also persists the split grid; the TUI currently restores the
    /// groups as equal horizontal splits.
    pub fn initFromSerializedPart(
        allocator: Allocator,
        io: Io,
        data: editor_groups.SerializedEditorPart,
        registry: *editor_factory.EditorFactoryRegistry,
        cols: usize,
        rows: usize,
    ) !*Workbench {
        const self = try allocator.create(Workbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.cols = @max(cols, 1);
        self.tab_service = null;
        self.global_service = null;
        self.statusbar_service = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        try self.initShellModels();
        errdefer self.deinitShellModels();
        self.outline_service = OutlineService.init(allocator);
        errdefer self.outline_service.deinit();
        self.breadcrumbs_service = BreadcrumbsService.init(allocator);
        errdefer self.breadcrumbs_service.deinit();
        self.breadcrumbs_settings = BreadcrumbsSettings.load(null);
        self.breadcrumbs_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.breadcrumbs_arena.deinit();
        self.breadcrumbs_control = null;
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.last_tab_click = null;
        self.expanded_pane = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.initFromSerializedPart(allocator, data, registry, .{});
        errdefer self.service.deinit();
        self.part = try editor_part.EditorPart(GroupPane).init(allocator, self.service);
        errdefer self.part.deinit();
        try self.part.restoreGroups();

        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();

        try self.initQuickAccess();
        errdefer self.history.deinit();
        errdefer self.commands.deinit();
        errdefer self.quick_access.deinit();
        for (self.service.groups.items, 0..) |group, index| {
            const pane = self.part.group_views.items[index];

            const editors = try group.model.getEditors(allocator, .SEQUENTIAL, false);
            defer allocator.free(editors);
            for (editors) |input| {
                if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
                const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
                const tab = try Tab.initFromInput(allocator, file_input);
                try tab.view.setStatusBarVisible(false);
                try pane.addTab(tab);
                self.registerWorkingCopy(tab);
                try self.history.add(file_input.editor.path);
            }
        }

        self.layoutAll();
        return self;
    }

    /// Serializes every group and the active group index.
    pub fn serializePart(
        self: *Workbench,
        allocator: Allocator,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !editor_groups.SerializedEditorPart {
        return self.service.serializePart(allocator, registry);
    }

    /// Serializes the active group.
    pub fn serialize(
        self: *Workbench,
        allocator: Allocator,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !group_mod.SerializedEditorGroupModel {
        return self.service.activeGroup().model.serialize(allocator, registry);
    }

    pub fn createFileSerializer(self: *Workbench) FileEditorSerializer {
        return FileEditorSerializer.init(self.allocator, self.io, self.cols, self.editorContentHeight());
    }

    fn initShellModels(self: *Workbench) !void {
        self.layout_model = LayoutModel.init(self.allocator);
        errdefer self.layout_model.deinit();
        self.activity_bar_part = ActivityBarPart.init(self.allocator);
        errdefer self.activity_bar_part.deinit();
        self.sidebar_part = SidebarPart.init(self.allocator);
        errdefer self.sidebar_part.deinit();
        self.statusbar = try StatusbarService.init(self.allocator);
        errdefer self.statusbar.deinit();
        self.activity_service = ActivityService.init(self.allocator);
        errdefer self.activity_service.deinit();

        try self.layout_model.setSize(.sidebar, 28);
        try self.layout_model.setVisible(.sidebar, false);
        try self.layout_model.setVisible(.activitybar, true);
        try self.layout_model.setVisible(.statusbar, true);

        for (activity_bar_mod.default_activities) |activity| {
            try self.activity_bar_part.addActivity(activity);
        }
        try self.activity_bar_part.setVisible(true);

        try self.sidebar_part.pane.addComposite(.{ .id = "explorer", .name = "Explorer", .order = 1 });
        try self.sidebar_part.pane.addComposite(.{ .id = "search", .name = "Search", .order = 2 });
        try self.sidebar_part.pane.addComposite(.{ .id = "settings", .name = "Settings", .order = 3 });
        try self.sidebar_part.setWidth(28);

        try self.initStatusHint();
    }

    fn initStatusHint(self: *Workbench) !void {
        self.status_hint_accessor = try self.statusbar.addEntry(.{
            .name = "Quit hint",
            .text = "Ctrl-Q quit",
        }, "workbench.hint", .right, .{ .number = 0 });
    }

    fn deinitShellModels(self: *Workbench) void {
        self.activity_service.deinit();
        self.statusbar.deinit();
        self.sidebar_part.deinit();
        self.activity_bar_part.deinit();
        self.layout_model.deinit();
    }

    fn initQuickAccess(self: *Workbench) !void {
        self.history = HistoryService.init(self.allocator);
        errdefer self.history.deinit();

        self.commands = CommandRegistry.init(self.allocator);
        self.working_copy_service = WorkingCopyService.init(self.allocator);
        errdefer self.working_copy_service.deinit();
        errdefer self.commands.deinit();
        self.commands.setEditorAvailability(self, hasActiveEditor);

        self.quick_access = try QuickAccessService.init(
            self.allocator,
            self.io,
            self.workspace,
            &self.history,
            &self.commands,
            .{
                .context = self,
                .open_file = quickOpenFile,
                .report_error = quickReportError,
                .cancel_popups = quickCancelPopups,
            },
        );
        errdefer self.quick_access.deinit();

        self.editor_status = try EditorStatus.init(
            self.allocator,
            &self.statusbar,
            self.quick_access.inputService(),
            .{ .context = self, .focus = statusFocusEditor },
        );
        errdefer {
            if (self.editor_status) |status| status.deinit();
            self.editor_status = null;
        }

        try self.registerDefaultCommands();
        self.statusbar.setCommandExecutor(.{
            .context = self,
            .execute = executeStatusbarCommand,
        });
    }

    fn registerDefaultCommands(self: *Workbench) !void {
        const status = self.editor_status.?;
        const commands = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.action.quickOpen", .label = "Go to File...", .category = "File", .context = self, .run = commandQuickOpen },
            .{ .id = "workbench.action.showCommands", .label = "Show All Commands", .context = self, .run = commandShowCommands },
            .{ .id = editor_status_mod.goto_line_command, .label = "Go to Line/Column...", .category = "Go", .context = status, .run = editor_status_mod.commandGotoLine },
            .{ .id = editor_status_mod.change_indentation_command, .label = "Change Indentation", .category = "Editor", .context = status, .run = editor_status_mod.commandChangeIndentation },
            .{ .id = editor_status_mod.change_encoding_command, .label = "Change File Encoding", .category = "Editor", .context = status, .run = editor_status_mod.commandChangeEncoding },
            .{ .id = editor_status_mod.change_eol_command, .label = "Change End of Line Sequence", .category = "Editor", .context = status, .run = editor_status_mod.commandChangeEOL },
            .{ .id = editor_status_mod.change_language_mode_command, .label = "Change Language Mode", .category = "Editor", .context = status, .run = editor_status_mod.commandChangeLanguageMode },
            .{ .id = "workbench.action.files.save", .label = "Save", .category = "File", .context = self, .run = commandSave },
            .{ .id = "workbench.action.files.revert", .label = "Revert File", .category = "File", .context = self, .run = commandRevert },
            .{ .id = "workbench.action.closeActiveEditor", .label = "Close Editor", .category = "View", .context = self, .run = commandCloseEditor },
            .{ .id = "breadcrumbs.focusAndSelect", .label = "Focus and Select Breadcrumbs", .category = "View", .context = self, .run = commandFocusAndSelectBreadcrumbs },
            .{ .id = "breadcrumbs.focus", .label = "Focus Breadcrumbs", .category = "View", .context = self, .run = commandFocusBreadcrumbs },
            .{ .id = "workbench.action.splitEditor", .label = "Split Editor", .category = "View", .context = self, .run = commandSplitEditor },
            .{ .id = "workbench.action.toggleSidebarVisibility", .label = "Toggle Primary Side Bar Visibility", .category = "View", .context = self, .run = commandToggleSidebar },
            .{ .id = "workbench.action.focusStatusBar", .label = "Focus Status Bar", .category = "View", .context = self, .run = commandFocusStatusBar },
            .{ .id = "workbench.action.findInFiles", .label = "Find in Files", .category = "Search", .context = self, .run = commandFindInFiles },
            .{ .id = "workbench.action.replaceInFiles", .label = "Replace in Files", .category = "Search", .context = self, .run = commandReplaceInFiles },
            .{ .id = "toggleSearchCaseSensitive", .label = "Toggle Case Sensitive", .category = "Search", .context = self, .run = commandToggleSearchCase },
            .{ .id = "toggleSearchWholeWord", .label = "Toggle Whole Word", .category = "Search", .context = self, .run = commandToggleSearchWholeWord },
            .{ .id = "toggleSearchRegex", .label = "Toggle Regex", .category = "Search", .context = self, .run = commandToggleSearchRegex },
            .{ .id = "toggleSearchPreserveCase", .label = "Toggle Preserve Case", .category = "Search", .context = self, .run = commandToggleSearchPreserveCase },
            .{ .id = "search.action.focusNextSearchResult", .label = "Focus Next Search Result", .category = "Search", .context = self, .run = commandSearchNext },
            .{ .id = "search.action.focusPreviousSearchResult", .label = "Focus Previous Search Result", .category = "Search", .context = self, .run = commandSearchPrevious },
            .{ .id = "search.action.remove", .label = "Dismiss Search Result", .category = "Search", .context = self, .run = commandSearchRemove },
            .{ .id = "search.action.replace", .label = "Replace", .category = "Search", .context = self, .run = commandSearchReplace },
            .{ .id = "search.action.replaceAllInFile", .label = "Replace All in File", .category = "Search", .context = self, .run = commandSearchReplace },
            .{ .id = "search.action.replaceAllInFolder", .label = "Replace All in Folder", .category = "Search", .context = self, .run = commandSearchReplace },
            .{ .id = "search.action.clearSearchResults", .label = "Clear Search Results", .category = "Search", .context = self, .run = commandSearchClear },
            .{ .id = "workbench.action.search.toggleQueryDetails", .label = "Toggle Search Details", .category = "Search", .context = self, .run = commandSearchDetails },
            .{ .id = "actions.find", .label = "Find", .context = self, .requires_editor = true, .run = commandFind },
            .{ .id = "editor.action.startFindReplaceAction", .label = "Replace", .context = self, .requires_editor = true, .run = commandReplace },
            .{ .id = "editor.action.commentLine", .label = "Toggle Line Comment", .category = "Editor", .context = self, .requires_editor = true, .run = commandToggleLineComment },
            .{ .id = "editor.action.blockComment", .label = "Toggle Block Comment", .category = "Editor", .context = self, .requires_editor = true, .run = commandToggleBlockComment },
            .{ .id = "editor.action.moveLinesUpAction", .label = "Move Line Up", .category = "Editor", .context = self, .requires_editor = true, .run = commandMoveLinesUp },
            .{ .id = "editor.action.moveLinesDownAction", .label = "Move Line Down", .category = "Editor", .context = self, .requires_editor = true, .run = commandMoveLinesDown },
            .{ .id = "editor.action.copyLinesUpAction", .label = "Copy Line Up", .category = "Editor", .context = self, .requires_editor = true, .run = commandCopyLinesUp },
            .{ .id = "editor.action.copyLinesDownAction", .label = "Copy Line Down", .category = "Editor", .context = self, .requires_editor = true, .run = commandCopyLinesDown },
            .{ .id = "editor.action.duplicateSelection", .label = "Duplicate Selection", .category = "Editor", .context = self, .requires_editor = true, .run = commandDuplicateSelection },
            .{ .id = "editor.action.sortLinesAscending", .label = "Sort Lines Ascending", .category = "Editor", .context = self, .requires_editor = true, .run = commandSortLinesAscending },
            .{ .id = "editor.action.sortLinesDescending", .label = "Sort Lines Descending", .category = "Editor", .context = self, .requires_editor = true, .run = commandSortLinesDescending },
            .{ .id = "editor.action.indentLines", .label = "Indent Lines", .category = "Editor", .context = self, .requires_editor = true, .run = commandIndentLines },
            .{ .id = "editor.action.outdentLines", .label = "Outdent Lines", .category = "Editor", .context = self, .requires_editor = true, .run = commandOutdentLines },
            .{ .id = "editor.action.insertFinalNewLine", .label = "Insert Final New Line", .category = "Editor", .context = self, .requires_editor = true, .run = commandInsertFinalNewLine },
            .{ .id = "expandLineSelection", .label = "Expand Line Selection", .category = "Editor", .context = self, .requires_editor = true, .run = commandExpandLineSelection },
            .{ .id = "editor.action.insertCursorAbove", .label = "Add Cursor Above", .category = "Editor", .context = self, .requires_editor = true, .run = commandInsertCursorAbove },
            .{ .id = "editor.action.insertCursorBelow", .label = "Add Cursor Below", .category = "Editor", .context = self, .requires_editor = true, .run = commandInsertCursorBelow },
            .{ .id = "editor.action.addSelectionToNextFindMatch", .label = "Add Selection To Next Find Match", .category = "Selection", .context = self, .requires_editor = true, .run = commandAddSelectionToNextFindMatch },
            .{ .id = "editor.action.selectHighlights", .label = "Select All Occurrences of Find Match", .category = "Selection", .context = self, .requires_editor = true, .run = commandSelectHighlights },
            .{ .id = "editor.action.jumpToBracket", .label = "Go to Bracket", .category = "Go", .context = self, .requires_editor = true, .run = commandJumpToBracket },
            .{ .id = "editor.action.selectToBracket", .label = "Select to Bracket", .category = "Selection", .context = self, .requires_editor = true, .run = commandSelectToBracket },
            .{ .id = "editor.action.removeBrackets", .label = "Remove Brackets", .category = "Editor", .context = self, .requires_editor = true, .run = commandRemoveBrackets },
            .{ .id = "editor.action.smartSelect.expand", .label = "Expand Selection", .category = "Selection", .context = self, .requires_editor = true, .run = commandExpandSelection },
            .{ .id = "editor.action.smartSelect.shrink", .label = "Shrink Selection", .category = "Selection", .context = self, .requires_editor = true, .run = commandShrinkSelection },
            .{ .id = "editor.action.inPlaceReplace.up", .label = "Replace with Previous Value", .category = "Editor", .context = self, .requires_editor = true, .run = commandInPlaceReplacePrevious },
            .{ .id = "editor.action.inPlaceReplace.down", .label = "Replace with Next Value", .category = "Editor", .context = self, .requires_editor = true, .run = commandInPlaceReplaceNext },
            .{ .id = "editor.action.reindentlines", .label = "Reindent Lines", .category = "Editor", .context = self, .requires_editor = true, .run = commandReindentLines },
            .{ .id = "editor.action.reindentselectedlines", .label = "Reindent Selected Lines", .category = "Editor", .context = self, .requires_editor = true, .run = commandReindentSelectedLines },
            .{ .id = "editor.fold", .label = "Fold", .category = "Editor", .context = self, .requires_editor = true, .run = commandFold },
            .{ .id = "editor.unfold", .label = "Unfold", .category = "Editor", .context = self, .requires_editor = true, .run = commandUnfold },
            .{ .id = "editor.toggleFold", .label = "Toggle Fold", .category = "Editor", .context = self, .requires_editor = true, .run = commandToggleFold },
            .{ .id = "editor.foldRecursively", .label = "Fold Recursively", .category = "Editor", .context = self, .requires_editor = true, .run = commandFoldRecursively },
            .{ .id = "editor.unfoldRecursively", .label = "Unfold Recursively", .category = "Editor", .context = self, .requires_editor = true, .run = commandUnfoldRecursively },
            .{ .id = "editor.foldAll", .label = "Fold All", .category = "Editor", .context = self, .requires_editor = true, .run = commandFoldAll },
            .{ .id = "editor.unfoldAll", .label = "Unfold All", .category = "Editor", .context = self, .requires_editor = true, .run = commandUnfoldAll },
            .{ .id = "editor.action.wordHighlight.next", .label = "Go to Next Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightNext },
            .{ .id = "editor.action.wordHighlight.prev", .label = "Go to Previous Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightPrevious },
        };
        for (commands) |command| try self.commands.register(command);
    }

    pub fn handleQuickAccessKey(self: *Workbench, event: *ui.KeyEvent) !bool {
        return self.quick_access.handleKey(event);
    }

    pub fn handleQuickAccessMouse(self: *Workbench, event: *ui.MouseEvent) bool {
        return self.quick_access.handleMouse(event);
    }

    pub fn pollQuickAccess(self: *Workbench, now_ms: i64) !bool {
        return self.quick_access.poll(now_ms);
    }

    pub fn quickAccessWantsTick(self: *Workbench) bool {
        return self.quick_access.wantsTick();
    }

    pub fn isQuickAccessOpen(self: *const Workbench) bool {
        return self.quick_access.isOpen();
    }

    pub fn pollSearch(self: *Workbench, now_ms: i64) bool {
        if (self.search_view) |view| return view.tick(now_ms);
        return false;
    }

    pub fn searchWantsTick(self: *const Workbench) bool {
        if (self.search_view) |view| return view.wantsTick();
        return false;
    }

    pub fn onSearchEditorChanged(self: *Workbench) void {
        if (self.search_view) |view| {
            view.onEditorChanged(self.activeEditorInfo());
        }
    }

    fn activeEditorInfo(self: *Workbench) ?search_view_mod.EditorInfo {
        const tab = self.activeTab() orelse return null;
        return .{ .path = tab.editor.path, .version = tab.editor.model.getVersionId() };
    }

    pub fn findInFiles(self: *Workbench) !void {
        try self.showActivity(1);
        if (self.search_view) |view| {
            try view.seedFromSelection();
            view.focus();
        }
    }

    pub fn replaceInFiles(self: *Workbench) !void {
        try self.showActivity(1);
        if (self.search_view) |view| view.focusReplace();
    }

    pub fn deinit(self: *Workbench) void {
        self.disposeBreadcrumbs();
        self.breadcrumbs_arena.deinit();
        self.breadcrumbs_service.deinit();
        self.outline_service.deinit();
        if (self.editor_status) |status| {
            status.deinit();
            self.editor_status = null;
        }
        self.deinitShellModels();
        if (self.tab_service) |service| service.deinit();
        if (self.global_service) |service| {
            service.deinit();
        }
        if (self.statusbar_service) |service| service.deinit();
        self.quick_access.deinit();
        self.working_copy_service.deinit();
        self.commands.deinit();
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.service.deinit();
        if (self.sidebar) |sidebar| sidebar.deinit();
        self.destroySearch();
        if (self.settings_watcher) |watcher| watcher.deinit();
        if (self.files_watcher) |watcher| {
            watcher.stop();
            watcher.deinit();
        }
        if (self.configuration) |configuration| configuration.deinit();
        if (self.user_settings_path) |path| self.allocator.free(path);
        self.workspace.deinit();
        // The part owns the group views; disposing it disposes the tab views.
        self.part.deinit();
        self.frame.deinit();
        self.allocator.destroy(self);
    }

    pub fn statusBarVisible(self: *const Workbench) bool {
        return self.layout_model.isVisible(.statusbar) and self.rows >= 2;
    }

    /// The workbench status row in global cells. It spans the full window,
    /// including under the sidebar and activity bar.
    pub fn statusBarRect(self: *const Workbench) ui.Rect {
        if (!self.statusBarVisible()) return .{};
        return .{
            .x = 0,
            .y = @floatFromInt(self.rows - 1),
            .w = @floatFromInt(self.cols),
            .h = 1,
        };
    }

    fn editorRows(self: *const Workbench) usize {
        return if (self.statusBarVisible()) self.rows - 1 else self.rows;
    }

    /// Editor content height: the rows above the workbench status bar minus the
    /// group chrome (tab strip plus the optional breadcrumb row).
    fn editorContentHeight(self: *const Workbench) usize {
        return @max(self.editorRows() -| self.chromeHeight(), 1);
    }

    fn chromeHeight(self: *const Workbench) usize {
        return editor_group_view.title_height +
            (if (self.breadcrumbs_settings.enabled) editor_group_view.breadcrumbs_height else 0);
    }

    fn breadcrumbsEnabled(self: *const Workbench) bool {
        return self.breadcrumbs_settings.enabled;
    }

    fn sidebarWidth(self: *const Workbench) usize {
        const max_width = @max(self.cols / 2, 10);
        return @min(self.layout_model.size(.sidebar), @max(max_width, 1));
    }

    fn activityBarWidth(self: *const Workbench) usize {
        return self.activity_bar_part.width();
    }

    fn sidebarShown(self: *const Workbench) bool {
        return self.layout_model.isVisible(.sidebar) and self.sidebar != null and
            self.activityBarWidth() + self.sidebarWidth() + 8 < self.cols;
    }

    fn setSidebarVisible(self: *Workbench, visible: bool) !void {
        try self.layout_model.setVisible(.sidebar, visible);
        try self.sidebar_part.setVisible(visible);
    }

    pub fn activeActivity(self: *const Workbench) usize {
        return self.activity_bar_part.activeIndex() orelse 0;
    }

    /// Open-editor query for the Explorer filter. A file is visible when it is
    /// open, and a folder is visible when an open file is below it.
    fn isPathOpen(context: *anyopaque, resource: []const u8) bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const path = tab.editor.path;
                if (std.mem.eql(u8, path, resource)) return true;
                if (std.mem.startsWith(u8, path, resource) and path.len > resource.len and
                    (path[resource.len] == '/' or path[resource.len] == '\\'))
                {
                    return true;
                }
            }
        }
        return false;
    }

    fn activityRect(self: *const Workbench) ui.Rect {
        return .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.activityBarWidth()),
            .h = @floatFromInt(self.editorRows()),
        };
    }

    fn sidebarRect(self: *const Workbench) ui.Rect {
        return .{
            .x = @floatFromInt(self.activityBarWidth()),
            .y = 0,
            .w = @floatFromInt(self.sidebarWidth()),
            .h = @floatFromInt(self.editorRows()),
        };
    }

    /// Sets the workspace folders and rebuilds the Explorer roots. Upstream
    /// the workspace context service is set by the workbench startup; here the
    /// CLI folder arguments replace the empty workspace.
    pub fn setWorkspaceFolders(self: *Workbench, folders: []const []const u8) !void {
        const replacement = try WorkspaceContextService.initWithFolders(self.allocator, "workspace", folders);
        if (self.sidebar) |sidebar| {
            sidebar.deinit();
            self.sidebar = null;
        }
        self.destroySearch();
        if (self.settings_watcher) |watcher| {
            watcher.deinit();
            self.settings_watcher = null;
        }
        if (self.files_watcher) |watcher| {
            watcher.stop();
            watcher.deinit();
            self.files_watcher = null;
        }
        if (self.configuration) |configuration| {
            configuration.deinit();
            self.configuration = null;
        }
        self.workspace.deinit();
        self.workspace = replacement;
        try self.ensureConfiguration();
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        self.disposeBreadcrumbs();
        self.layoutAll();
        try self.quick_access.setWorkspace(self.workspace);
        self.startFilesWatcher() catch {};
    }

    /// Sets the user settings file before the Explorer/configuration service is
    /// created. The app derives it from `XDG_CONFIG_HOME`/`HOME`.
    pub fn setUserSettingsPath(self: *Workbench, path: ?[]const u8) !void {
        if (self.user_settings_path) |old| self.allocator.free(old);
        self.user_settings_path = if (path) |value| try self.allocator.dupe(u8, value) else null;
        if (self.configuration) |configuration| {
            if (self.settings_watcher) |watcher| {
                watcher.deinit();
                self.settings_watcher = null;
            }
            configuration.deinit();
            self.configuration = null;
            try self.ensureConfiguration();
            self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
            self.disposeBreadcrumbs();
            self.layoutAll();
        }
    }

    fn ensureConfiguration(self: *Workbench) !void {
        if (self.configuration != null) return;
        self.configuration = try ConfigurationService.init(
            self.allocator,
            self.io,
            self.workspace,
            .{
                .user_settings_path = self.user_settings_path,
                .defaults_json = &.{search_configuration.defaults_json},
            },
        );
        self.settings_watcher = SettingsWatcher.init(self.allocator, self.io, self.configuration.?) catch null;
        if (self.settings_watcher) |watcher| {
            watcher.setOnReload(.{ .context = self, .callback = onSettingsReloaded });
        }
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
    }

    fn onSettingsReloaded(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyConfiguredLanguageAssociationsToAllEditors();
        self.applyBreadcrumbsSettings();
    }

    /// Applies `files.associations` from the current configuration to `editor`.
    fn applyConfiguredLanguageAssociations(self: *Workbench, editor: *Editor) void {
        self.ensureConfiguration() catch {};
        const configuration = self.configuration orelse {
            editor.applyFileAssociations(&.{}) catch {};
            return;
        };
        const value = configuration.getValue("files.associations", .{}) orelse {
            editor.applyFileAssociations(&.{}) catch {};
            return;
        };
        switch (value.*) {
            .object => |object| {
                var associations = std.array_list.Managed(languages_associations.ILanguageAssociation).init(self.allocator);
                defer associations.deinit();
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const language_id = switch (entry.value_ptr.*) {
                        .string => |text| text,
                        else => continue,
                    };
                    associations.append(.{
                        .id = language_id,
                        .mime = "",
                        .filepattern = entry.key_ptr.*,
                    }) catch {};
                }
                editor.applyFileAssociations(associations.items) catch {};
            },
            else => editor.applyFileAssociations(&.{}) catch {},
        }
    }

    fn applyConfiguredLanguageAssociationsToAllEditors(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                self.applyConfiguredLanguageAssociations(tab.editor);
            }
        }
    }

    /// Drives the settings watcher. Returns true when a settings reload was
    /// performed (or an event was emitted) and the host should repaint.
    /// Handles external file changes: clean open editors are reloaded, dirty
    /// ones keep the user's in-memory content (upstream marks the conflict).
    pub fn handleFileChanges(self: *Workbench, changes: []const @import("../vs/platform/files/common/files.zig").FileChange) void {
        for (changes) |change| {
            if (change.type != .UPDATED) continue;
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    if (!std.mem.eql(u8, tab.editor.path, change.resource)) continue;
                    if (tab.editor.isDirty()) {
                        tab.editor.markConflict();
                        continue;
                    }
                    tab.editor.reloadFromDisk() catch {};
                }
            }
        }
    }

    pub fn workingCopyService(self: *Workbench) *WorkingCopyService {
        return &self.working_copy_service;
    }

    fn registerWorkingCopy(self: *Workbench, tab: *Tab) void {
        self.working_copy_service.registerWorkingCopy(working_copy_mod.interface(tab.editor)) catch {};
    }

    fn unregisterWorkingCopy(self: *Workbench, tab: *Tab) void {
        _ = self.working_copy_service.unregisterWorkingCopy(working_copy_mod.interface(tab.editor));
    }

    pub fn pollFileWatcher(self: *Workbench, now_ms: i64) bool {
        var changed = false;
        if (self.settings_watcher) |watcher| {
            changed = watcher.poll(now_ms) catch false;
            if (changed) {
                if (self.search_view) |view| view.onConfigurationChanged();
            }
        }
        if (self.files_watcher) |watcher| {
            _ = watcher.poll(now_ms) catch false;
        }
        return changed;
    }

    /// Starts the workspace watcher for absolute workspace folders; relative
    /// folders (used by tests and some CLI invocations) are resolved by the app
    /// before being passed here.
    fn startFilesWatcher(self: *Workbench) !void {
        if (self.workspace.getWorkspace().folders.items.len == 0) return;
        var requests = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer requests.deinit();
        for (self.workspace.getWorkspace().folders.items) |folder| {
            if (!std.fs.path.isAbsolute(folder.resource)) continue;
            try requests.append(.{ .path = folder.resource, .recursive = true });
        }
        if (requests.items.len == 0) return;

        const watcher = try UniversalWatcher.init(self.allocator, self.io);
        errdefer watcher.deinit();
        _ = try watcher.on_change.listen(self, onWorkspaceFileChanges);
        try watcher.watch(requests.items);
        self.files_watcher = watcher;
    }

    fn onWorkspaceFileChanges(changes: []const @import("../vs/platform/files/common/files.zig").FileChange, self: *Workbench) !void {
        self.handleFileChanges(changes);
    }

    pub fn fileWatcherFd(self: *const Workbench) ?std.posix.fd_t {
        const watcher = self.settings_watcher orelse return null;
        return switch (watcher.waitHandle()) {
            .fd => |fd| fd,
            else => null,
        };
    }

    pub fn fileWatcherHandle(self: *const Workbench) ?*anyopaque {
        const watcher = self.settings_watcher orelse return null;
        return switch (watcher.waitHandle()) {
            .handle => |handle| handle,
            else => null,
        };
    }

    pub fn fileWatcherTimeout(self: *const Workbench, now_ms: i64) ?u32 {
        const watcher = self.settings_watcher orelse return null;
        return watcher.nextTimeout(now_ms);
    }

    fn autoRevealEnabled(self: *const Workbench, resource: []const u8) bool {
        const configuration = self.configuration orelse return true;
        const value = configuration.getValue("explorer.autoReveal", .{ .resource = resource }) orelse
            return true;
        return switch (value.*) {
            .bool => |enabled| enabled,
            else => true,
        };
    }

    fn revealActiveEditor(self: *Workbench) void {
        const tab = self.activeTab() orelse return;
        if (!self.autoRevealEnabled(tab.input.editor.path)) return;
        if (self.sidebar) |sidebar| sidebar.revealPath(tab.input.editor.path) catch {};
    }

    /// Test/standalone helper: set a single-folder workspace and open the
    /// Explorer on it.
    pub fn initSidebar(self: *Workbench, root_path: []const u8) !void {
        try self.setWorkspaceFolders(&.{root_path});
        try self.initSidebarFromWorkspace();
    }

    pub fn initSidebarFromWorkspace(self: *Workbench) !void {
        try self.ensureConfiguration();
        if (self.sidebar == null) {
            self.sidebar = try Sidebar.init(
                self.allocator,
                self.io,
                self.workspace,
                self.configuration.?,
            );
        }
        if (self.search_view == null) try self.initSearchFromWorkspace();
        self.sidebar.?.setOpenEditorQuery(.{ .context = self, .is_open = isPathOpen });
        try self.setSidebarVisible(true);
        _ = try self.activity_bar_part.setActive(self.activity_bar_part.activities.items[0].id);
        _ = try self.sidebar_part.openPaneComposite(self.activity_bar_part.activities.items[0].id);
        self.layoutAll();
    }

    fn initSearchFromWorkspace(self: *Workbench) !void {
        self.destroySearch();
        const service = try self.allocator.create(SearchService);
        errdefer self.allocator.destroy(service);
        service.* = SearchService.init(self.allocator, self.io, self.workspace, .{
            .context = self,
            .read = searchReadFile,
            .extra_files = searchExtraFiles,
            .free_paths = searchFreePaths,
        });
        const view = try SearchView.init(
            self.allocator,
            self.workspace,
            self.configuration.?,
            service.interface(),
            .{
                .context = self,
                .open_match = searchOpenMatch,
                .highlight_range = searchHighlightRange,
                .read_file = searchReadFile,
                .extra_files = searchExtraFiles,
                .free_paths = searchFreePaths,
                .apply_edits = searchApplyEdits,
                .save_file = searchSaveFile,
                .active_selection_text = searchActiveSelectionText,
                .active_editor = searchActiveEditorInfo,
            },
        );
        errdefer view.deinit();
        self.search_service = service;
        self.search_view = view;
    }

    fn destroySearch(self: *Workbench) void {
        if (self.search_view) |view| view.deinit();
        self.search_view = null;
        if (self.search_service) |service| self.allocator.destroy(service);
        self.search_service = null;
    }

    pub fn showActivity(self: *Workbench, index: usize) !void {
        const activity = self.activity_bar_part.activityAtVisibleIndex(index) orelse return;
        if (self.sidebar == null or self.search_view == null) try self.initSidebarFromWorkspace();
        _ = try self.activity_bar_part.setActive(activity.id);
        _ = try self.sidebar_part.openPaneComposite(activity.id);
        try self.setSidebarVisible(true);
        try self.layout_model.setVisible(.activitybar, true);
        self.focus = .sidebar;
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, activity.id, "search")) {
            if (self.search_view) |view| view.focus();
        }
        self.layoutAll();
    }

    pub fn toggleSidebar(self: *Workbench) !void {
        if (self.sidebar == null) {
            try self.initSidebarFromWorkspace();
            self.focus = .sidebar;
            return;
        }
        const visible = !self.layout_model.isVisible(.sidebar);
        try self.setSidebarVisible(visible);
        self.focus = if (visible) .sidebar else .editor;
        self.statusbar.main_part.clearFocus();
        self.layoutAll();
    }

    pub fn focusSidebar(self: *Workbench) void {
        if (!self.sidebarShown()) return;
        self.focus = .sidebar;
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) {
            if (self.search_view) |view| view.focus();
        }
    }

    pub fn focusEditor(self: *Workbench) void {
        self.focus = .editor;
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (self.search_view) |view| view.blur();
    }

    pub fn focusStatusBar(self: *Workbench) void {
        if (!self.statusBarVisible()) return;
        self.focus = .statusbar;
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        if (self.statusbar.main_part.focusedHandle() == null) {
            if (self.statusbar.main_part.lastFocusedHandle()) |handle| {
                self.statusbar.main_part.setFocused(handle);
            }
            if (self.statusbar.main_part.focusedHandle() == null) {
                _ = self.statusbar.main_part.focusNextEntry();
            }
        }
        if (self.activeTab()) |tab| tab.view.focusEditor();
        if (self.search_view) |view| view.blur();
    }

    fn editorAreaRect(self: *const Workbench) ui.Rect {
        if (self.sidebarShown()) {
            const width = self.sidebarWidth();
            return .{
                .x = @floatFromInt(self.activityBarWidth() + width + 1),
                .y = 0,
                .w = @floatFromInt(self.cols - self.activityBarWidth() - width - 1),
                .h = @floatFromInt(self.editorRows()),
            };
        }
        return .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.cols),
            .h = @floatFromInt(self.editorRows()),
        };
    }

    fn layoutAll(self: *Workbench) void {
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        const rect = self.editorAreaRect();
        for (self.part.group_views.items) |pane| {
            pane.setBreadcrumbsVisible(self.breadcrumbsEnabled());
        }
        self.part.layout(rect);
        if (self.expanded_pane) |expanded| {
            if (!self.paneExists(expanded)) {
                self.expanded_pane = null;
            } else {
                expanded.rect = rect;
                expanded.layout();
            }
        }
    }

    fn paneExists(self: *const Workbench, pane: *GroupPane) bool {
        for (self.part.group_views.items) |candidate| {
            if (candidate == pane) return true;
        }
        return false;
    }

    /// Removes an empty pane from the grid and the editor-group service,
    /// promoting its sibling. The last group is kept so the workbench always
    /// has a target for the next editor.
    fn collapseEmptyPane(self: *Workbench, pane: *GroupPane) void {
        if (self.expanded_pane == pane) self.expanded_pane = null;
        _ = self.part.collapseView(pane);
    }

    fn activeGroup(self: *Workbench) *editor_groups.EditorGroup {
        return self.service.activeGroup();
    }

    fn paneForGroup(self: *Workbench, group: *editor_groups.EditorGroup) ?*GroupPane {
        return self.part.viewForGroup(group);
    }

    pub fn activePane(self: *Workbench) ?*GroupPane {
        return self.part.activeView();
    }

    /// First workspace folder, used for the extension host's workspace data.
    pub fn workspaceFolderPath(self: *Workbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    pub fn activeTab(self: *Workbench) ?*Tab {
        const pane = self.activePane() orelse return null;
        return pane.activeTab();
    }

    pub fn tabCount(self: *Workbench) usize {
        var count: usize = 0;
        for (self.part.group_views.items) |pane| count += pane.tabs.items.len;
        return count;
    }

    pub fn groupCount(self: *const Workbench) usize {
        return self.service.count();
    }

    pub const OpenOptions = struct {
        /// Preview editors are replaced by the next preview in the group.
        pinned: bool = true,
    };

    /// Opens a path through the editor-groups service. If the resource is
    /// already open in another group, the service reveals that group and the
    /// newly created input is discarded.
    pub fn openPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{});
    }

    pub fn openPreviewPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{ .pinned = false });
    }

    pub fn openPathWithOptions(self: *Workbench, path: []const u8, options: OpenOptions) !void {
        const editor = try Editor.create(self.allocator, self.io, path, self.cols, self.editorContentHeight());
        errdefer {
            editor.deinit();
            self.allocator.destroy(editor);
        }
        self.applyConfiguredLanguageAssociations(editor);
        const input = try FileEditorInput.init(self.allocator, editor);
        errdefer input.deinit();

        const opened = try self.service.openEditor(
            &input.base,
            null,
            .{ .open = .{ .pinned = options.pinned, .active = true } },
        );

        const pane = self.paneForGroup(opened.group) orelse return error.GroupPaneMissing;
        if (self.autoRevealEnabled(path)) {
            if (self.sidebar) |sidebar| sidebar.revealPath(path) catch {};
        }
        if (!opened.result.is_new) {
            input.deinit();
            if (pane.tabForInput(opened.result.editor)) |tab| {
                try pane.activateTab(tab);
                try tab.ensureControllers();
                tab.view.focusEditor();
            }
            try self.history.add(path);
            self.pruneTabs(pane);
            return;
        }

        const tab = try Tab.initFromInput(self.allocator, input);
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        self.registerWorkingCopy(tab);
        try tab.ensureControllers();
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    /// Removes tab views whose input the group model no longer contains. This
    /// is needed when a preview editor is replaced by the next preview.
    fn pruneTabs(self: *Workbench, pane: *GroupPane) void {
        var index = pane.tabs.items.len;
        var removed_active = false;
        while (index > 0) {
            index -= 1;
            const tab = pane.tabs.items[index];
            if (pane.group.model.contains(.{ .input = &tab.input.base }, .{})) continue;
            if (pane.activeTab() == tab) removed_active = true;
            _ = pane.removeTab(tab);
            if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
            self.unregisterWorkingCopy(tab);
            tab.deinit();
        }
        if (removed_active) pane.syncActivePane();
    }

    fn pinDirtyPreviews(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.editor.isDirty()) continue;
                if (pane.group.model.isPinned(.{ .editor = &tab.input.base })) continue;
                _ = pane.group.model.pin(&tab.input.base) catch {};
            }
        }
    }

    pub fn activateIndex(self: *Workbench, index: usize) !void {
        const pane = self.activePane() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (index >= ordered.items.len) return;

        const tab = ordered.items[index];
        try pane.activateTab(tab);
        try tab.ensureControllers();
        self.focusEditor();
        tab.view.focusEditor();
        tab.onEditorChanged(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
        try tab.refresh();
        try self.history.add(tab.input.editor.path);
        self.revealActiveEditor();
    }

    /// Closes the tab showing `path`, if any. Used by extension tab commands.
    pub fn closePath(self: *Workbench, path: []const u8) !bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!std.mem.eql(u8, tab.editor.path, path)) continue;
                return self.closeTab(pane, tab);
            }
        }
        return false;
    }

    pub fn switchTab(self: *Workbench, delta: isize) !void {
        const pane = self.activePane() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (ordered.items.len == 0) return;

        const current: isize = @intCast(pane.activeIndex(ordered.items));
        const count: isize = @intCast(ordered.items.len);
        const next: isize = @mod(current + delta, count);
        try self.activateIndex(@intCast(next));
    }

    pub fn switchGroup(self: *Workbench, delta: isize) !void {
        self.expanded_pane = null;
        const groups = try self.service.getGroups(self.allocator, .CREATION_TIME);
        defer self.allocator.free(groups);
        if (groups.len <= 1) return;

        const current = for (groups, 0..) |group, index| {
            if (group == self.service.activeGroup()) break index;
        } else 0;

        const count: isize = @intCast(groups.len);
        var offset: isize = 1;
        while (offset <= count) : (offset += 1) {
            const next_index: usize = @intCast(@mod(@as(isize, @intCast(current)) + delta * offset, count));
            const candidate = groups[next_index];
            if (candidate == self.service.activeGroup()) continue;
            const pane = self.paneForGroup(candidate) orelse continue;
            if (pane.tabs.items.len == 0) continue;
            self.service.activateGroup(candidate);
            pane.syncActivePane();
            if (self.activeTab()) |tab| try tab.ensureControllers();
            self.revealActiveEditor();
            return;
        }
    }

    /// Splits the active group and moves the active tab into the new group.
    pub fn splitActive(self: *Workbench, direction: SplitDirection) !void {
        self.part.active_sash = null;
        self.expanded_pane = null;
        self.clearTabDrag();
        const source = self.activePane() orelse return;
        const tab = source.activeTab() orelse return;

        const new_pane = try self.part.splitGroup(source, direction, false);

        _ = try source.group.model.closeEditor(&tab.input.base, .MOVE, false);
        _ = source.removeTab(tab);
        source.syncActivePane();
        _ = try new_pane.group.model.openEditor(&tab.input.base, .{ .pinned = true, .active = true });
        try new_pane.addTab(tab);

        self.layoutAll();
        if (self.activeTab()) |active| {
            try active.ensureControllers();
            try active.refresh();
        }
    }

    pub fn closeActive(self: *Workbench) !bool {
        self.part.active_sash = null;
        self.clearTabDrag();
        const pane = self.activePane() orelse return false;
        const tab = pane.activeTab() orelse return false;
        return self.closeTab(pane, tab);
    }

    /// Closes `tab` from `pane`, applying the dirty-close arming rule and the
    /// empty-pane collapse. Used by Ctrl-W, the tab close cell and middle click.
    fn closeTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !bool {
        if (!tab.editor.requestCloseTab()) return false;

        _ = try pane.group.model.closeEditor(&tab.input.base, .UNKNOWN, true);
        _ = pane.removeTab(tab);
        pane.syncActivePane();
        if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
        self.unregisterWorkingCopy(tab);
        tab.deinit();

        if (self.tabCount() == 0) return false;

        if (self.expanded_pane == pane and pane.tabs.items.len == 0) self.expanded_pane = null;

        if (pane.tabs.items.len == 0) {
            const groups = try self.service.getGroups(self.allocator, .MOST_RECENTLY_ACTIVE);
            defer self.allocator.free(groups);
            var next_group: ?*editor_groups.EditorGroup = null;
            for (groups) |group| {
                if (group == pane.group) continue;
                const candidate = self.paneForGroup(group) orelse continue;
                if (candidate.tabs.items.len == 0) continue;
                next_group = group;
                break;
            }

            // Collapse the empty group out of the grid when another group can
            // take focus; the last group stays so the workbench keeps a view.
            if (next_group) |group| {
                self.service.activateGroup(group);
                self.collapseEmptyPane(pane);
            }
        }

        if (self.activeTab()) |active| {
            try active.ensureControllers();
        }
        return false;
    }

    /// Upstream `toggleExpandGroup`: the group temporarily occupies the whole
    /// editor area; its siblings keep their grid rects and return unchanged
    /// when the expanded group is toggled off.
    fn toggleExpandGroup(self: *Workbench, pane: *GroupPane) void {
        if (self.expanded_pane == pane) {
            self.expanded_pane = null;
        } else {
            self.service.activateGroup(pane.group);
            pane.syncActivePane();
            self.expanded_pane = pane;
        }
        self.layoutAll();
        self.breadcrumbs_dirty = true;
    }

    fn ensureGlobalService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.global_service) |service| return service;
        const service = try keybinding_service.KeybindingService.init(self.allocator, &global_keybinding_rules, .{ .context = self, .execute = executeGlobalCommand });
        self.global_service = service;
        return service;
    }

    /// Workbench-global shortcuts through the abstract keybinding service.
    /// Skipped while quick access owns the keyboard so Ctrl+P keeps cycling
    /// the open picker.
    pub fn handleGlobalKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (self.quick_access.isOpen()) return false;
        const service = try self.ensureGlobalService();
        return service.dispatch(event.*);
    }

    fn ensureTabService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.tab_service) |service| return service;
        const service = try keybinding_service.KeybindingService.init(self.allocator, &tab_keybinding_rules, .{
            .context = self,
            .execute = executeTabCommand,
        });
        self.tab_service = service;
        return service;
    }

    fn runTabCommand(self: *Workbench, command: []const u8) !?TabKeyResult {
        if (std.mem.eql(u8, command, "workbench.action.closeActiveEditor")) {
            return if (try self.closeActive()) .quit else .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.nextEditor")) {
            try self.switchTab(1);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.previousEditor")) {
            try self.switchTab(-1);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.focusLeftGroup")) {
            try self.switchGroup(-1);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.focusRightGroup")) {
            try self.switchGroup(1);
            return .handled;
        }
        if (std.mem.startsWith(u8, command, "workbench.action.openEditorAtIndex")) {
            const digit = command[command.len - 1];
            if (digit >= '1' and digit <= '9') {
                try self.activateIndex(digit - '1');
                return .handled;
            }
        }
        return null;
    }

    pub fn handleTabKey(self: *Workbench, event: *const ui.KeyEvent) !TabKeyResult {
        self.tab_command_result = null;
        const service = try self.ensureTabService();
        if (service.dispatch(event.*)) {
            if (self.tab_command_result) |result| return result;
            return .handled;
        }

        if (isCtrlChar(event, 'w')) {
            return if (try self.closeActive()) .quit else .handled;
        }

        if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
            switch (event.key) {
                .char => |ch| {
                    if (ch == '\\') {
                        try self.splitActive(.horizontal);
                        return .handled;
                    }
                },
                else => {},
            }
        }
        if (event.mods.alt and event.mods.shift and !event.mods.ctrl) {
            switch (event.key) {
                .char => |ch| {
                    if (ch == '|' or ch == '\\') {
                        try self.splitActive(.vertical);
                        return .handled;
                    }
                },
                else => {},
            }
        }

        if (event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .page_up => {
                    try self.switchTab(-1);
                    return .handled;
                },
                .page_down => {
                    try self.switchTab(1);
                    return .handled;
                },
                else => {},
            }
        }

        if (event.mods.ctrl and event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .left => {
                    try self.switchGroup(-1);
                    return .handled;
                },
                .right => {
                    try self.switchGroup(1);
                    return .handled;
                },
                else => {},
            }
        }

        if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
            switch (event.key) {
                .char => |ch| {
                    if (ch >= '1' and ch <= '9') {
                        try self.activateIndex(ch - '1');
                        return .handled;
                    }
                },
                else => {},
            }
        }

        return .unhandled;
    }

    pub fn hasDirtyTabs(self: *const Workbench) bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor.isDirty()) return true;
            }
        }
        return false;
    }

    pub fn requestQuit(self: *Workbench) bool {
        if (!self.hasDirtyTabs()) return true;
        if (self.quit_armed) return true;

        self.quit_armed = true;
        if (self.activeTab()) |tab| {
            tab.editor.setMessage("Unsaved changes: Ctrl-Q again to quit, Ctrl-S to save", .{});
        }
        return false;
    }

    pub fn clearQuitArmed(self: *Workbench) void {
        self.quit_armed = false;
    }

    fn paneAt(self: *Workbench, x: usize, y: usize) ?*GroupPane {
        if (self.expanded_pane) |pane| {
            if (x >= ui.cell.snap(pane.rect.x) and x < ui.cell.snap(pane.rect.right()) and
                y >= ui.cell.snap(pane.rect.y) and y < ui.cell.snap(pane.rect.bottom()))
            {
                return pane;
            }
            return null;
        }
        return self.part.viewAt(x, y);
    }

    /// Starts, updates and ends a sash drag. Called before tab and editor mouse
    /// handling; a drag consumes every event until the button is released.
    pub fn handleSashMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.expanded_pane != null) return false;
        if (self.drag_tab != null or self.pending_tab_drag != null) return false;
        if (self.part.active_sash) |split| {
            switch (event.kind) {
                .move => {
                    // Upstream's sash owns pointer capture, so motion while
                    // the boundary is grabbed resizes it. Some terminals and
                    // multiplexers report that motion without the held button
                    // bits; relying on them here would drop the drag. A lost
                    // release is healed by the next down or up event.
                    self.part.resizeSash(split, event.x, event.y);
                    return true;
                },
                .up, .click => {
                    self.part.resizeSash(split, event.x, event.y);
                    self.part.active_sash = null;
                    return true;
                },
                .down => return true,
                .wheel => return false,
            }
        }

        if (self.quick_access.isOpen()) return false;
        if (event.kind != .down or event.button != .left) {
            // Keep the editor from treating a click on the sash as a caret
            // placement; hover motion over the line is also consumed.
            return event.kind != .wheel and self.part.dividerAt(event.x, event.y) != null;
        }

        const split = self.part.dividerAt(event.x, event.y) orelse return false;
        self.part.active_sash = split;
        return true;
    }

    fn orderedTabAt(self: *Workbench, pane: *GroupPane, index: usize) ?*Tab {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        pane.orderedTabs(self.allocator, &ordered) catch return null;
        if (index >= ordered.items.len) return null;
        return ordered.items[index];
    }

    /// Called before the sash, overlay and editor routing so a live tab drag
    /// owns the pointer for its whole gesture, even across pane boundaries.
    pub fn handleTabDragMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.expanded_pane != null) return false;
        if (self.drag_tab == null) return false;
        switch (event.kind) {
            .move => self.updateDragTarget(event),
            .up => {
                self.finishTabDrag();
                return true;
            },
            .click => {
                self.clearTabDrag();
                return true;
            },
            .down => {
                // A second press during a pending drag is often the second
                // half of a double click (hand jitter starts the drag). Let
                // the tab strip handle it so the preview can be pinned.
                self.clearTabDrag();
                return false;
            },
            .wheel => return false,
        }
        return true;
    }

    fn clearTabDrag(self: *Workbench) void {
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
    }

    fn updateDragTarget(self: *Workbench, event: *const ui.MouseEvent) void {
        self.drag_target = null;
        const pane = self.paneAt(event.x, event.y) orelse return;
        const zone = editor_drop_target.zoneAt(pane.rect, event.x, event.y) orelse return;
        self.drag_target = .{ .pane = pane, .zone = zone };
    }

    fn finishTabDrag(self: *Workbench) void {
        const tab = self.drag_tab;
        const source = self.drag_source_pane;
        const target = self.drag_target;
        self.clearTabDrag();
        if (tab == null or source == null or target == null) return;
        self.dropTab(source.?, tab.?, target.?.pane, target.?.zone) catch |err| {
            if (self.activeTab()) |active| {
                active.editor.setMessage("tile: {s}", .{@errorName(err)});
            }
        };
    }

    fn moveTabToPane(self: *Workbench, source: *GroupPane, dest: *GroupPane, tab: *Tab) !void {
        _ = try source.group.model.closeEditor(&tab.input.base, .MOVE, false);
        _ = source.removeTab(tab);
        source.syncActivePane();
        _ = try dest.group.model.openEditor(&tab.input.base, .{ .pinned = true, .active = true });
        try dest.addTab(tab);
        self.service.activateGroup(dest.group);
        try tab.ensureControllers();
        tab.view.focusEditor();
        self.focus = .editor;
    }

    fn dropTab(self: *Workbench, source: *GroupPane, tab: *Tab, target: *GroupPane, zone: DropZone) !void {
        if (zone == .center) {
            if (source == target) return;
            // The target group may already show this input; moving would
            // create a second Tab for one model.
            if (target.tabForInput(&tab.input.base) != null) return;
            try self.moveTabToPane(source, target, tab);
            self.collapseEmptyPane(source);
            self.layoutAll();
            return;
        }

        const direction: SplitDirection = editor_drop_target.orientation(zone);
        const new_first = editor_drop_target.newFirst(zone);

        // Insert before collapsing the source: if source and target are
        // siblings, collapsing first would promote and destroy the target leaf.
        const new_pane = try self.part.splitGroup(target, direction, new_first);
        try self.moveTabToPane(source, new_pane, tab);

        self.collapseEmptyPane(source);
        self.layoutAll();
    }

    fn renderDropTarget(self: *Workbench, target: DropTarget) void {
        if (!self.part.cell_borders) return;
        const stroke = ui.cell_border.Stroke{
            .width = 64,
            .color = .{ .rgb = .{ .r = 0xe5, .g = 0xc0, .b = 0x7b } },
            .placement = .centered,
            .layer = .above_text,
            .priority = 3,
        };
        const rect = target.pane.rect;
        const x0 = ui.cell.snap(rect.x);
        const y0 = ui.cell.snap(rect.y);
        const x1 = ui.cell.snap(rect.right());
        const y1 = ui.cell.snap(rect.bottom());
        if (x1 <= x0 or y1 <= y0) return;
        var col = x0;
        while (col < x1) : (col += 1) {
            self.frame.next.addBorder(col, y0, ui.cell_border.Segment.top, stroke);
            self.frame.next.addBorder(col, y1 - 1, ui.cell_border.Segment.bottom, stroke);
        }
        var row = y0;
        while (row < y1) : (row += 1) {
            self.frame.next.addBorder(x0, row, ui.cell_border.Segment.left, stroke);
            self.frame.next.addBorder(x1 - 1, row, ui.cell_border.Segment.right, stroke);
        }
    }

    /// Routes pointer input on the workbench status row. The row is outside
    /// every editor pane, so it is handled before sash/sidebar/editor routing.
    pub fn handleStatusbarMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (!self.statusBarVisible()) return false;
        const rect = self.statusBarRect();
        const part = self.statusbar.main_part;
        if (event.y != ui.cell.snap(rect.y)) {
            if (event.kind == .move) part.clearHover();
            return false;
        }
        switch (event.kind) {
            .move => {
                const hit = part.hitAt(event.x, event.y) catch null;
                if (hit) |value| {
                    switch (value) {
                        .entry => |handle| part.setHovered(handle),
                        .part => part.clearHover(),
                    }
                } else {
                    part.clearHover();
                }
                self.leaveEditorHover();
                return true;
            },
            .down => {
                self.leaveEditorHover();
                part.clearHover();
                self.focusStatusBar();
                if (part.hitAt(event.x, event.y) catch null) |hit| {
                    switch (hit) {
                        .entry => |handle| {
                            part.setFocused(handle);
                            _ = part.executeEntry(handle) catch |err| {
                                if (self.activeTab()) |tab| {
                                    tab.editor.setMessage("status bar: {s}", .{@errorName(err)});
                                }
                            };
                        },
                        .part => part.clearFocus(),
                    }
                } else {
                    part.clearFocus();
                }
                return true;
            },
            .up, .click, .wheel => return true,
        }
    }

    fn ensureStatusbarService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.statusbar_service) |service| return service;
        const service = try keybinding_service.KeybindingService.init(self.allocator, &statusbar_keybinding_rules, .{
            .context = self,
            .execute = executeStatusbarKeyCommand,
        });
        self.statusbar_service = service;
        return service;
    }

    fn runStatusbarCommand(self: *Workbench, command: []const u8) bool {
        const part = self.statusbar.main_part;
        if (std.mem.eql(u8, command, "workbench.action.statusbar.focusPreviousEntry")) {
            _ = part.focusPreviousEntry();
            return true;
        }
        if (std.mem.eql(u8, command, "workbench.action.statusbar.focusNextEntry")) {
            _ = part.focusNextEntry();
            return true;
        }
        if (std.mem.eql(u8, command, "workbench.action.statusbar.focusFirstEntry")) {
            _ = part.focusFirstEntry();
            return true;
        }
        if (std.mem.eql(u8, command, "workbench.action.statusbar.focusLastEntry")) {
            _ = part.focusLastEntry();
            return true;
        }
        if (std.mem.eql(u8, command, "workbench.action.statusbar.executeFocused")) {
            _ = part.executeFocused() catch |err| {
                if (self.activeTab()) |tab| {
                    tab.editor.setMessage("status bar: {s}", .{@errorName(err)});
                }
            };
            return true;
        }
        if (std.mem.eql(u8, command, "workbench.action.statusbar.escapeFocus")) {
            if (part.focusedHandle() != null) {
                part.clearFocus();
            } else {
                self.focusEditor();
            }
            return true;
        }
        return false;
    }

    /// Keyboard input while the status bar owns focus. `Ctrl-Alt-S` is a
    /// TUI-specific shortcut for the upstream `focusStatusBar` command because
    /// the TUI does not port F6 part navigation.
    pub fn handleStatusbarKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (event.mods.ctrl and event.mods.alt and !event.mods.shift) {
            if (event.key == .char and (event.key.char == 's' or event.key.char == 'S')) {
                if (self.focus == .statusbar) {
                    self.focusEditor();
                } else {
                    self.focusStatusBar();
                }
                return true;
            }
        }
        if (self.focus != .statusbar) return false;

        const service = self.ensureStatusbarService() catch null;
        if (service) |host| {
            if (host.dispatch(event.*)) return true;
        }

        const part = self.statusbar.main_part;
        switch (event.key) {
            .left, .up => _ = part.focusPreviousEntry(),
            .right, .down => _ = part.focusNextEntry(),
            .home => _ = part.focusFirstEntry(),
            .end => _ = part.focusLastEntry(),
            .escape => {
                if (part.focusedHandle() != null) {
                    part.clearFocus();
                } else {
                    self.focusEditor();
                }
            },
            .enter => {
                _ = part.executeFocused() catch |err| {
                    if (self.activeTab()) |tab| {
                        tab.editor.setMessage("status bar: {s}", .{@errorName(err)});
                    }
                };
            },
            .char => |ch| {
                if (ch == ' ') {
                    _ = part.executeFocused() catch |err| {
                        if (self.activeTab()) |tab| {
                            tab.editor.setMessage("status bar: {s}", .{@errorName(err)});
                        }
                    };
                }
            },
            else => {},
        }
        return true;
    }

    pub fn clearStatusHover(self: *Workbench) void {
        self.statusbar.main_part.clearHover();
    }

    pub fn leaveEditorHover(self: *Workbench) void {
        if (self.activeTab()) |tab| {
            if (tab.controllers) |controllers| controllers.hover.hideContentHover();
        }
    }

    pub fn handleSidebarKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (isCtrlChar(event, 'b')) {
            try self.toggleSidebar();
            return true;
        }

        // A normal terminal cannot distinguish Ctrl-Shift-F from Ctrl-F, so
        // the TUI exposes Find in Files as Alt-F.
        if (event.mods.alt and !event.mods.ctrl and !event.mods.shift and event.key == .char) {
            const ch = event.key.char;
            if (ch == 'f' or ch == 'F') {
                try self.showActivity(1);
                if (self.search_view) |view| {
                    view.seedFromSelection() catch {};
                    view.focus();
                }
                return true;
            }
        }

        if (self.focus != .sidebar or !self.sidebarShown()) return false;

        if (event.key == .escape) {
            self.focusEditor();
            if (self.activeTab()) |tab| tab.view.focusEditor();
            return true;
        }

        if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
            switch (event.key) {
                .char => |ch| {
                    if (ch >= '1' and ch <= '9') {
                        try self.showActivity(ch - '1');
                        return true;
                    }
                },
                else => {},
            }
        }

        const active_id = self.activity_bar_part.active_id orelse "";
        if (std.mem.eql(u8, active_id, "search")) {
            if (self.search_view) |view| {
                switch (view.handleKey(event)) {
                    .handled => return true,
                    .focus_editor => {
                        self.focusEditor();
                        if (self.activeTab()) |tab| tab.view.focusEditor();
                        return true;
                    },
                    .unhandled => return true,
                }
            }
            return true;
        }

        if (!std.mem.eql(u8, active_id, "explorer")) {
            const current = self.activeActivity();
            if (event.key == .up) try self.showActivity(self.activity_bar_part.next(current, -1));
            if (event.key == .down) try self.showActivity(self.activity_bar_part.next(current, 1));
            return true;
        }

        if (self.sidebar == null) return false;
        switch (try self.sidebar.?.handleKey(event)) {
            .open => |path| {
                try self.openPath(path);
                self.focus = .editor;
                return true;
            },
            .handled, .none => return true,
        }
    }

    pub fn handleSidebarMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (!self.sidebarShown()) return false;

        if (event.x < self.activityBarWidth()) {
            if (event.kind == .down) {
                if (activity_bar_mod.hitAt(&self.activity_bar_part, event.x, event.y, self.activityRect())) |index| {
                    self.showActivity(index) catch {};
                }
            }
            return true;
        }

        if (event.x > self.activityBarWidth() + self.sidebarWidth()) return false;
        if (event.kind == .down) self.focus = .sidebar;
        const active_id = self.activity_bar_part.active_id orelse "";
        if (std.mem.eql(u8, active_id, "search")) {
            if (self.search_view) |view| _ = view.handleMouse(event);
            return true;
        }
        if (!std.mem.eql(u8, active_id, "explorer")) return true;

        const sidebar = self.sidebar orelse return false;
        if (event.kind == .wheel) {
            _ = sidebar.handleMouse(event);
            return true;
        }
        if (event.kind == .down) {
            if (sidebar.handleClickPreview(event.x, event.y) catch null) |path| {
                self.openPreviewPath(path) catch {};
                self.focus = .editor;
            }
        }
        return true;
    }

    pub fn handleTabMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.sidebarShown() and event.x <= self.activityBarWidth() + self.sidebarWidth()) return false;

        if (self.pending_tab_drag) |pending| {
            if (event.kind == .move and event.button == .left and
                (event.x -| pending.x) + (event.y -| pending.y) >= 3)
            {
                self.drag_tab = pending.tab;
                self.drag_source_pane = pending.pane;
                self.pending_tab_drag = null;
                self.updateDragTarget(event);
                return true;
            }
            if (event.kind == .up or event.kind == .click) self.pending_tab_drag = null;
        }

        const pane = self.paneAt(event.x, event.y) orelse {
            self.clearTabHover();
            return false;
        };
        const pane_y = ui.cell.snap(pane.rect.y);
        const breadcrumb_y = pane_y + editor_group_view.title_height;

        // Hover tracking on the tab row and the breadcrumb row.
        if (event.kind == .move) {
            if (event.y == pane_y) {
                self.hovered_pane = pane;
                if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                    self.hovered_tab = self.orderedTabAt(pane, index);
                } else {
                    self.hovered_tab = null;
                }
                return true;
            }
            self.clearTabHover();
            if (self.breadcrumbsEnabled() and event.y == breadcrumb_y and self.activePane() == pane) {
                if (self.ensureBreadcrumbsControl(pane)) |control| {
                    control.hover(event.x);
                    return true;
                } else |_| {}
            }
            return false;
        }

        if (event.kind == .down) {
            self.pending_tab_drag = null;
            if (event.y == pane_y) {
                self.focusEditor();
            }
        }

        if (event.y == breadcrumb_y and self.breadcrumbsEnabled()) {
            if (event.kind == .down and pane.tabs.items.len > 0) {
                self.service.activateGroup(pane.group);
                self.focus = .breadcrumbs;
                self.statusbar.main_part.clearFocus();
                if (self.search_view) |view| view.blur();
                if (self.ensureBreadcrumbsControl(pane)) |control| {
                    control.setFocused(true);
                    // Populate the hit rectangles before handling the click;
                    // the inactive pane's row was painted by a short-lived
                    // control whose hits are gone.
                    control.draw(&self.frame.next, .{
                        .x = pane.rect.x,
                        .y = @floatFromInt(breadcrumb_y),
                        .w = pane.rect.w,
                        .h = 1,
                    }, true) catch {};
                    _ = control.click(event.x) catch {};
                    self.breadcrumbs_dirty = true;
                } else |_| {}
            }
            return true;
        }

        if (event.y != pane_y) {
            if (pane.tabs.items.len > 0 and event.kind == .down) {
                self.service.activateGroup(pane.group);
            }
            return false;
        }

        if (event.kind == .down and pane.tabs.items.len > 0) {
            self.service.activateGroup(pane.group);

            // A double click is matched against the rectangle the first click
            // recorded. Activating a partially visible tab can scroll the
            // strip, so the second cell may now belong to a different tab.
            const now = @import("../vs/base/common/timeCompat.zig").milliTimestamp();
            if (event.button == .left) {
                if (self.last_tab_click) |previous| {
                    if (previous.pane == pane and event.y == previous.y and
                        event.x >= previous.start and event.x < previous.end and
                        now - previous.at_ms <= 800 and
                        pane.indexOfTab(previous.tab) != null)
                    {
                        self.last_tab_click = null;
                        // Upstream: double click pins a preview tab; a pinned
                        // tab toggles the group size (default: expand).
                        if (pane.group.model.isPinned(.{ .editor = &previous.tab.input.base })) {
                            self.toggleExpandGroup(pane);
                        } else {
                            _ = pane.group.model.pin(&previous.tab.input.base) catch {};
                        }
                        self.focusEditor();
                        self.breadcrumbs_dirty = true;
                        return true;
                    }
                }
            }

            if (event.button == .middle) {
                if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                    if (self.orderedTabAt(pane, index)) |tab| {
                        _ = self.closeTab(pane, tab) catch {};
                    }
                }
                return true;
            }
            if (tab_bar.closeHitAt(pane.hits.items, event.x)) |index| {
                if (self.orderedTabAt(pane, index)) |tab| {
                    _ = self.closeTab(pane, tab) catch {};
                }
                return true;
            }
            if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                const tab = self.orderedTabAt(pane, index);
                var recorded_hit: ?tab_bar.Hit = null;
                if (tab != null and event.button == .left) {
                    recorded_hit = for (pane.hits.items) |candidate| {
                        if (candidate.index == index) break candidate;
                    } else null;
                }
                self.activateIndex(index) catch {};
                if (tab) |value| {
                    // Timestamp after activation: creating controllers or
                    // revealing a large file can take long enough that the
                    // second press would otherwise fall outside the window.
                    if (recorded_hit) |entry| {
                        self.last_tab_click = .{
                            .pane = pane,
                            .tab = value,
                            .at_ms = @import("../vs/base/common/timeCompat.zig").milliTimestamp(),
                            .x = event.x,
                            .y = event.y,
                            .start = entry.start,
                            .end = entry.end,
                        };
                    }
                    self.pending_tab_drag = .{
                        .pane = pane,
                        .tab = value,
                        .x = event.x,
                        .y = event.y,
                    };
                }
            }
        }
        return true;
    }

    fn clearTabHover(self: *Workbench) void {
        self.hovered_tab = null;
        self.hovered_pane = null;
        if (self.breadcrumbs_control) |control| control.clearHover();
    }

    /// Converts a terminal mouse position inside a pane into editor-relative
    /// coordinates, or null when the event belongs to a tab row.
    pub fn editorMouseEvent(self: *Workbench, event: ui.MouseEvent) ?ui.MouseEvent {
        if (self.sidebarShown() and event.x <= self.activityBarWidth() + self.sidebarWidth()) return null;
        const pane = self.paneAt(event.x, event.y) orelse return null;
        if (pane.group != self.service.activeGroup()) return null;
        const y = ui.cell.snap(pane.rect.y);
        const chrome = pane.chromeHeight();
        if (event.y >= y and event.y < y + chrome) return null;
        if (pane.activeTab() == null) return null;

        var adjusted = event;
        adjusted.x -|= ui.cell.snap(pane.rect.x);
        adjusted.y -|= y + chrome;
        return adjusted;
    }

    /// Publishes the search result count as the Search activity badge. This
    /// is the first live activity-service badge source in the terminal
    /// workbench; view containers without a source have no badge.
    fn syncSearchActivity(self: *Workbench) void {
        const count = if (self.search_view) |view| view.matchCount() else 0;
        if (self.search_badge_count == count) return;
        self.search_badge_count = count;
        if (count == 0) {
            self.activity_service.removeActivity("search", "search.results");
            return;
        }
        const text = std.fmt.bufPrint(&self.search_badge_buf, "{d}", .{count}) catch "?";
        self.activity_service.setViewContainerActivity("search", .{
            .id = "search.results",
            .badge = .{ .description = text },
        }) catch {};
    }

    /// Rebuilds every status-bar entry from the active editor. Values use the
    /// upstream editor-status labels; the standard entries keep their
    /// quick-picker commands so a click opens the same action as upstream.
    pub fn refreshStatus(self: *Workbench) void {
        self.pinDirtyPreviews();
        const target = if (self.activeTab()) |tab| tab.editor.statusTarget() else null;
        if (self.editor_status) |status| {
            status.update(target) catch {};
        }
    }

    pub fn render(self: *Workbench, writer: *std.Io.Writer) !void {
        self.syncSearchActivity();
        self.frame.begin();

        if (self.sidebarShown()) {
            const focused = self.focus == .sidebar;
            activity_bar_mod.render(&self.activity_bar_part, &self.activity_service, &self.frame.next, self.activityRect(), self.activeActivity(), focused);
            const active_id = self.activity_bar_part.active_id orelse "";
            if (std.mem.eql(u8, active_id, "explorer")) {
                if (self.sidebar) |sidebar| {
                    try sidebar.render(&self.frame.next, self.sidebarRect(), focused);
                }
            } else if (std.mem.eql(u8, active_id, "search")) {
                if (self.search_view) |view| {
                    try view.render(&self.frame.next, self.sidebarRect());
                }
            } else {
                self.renderPlaceholder(self.sidebarRect(), focused);
            }

            const divider_x = self.activityBarWidth() + self.sidebarWidth();
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
            };
            var row: usize = 0;
            while (row < self.editorRows()) : (row += 1) {
                self.frame.next.putCodepoint(divider_x, row, '│', 1, style);
            }
        }

        if (self.expanded_pane) |expanded| {
            if (self.paneExists(expanded)) {
                try self.renderPane(expanded);
                if (self.part.cell_borders) self.renderPaneBorder(expanded);
            } else {
                self.expanded_pane = null;
            }
        }
        if (self.expanded_pane == null) {
            for (self.part.group_views.items) |pane| {
                try self.renderPane(pane);
            }
            if (self.part.cell_borders) {
                // Each pane is outlined on its own cell edges. Adjacent panes put
                // strokes on opposite cells of the shared boundary and the
                // terminal merges them into one line, so no gutter is needed.
                for (self.part.group_views.items) |pane| self.renderPaneBorder(pane);
                if (self.drag_target) |target| self.renderDropTarget(target);
            } else {
                self.renderDividers(self.part.root);
            }
        }
        if (self.statusBarVisible()) {
            try self.statusbar.main_part.render(&self.frame.next, self.statusBarRect(), .{
                .no_folder = self.workspace.getWorkbenchState() == .EMPTY,
                .part_focused = self.focus == .statusbar,
            });
        }
        try self.quick_access.render(&self.frame.next);

        const encoded = try ui.ansi.encode(
            self.allocator,
            if (self.frame.have_prev) &self.frame.prev else null,
            &self.frame.next,
            .{ .synchronized = true },
        );
        defer self.allocator.free(encoded);
        if (encoded.len > 0) try writer.writeAll(encoded);

        self.frame.swap();
    }

    fn renderPane(self: *Workbench, pane: *GroupPane) !void {
        const x = ui.cell.snap(pane.rect.x);
        const y = ui.cell.snap(pane.rect.y);
        const width = ui.cell.snap(pane.rect.w);
        const height = ui.cell.snap(pane.rect.h);
        if (width == 0 or height == 0) return;

        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);

        const infos = try self.allocator.alloc(tab_bar.TabInfo, ordered.items.len);
        defer self.allocator.free(infos);
        for (ordered.items, 0..) |tab, index| {
            infos[index] = .{
                .label = tab.input.base.getName(),
                .language = tab.editor.languageId(),
                .dirty = tab.input.base.isDirty(),
                .pinned = pane.group.model.isPinned(.{ .editor = &tab.input.base }),
                .sticky = pane.group.model.isSticky(.{ .editor = &tab.input.base }),
                .closeable = !tab.input.base.hasCapability(editor_mod.EditorInputCapabilities.CannotClose),
            };
        }

        const active_group = pane.group == self.service.activeGroup();
        var hovered_index: ?usize = null;
        if (self.hovered_pane == pane and self.hovered_tab != null) {
            for (ordered.items, 0..) |tab, index| {
                if (tab == self.hovered_tab.?) {
                    hovered_index = index;
                    break;
                }
            }
        }
        try tab_bar.draw(
            &self.frame.next,
            infos,
            pane.activeIndex(ordered.items),
            x,
            y,
            width,
            &pane.hits,
            .{ .group_active = active_group, .hovered = hovered_index },
        );

        const chrome = pane.chromeHeight();
        if (chrome > height) return;
        if (chrome > editor_group_view.title_height) {
            try self.renderBreadcrumbs(pane, x, y + editor_group_view.title_height, width, active_group);
        }
        if (pane.activeTab()) |active| {
            try active.view.paint();
            ui.CellGrid.blit(
                &self.frame.next,
                active.view.grid(),
                x,
                y + chrome,
                width,
                height -| chrome,
            );
        }
    }

    fn renderPlaceholder(self: *Workbench, rect: ui.Rect, focused: bool) void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const bg = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
            .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }),
        };
        const header = if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) " SEARCH " else " SETTINGS ";
        const title = "Settings view is not ported yet";
        self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), bg);
        const header_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 220, .g = 220, .b = 220 }),
            .bg = ui.cell.packColor(.{ .r = 38, .g = 38, .b = 42 }),
        };
        self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, header_style);
        drawPlainText(&self.frame.next, x + 1, y, width - 2, header, header_style);
        drawPlainText(&self.frame.next, x + 2, y + 2, width -| 3, title, bg);
        _ = focused;
    }

    fn renderDividers(self: *Workbench, node: *LayoutNode) void {
        switch (node.kind) {
            .leaf => {},
            .split => |split| {
                const style = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
                };
                if (split.direction == .horizontal) {
                    const x = ui.cell.snap(split.first.rect.right());
                    var y = ui.cell.snap(split.first.rect.y);
                    const bottom = ui.cell.snap(split.first.rect.bottom());
                    while (y < bottom) : (y += 1) {
                        self.frame.next.putCodepoint(x, y, '│', 1, style);
                    }
                } else {
                    const y = ui.cell.snap(split.first.rect.bottom());
                    var x = ui.cell.snap(split.first.rect.x);
                    const right = ui.cell.snap(split.first.rect.right());
                    while (x < right) : (x += 1) {
                        self.frame.next.putCodepoint(x, y, '─', 1, style);
                    }
                }
                self.renderDividers(split.first);
                self.renderDividers(split.second);
            },
        }
    }

    /// Article-style pane chrome: a full outline around the pane's border box
    /// (tab row and editor content). The active pane uses the focus colour with
    /// priority 1, so a supporting terminal keeps its outline on shared edges
    /// regardless of neighbour order; inactive panes stay dim.
    fn renderPaneBorder(self: *Workbench, pane: *GroupPane) void {
        const active = self.focus == .editor and pane.group == self.service.activeGroup();
        const stroke = ui.cell_border.Stroke{
            .width = pane_border_width,
            .color = .{ .rgb = if (active) active_pane_border else inactive_pane_border },
            .placement = .centered,
            .layer = .below_text,
            .priority = if (active) 1 else 0,
        };
        const rect = pane.rect;
        const x0 = ui.cell.snap(rect.x);
        const y0 = ui.cell.snap(rect.y);
        const x1 = ui.cell.snap(rect.right());
        const y1 = ui.cell.snap(rect.bottom());
        if (x1 <= x0 or y1 <= y0) return;

        var col = x0;
        while (col < x1) : (col += 1) {
            self.frame.next.addBorder(col, y0, ui.cell_border.Segment.top, stroke);
            self.frame.next.addBorder(col, y1 - 1, ui.cell_border.Segment.bottom, stroke);
        }
        var row = y0;
        while (row < y1) : (row += 1) {
            self.frame.next.addBorder(x0, row, ui.cell_border.Segment.left, stroke);
            self.frame.next.addBorder(x1 - 1, row, ui.cell_border.Segment.right, stroke);
        }
    }

    fn disposeBreadcrumbs(self: *Workbench) void {
        if (self.breadcrumbs_control) |control| {
            control.deinit();
            self.breadcrumbs_control = null;
        }
        if (self.breadcrumbs_registration) |registration| {
            registration.dispose();
            self.breadcrumbs_registration = null;
        }
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_group = null;
    }

    fn applyBreadcrumbsSettings(self: *Workbench) void {
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        if (self.breadcrumbs_control) |control| {
            control.setSettings(self.breadcrumbs_settings) catch {};
        }
        if (!self.breadcrumbs_settings.enabled) self.disposeBreadcrumbs();
        self.layoutAll();
        self.breadcrumbs_dirty = true;
    }

    fn ensureBreadcrumbsControl(self: *Workbench, pane: *GroupPane) !*BreadcrumbsControl {
        const tab = pane.activeTab() orelse return error.NoActiveTab;
        if (self.breadcrumbs_control) |control| {
            if (self.breadcrumbs_pane == pane and self.breadcrumbs_input == tab.editorInput()) {
                if (self.breadcrumbs_group != pane.group.id) {
                    if (self.breadcrumbs_registration) |registration| registration.dispose();
                    self.breadcrumbs_registration = null;
                    control.setGroup(pane.group.id);
                    self.breadcrumbs_registration = try self.breadcrumbs_service.register(pane.group.id, control);
                    self.breadcrumbs_group = pane.group.id;
                }
                return control;
            }
            self.disposeBreadcrumbs();
        }
        self.breadcrumbs_host_context = .{ .workbench = self, .pane = pane };
        const control = try BreadcrumbsControl.init(
            self.allocator,
            breadcrumbHost(&self.breadcrumbs_host_context),
            self.workspace,
            self.configuration,
            &self.outline_service,
        );
        errdefer control.deinit();
        control.setGroup(pane.group.id);
        const registration = try self.breadcrumbs_service.register(pane.group.id, control);
        self.breadcrumbs_control = control;
        self.breadcrumbs_pane = pane;
        self.breadcrumbs_input = tab.editorInput();
        self.breadcrumbs_group = pane.group.id;
        self.breadcrumbs_registration = registration;
        return control;
    }

    fn renderBreadcrumbs(self: *Workbench, pane: *GroupPane, x: usize, y: usize, width: usize, active_group: bool) !void {
        if (!self.breadcrumbsEnabled() or width == 0) return;
        const row_background = ui.cell.PaintStyle{
            .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
        };
        self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, row_background);
        if (pane.activeTab() == null) return;

        const is_active_pane = self.activePane() == pane;
        if (is_active_pane) {
            const control = self.ensureBreadcrumbsControl(pane) catch return;
            if (!std.meta.eql(control.settings, self.breadcrumbs_settings)) {
                control.setSettings(self.breadcrumbs_settings) catch {};
            }
            try control.draw(&self.frame.next, .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .w = @floatFromInt(width),
                .h = 1,
            }, active_group);
            return;
        }

        // Inactive groups only need the path readout. Build a short-lived
        // control so rendering stays on the same model/widget path.
        var context = BreadcrumbContext{ .workbench = self, .pane = pane };
        const control = BreadcrumbsControl.init(
            self.allocator,
            breadcrumbHost(&context),
            self.workspace,
            self.configuration,
            &self.outline_service,
        ) catch return;
        defer control.deinit();
        try control.draw(&self.frame.next, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(width),
            .h = 1,
        }, active_group);
    }

    pub fn pollBreadcrumbs(self: *Workbench) bool {
        if (!self.breadcrumbs_dirty) return false;
        self.breadcrumbs_dirty = false;
        return true;
    }

    pub fn focusBreadcrumbs(self: *Workbench, select: bool) bool {
        const pane = self.activePane() orelse return false;
        const control = self.ensureBreadcrumbsControl(pane) catch return false;
        self.focus = .breadcrumbs;
        self.statusbar.main_part.clearFocus();
        if (self.search_view) |view| view.blur();
        control.setFocused(true);
        if (select) {
            _ = control.focusAndSelect();
        } else {
            _ = control.focusAndSelect();
            control.widget.setSelection(null);
            control.widget.setFocused(control.widget.itemCount() -| 1);
        }
        self.breadcrumbs_dirty = true;
        return true;
    }

    pub fn handleBreadcrumbsKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (self.focus != .breadcrumbs) return false;
        const control = self.breadcrumbs_control orelse {
            self.focusEditor();
            return false;
        };
        switch (event.key) {
            .left => {
                control.focusPrevious();
                return true;
            },
            .right => {
                control.focusNext();
                return true;
            },
            .enter, .down => {
                _ = control.selectFocused() catch {};
                return true;
            },
            .escape => {
                _ = control.escapeFocus();
                return true;
            },
            .char => |ch| {
                if (ch == ' ') {
                    _ = control.revealFocused() catch {};
                    return true;
                }
                return true;
            },
            else => return true,
        }
    }

    pub fn showBreadcrumbPicker(self: *Workbench, file: *const breadcrumbs_model.FileElement) !void {
        if (file.kind == .ROOT_FOLDER) {
            const workspace = self.workspace.getWorkspace();
            if (workspace.folders.items.len > 1) {
                _ = self.breadcrumbs_arena.reset(.retain_capacity);
                const arena = self.breadcrumbs_arena.allocator();
                var items = std.array_list.Managed(QuickPickItem).init(arena);
                for (workspace.folders.items) |folder| {
                    try items.append(.{ .item = .{
                        .id = try std.fmt.allocPrint(arena, "f:{s}", .{folder.resource}),
                        .label = folder.name,
                        .description = "folder",
                    } });
                }
                try self.quick_access.inputService().showPick(
                    items.items,
                    .{ .placeholder = "Select File" },
                    onBreadcrumbPick,
                    self,
                );
                return;
            }
        }
        const directory = breadcrumbs_picker.inputDirectory(file);
        try self.showBreadcrumbPickerForDir(directory, file.path);
    }

    fn showBreadcrumbPickerForDir(self: *Workbench, directory: []const u8, focus_path: ?[]const u8) !void {
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();

        const entries = breadcrumbs_picker.list(self.allocator, self.io, directory) catch {
            if (self.activeTab()) |tab| tab.editor.setMessage("breadcrumb: cannot open {s}", .{directory});
            return;
        };
        defer breadcrumbs_picker.freeEntries(self.allocator, entries);

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        var active_id: ?[]const u8 = null;
        for (entries) |entry| {
            const id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ if (entry.is_dir) "d" else "f", entry.path });
            if (focus_path) |focus| {
                if (std.mem.eql(u8, focus, entry.path)) active_id = id;
            }
            try items.append(.{ .item = .{
                .id = id,
                .label = try arena.dupe(u8, entry.name),
                .description = if (entry.is_dir) "folder" else "",
            } });
        }
        try self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = "Select File", .active_id = active_id },
            onBreadcrumbPick,
            self,
        );
    }

    fn openBreadcrumbFile(self: *Workbench, path: []const u8) !void {
        try self.openPath(path);
        self.focusEditor();
    }

    fn revealBreadcrumbElement(self: *Workbench, outline: *outline_mod.IOutline, element: *anyopaque) !void {
        try outline.reveal(element, .{});
        self.focusEditor();
    }
    pub fn cursorCell(self: *Workbench) ?ViewCell {
        if (self.quick_access.isOpen()) return null;
        if (self.focus != .editor) return null;
        const pane = self.activePane() orelse return null;
        const active = pane.activeTab() orelse return null;
        const cell = active.view.cursorCell() orelse return null;
        const row = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + cell.row;
        const col = ui.cell.snap(pane.rect.x) + cell.col;
        if (row >= self.editorRows() or col >= self.cols) return null;
        return .{ .row = row, .col = col };
    }

    pub fn resize(self: *Workbench, cols: usize, rows: usize) !void {
        self.part.active_sash = null;
        self.clearTabDrag();
        const new_cols = @max(cols, 1);
        const new_rows = @max(rows, 1);
        if (new_cols == self.cols and new_rows == self.rows) {
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| try tab.refresh();
            }
            return;
        }

        self.cols = new_cols;
        self.rows = new_rows;

        const replacement = try ui.Frame.init(self.allocator, new_cols, new_rows);
        var previous = self.frame;
        self.frame = replacement;
        previous.deinit();

        self.layoutAll();
    }

    /// Hosts call this after the terminal capability probe. Cell borders keep
    /// the split gutters from consuming a column/row; the fallback keeps them.
    pub fn setCellBorders(self: *Workbench, enabled: bool) void {
        self.part.setCellBorders(enabled);
    }

    pub fn syncCursor(self: *Workbench, out: *std.Io.Writer) !void {
        if (self.cursorCell()) |cell| {
            try tui.moveCursor(out, .{ .row = cell.row + 1, .col = cell.col + 1 });
            try tui.showCursor(out);
        } else {
            try tui.hideCursor(out);
        }
    }
};

const BreadcrumbContext = struct {
    workbench: *Workbench,
    pane: ?*GroupPane,

    fn activeTab(self: *BreadcrumbContext) ?*Tab {
        if (self.pane) |pane| return pane.activeTab();
        return self.workbench.activeTab();
    }

    fn activate(self: *BreadcrumbContext) void {
        if (self.pane) |pane| {
            self.workbench.service.activateGroup(pane.group);
            pane.syncActivePane();
        }
    }
};

fn breadcrumbHost(context: *BreadcrumbContext) BreadcrumbsHost {
    return .{
        .context = context,
        .active_resource = breadcrumbActiveResource,
        .active_language = breadcrumbActiveLanguage,
        .outline_editor = breadcrumbOutlineEditor,
        .file_badge = breadcrumbFileBadge,
        .symbol_icon = breadcrumbSymbolIcon,
        .open_element = breadcrumbOpenElement,
        .reveal_element = breadcrumbRevealElement,
        .request_render = breadcrumbRequestRender,
        .focus_editor = breadcrumbFocusEditor,
    };
}

fn breadcrumbActiveResource(context: *anyopaque) ?[]const u8 {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.path;
}

fn breadcrumbActiveLanguage(context: *anyopaque) []const u8 {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return "plaintext";
    return tab.editor.languageId();
}

fn breadcrumbOutlineEditor(context: *anyopaque) ?OutlineEditor {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return .{
        .context = @ptrCast(tab),
        .resource = tab.editor.path,
        .language_id = tab.editor.languageId(),
    };
}

fn breadcrumbFileBadge(context: *anyopaque) []const u8 {
    return file_icon.badge(breadcrumbActiveLanguage(context));
}

fn breadcrumbSymbolIcon(_: *anyopaque, kind: ?u32) []const u8 {
    const value = kind orelse return "◇";
    return switch (value) {
        1, 2, 3 => "N",
        4, 9, 10, 22 => "◇",
        5, 8, 11 => "ƒ",
        6, 7, 12, 13, 21 => "·",
        else => "◇",
    };
}

fn breadcrumbOpenElement(context: *anyopaque, selection: BreadcrumbsSelection, mode: BreadcrumbsSelectMode) anyerror!void {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    self.activate();
    switch (selection) {
        .file => |file| {
            if (mode == .reveal and file.kind == .FILE) {
                try self.workbench.openBreadcrumbFile(file.path);
            } else {
                try self.workbench.showBreadcrumbPicker(file);
            }
        },
        .outline => |outline| try self.workbench.revealBreadcrumbElement(outline.outline, outline.element),
        .placeholder => {},
    }
}

fn breadcrumbRevealElement(context: *anyopaque, outline: *outline_mod.IOutline, element: *anyopaque) anyerror!void {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    try self.workbench.revealBreadcrumbElement(outline, element);
}

fn breadcrumbRequestRender(context: *anyopaque) void {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    self.workbench.breadcrumbs_dirty = true;
}

fn breadcrumbFocusEditor(context: *anyopaque) void {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    self.workbench.focusEditor();
    if (self.workbench.activeTab()) |tab| tab.view.focusEditor();
}

fn onBreadcrumbPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    const id = item.id;
    if (std.mem.startsWith(u8, id, "f:")) {
        try self.openBreadcrumbFile(id[2..]);
    } else if (std.mem.startsWith(u8, id, "d:")) {
        try self.showBreadcrumbPickerForDir(id[2..], null);
    }
}

fn hasActiveEditor(context: *anyopaque) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.activeTab() != null;
}

fn quickOpenFile(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.openPath(path);
}

fn quickReportError(context: *anyopaque, message: []const u8) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| {
        tab.editor.setMessage("Quick open: {s}", .{message});
    }
}

fn quickCancelPopups(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| {
        if (tab.controllers) |controllers| {
            controllers.suggest.cancel();
            controllers.hover.hideContentHover();
        }
    }
}

fn commandTab(context: *anyopaque) !*Tab {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.activeTab() orelse error.NoActiveEditor;
}

fn commandQuickOpen(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.quick_access.showFilePicker();
}

fn commandShowCommands(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.quick_access.showCommandPicker();
}

fn commandSave(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.save();
}

fn commandRevert(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.reloadFromDisk();
}

fn commandFocusAndSelectBreadcrumbs(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.focusBreadcrumbs(true);
}

fn commandFocusBreadcrumbs(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.focusBreadcrumbs(false);
}

fn commandCloseEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = try self.closeActive();
}

fn commandSplitEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.splitActive(.horizontal);
}

fn commandToggleSidebar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.toggleSidebar();
}

fn statusFocusEditor(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusEditor();
}

fn commandFocusStatusBar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusStatusBar();
}

fn executeStatusbarCommand(context: *anyopaque, command: statusbar_types.StatusbarCommand) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (statusbar_types.isTooltipCommand(command)) return;
    _ = try self.commands.platform.execute(command.id);
}

fn commandFind(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    try tab.controllers.?.find.startFind();
}

fn commandReplace(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    try tab.controllers.?.find.startReplace();
}

fn commandToggleLineComment(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.toggleLineComment();
}

fn commandToggleBlockComment(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.toggleBlockComment();
}

fn commandMoveLinesUp(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.moveLines(false);
}

fn commandMoveLinesDown(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.moveLines(true);
}

fn commandCopyLinesUp(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.copyLines(false);
}

fn commandCopyLinesDown(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.copyLines(true);
}

fn commandDuplicateSelection(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.duplicateSelection();
}

fn commandSortLinesAscending(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.sortLines(false);
}

fn commandSortLinesDescending(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.sortLines(true);
}

fn commandIndentLines(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.indentLines();
}

fn commandOutdentLines(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.outdentLines();
}

fn commandInsertFinalNewLine(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.insertFinalNewLine();
}

fn commandExpandLineSelection(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.expandLineSelection();
}

fn commandInsertCursorAbove(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.addCursorAbove();
}

fn commandInsertCursorBelow(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.addCursorBelow();
}

fn commandAddSelectionToNextFindMatch(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.selectNextOccurrence();
}

fn commandSelectHighlights(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.selectAllOccurrences();
}

fn commandJumpToBracket(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.jumpToBracket();
}

fn commandSelectToBracket(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.selectToBracket(true);
}

fn commandRemoveBrackets(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.removeBrackets();
}

fn commandExpandSelection(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.growSelection(true);
}

fn commandShrinkSelection(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.growSelection(false);
}

fn commandInPlaceReplacePrevious(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    _ = try tab.editor.inPlaceReplace(false);
}

fn commandInPlaceReplaceNext(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    _ = try tab.editor.inPlaceReplace(true);
}

fn commandReindentLines(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.reindentLines();
}

fn commandReindentSelectedLines(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.reindentSelectedLines();
}

fn commandFold(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.foldAtCursor();
}

fn commandUnfold(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.unfoldAtCursor();
}

fn commandToggleFold(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.toggleFoldAtCursor();
}

fn commandFoldRecursively(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.foldRecursivelyAtCursor();
}

fn commandUnfoldRecursively(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.unfoldRecursivelyAtCursor();
}

fn commandFoldAll(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.foldAll();
}

fn commandUnfoldAll(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.unfoldAll();
}

fn commandWordHighlightNext(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    tab.controllers.?.word_highlighter.moveNext();
}

fn commandWordHighlightPrevious(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    tab.controllers.?.word_highlighter.moveBack();
}

fn searchOpenMatch(context: *anyopaque, path: []const u8, range: ?Range) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openPath(path);
    self.focus = .editor;
    if (self.activeTab()) |tab| {
        if (range) |value| try tab.editor.setSelection(value);
        tab.view.focusEditor();
    }
    if (range) |value| searchHighlightRange(context, path, value) else searchHighlightRange(context, path, null);
}

fn searchHighlightRange(context: *anyopaque, path: []const u8, range: ?Range) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (range != null and std.mem.eql(u8, tab.editor.path, path)) {
                const decorations = [_]editorBrowser.Decoration{.{ .range = range.?, .kind = .search_range_highlight }};
                tab.view.setSearchHighlights(&decorations) catch {};
            } else {
                tab.view.setSearchHighlights(&.{}) catch {};
            }
        }
    }
}

fn searchReadFile(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (!std.mem.eql(u8, tab.editor.path, path)) continue;
            var value = try tab.editor.model.getValue(null, false);
            return try value.toOwnedSlice();
        }
    }
    _ = allocator;
    return null;
}

fn searchExtraFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (self.workspace.isInsideWorkspace(tab.editor.path)) continue;
            var duplicate = false;
            for (paths.items) |existing| {
                if (std.mem.eql(u8, existing, tab.editor.path)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try paths.append(try allocator.dupe(u8, tab.editor.path));
        }
    }
    return try paths.toOwnedSlice();
}

fn searchFreePaths(_: *anyopaque, allocator: Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn searchApplyEdits(context: *anyopaque, path: []const u8, edits: []const replace_types.Edit) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (!pathsEqual(tab.editor.path, path)) continue;
            const converted = try self.allocator.alloc(TextEdit, edits.len);
            defer self.allocator.free(converted);
            for (edits, 0..) |edit, index| {
                converted[index] = .{ .range = edit.range, .text = edit.text };
            }
            try tab.editor.applyTextEdits(converted, &.{});
            return;
        }
    }
    return applyClosedFileEdits(self, path, edits);
}

fn applyClosedFileEdits(self: *Workbench, path: []const u8, edits: []const replace_types.Edit) !void {
    const content = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024));
    defer self.allocator.free(content);

    var starts = std.array_list.Managed(usize).init(self.allocator);
    defer starts.deinit();
    var bom_len: usize = 0;
    if (content.len >= 3 and content[0] == 0xef and content[1] == 0xbb and content[2] == 0xbf) bom_len = 3;
    try starts.append(bom_len);
    for (content, 0..) |ch, index| {
        if (ch == '\n' and index + 1 <= content.len) try starts.append(index + 1);
    }

    const Resolved = struct { start: usize, end: usize, text: []const u8 };
    var resolved = std.array_list.Managed(Resolved).init(self.allocator);
    defer resolved.deinit();
    for (edits) |edit| {
        const start = offsetAt(starts.items, edit.range.startLineNumber, edit.range.startColumn);
        const end = offsetAt(starts.items, edit.range.endLineNumber, edit.range.endColumn);
        try resolved.append(.{ .start = @min(start, content.len), .end = @min(end, content.len), .text = edit.text });
    }
    std.sort.heap(Resolved, resolved.items, {}, struct {
        fn lessThan(_: void, a: Resolved, b: Resolved) bool {
            return a.start > b.start;
        }
    }.lessThan);

    var buffer = std.array_list.Managed(u8).init(self.allocator);
    defer buffer.deinit();
    try buffer.appendSlice(content);
    for (resolved.items) |edit| {
        if (edit.end < edit.start or edit.end > buffer.items.len) continue;
        try buffer.replaceRange(edit.start, edit.end - edit.start, edit.text);
    }
    try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = buffer.items });
}

fn offsetAt(starts: []const usize, line: usize, column: usize) usize {
    if (starts.len == 0) return 0;
    const index = @min(line -| 1, starts.len - 1);
    return starts[index] + (column -| 1);
}

fn searchSaveFile(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (pathsEqual(tab.editor.path, path)) {
                try tab.editor.save();
                return;
            }
        }
    }
}

/// Compares resource paths across the CLI/test boundary. Windows tests and
/// callers can mix `/` and `\`, and Windows paths are case-insensitive.
fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left == right) continue;
        const separators = (left == '/' or left == '\\') and (right == '/' or right == '\\');
        if (separators) continue;
        if (builtin.os.tag == .windows and std.ascii.toLower(left) == std.ascii.toLower(right)) continue;
        return false;
    }
    return true;
}

fn searchActiveSelectionText(context: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    const selections = try tab.editor.getSelections();
    defer self.allocator.free(selections);
    for (selections) |selection| {
        if (selection.isEmpty()) continue;
        var value = try tab.editor.model.getValueInRange(Range.init(
            selection.startLineNumber,
            selection.startColumn,
            selection.endLineNumber,
            selection.endColumn,
        ), null);
        return try value.toOwnedSlice();
    }
    _ = allocator;
    return null;
}

fn searchActiveEditorInfo(context: *anyopaque) ?search_view_mod.EditorInfo {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.activeEditorInfo();
}

fn commandFindInFiles(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.findInFiles();
}

fn commandReplaceInFiles(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.replaceInFiles();
}

fn ensureSearch(context: *anyopaque) !*SearchView {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showActivity(1);
    return self.search_view.?;
}

fn commandToggleSearchCase(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandToggle(.match_case);
}

fn commandToggleSearchWholeWord(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandToggle(.whole_word);
}

fn commandToggleSearchRegex(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandToggle(.regex);
}

fn commandToggleSearchPreserveCase(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandToggle(.preserve_case);
}

fn commandSearchNext(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandFocusNext();
}

fn commandSearchPrevious(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandFocusPrevious();
}

fn commandSearchRemove(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandRemove();
}

fn commandSearchReplace(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandReplace();
}

fn commandSearchClear(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandClear();
}

fn commandSearchDetails(context: *anyopaque) anyerror!void {
    const view = try ensureSearch(context);
    view.commandToggleDetails();
}

fn drawPlainText(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, paint: ui.cell.PaintStyle) void {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > x + max_width) break;
        grid.putCodepoint(col, y, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
}

fn isCtrlChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

fn clickStatusEntry(workbench: *Workbench, id: []const u8) !bool {
    const part = workbench.statusbar.main_part;
    const handle = part.model.findHandle(id) orelse return false;
    const y = ui.cell.snap(workbench.statusBarRect().y);
    const width = ui.cell.snap(workbench.statusBarRect().w);
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const hit = part.hitAt(x, y) catch null;
        if (hit) |value| {
            switch (value) {
                .entry => |candidate| if (candidate == handle) {
                    var event = ui.MouseEvent{
                        .kind = .down,
                        .x = x,
                        .y = y,
                        .button = .left,
                    };
                    return workbench.handleStatusbarMouse(&event);
                },
                .part => {},
            }
        }
    }
    return false;
}

fn grid_attr_italic(grid: *const ui.CellGrid, col: usize, row: usize) bool {
    if (row >= grid.rows or col >= grid.cols) return false;
    return grid.attrs[row * grid.cols + col] & ui.cell.Attr.italic != 0;
}

fn seedFile(allocator: Allocator, io: Io, tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    errdefer allocator.free(path);
    if (std.fs.path.dirname(path)) |directory| {
        Io.Dir.cwd().createDirPath(io, directory) catch {};
    }
    var editor = try Editor.createFromText(allocator, io, contents, path, 40, 7);
    try editor.save();
    editor.deinit();
    allocator.destroy(editor);
    return path;
}

test "Workbench: opens two files, switches tabs and closes them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();

    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.base.getName());

    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b.txt") != null);
    try std.testing.expectEqual(@as(usize, 2), workbench.cursorCell().?.row);

    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.base.getName());
    try workbench.switchTab(1);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.base.getName());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.base.getName());
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: split moves the active tab into a second group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "split_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "split_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("split_b.txt", workbench.activeTab().?.input.base.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "split_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "split_b.txt") != null);

    // The original group still holds the other tab.
    const first_pane = workbench.part.group_views.items[0];
    const second_pane = workbench.part.group_views.items[1];
    try std.testing.expectEqual(@as(usize, 1), first_pane.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), second_pane.tabs.items.len);

    // Splitting again moves the active tab to a third group.
    try workbench.splitActive(.vertical);
    try std.testing.expectEqual(@as(usize, 3), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: cell borders remove the split gutter" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "border_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "border_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    // The fallback reserves one gutter column between the panes.
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()) + 1, ui.cell.snap(second.rect.x));

    workbench.setCellBorders(true);
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const grid = &workbench.frame.prev;
    const left_edge = ui.cell.snap(first.rect.right()) - 1;
    const right_edge = ui.cell.snap(second.rect.x);
    const row: usize = 2;
    try std.testing.expect(grid.borderIdAt(left_edge, row) != 0);
    try std.testing.expect(grid.borderIdAt(right_edge, row) != 0);

    var left_mask: u12 = 0;
    for (grid.borderSetAt(left_edge, row).groups[0..grid.borderSetAt(left_edge, row).count]) |group| left_mask |= group.mask;
    try std.testing.expect((left_mask & ui.cell_border.Segment.right) != 0);
    var right_mask: u12 = 0;
    for (grid.borderSetAt(right_edge, row).groups[0..grid.borderSetAt(right_edge, row).count]) |group| right_mask |= group.mask;
    try std.testing.expect((right_mask & ui.cell_border.Segment.left) != 0);

    // Every pane is outlined; the active pane uses the focus colour and
    // priority 1 so it wins a merged shared edge.
    const active_set = grid.borderSetAt(ui.cell.snap(second.rect.x), ui.cell.snap(second.rect.y));
    var active_priority: u4 = 0;
    var active_color: ui.Color = .{ .r = 0, .g = 0, .b = 0 };
    for (active_set.groups[0..active_set.count]) |group| {
        if ((group.mask & ui.cell_border.Segment.top) != 0) {
            active_priority = group.stroke.priority;
            if (group.stroke.color == .rgb) active_color = group.stroke.color.rgb;
        }
    }
    try std.testing.expectEqual(@as(u4, 1), active_priority);
    try std.testing.expect(active_color.eql(active_pane_border));

    const inactive_set = grid.borderSetAt(ui.cell.snap(first.rect.x), ui.cell.snap(first.rect.y));
    var inactive_priority: u4 = 9;
    var inactive_color: ui.Color = .{ .r = 0, .g = 0, .b = 0 };
    for (inactive_set.groups[0..inactive_set.count]) |group| {
        if ((group.mask & ui.cell_border.Segment.top) != 0) {
            inactive_priority = group.stroke.priority;
            if (group.stroke.color == .rgb) inactive_color = group.stroke.color.rgb;
        }
    }
    try std.testing.expectEqual(@as(u4, 0), inactive_priority);
    try std.testing.expect(inactive_color.eql(inactive_pane_border));
}

test "Workbench: sash drag resizes the split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    workbench.setCellBorders(true);

    try std.testing.expectEqual(@as(usize, 25), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));
    const boundary = ui.cell.snap(workbench.part.root.kind.split.first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.part.active_sash != null);

    var move = ui.MouseEvent{ .kind = .move, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expectEqual(@as(f64, 0.6), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));

    var up = ui.MouseEvent{ .kind = .up, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: closing the last tab collapses the empty group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "collapse_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "collapse_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.part.group_views.items.len);

    _ = try workbench.closeActive();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 50), ui.cell.snap(workbench.part.root.rect.w));
}

test "Workbench: dragging a tab into a pane moves it there" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "drag_move_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "drag_move_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const source = workbench.part.group_views.items[1];
    const target = workbench.part.group_views.items[0];
    const tab_x = source.hits.items[0].start;
    const tab_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    var move = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(target.rect.x) + ui.cell.snap(target.rect.w) / 2,
        .y = ui.cell.snap(target.rect.y) + ui.cell.snap(target.rect.h) / 2,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.drag_tab != null);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: dropping a tab on a pane edge tiles a new pane" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "drag_split_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "drag_split_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    workbench.setCellBorders(true);
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_x = pane.hits.items[0].start;
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    var move = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(pane.rect.right()) - 1,
        .y = ui.cell.snap(pane.rect.y) + ui.cell.snap(pane.rect.h) / 2,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.drag_target != null);
    try std.testing.expectEqual(DropZone.right, workbench.drag_target.?.zone);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));
}

test "Workbench: openPath reveals an already-open file in another group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "reveal_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "reveal_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("reveal_b.txt", workbench.activeTab().?.input.base.getName());

    try workbench.openPath(path_a);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("reveal_a.txt", workbench.activeTab().?.input.base.getName());
}

test "Workbench: serialize and restore a group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "restore_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "restore_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 9);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var serializer = workbench.createFileSerializer();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.serialize(allocator, &registry);
    defer data.deinit(allocator);

    const restored = try Workbench.initFromSerialized(allocator, io, data, &registry, 60, 9);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.tabCount());
    try std.testing.expectEqualStrings("restore_b.txt", restored.activeTab().?.input.base.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try restored.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "restore_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "restore_b.txt") != null);
}

test "Workbench: serialize and restore multiple groups" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "part_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "part_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 70, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var serializer = workbench.createFileSerializer();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.serializePart(allocator, &registry);
    defer data.deinit(allocator);

    const restored = try Workbench.initFromSerializedPart(allocator, io, data, &registry, 70, 10);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.groupCount());
    try std.testing.expectEqual(@as(usize, 2), restored.tabCount());
    try std.testing.expectEqualStrings("part_b.txt", restored.activeTab().?.input.base.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try restored.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_b.txt") != null);
}

test "Workbench: sidebar renders and opens a file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "side_a.txt", "alpha");
    defer allocator.free(path_a);

    const workbench = try Workbench.init(allocator, io, &.{path_a}, 70, 12);
    defer workbench.deinit();

    // Put the sidebar at the temp root and create the file it should open.
    var sidebar_file = try tmp.dir.createFile(io, "side_open.txt", .{});
    try sidebar_file.writeStreamingAll(io, "opened from sidebar");
    sidebar_file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    try workbench.initSidebar(root);
    workbench.focusSidebar();
    try std.testing.expect(workbench.part.group_views.items[0].rect.x > 0);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "side_open.txt") != null);

    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 2 };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("side_open.txt", workbench.activeTab().?.input.base.getName());
    try std.testing.expectEqual(Focus.editor, workbench.focus);

    const ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&ctrl_b));
    try std.testing.expect(!workbench.layout_model.isVisible(.sidebar));
    try std.testing.expect(try workbench.handleSidebarKey(&ctrl_b));
    try std.testing.expect(workbench.layout_model.isVisible(.sidebar));
}

test "Workbench: workspace search streams results and opens a match" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "search_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.model.isSearching() or view.wantsTick()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 results in 1 file") != null);
}

test "Workbench: opening a search match selects its range" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "open_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expect(view.rows.items.len > 0);

    var match_row: ?usize = null;
    for (view.rows.items, 0..) |row, index| {
        switch (row) {
            .match => {
                match_row = index;
                break;
            },
            else => {},
        }
    }
    view.selected = match_row.?;
    view.results_focused = true;
    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(@as(@TypeOf(view.handleKey(&enter)), .handled), view.handleKey(&enter));
    const tab = workbench.activeTab().?;
    const selections = try tab.editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqual(@as(usize, 1), selections[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selections[0].startColumn);
    try std.testing.expectEqual(@as(usize, 1), selections[0].endLineNumber);
    try std.testing.expectEqual(@as(usize, 6), selections[0].endColumn);
}

test "Workbench: search replace all updates an open editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "replace_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.widget.setValue(.replace, "omega");
    view.model.setReplaceString("omega") catch {};
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
    view.commandReplaceAll();

    const tab = workbench.activeTab().?;
    var content = try tab.editor.model.getValue(null, false);
    defer content.deinit();
    try std.testing.expect(std.mem.indexOf(u8, content.items, "omega beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "gamma omega") != null);
}

test "Workbench: activity bar switches view containers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "activity.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    try workbench.initSidebar(root);
    workbench.focusSidebar();

    const search_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 2 };
    try std.testing.expect(workbench.handleSidebarMouse(&search_click));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeActivity());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results") != null or std.mem.indexOf(u8, out.written(), "Search") != null);

    const settings_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 3 };
    try std.testing.expect(workbench.handleSidebarMouse(&settings_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SETTINGS") != null);

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.activeActivity());
}

test "Workbench: opens a folder workspace with no initial tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "folder_file.txt", .{});
    try file.writeStreamingAll(io, "from folder");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 12);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    workbench.focusSidebar();

    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
    try std.testing.expect(workbench.activeTab() == null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "folder_file.txt") != null);

    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 1 };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("folder_file.txt", workbench.activeTab().?.input.base.getName());
}

test "Workbench: Ctrl-P opens a file and Alt-P runs a command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    var file = try tmp.dir.createFile(io, "src/alpha.txt", .{});
    try file.writeStreamingAll(io, "alpha");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    const picker = workbench.quick_access.controller.pickerRef();
    try picker.setValue("alp");
    var guard: usize = 0;
    while (workbench.quickAccessWantsTick() and guard < 200) : (guard += 1) {
        _ = try workbench.pollQuickAccess(0);
    }
    try std.testing.expectEqualStrings("alpha.txt", picker.activeItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("alpha.txt", workbench.activeTab().?.input.base.getName());
    try std.testing.expectEqual(@as(usize, 1), workbench.history.getHistory().len);

    // Alt-P opens the command palette directly; "split" runs the split command.
    var alt_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&alt_p));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try picker.setValue(">split");
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
}

test "Workbench: opening a file reveals it in the Explorer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    var file = try tmp.dir.createFile(io, "src/revealed.txt", .{});
    try file.writeStreamingAll(io, "revealed");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/src/revealed.txt", .{root});
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.openPath(path);

    const selected = workbench.sidebar.?.selectedNode().?;
    try std.testing.expectEqualStrings("revealed.txt", selected.name);
    try std.testing.expect(workbench.sidebar.?.isExpanded(selected.parent.?));
}

test "Workbench: explorer.autoReveal false disables selection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"explorer.autoReveal\": false}");
    settings.close(io);
    var file = try tmp.dir.createFile(io, "no_reveal.txt", .{});
    try file.writeStreamingAll(io, "x");
    file.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const path = try std.fmt.allocPrint(allocator, "{s}/no_reveal.txt", .{root});
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.openPath(path);

    const selected = workbench.sidebar.?.selectedNode().?;
    try std.testing.expect(!std.mem.eql(u8, selected.name, "no_reveal.txt"));
}

test "Workbench: switching tabs reveals the active file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = try tmp.dir.createFile(io, "a.txt", .{});
    try a.writeStreamingAll(io, "a");
    a.close(io);
    var b = try tmp.dir.createFile(io, "b.txt", .{});
    try b.writeStreamingAll(io, "b");
    b.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const path_a = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, "{s}/b.txt", .{root});
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.openPath(path_a);
    try workbench.openPath(path_b);
    try std.testing.expectEqualStrings("b.txt", workbench.sidebar.?.selectedNode().?.name);

    try workbench.switchTab(-1);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.base.getName());
    try std.testing.expectEqualStrings("a.txt", workbench.sidebar.?.selectedNode().?.name);
}

test "Workbench: quick open renders and an outside click only closes it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "outside.txt", .{});
    try file.writeStreamingAll(io, "outside");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&ctrl_p));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Search files") != null);

    var click = ui.MouseEvent{ .kind = .down, .x = 0, .y = 9 };
    try std.testing.expect(workbench.handleQuickAccessMouse(&click));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: search shows no-results and honors showLineNumbers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "settings_search.txt", "alpha beta\n");
    defer allocator.free(path);
    var settings_file = try tmp.dir.createFile(io, "search-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"search.showLineNumbers\": true}");
    settings_file.close(io);
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_dir_len = try tmp.dir.realPath(io, &settings_buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ settings_buffer[0..settings_dir_len], "search-settings.json" });
    defer allocator.free(settings_path);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.setUserSettingsPath(settings_path);
    try workbench.initSidebar(root);
    try workbench.findInFiles();
    const view = workbench.search_view.?;

    try view.widget.setValue(.search, "zzz-not-found");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results found") != null);

    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    guard = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try workbench.render(&rendered.writer);
    try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "1: ") != null);
}

test "Workbench: typing a search query restarts results without stale collapse keys" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "typed_search.txt", "test tester testing\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.findInFiles();
    const view = workbench.search_view.?;

    for ([_][]const u8{ "t", "te", "tes", "test" }) |query| {
        try view.widget.setValue(.search, query);
        try view.startSearch();
        var guard: usize = 0;
        while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
            _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
        }
    }

    var saw_file = false;
    var saw_match = false;
    for (view.rows.items, view.depths.items) |row, depth| {
        switch (row) {
            .file => {
                saw_file = true;
                // List mode places files at the root; only tree mode nests them.
                try std.testing.expectEqual(@as(usize, 0), depth);
            },
            .match => {
                saw_match = true;
                try std.testing.expectEqual(@as(usize, 1), depth);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_match);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "test") != null);
}

test "Workbench: wheel scrolls search results without moving the selection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (0..14) |index| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "scroll_{d}.txt", .{index});
        const path = try seedFile(allocator, io, &tmp, name, "alpha\n");
        try paths.append(path);
    }
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, paths.items, 80, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(view.rows.items.len > view.visible_rows);

    const selected_before = view.selected;
    const scroll_before = view.scroll;
    const x = ui.cell.snap(view.last_rect.x) + 2;
    const y = ui.cell.snap(view.last_rect.y) + 1 + view.widget.layout.height + 2;
    const wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 1 };
    try std.testing.expect(workbench.handleSidebarMouse(&wheel));
    try std.testing.expect(view.scroll > scroll_before);
    try std.testing.expectEqual(selected_before, view.selected);

    var after: std.Io.Writer.Allocating = .init(allocator);
    defer after.deinit();
    try workbench.render(&after.writer);
    try std.testing.expect(view.scroll > scroll_before);
}

test "Workbench: status bar spans the window and shows editor state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();

    try std.testing.expect(workbench.statusBarVisible());
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(workbench.statusBarRect().y));

    const pane = workbench.part.group_views.items[0];
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(pane.rect.h));
    try std.testing.expectEqual(@as(usize, 7), workbench.activeTab().?.editor.screen_height);

    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const status = try workbench.frame.prev.rowText(allocator, 9);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "status.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Ln 1, Col 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Spaces: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "LF") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "UTF-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Plain Text") != null);

    workbench.focusStatusBar();
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() != null);
    try std.testing.expect(workbench.cursorCell() == null);

    const right = ui.KeyEvent{ .key = .right };
    try std.testing.expect(try workbench.handleStatusbarKey(&right));
    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try workbench.handleStatusbarKey(&escape));
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() == null);
    try std.testing.expect(try workbench.handleStatusbarKey(&escape));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: Ctrl-Alt-S toggles status bar focus" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "focus.txt", "x");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 8);
    defer workbench.deinit();

    const toggle = ui.KeyEvent{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleStatusbarKey(&toggle));
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(try workbench.handleStatusbarKey(&toggle));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: clicking a status entry focuses it and runs its command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "click.txt", "x");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 8);
    defer workbench.deinit();

    const State = struct {
        hits: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hits += 1;
        }
    };
    var state = State{};
    try workbench.commands.register(.{
        .id = "test.statusbar.command",
        .label = "Status Command",
        .context = &state,
        .run = State.run,
    });
    const accessor = try workbench.statusbar.addEntry(.{
        .name = "Status command",
        .text = "CMD",
        .command = .{ .id = "test.statusbar.command" },
    }, "test.statusbar.command", .right, .{ .number = 50 });

    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const y = ui.cell.snap(workbench.statusBarRect().y);
    var hit_x: ?usize = null;
    var x: usize = 0;
    while (x < 100) : (x += 1) {
        const hit = workbench.statusbar.main_part.hitAt(x, y) catch null;
        if (hit) |value| {
            switch (value) {
                .entry => |handle| if (handle == accessor.handle) {
                    hit_x = x;
                    break;
                },
                .part => {},
            }
        }
    }
    const click_x = hit_x orelse return error.StatusEntryNotFound;
    var click = ui.MouseEvent{ .kind = .down, .x = click_x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleStatusbarMouse(&click));
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expectEqual(accessor.handle, workbench.statusbar.main_part.focusedHandle().?);
}

test "Workbench: status values open the matching pickers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "pick.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();
    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("Indent Using Spaces", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("UTF-8", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("LF", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.quick_access.inputService().pickerRef().items.items.len);
    _ = try workbench.handleQuickAccessKey(&escape);
    try std.testing.expect(!workbench.quick_access.isOpen());
}

test "Workbench: EOL and language pickers update the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "pick-actions.txt", "alpha\nbeta\ngamma");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();
    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    var down = ui.KeyEvent{ .key = .down };
    _ = try workbench.handleQuickAccessKey(&down);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqual(
        encoding_mod.Encoding.utf8_with_bom,
        workbench.activeTab().?.editor.getEncoding(),
    );
    try std.testing.expectEqualStrings(
        "UTF-8 with BOM",
        workbench.statusbar.main_part.model.findEntry("status.editor.encoding").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    _ = try workbench.handleQuickAccessKey(&down);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.quick_access.isOpen());
    try std.testing.expectEqual(EOL.CRLF, workbench.activeTab().?.editor.model.getEOL());
    try std.testing.expectEqualStrings(
        "CRLF",
        workbench.statusbar.main_part.model.findEntry("status.editor.eol").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    for ("zig") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try workbench.handleQuickAccessKey(&typed);
    }
    try std.testing.expectEqualStrings("zig", workbench.quick_access.inputService().pickerRef().activeItem().?.id);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
    try std.testing.expectEqualStrings(
        "Zig",
        workbench.statusbar.main_part.model.findEntry("status.editor.mode").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    for ("2:3") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try workbench.handleQuickAccessKey(&typed);
    }
    _ = try workbench.handleQuickAccessKey(&enter);
    const selections = try workbench.activeTab().?.editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), selections[0].startColumn);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    _ = try workbench.handleQuickAccessKey(&down);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.activeTab().?.editor.model.getOptions().insertSpaces);
    try std.testing.expectEqualStrings(
        "Tab Size: 4",
        workbench.statusbar.main_part.model.findEntry("status.editor.indentation").?.item.text(),
    );
}

const tab_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{ .id = "workbench.action.closeActiveEditor", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyW) } },
    .{ .id = "workbench.action.nextEditor", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.PageDown) } },
    .{ .id = "workbench.action.previousEditor", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.PageUp) } },
    .{ .id = "workbench.action.focusLeftGroup", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.LeftArrow) } },
    .{ .id = "workbench.action.focusRightGroup", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.RightArrow) } },
    .{ .id = "workbench.action.openEditorAtIndex1", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit1) } },
    .{ .id = "workbench.action.openEditorAtIndex2", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit2) } },
    .{ .id = "workbench.action.openEditorAtIndex3", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit3) } },
    .{ .id = "workbench.action.openEditorAtIndex4", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit4) } },
    .{ .id = "workbench.action.openEditorAtIndex5", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit5) } },
    .{ .id = "workbench.action.openEditorAtIndex6", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit6) } },
    .{ .id = "workbench.action.openEditorAtIndex7", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit7) } },
    .{ .id = "workbench.action.openEditorAtIndex8", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit8) } },
    .{ .id = "workbench.action.openEditorAtIndex9", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Digit9) } },
};

const global_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{ .id = "workbench.action.quickOpen", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyP) } },
    .{ .id = "workbench.action.showCommands", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyP) } },
    .{ .id = "workbench.action.findInFiles", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyF), .secondary = &.{key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyF)} } },
    .{ .id = "workbench.action.replaceInFiles", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyH) } },
    .{ .id = "workbench.action.toggleSidebarVisibility", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyB) } },
    .{ .id = "workbench.action.focusStatusBar", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyS) } },
    .{ .id = "breadcrumbs.focusAndSelect", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Period) } },
    .{ .id = "breadcrumbs.focus", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Semicolon) } },
};

test "workbench: global shortcuts dispatch through the keybinding registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    // While quick access owns the keyboard the global host steps aside.
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_p)));
}

const statusbar_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{ .id = "workbench.action.statusbar.focusPreviousEntry", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.LeftArrow), .secondary = &.{@backingInt(key_codes.KeyCode.UpArrow)} } },
    .{ .id = "workbench.action.statusbar.focusNextEntry", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.RightArrow), .secondary = &.{@backingInt(key_codes.KeyCode.DownArrow)} } },
    .{ .id = "workbench.action.statusbar.focusFirstEntry", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Home) } },
    .{ .id = "workbench.action.statusbar.focusLastEntry", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.End) } },
    .{ .id = "workbench.action.statusbar.executeFocused", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Enter), .secondary = &.{@backingInt(key_codes.KeyCode.Space)} } },
    .{ .id = "workbench.action.statusbar.escapeFocus", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Escape) } },
};

fn executeTabCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (try self.runTabCommand(command_id)) |result| self.tab_command_result = result;
}

fn executeStatusbarKeyCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.runStatusbarCommand(command_id);
}

fn executeGlobalCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.commands.execute(command_id);
}

test "Workbench: files.associations change the opened editor language" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"files.associations\":{\"*.custom\":\"zig\"}}");
    settings_file.close(io);
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_dir_len = try tmp.dir.realPath(io, &settings_buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ settings_buffer[0..settings_dir_len], "settings.json" });
    defer allocator.free(settings_path);

    const path = try seedFile(allocator, io, &tmp, "sample.custom", "body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.setUserSettingsPath(settings_path);
    try workbench.openPath(path);

    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
}

test "Workbench: external file changes reload clean editors only" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "external.txt", "before");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();

    const tab = workbench.activeTab().?;

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "after" });
    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    var reloaded = try tab.editor.model.getValue(.TextDefined, true);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("after", reloaded.items);

    // Dirty editors keep the in-memory content.
    try tab.editor.insertText("local ");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "external" });
    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    var preserved = try tab.editor.model.getValue(.TextDefined, true);
    defer preserved.deinit();
    try std.testing.expectEqualStrings("local after", preserved.items);
    try std.testing.expect(tab.editor.hasConflict());
    try std.testing.expect(std.mem.indexOf(u8, tab.editor.message(), "Conflict") != null);
    try tab.editor.save();
    try std.testing.expect(!tab.editor.hasConflict());
    try std.testing.expect(std.mem.indexOf(u8, tab.editor.message(), "Saved") != null);
}

test "Workbench: starts a workspace file watcher for absolute folders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try std.testing.expect(workbench.files_watcher != null);
}

test "Workbench: revert command discards edits and clears conflicts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "revert.txt", "on disk");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;

    try tab.editor.insertText("local ");
    try std.testing.expect(tab.editor.isDirty());
    tab.editor.markConflict();

    try workbench.commands.execute("workbench.action.files.revert");
    var text = try tab.editor.model.getValue(.TextDefined, true);
    defer text.deinit();
    try std.testing.expectEqualStrings("on disk", text.items);
    try std.testing.expect(!tab.editor.isDirty());
    try std.testing.expect(!tab.editor.hasConflict());
}

test "Workbench: working copy service tracks dirty editors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "working-copy.txt", "content");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const service = workbench.workingCopyService();
    try std.testing.expectEqual(@as(usize, 0), service.dirtyCount());
    try std.testing.expect(service.hasResource(path));

    const tab = workbench.activeTab().?;
    try tab.editor.insertText("X");
    try std.testing.expectEqual(@as(usize, 1), service.dirtyCount());
    try std.testing.expect(service.isDirty(path, null));

    try tab.editor.save();
    try std.testing.expectEqual(@as(usize, 0), service.dirtyCount());
    try std.testing.expect(!service.isDirty(path, null));

    _ = try workbench.closeActive();
    try std.testing.expect(!service.hasResource(path));
}

test "Workbench: decoded divider drag resizes the split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_decoded_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_decoded_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    try std.testing.expect(!workbench.part.cell_borders);
    const boundary = ui.cell.snap(first.rect.right());
    try std.testing.expectEqual(@as(usize, 24), boundary);

    // Press on the gutter divider, drag it six cells right and release.
    var buf: [160]u8 = undefined;
    const seq = try std.fmt.bufPrint(
        &buf,
        "\x1b[<0;{d};3M\x1b[<32;{d};3M\x1b[<0;{d};3m",
        .{ boundary + 1, boundary + 7, boundary + 7 },
    );
    var items = try ui.input.decode(allocator, seq);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key => return error.TestUnexpectedResult,
            .mouse => |*mouse| {
                if (workbench.handleTabDragMouse(mouse)) continue;
                if (workbench.handleQuickAccessMouse(mouse)) continue;
                if (workbench.handleStatusbarMouse(mouse)) continue;
                if (workbench.handleSashMouse(mouse)) continue;
            },
        }
    }

    try std.testing.expectEqual(@as(f64, 30.0 / 49.0), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(first.rect.w));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: sash follows drag motion without button bits" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_buttonless_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_buttonless_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    const boundary = ui.cell.snap(first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.part.active_sash != null);

    // Mode 1003 terminals may report drag motion with button `none`; the
    // grabbed sash still follows the pointer instead of ending the drag.
    var move = ui.MouseEvent{ .kind = .move, .x = boundary + 6, .y = 2, .button = .none };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expect(workbench.part.active_sash != null);
    try std.testing.expectEqual(@as(f64, 30.0 / 49.0), workbench.part.root.kind.split.ratio);

    var up = ui.MouseEvent{ .kind = .up, .x = boundary + 6, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: decoded divider drag resizes a vertical split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_vertical_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_vertical_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 14);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.vertical);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    try std.testing.expectEqual(@as(usize, 6), ui.cell.snap(first.rect.bottom()));

    var buf: [160]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[<0;3;7M\x1b[<32;3;10M\x1b[<0;3;10m", .{});
    var items = try ui.input.decode(allocator, seq);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key => return error.TestUnexpectedResult,
            .mouse => |*mouse| {
                if (workbench.handleTabDragMouse(mouse)) continue;
                if (workbench.handleQuickAccessMouse(mouse)) continue;
                if (workbench.handleStatusbarMouse(mouse)) continue;
                if (workbench.handleSashMouse(mouse)) continue;
            },
        }
    }

    try std.testing.expectEqual(@as(f64, 9.0 / 12.0), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(first.rect.h));
}

test "Workbench: breadcrumb row shows the workspace-relative path" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "crumbs/src/http-proxy.js", "function parseAuthority() {}");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/crumbs", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 2), pane.chromeHeight());
    const row = try workbench.frame.prev.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "http-proxy.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, ">") != null);
    try std.testing.expectEqual(@as(usize, 2), workbench.cursorCell().?.row);

    // The first breadcrumb item opens the folder picker.
    const control = workbench.breadcrumbs_control.?;
    try std.testing.expect(control.widget.itemCount() >= 2);
    const hit = control.widget.hits.items[0];
    var click = ui.MouseEvent{ .kind = .down, .x = hit.start, .y = 1, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expect(workbench.quick_access.inputService().isVisible());
    workbench.quick_access.inputService().hide();
}

test "Workbench: breadcrumb symbols come from a registered outline provider" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "symbols/file.ts", "class A {}");
    defer allocator.free(path);

    const Fake = struct {
        var labels = [_][]const u8{ "parseAuthority", "port" };
        var elements: [2]outline_mod.OutlineElement = undefined;
        var outline: outline_mod.IOutline = undefined;

        fn matches(_: *anyopaque, _: OutlineEditor) bool {
            return true;
        }
        fn create(_: *anyopaque, _: OutlineEditor, _: outline_mod.OutlineTarget) !?*outline_mod.IOutline {
            return &outline;
        }
        fn getElements(_: *anyopaque) []const outline_mod.OutlineElement {
            return &elements;
        }
        fn reveal(_: *anyopaque, _: *anyopaque, _: outline_mod.RevealOptions) !void {}
        fn dispose(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    Fake.elements[0] = .{ .element = @ptrCast(@constCast(&Fake.labels[0])), .label = Fake.labels[0] };
    Fake.elements[1] = .{ .element = @ptrCast(@constCast(&Fake.labels[1])), .label = Fake.labels[1] };
    Fake.outline = .{
        .context = @ptrCast(&context),
        .uri = path,
        .outline_kind = "test",
        .config = .{ .breadcrumbs_data_source = .{
            .context = @ptrCast(&context),
            .get_breadcrumb_elements = Fake.getElements,
        } },
        .on_did_change = null,
        .revealFn = Fake.reveal,
        .disposeFn = Fake.dispose,
    };

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    const registration = try workbench.outline_service.registerOutlineCreator(.{
        .context = @ptrCast(&context),
        .matches = Fake.matches,
        .create_outline = Fake.create,
    });
    defer registration.dispose();
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const row = try workbench.frame.prev.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "parseAuthority") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "port") != null);
}

test "Workbench: tab close cell closes and a dirty close arms first" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "close.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    var click = ui.MouseEvent{
        .kind = .down,
        .x = hit.close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    // A dirty tab arms on the first close activation.
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    try workbench.render(&out.writer);
    const pane2 = workbench.activePane().?;
    const hit2 = pane2.hits.items[0];
    var click2 = ui.MouseEvent{
        .kind = .down,
        .x = hit2.close_start.?,
        .y = ui.cell.snap(pane2.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click2));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try workbench.render(&out.writer);
    var click3 = ui.MouseEvent{
        .kind = .down,
        .x = pane2.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane2.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click3));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: preview replacement and dirty pin" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "preview_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "preview_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.openPreviewPath(path_a);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(!workbench.activePane().?.group.model.isPinned(.{ .editor = &workbench.activeTab().?.input.base }));

    try workbench.openPreviewPath(path_b);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(std.mem.endsWith(u8, workbench.activeTab().?.editor.path, "preview_b.txt"));

    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    workbench.refreshStatus();
    try std.testing.expect(workbench.activePane().?.group.model.isPinned(.{ .editor = &workbench.activeTab().?.input.base }));

    try workbench.openPreviewPath(path_a);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: disabling breadcrumbs removes the row and shifts content" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"breadcrumbs.enabled\":false}");
    settings_file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ buffer[0..dir_len], "settings.json" });
    defer allocator.free(settings_path);

    const path = try seedFile(allocator, io, &tmp, "no_crumbs.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.setUserSettingsPath(settings_path);
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 1), pane.chromeHeight());
    try std.testing.expectEqual(@as(usize, 1), workbench.cursorCell().?.row);
}

test "Workbench: double click pins a preview tab and toggles a pinned group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "dblclick.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&first));
    try std.testing.expect(!pane.group.model.isPinned(.{ .editor = &workbench.activeTab().?.input.base }));
    // A real terminal also delivers the release between the two presses.
    var up = ui.MouseEvent{ .kind = .up, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&up));
    // Simulate a slow second click caused by the first activation's work.
    workbench.last_tab_click.?.at_ms -= 700;
    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = &workbench.activeTab().?.input.base }));
    try std.testing.expect(workbench.expanded_pane == null);

    // The UI repaints the now-pinned label without italics.
    try workbench.render(&out.writer);
    const hit_after = pane.hits.items[0];
    var col = hit_after.start;
    while (col < hit_after.end) : (col += 1) {
        try std.testing.expect(grid_attr_italic(&workbench.frame.prev, col, y) == false);
    }

    // A second double click on the now-pinned tab expands the group.
    var third = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&third));
    var fourth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&fourth));
    try std.testing.expect(workbench.expanded_pane == pane);

    // And another double click restores the split layout.
    try workbench.render(&out.writer);
    var fifth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&fifth));
    var sixth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&sixth));
    try std.testing.expect(workbench.expanded_pane == null);
}

test "Workbench: double click still pins after a jittery drag starts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "jitter.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&first));

    // Hand jitter turns the pending click into a drag before the second press.
    var jitter = ui.MouseEvent{ .kind = .move, .x = x + 3, .y = y, .button = .left };
    try std.testing.expect(!workbench.handleTabDragMouse(&jitter));
    try std.testing.expect(workbench.handleTabMouse(&jitter));
    try std.testing.expect(workbench.drag_tab != null);

    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(!workbench.handleTabDragMouse(&second));
    try std.testing.expect(workbench.handleTabMouse(&second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = &workbench.activeTab().?.input.base }));
}
