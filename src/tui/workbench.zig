//! The multi-file terminal workbench: an editor-part-like shell over the
//! ported editor-groups service and `EditorGroupModel`.
//!
//! Layout is the terminal adaptation of the workbench editor part and of
//! `vs/base/browser/ui/grid`: every group gets a tab row and an editor pane,
//! groups are arranged in an oriented split tree, and the workbench composites
//! all visible panes into one frame before encoding a single ANSI diff. Each
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
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
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
const Sidebar = @import("./sidebar.zig").Sidebar;
const activity_bar_mod = @import("./activityBar.zig");
const history_mod = @import("../vs/workbench/services/history/common/history.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const quick_access_mod = @import("./quickAccess.zig");
const QuickAccessService = quick_access_mod.QuickAccessService;
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../vs/workbench/services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const ActivityBar = activity_bar_mod.ActivityBar;
const search_view_mod = @import("./searchView.zig");
const SearchView = search_view_mod.SearchView;
const search_service_mod = @import("../vs/workbench/services/search/common/searchService.zig");
const SearchService = search_service_mod.SearchService;
const search_types = @import("../vs/workbench/services/search/common/search.zig");
const FileContentProvider = search_types.FileContentProvider;
const replace_service_mod = @import("../vs/workbench/contrib/search/browser/replaceService.zig");
const ReplaceService = replace_service_mod.ReplaceService;
const replace_types = replace_service_mod;
const tree = @import("../vs/workbench/contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");
const editor_groups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");
const editor_input = @import("../vs/workbench/common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const Range = @import("../vs/editor/common/core/range.zig").Range;
const SearchOption = @import("./searchWidget.zig").Option;

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = enum { horizontal, vertical };
pub const Focus = enum { editor, sidebar };

/// Pane chrome for the terminal editor part. The active pane's outline uses
/// the focused border colour and priority 1, so it wins a shared edge in a
/// terminal that implements cell-border priority merging; inactive panes are
/// dim. The stroke width is 1/8 cell, matching the article's thin outlines.
const inactive_pane_border = ui.Color{ .r = 70, .g = 70, .b = 70 };
const active_pane_border = ui.Color{ .r = 0x4d, .g = 0x9b, .b = 0xd6 };
const pane_border_width: u8 = 32;
const min_pane_width: usize = 10;
const min_pane_height: usize = 3;

/// A tab drag can drop in the middle of a pane (move into that group) or on an
/// edge (split that pane and move into the new group), mirroring the drop
/// locations of VS Code's grid.
const DropZone = enum { center, left, right, top, bottom };
const DropTarget = struct { pane: *GroupPane, zone: DropZone };
const PendingTabDrag = struct { pane: *GroupPane, tab: *Tab, x: usize, y: usize };

const LayoutNode = struct {
    kind: union(enum) {
        leaf: *GroupPane,
        split: struct {
            direction: SplitDirection,
            ratio: f64,
            first: *LayoutNode,
            second: *LayoutNode,
        },
    },
    rect: ui.Rect = .{},
};

/// One editor group in the terminal editor part: the group model plus the tabs
/// (views/controllers) and the cell rectangle it occupies.
pub const GroupPane = struct {
    group: *editor_groups.EditorGroup,
    tabs: std.array_list.Managed(*Tab),
    hits: std.array_list.Managed(tab_bar.Hit),
    rect: ui.Rect = .{},

    pub fn init(allocator: Allocator, group: *editor_groups.EditorGroup) GroupPane {
        return .{
            .group = group,
            .tabs = std.array_list.Managed(*Tab).init(allocator),
            .hits = std.array_list.Managed(tab_bar.Hit).init(allocator),
        };
    }

    pub fn deinit(self: *GroupPane) void {
        self.hits.deinit();
        self.tabs.deinit();
    }

    pub fn activeTab(self: *const GroupPane) ?*Tab {
        const active = self.group.model.activeEditor() orelse return null;
        for (self.tabs.items) |tab| {
            if (&tab.input.base == active) return tab;
        }
        return null;
    }

    pub fn tabForInput(self: *const GroupPane, input: *EditorInput) ?*Tab {
        for (self.tabs.items) |tab| {
            if (&tab.input.base == input) return tab;
        }
        return null;
    }
};

const editor_mod = @import("../vs/workbench/common/editor.zig");

pub const Workbench = struct {
    allocator: Allocator,
    io: Io,
    cols: usize,
    rows: usize,

    service: *editor_groups.EditorGroupsService,
    panes: std.array_list.Managed(*GroupPane),
    layout: *LayoutNode,
    frame: ui.Frame,
    /// The terminal implements the cell-border protocol: split gutters are
    /// zero-width, panes get shared-edge outlines, and the dividers are sashes.
    cell_borders: bool = false,
    /// The split whose boundary is being dragged, if any.
    active_sash: ?*LayoutNode = null,
    /// Tab drag state: pending until the pointer moves, then a live drop target.
    pending_tab_drag: ?PendingTabDrag = null,
    drag_tab: ?*Tab = null,
    drag_source_pane: ?*GroupPane = null,
    drag_target: ?DropTarget = null,
    sidebar: ?*Sidebar = null,
    search_view: ?*SearchView = null,
    search_service: ?*SearchService = null,
    search_replace: ?*ReplaceService = null,
    sidebar_visible: bool = false,
    sidebar_width: usize = 28,
    activity_bar: ActivityBar = .{},
    active_activity: usize = 0,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    user_settings_path: ?[]u8,
    history: HistoryService,
    commands: CommandRegistry,
    quick_access: *QuickAccessService,
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
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.cell_borders = false;
        self.active_sash = null;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        self.search_replace = null;
        self.sidebar_visible = false;
        self.sidebar_width = 28;
        self.activity_bar = .{};
        self.active_activity = 0;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();

        self.panes = std.array_list.Managed(*GroupPane).init(allocator);
        errdefer {
            for (self.panes.items) |pane| {
                for (pane.tabs.items) |tab| tab.deinit();
                pane.deinit();
                allocator.destroy(pane);
            }
            self.panes.deinit();
        }

        const pane = try self.createPane(self.service.activeGroup());
        self.layout = try self.createLeaf(pane);
        errdefer self.destroyLayout(self.layout);

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
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.cell_borders = false;
        self.active_sash = null;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        self.search_replace = null;
        self.sidebar_visible = false;
        self.sidebar_width = 28;
        self.activity_bar = .{};
        self.active_activity = 0;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();

        self.panes = std.array_list.Managed(*GroupPane).init(allocator);
        errdefer {
            for (self.panes.items) |pane| {
                for (pane.tabs.items) |tab| tab.deinit();
                pane.deinit();
                allocator.destroy(pane);
            }
            self.panes.deinit();
        }

        const group = self.service.activeGroup();
        group.model.deinit();
        group.model = try group_mod.EditorGroupModel.initFromSerialized(allocator, .{}, data, registry);
        group.id = group.model.id;

        const pane = try self.createPane(group);
        self.layout = try self.createLeaf(pane);
        errdefer self.destroyLayout(self.layout);

        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();

        try self.initQuickAccess();
        errdefer self.history.deinit();
        errdefer self.commands.deinit();
        errdefer self.quick_access.deinit();
        self.layoutAll();

        const editors = try group.model.getEditors(allocator, .SEQUENTIAL, false);
        defer allocator.free(editors);
        for (editors) |input| {
            if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
            const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
            const tab = try Tab.initFromInput(allocator, file_input);
            try addTabToPane(pane, tab);
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
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;
        self.cell_borders = false;
        self.active_sash = null;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.focus = .editor;
        self.sidebar = null;
        self.search_view = null;
        self.search_service = null;
        self.search_replace = null;
        self.sidebar_visible = false;
        self.sidebar_width = 28;
        self.activity_bar = .{};
        self.active_activity = 0;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.user_settings_path = null;

        self.service = try editor_groups.EditorGroupsService.initFromSerializedPart(allocator, data, registry, .{});
        errdefer self.service.deinit();

        self.panes = std.array_list.Managed(*GroupPane).init(allocator);
        errdefer {
            for (self.panes.items) |pane| {
                for (pane.tabs.items) |tab| tab.deinit();
                pane.deinit();
                allocator.destroy(pane);
            }
            self.panes.deinit();
        }

        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();

        try self.initQuickAccess();
        errdefer self.history.deinit();
        errdefer self.commands.deinit();
        errdefer self.quick_access.deinit();
        self.layout = undefined;
        for (self.service.groups.items, 0..) |group, index| {
            const pane = try self.createPane(group);
            const leaf = try self.createLeaf(pane);
            if (index == 0) {
                self.layout = leaf;
            } else {
                self.layout = try self.createSplit(.horizontal, self.layout, leaf);
            }

            const editors = try group.model.getEditors(allocator, .SEQUENTIAL, false);
            defer allocator.free(editors);
            for (editors) |input| {
                if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
                const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
                const tab = try Tab.initFromInput(allocator, file_input);
                try addTabToPane(pane, tab);
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
        return FileEditorSerializer.init(self.allocator, self.io, self.cols, editorHeight(self.rows));
    }

    fn initQuickAccess(self: *Workbench) !void {
        self.history = HistoryService.init(self.allocator);
        errdefer self.history.deinit();

        self.commands = CommandRegistry.init(self.allocator);
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

        try self.registerDefaultCommands();
    }

    fn registerDefaultCommands(self: *Workbench) !void {
        const commands = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.action.quickOpen", .label = "Go to File...", .category = "File", .context = self, .run = commandQuickOpen },
            .{ .id = "workbench.action.showCommands", .label = "Show All Commands", .context = self, .run = commandShowCommands },
            .{ .id = "workbench.action.files.save", .label = "Save", .category = "File", .context = self, .run = commandSave },
            .{ .id = "workbench.action.closeActiveEditor", .label = "Close Editor", .category = "View", .context = self, .run = commandCloseEditor },
            .{ .id = "workbench.action.splitEditor", .label = "Split Editor", .category = "View", .context = self, .run = commandSplitEditor },
            .{ .id = "workbench.action.toggleSidebarVisibility", .label = "Toggle Primary Side Bar Visibility", .category = "View", .context = self, .run = commandToggleSidebar },
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
        self.quick_access.deinit();
        self.commands.deinit();
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.service.deinit();
        if (self.sidebar) |sidebar| sidebar.deinit();
        self.destroySearch();
        if (self.configuration) |configuration| configuration.deinit();
        if (self.user_settings_path) |path| self.allocator.free(path);
        self.workspace.deinit();
        for (self.panes.items) |pane| {
            for (pane.tabs.items) |tab| tab.deinit();
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.panes.deinit();
        self.destroyLayout(self.layout);
        self.frame.deinit();
        self.allocator.destroy(self);
    }

    fn editorHeight(rows: usize) usize {
        return @max(rows -| 1, 1);
    }

    fn createPane(self: *Workbench, group: *editor_groups.EditorGroup) !*GroupPane {
        const pane = try self.allocator.create(GroupPane);
        errdefer self.allocator.destroy(pane);
        pane.* = GroupPane.init(self.allocator, group);
        try self.panes.append(pane);
        return pane;
    }

    fn createLeaf(self: *Workbench, pane: *GroupPane) !*LayoutNode {
        const node = try self.allocator.create(LayoutNode);
        node.* = .{ .kind = .{ .leaf = pane } };
        return node;
    }

    fn createSplit(self: *Workbench, direction: SplitDirection, first: *LayoutNode, second: *LayoutNode) !*LayoutNode {
        const node = try self.allocator.create(LayoutNode);
        node.* = .{ .kind = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = first,
            .second = second,
        } } };
        return node;
    }

    fn destroyLayout(self: *Workbench, node: *LayoutNode) void {
        switch (node.kind) {
            .leaf => {},
            .split => |split| {
                self.destroyLayout(split.first);
                self.destroyLayout(split.second);
            },
        }
        self.allocator.destroy(node);
    }

    fn sidebarWidth(self: *const Workbench) usize {
        const max_width = @max(self.cols / 2, 10);
        return @min(self.sidebar_width, @max(max_width, 1));
    }

    const activity_width: usize = 3;

    fn sidebarShown(self: *const Workbench) bool {
        return self.sidebar_visible and self.sidebar != null and
            activity_width + self.sidebarWidth() + 8 < self.cols;
    }

    fn activityRect(self: *const Workbench) ui.Rect {
        return .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(activity_width),
            .h = @floatFromInt(self.rows),
        };
    }

    fn sidebarRect(self: *const Workbench) ui.Rect {
        return .{
            .x = @floatFromInt(activity_width),
            .y = 0,
            .w = @floatFromInt(self.sidebarWidth()),
            .h = @floatFromInt(self.rows),
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
        if (self.configuration) |configuration| {
            configuration.deinit();
            self.configuration = null;
        }
        self.workspace.deinit();
        self.workspace = replacement;
        try self.ensureConfiguration();
        try self.quick_access.setWorkspace(self.workspace);
    }

    /// Sets the user settings file before the Explorer/configuration service is
    /// created. The app derives it from `XDG_CONFIG_HOME`/`HOME`.
    pub fn setUserSettingsPath(self: *Workbench, path: ?[]const u8) !void {
        if (self.user_settings_path) |old| self.allocator.free(old);
        self.user_settings_path = if (path) |value| try self.allocator.dupe(u8, value) else null;
        if (self.configuration) |configuration| {
            configuration.deinit();
            self.configuration = null;
            try self.ensureConfiguration();
        }
    }

    fn ensureConfiguration(self: *Workbench) !void {
        if (self.configuration != null) return;
        self.configuration = try ConfigurationService.init(
            self.allocator,
            self.io,
            self.workspace,
            .{ .user_settings_path = self.user_settings_path },
        );
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
        self.sidebar_visible = true;
        if (self.active_activity >= self.activity_bar.count()) self.active_activity = 0;
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
        const replace = try self.allocator.create(ReplaceService);
        errdefer self.allocator.destroy(replace);
        replace.* = ReplaceService.init(self.allocator, .{
            .context = self,
            .apply_edits = searchApplyEdits,
            .save_file = searchSaveFile,
        });
        const view = try SearchView.init(
            self.allocator,
            self.workspace,
            service.interface(),
            replace,
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
        self.search_replace = replace;
        self.search_view = view;
    }

    fn destroySearch(self: *Workbench) void {
        if (self.search_view) |view| view.deinit();
        self.search_view = null;
        if (self.search_replace) |replace| self.allocator.destroy(replace);
        self.search_replace = null;
        if (self.search_service) |service| self.allocator.destroy(service);
        self.search_service = null;
    }

    pub fn showActivity(self: *Workbench, index: usize) !void {
        if (index >= self.activity_bar.count()) return;
        if (self.sidebar == null or self.search_view == null) try self.initSidebarFromWorkspace();
        self.active_activity = index;
        self.sidebar_visible = true;
        self.focus = .sidebar;
        if (index == 1) {
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
        self.sidebar_visible = !self.sidebar_visible;
        self.focus = if (self.sidebar_visible) .sidebar else .editor;
        self.layoutAll();
    }

    pub fn focusSidebar(self: *Workbench) void {
        if (!self.sidebarShown()) return;
        self.focus = .sidebar;
        if (self.active_activity == 1) {
            if (self.search_view) |view| view.focus();
        }
    }

    pub fn focusEditor(self: *Workbench) void {
        self.focus = .editor;
        if (self.search_view) |view| view.blur();
    }

    fn layoutAll(self: *Workbench) void {
        var rect = ui.Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.cols),
            .h = @floatFromInt(self.rows),
        };
        if (self.sidebarShown()) {
            const width = self.sidebarWidth();
            rect = .{
                .x = @floatFromInt(activity_width + width + 1),
                .y = 0,
                .w = @floatFromInt(self.cols - activity_width - width - 1),
                .h = @floatFromInt(self.rows),
            };
        }
        self.computeLayout(self.layout, rect);
        for (self.panes.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.setViewport(
                    @max(ui.cell.snap(pane.rect.w), 1),
                    editorHeight(@max(ui.cell.snap(pane.rect.h), 1)),
                );
                tab.view.resize() catch {};
            }
        }
    }

    fn computeLayout(self: *Workbench, node: *LayoutNode, rect: ui.Rect) void {
        node.rect = rect;
        switch (node.kind) {
            .leaf => |pane| pane.rect = rect,
            .split => |split| {
                if (split.direction == .horizontal) {
                    const gap = self.paneGap(split.direction, rect);
                    const available = @max(rect.w - gap, 0);
                    const first_width = @floor(available * split.ratio);
                    const first = ui.Rect{ .x = rect.x, .y = rect.y, .w = first_width, .h = rect.h };
                    const second = ui.Rect{
                        .x = rect.x + first_width + gap,
                        .y = rect.y,
                        .w = @max(rect.w - first_width - gap, 0),
                        .h = rect.h,
                    };
                    self.computeLayout(split.first, first);
                    self.computeLayout(split.second, second);
                } else {
                    const gap = self.paneGap(split.direction, rect);
                    const available = @max(rect.h - gap, 0);
                    const first_height = @floor(available * split.ratio);
                    const first = ui.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_height };
                    const second = ui.Rect{
                        .x = rect.x,
                        .y = rect.y + first_height + gap,
                        .w = rect.w,
                        .h = @max(rect.h - first_height - gap, 0),
                    };
                    self.computeLayout(split.first, first);
                    self.computeLayout(split.second, second);
                }
            },
        }
    }

    /// Gutter cells between two panes. Cell borders need none: both panes put
    /// a centred stroke on their own side of the shared edge. The glyph
    /// fallback needs one divider column/row when there is room.
    fn paneGap(self: *const Workbench, direction: SplitDirection, rect: ui.Rect) f64 {
        if (self.cell_borders) return 0;
        return switch (direction) {
            .horizontal => if (rect.w >= 6) 1 else 0,
            .vertical => if (rect.h >= 6) 1 else 0,
        };
    }

    /// Removes a leaf from the split tree and promotes its sibling, the
    /// terminal equivalent of Grid's branch demotion when the last view leaves
    /// a group. The root leaf is kept: the workbench always has one group.
    fn removePaneFromLayout(self: *Workbench, target: *GroupPane) bool {
        if (self.layout.kind == .leaf) return false;
        return self.removePaneFromNode(self.layout, target);
    }

    fn removePaneFromNode(self: *Workbench, node: *LayoutNode, target: *GroupPane) bool {
        switch (node.kind) {
            .leaf => return false,
            .split => |*split| {
                const first_matches = split.first.kind == .leaf and split.first.kind.leaf == target;
                const second_matches = split.second.kind == .leaf and split.second.kind.leaf == target;
                if (first_matches or second_matches) {
                    const keep = if (first_matches) split.second else split.first;
                    const removed = if (first_matches) split.first else split.second;
                    self.allocator.destroy(removed);
                    // Promote the sibling into this node, then release only the
                    // sibling container: its children now belong to `node`.
                    node.* = keep.*;
                    self.allocator.destroy(keep);
                    return true;
                }
                return self.removePaneFromNode(split.first, target) or
                    self.removePaneFromNode(split.second, target);
            },
        }
    }

    /// Removes an empty pane from the grid and the editor-group service,
    /// promoting its sibling. The last group is kept so the workbench always
    /// has a target for the next editor.
    fn collapseEmptyPane(self: *Workbench, pane: *GroupPane) void {
        if (pane.tabs.items.len != 0 or self.service.count() <= 1) return;
        self.active_sash = null;
        if (!self.removePaneFromLayout(pane)) return;
        self.service.removeGroup(pane.group) catch {};
        for (self.panes.items, 0..) |candidate, index| {
            if (candidate == pane) {
                _ = self.panes.orderedRemove(index);
                break;
            }
        }
        pane.deinit();
        self.allocator.destroy(pane);
        self.layoutAll();
    }

    fn replaceLeaf(self: *Workbench, target: *GroupPane, replacement: *LayoutNode) bool {
        if (self.layout.kind == .leaf and self.layout.kind.leaf == target) {
            replacement.kind.split.first = self.layout;
            self.layout = replacement;
            return true;
        }
        return self.replaceChild(self.layout, target, replacement);
    }

    fn replaceChild(self: *Workbench, node: *LayoutNode, target: *GroupPane, replacement: *LayoutNode) bool {
        switch (node.kind) {
            .leaf => return false,
            .split => |*split| {
                if (split.first.kind == .leaf and split.first.kind.leaf == target) {
                    split.first = replacement;
                    return true;
                }
                if (split.second.kind == .leaf and split.second.kind.leaf == target) {
                    split.second = replacement;
                    return true;
                }
                if (self.replaceChild(split.first, target, replacement)) return true;
                return self.replaceChild(split.second, target, replacement);
            },
        }
    }

    fn activeGroup(self: *Workbench) *editor_groups.EditorGroup {
        return self.service.activeGroup();
    }

    fn paneForGroup(self: *Workbench, group: *editor_groups.EditorGroup) ?*GroupPane {
        for (self.panes.items) |pane| {
            if (pane.group == group) return pane;
        }
        return null;
    }

    pub fn activePane(self: *Workbench) ?*GroupPane {
        return self.paneForGroup(self.service.activeGroup());
    }

    pub fn activeTab(self: *Workbench) ?*Tab {
        const pane = self.activePane() orelse return null;
        return pane.activeTab();
    }

    pub fn tabCount(self: *Workbench) usize {
        var count: usize = 0;
        for (self.panes.items) |pane| count += pane.tabs.items.len;
        return count;
    }

    pub fn groupCount(self: *const Workbench) usize {
        return self.service.count();
    }

    fn orderedTabs(pane: *GroupPane, allocator: Allocator, out: *std.array_list.Managed(*Tab)) !void {
        const editors = try pane.group.model.getEditors(allocator, .SEQUENTIAL, false);
        defer allocator.free(editors);
        for (editors) |input| {
            for (pane.tabs.items) |tab| {
                if (&tab.input.base == input) {
                    try out.append(tab);
                    break;
                }
            }
        }
    }

    fn activeIndex(pane: *GroupPane, ordered: []const *Tab) usize {
        const active = pane.group.model.activeEditor() orelse return 0;
        for (ordered, 0..) |tab, index| {
            if (&tab.input.base == active) return index;
        }
        return 0;
    }

    fn addTabToPane(pane: *GroupPane, tab: *Tab) !void {
        try pane.tabs.append(tab);
        tab.editor.setViewport(
            @max(ui.cell.snap(pane.rect.w), 1),
            editorHeight(@max(ui.cell.snap(pane.rect.h), 1)),
        );
        try tab.view.resize();
    }

    /// Opens a path through the editor-groups service. If the resource is
    /// already open in another group, the service reveals that group and the
    /// newly created input is discarded.
    pub fn openPath(self: *Workbench, path: []const u8) !void {
        const editor = try Editor.create(self.allocator, self.io, path, self.cols, editorHeight(self.rows));
        errdefer {
            editor.deinit();
            self.allocator.destroy(editor);
        }
        const input = try FileEditorInput.init(self.allocator, editor);
        errdefer input.deinit();

        const opened = try self.service.openEditor(
            &input.base,
            null,
            .{ .open = .{ .pinned = true, .active = true } },
        );

        const pane = self.paneForGroup(opened.group) orelse return error.GroupPaneMissing;
        if (!opened.result.is_new) {
            input.deinit();
            if (pane.tabForInput(opened.result.editor)) |tab| {
                try tab.ensureControllers();
                tab.view.focusEditor();
            }
            try self.history.add(path);
            return;
        }

        const tab = try Tab.initFromInput(self.allocator, input);
        try addTabToPane(pane, tab);
        try tab.ensureControllers();
        try self.history.add(path);
    }

    pub fn activateIndex(self: *Workbench, index: usize) !void {
        const pane = self.activePane() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try orderedTabs(pane, self.allocator, &ordered);
        if (index >= ordered.items.len) return;

        const tab = ordered.items[index];
        _ = try pane.group.model.setActive(&tab.input.base);
        try tab.ensureControllers();
        tab.view.focusEditor();
        tab.onEditorChanged(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
        try tab.refresh();
        try self.history.add(tab.input.editor.path);
    }

    pub fn switchTab(self: *Workbench, delta: isize) !void {
        const pane = self.activePane() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try orderedTabs(pane, self.allocator, &ordered);
        if (ordered.items.len == 0) return;

        const current: isize = @intCast(activeIndex(pane, ordered.items));
        const count: isize = @intCast(ordered.items.len);
        const next: isize = @mod(current + delta, count);
        try self.activateIndex(@intCast(next));
    }

    pub fn switchGroup(self: *Workbench, delta: isize) !void {
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
            if (self.activeTab()) |tab| try tab.ensureControllers();
            return;
        }
    }

    /// Splits the active group and moves the active tab into the new group.
    pub fn splitActive(self: *Workbench, direction: SplitDirection) !void {
        self.active_sash = null;
        self.clearTabDrag();
        const source = self.activePane() orelse return;
        const tab = source.activeTab() orelse return;

        const new_group = try self.service.addGroup(
            source.group,
            if (direction == .horizontal) .RIGHT else .DOWN,
        );
        const new_pane = try self.createPane(new_group);
        const new_leaf = try self.createLeaf(new_pane);

        _ = try source.group.model.closeEditor(&tab.input.base, .MOVE, false);
        for (source.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) {
                _ = source.tabs.orderedRemove(index);
                break;
            }
        }
        try new_pane.tabs.append(tab);
        _ = try new_group.model.openEditor(&tab.input.base, .{ .pinned = true, .active = true });

        const old_leaf = self.findLeaf(self.layout, source) orelse return error.LayoutLeafMissing;
        const split = try self.createSplit(direction, old_leaf, new_leaf);
        if (!self.replaceLeaf(source, split)) {
            return error.LayoutLeafMissing;
        }

        self.service.activateGroup(new_group);
        self.layoutAll();
        if (self.activeTab()) |active| {
            try active.ensureControllers();
            try active.refresh();
        }
    }

    fn findLeaf(self: *Workbench, node: *LayoutNode, pane: *GroupPane) ?*LayoutNode {
        switch (node.kind) {
            .leaf => |candidate| return if (candidate == pane) node else null,
            .split => |split| {
                if (self.findLeaf(split.first, pane)) |leaf| return leaf;
                return self.findLeaf(split.second, pane);
            },
        }
    }

    pub fn closeActive(self: *Workbench) !bool {
        self.active_sash = null;
        self.clearTabDrag();
        const pane = self.activePane() orelse return false;
        const tab = pane.activeTab() orelse return false;

        if (!tab.editor.requestCloseTab()) return false;

        _ = try pane.group.model.closeEditor(&tab.input.base, .UNKNOWN, true);
        for (pane.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) {
                _ = pane.tabs.orderedRemove(index);
                break;
            }
        }
        tab.deinit();

        if (self.tabCount() == 0) return false;

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

    pub fn handleTabKey(self: *Workbench, event: *const ui.KeyEvent) !TabKeyResult {
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
        for (self.panes.items) |pane| {
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
        for (self.panes.items) |pane| {
            if (x >= ui.cell.snap(pane.rect.x) and x < ui.cell.snap(pane.rect.right()) and
                y >= ui.cell.snap(pane.rect.y) and y < ui.cell.snap(pane.rect.bottom()))
            {
                return pane;
            }
        }
        return null;
    }

    /// The split boundary under a cell, if any. With cell borders the shared
    /// edge is between two cells, so both adjacent columns/rows are in the hit
    /// zone; the glyph fallback only has the divider cell.
    fn dividerAt(self: *const Workbench, x: usize, y: usize) ?*LayoutNode {
        return self.findDivider(self.layout, x, y);
    }

    fn findDivider(self: *const Workbench, node: *LayoutNode, x: usize, y: usize) ?*LayoutNode {
        switch (node.kind) {
            .leaf => return null,
            .split => |split| {
                const rect = node.rect;
                if (split.direction == .horizontal) {
                    const edge = ui.cell.snap(split.first.rect.right());
                    const on_edge = x == edge or (self.cell_borders and x + 1 == edge);
                    if (on_edge and y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom())) {
                        return node;
                    }
                } else {
                    const edge = ui.cell.snap(split.first.rect.bottom());
                    const on_edge = y == edge or (self.cell_borders and y + 1 == edge);
                    if (on_edge and x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right())) {
                        return node;
                    }
                }
                return self.findDivider(split.first, x, y) orelse self.findDivider(split.second, x, y);
            },
        }
    }

    /// Starts, updates and ends a sash drag. Called before tab and editor mouse
    /// handling; a drag consumes every event until the button is released.
    pub fn handleSashMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.drag_tab != null or self.pending_tab_drag != null) return false;
        if (self.active_sash) |split| {
            switch (event.kind) {
                .move => {
                    if (event.button == .left) {
                        self.resizeSash(split, event.x, event.y);
                    } else {
                        self.active_sash = null;
                    }
                    return true;
                },
                .up, .click => {
                    self.resizeSash(split, event.x, event.y);
                    self.active_sash = null;
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
            return event.kind != .wheel and self.dividerAt(event.x, event.y) != null;
        }

        const split = self.dividerAt(event.x, event.y) orelse return false;
        self.active_sash = split;
        return true;
    }

    fn resizeSash(self: *Workbench, node: *LayoutNode, x: usize, y: usize) void {
        const split = switch (node.kind) {
            .split => |*value| value,
            .leaf => return,
        };
        const rect = node.rect;
        const gap = self.paneGap(split.direction, rect);
        if (split.direction == .horizontal) {
            const available = rect.w - gap;
            if (available < 2 * min_pane_width) return;
            const target = @as(f64, @floatFromInt(x)) - rect.x;
            const clamped = std.math.clamp(
                target,
                @as(f64, @floatFromInt(min_pane_width)),
                available - @as(f64, @floatFromInt(min_pane_width)),
            );
            split.ratio = clamped / available;
        } else {
            const available = rect.h - gap;
            if (available < 2 * min_pane_height) return;
            const target = @as(f64, @floatFromInt(y)) - rect.y;
            const clamped = std.math.clamp(
                target,
                @as(f64, @floatFromInt(min_pane_height)),
                available - @as(f64, @floatFromInt(min_pane_height)),
            );
            split.ratio = clamped / available;
        }
        self.layoutAll();
    }

    fn orderedTabAt(self: *Workbench, pane: *GroupPane, index: usize) ?*Tab {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        orderedTabs(pane, self.allocator, &ordered) catch return null;
        if (index >= ordered.items.len) return null;
        return ordered.items[index];
    }

    /// Called before the sash, overlay and editor routing so a live tab drag
    /// owns the pointer for its whole gesture, even across pane boundaries.
    pub fn handleTabDragMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.drag_tab == null) return false;
        switch (event.kind) {
            .move => self.updateDragTarget(event),
            .up => self.finishTabDrag(),
            .click, .down => self.clearTabDrag(),
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
        const x0 = ui.cell.snap(pane.rect.x);
        const y0 = ui.cell.snap(pane.rect.y);
        const width = ui.cell.snap(pane.rect.right()) -| x0;
        const height = ui.cell.snap(pane.rect.bottom()) -| y0;
        if (width == 0 or height == 0) return;
        const rel_x = event.x -| x0;
        const rel_y = event.y -| y0;
        const zone: DropZone = if (rel_y * 4 < height)
            .top
        else if (rel_y * 4 >= height * 3)
            .bottom
        else if (rel_x * 4 < width)
            .left
        else if (rel_x * 4 >= width * 3)
            .right
        else
            .center;
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
        for (source.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) {
                _ = source.tabs.orderedRemove(index);
                break;
            }
        }
        try dest.tabs.append(tab);
        _ = try dest.group.model.openEditor(&tab.input.base, .{ .pinned = true, .active = true });
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

        const direction: SplitDirection = switch (zone) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
            .center => unreachable,
        };
        const new_first = zone == .left or zone == .top;
        const new_group = try self.service.addGroup(target.group, switch (zone) {
            .left => .LEFT,
            .right => .RIGHT,
            .top => .UP,
            .bottom => .DOWN,
            .center => unreachable,
        });
        const new_pane = try self.createPane(new_group);
        try self.moveTabToPane(source, new_pane, tab);

        // Insert before collapsing the source: if source and target are
        // siblings, collapsing first would promote and destroy the target leaf.
        const target_leaf = self.findLeaf(self.layout, target) orelse return error.LayoutLeafMissing;
        const new_leaf = try self.createLeaf(new_pane);
        const split = try self.createSplit(
            direction,
            if (new_first) new_leaf else target_leaf,
            if (new_first) target_leaf else new_leaf,
        );
        if (!self.replaceLeaf(target, split)) return error.LayoutLeafMissing;
        self.service.activateGroup(new_group);
        self.collapseEmptyPane(source);
        self.layoutAll();
    }

    fn renderDropTarget(self: *Workbench, target: DropTarget) void {
        if (!self.cell_borders) return;
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

        if (self.active_activity == 1) {
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

        if (self.active_activity != 0) {
            if (event.key == .up) try self.showActivity(@mod(self.active_activity + self.activity_bar.count() - 1, self.activity_bar.count()));
            if (event.key == .down) try self.showActivity(@mod(self.active_activity + 1, self.activity_bar.count()));
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

        if (event.x < activity_width) {
            if (event.kind == .down) {
                if (self.activity_bar.hitAt(event.x, event.y, self.activityRect())) |index| {
                    self.showActivity(index) catch {};
                }
            }
            return true;
        }

        if (event.x > activity_width + self.sidebarWidth()) return false;
        if (event.kind == .down) self.focus = .sidebar;
        if (self.active_activity == 1) {
            if (self.search_view) |view| _ = view.handleMouse(event);
            return true;
        }
        if (self.active_activity != 0) return true;

        const sidebar = self.sidebar orelse return false;
        if (event.kind == .down) {
            if (sidebar.handleClick(event.x, event.y) catch null) |path| {
                self.openPath(path) catch {};
                self.focus = .editor;
            }
        }
        return true;
    }

    pub fn handleTabMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.sidebarShown() and event.x <= activity_width + self.sidebarWidth()) return false;

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

        if (event.kind == .down) {
            self.pending_tab_drag = null;
            if (self.search_view) |view| view.blur();
        }
        const pane = self.paneAt(event.x, event.y) orelse return false;
        if (ui.cell.snap(pane.rect.y) != event.y) {
            if (pane.tabs.items.len > 0 and event.kind == .down) {
                self.service.activateGroup(pane.group);
            }
            return false;
        }

        if (event.kind == .down and pane.tabs.items.len > 0) {
            self.service.activateGroup(pane.group);
            if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                const tab = self.orderedTabAt(pane, index);
                self.activateIndex(index) catch {};
                if (tab) |value| {
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

    /// Converts a terminal mouse position inside a pane into editor-relative
    /// coordinates, or null when the event belongs to a tab row.
    pub fn editorMouseEvent(self: *Workbench, event: ui.MouseEvent) ?ui.MouseEvent {
        if (self.sidebarShown() and event.x <= activity_width + self.sidebarWidth()) return null;
        const pane = self.paneAt(event.x, event.y) orelse return null;
        if (pane.group != self.service.activeGroup()) return null;
        if (event.y == ui.cell.snap(pane.rect.y)) return null;
        if (pane.activeTab() == null) return null;

        var adjusted = event;
        adjusted.x -|= ui.cell.snap(pane.rect.x);
        adjusted.y -|= ui.cell.snap(pane.rect.y) + 1;
        return adjusted;
    }

    pub fn render(self: *Workbench, writer: *std.Io.Writer) !void {
        self.frame.begin();

        if (self.sidebarShown()) {
            const focused = self.focus == .sidebar;
            self.activity_bar.render(&self.frame.next, self.activityRect(), self.active_activity, focused);
            if (self.active_activity == 0) {
                if (self.sidebar) |sidebar| {
                    try sidebar.render(&self.frame.next, self.sidebarRect(), focused);
                }
            } else if (self.active_activity == 1) {
                if (self.search_view) |view| {
                    try view.render(&self.frame.next, self.sidebarRect());
                }
            } else {
                self.renderPlaceholder(self.sidebarRect(), focused);
            }

            const divider_x = activity_width + self.sidebarWidth();
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
            };
            var row: usize = 0;
            while (row < self.rows) : (row += 1) {
                self.frame.next.putCodepoint(divider_x, row, '│', 1, style);
            }
        }

        for (self.panes.items) |pane| {
            try self.renderPane(pane);
        }
        if (self.cell_borders) {
            // Each pane is outlined on its own cell edges. Adjacent panes put
            // strokes on opposite cells of the shared boundary and the
            // terminal merges them into one line, so no gutter is needed.
            for (self.panes.items) |pane| self.renderPaneBorder(pane);
            if (self.drag_target) |target| self.renderDropTarget(target);
        } else {
            self.renderDividers(self.layout);
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
        try orderedTabs(pane, self.allocator, &ordered);

        const infos = try self.allocator.alloc(tab_bar.TabInfo, ordered.items.len);
        defer self.allocator.free(infos);
        for (ordered.items, 0..) |tab, index| {
            infos[index] = .{
                .label = tab.input.base.getName(),
                .dirty = tab.input.base.isDirty(),
            };
        }

        try tab_bar.draw(
            &self.frame.next,
            infos,
            activeIndex(pane, ordered.items),
            x,
            y,
            width,
            &pane.hits,
        );

        if (pane.activeTab()) |active| {
            try active.view.paint();
            ui.CellGrid.blit(
                &self.frame.next,
                active.view.grid(),
                x,
                y + 1,
                width,
                height -| 1,
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
        const header = if (self.active_activity == 1) " SEARCH " else " SETTINGS ";
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

    pub fn cursorCell(self: *Workbench) ?ViewCell {
        if (self.quick_access.isOpen()) return null;
        if (self.focus == .sidebar) return null;
        const pane = self.activePane() orelse return null;
        const active = pane.activeTab() orelse return null;
        const cell = active.view.cursorCell() orelse return null;
        const row = ui.cell.snap(pane.rect.y) + 1 + cell.row;
        const col = ui.cell.snap(pane.rect.x) + cell.col;
        if (row >= self.rows or col >= self.cols) return null;
        return .{ .row = row, .col = col };
    }

    pub fn resize(self: *Workbench, cols: usize, rows: usize) !void {
        self.active_sash = null;
        self.clearTabDrag();
        const new_cols = @max(cols, 1);
        const new_rows = @max(rows, 1);
        if (new_cols == self.cols and new_rows == self.rows) {
            for (self.panes.items) |pane| {
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
        if (self.cell_borders == enabled) return;
        self.cell_borders = enabled;
        self.layoutAll();
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
    for (self.panes.items) |pane| {
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
    for (self.panes.items) |pane| {
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
    for (self.panes.items) |pane| {
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
    for (self.panes.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (!std.mem.eql(u8, tab.editor.path, path)) continue;
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
    for (self.panes.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (std.mem.eql(u8, tab.editor.path, path)) {
                try tab.editor.save();
                return;
            }
        }
    }
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

fn seedFile(allocator: Allocator, io: Io, tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    errdefer allocator.free(path);
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
    try std.testing.expectEqual(@as(usize, 1), workbench.cursorCell().?.row);

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
    const first_pane = workbench.panes.items[0];
    const second_pane = workbench.panes.items[1];
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

    const first = workbench.panes.items[0];
    const second = workbench.panes.items[1];
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

    try std.testing.expectEqual(@as(usize, 25), ui.cell.snap(workbench.layout.kind.split.first.rect.w));
    const boundary = ui.cell.snap(workbench.layout.kind.split.first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.active_sash != null);

    var move = ui.MouseEvent{ .kind = .move, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expectEqual(@as(f64, 0.6), workbench.layout.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(workbench.layout.kind.split.first.rect.w));

    var up = ui.MouseEvent{ .kind = .up, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(workbench.active_sash == null);
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
    try std.testing.expectEqual(@as(usize, 2), workbench.panes.items.len);

    _ = try workbench.closeActive();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.panes.items.len);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 50), ui.cell.snap(workbench.layout.rect.w));
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

    const source = workbench.panes.items[1];
    const target = workbench.panes.items[0];
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
    try std.testing.expectEqual(@as(usize, 1), workbench.panes.items.len);
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

    const pane = workbench.panes.items[0];
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
    try std.testing.expectEqual(@as(usize, 2), workbench.panes.items.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const first = workbench.panes.items[0];
    const second = workbench.panes.items[1];
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
    try std.testing.expect(workbench.panes.items[0].rect.x > 0);

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
    try std.testing.expect(!workbench.sidebar_visible);
    try std.testing.expect(try workbench.handleSidebarKey(&ctrl_b));
    try std.testing.expect(workbench.sidebar_visible);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 results in 1 files") != null);
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
    try std.testing.expectEqual(@as(usize, 1), workbench.active_activity);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results") != null or std.mem.indexOf(u8, out.written(), "Search") != null);

    const settings_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 3 };
    try std.testing.expect(workbench.handleSidebarMouse(&settings_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.active_activity);

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SETTINGS") != null);

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.active_activity);
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
