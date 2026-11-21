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
const grid_mod = @import("../../base/browser/ui/grid/grid.zig");
const editor_drop_target = @import("./parts/editor/editorDropTarget.zig");
const editor_group_view = @import("./parts/editor/editorGroupView.zig");
const editor_part = @import("./parts/editor/editorPart.zig");
const Tab = @import("./parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const FileEditorSerializer = @import("../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorSerializer;
const editor_factory = @import("../common/editor/editorFactory.zig");
const tui_editor_mod = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = tui_editor_mod.Editor;
const TextEdit = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const View = @import("../../../tui/editorView.zig").View;
const terminal_editor_config = @import("../../editor/browser/config/terminalEditorConfiguration.zig");
const editor_options = @import("../../editor/common/config/editorOptions.zig");
const ViewCell = @import("../../../tui/editorView.zig").Cell;
const tab_bar = @import("./parts/editor/multiEditorTabsControl.zig");
const Sidebar = @import("../contrib/files/browser/views/explorerView.zig").Sidebar;
const activity_bar_mod = @import("./parts/activitybar/activitybarPart.zig");
const ActivityBarPart = @import("./parts/activitybar/activitybarPart.zig").ActivityBarPart;
const SidebarPart = @import("./parts/sidebar/sidebarPart.zig").SidebarPart;
const LayoutModel = @import("./layout.zig").LayoutModel;
const statusbar_mod = @import("./parts/statusbar/statusbarPart.zig");
const StatusbarService = statusbar_mod.StatusbarService;
const EntryAccessor = statusbar_mod.EntryAccessor;
const statusbar_types = @import("../services/statusbar/browser/statusbar.zig");
const ActivityService = @import("../services/activity/browser/activityService.zig").ActivityService;
const history_mod = @import("../services/history/common/history.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const quick_access_mod = @import("./quickaccess.zig");
const QuickAccessService = quick_access_mod.QuickAccessService;
const editor_status_mod = @import("./parts/editor/editorStatus.zig");
const EditorStatus = editor_status_mod.EditorStatus;
const workspace_context = @import("../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const universal_watcher_mod = @import("../../platform/files/node/watcher/watcher.zig");
const UniversalWatcher = universal_watcher_mod.UniversalWatcher;
const watch_common = @import("../../platform/files/common/watcher.zig");
const WatchRequest = watch_common.WatchRequest;
const languages_associations = @import("../../editor/common/services/languagesAssociations.zig");
const working_copy_service_mod = @import("../services/workingCopy/common/workingCopyService.zig");
const WorkingCopyService = working_copy_service_mod.WorkingCopyService;
const keybinding_service = @import("../services/keybinding/browser/keybindingService.zig");
const key_codes = @import("../../base/common/keyCodes.zig");
const keybinding_registry = @import("../../platform/keybinding/common/keybindingsRegistry.zig");
const resolved_keybinding_item = @import("../../platform/keybinding/common/resolvedKeybindingItem.zig");
const context_key_mod = @import("../../platform/contextkey/common/contextkey.zig");
const user_keybindings_mod = @import("../services/keybinding/browser/userKeybindings.zig");
const theme_service_mod = @import("../services/themes/browser/workbenchThemeService.zig");
const theme_configuration_mod = @import("../services/themes/common/themeConfiguration.zig");
const host_color_scheme_mod = @import("../services/themes/common/hostColorSchemeService.zig");
const color_utils = @import("../../platform/theme/common/colorUtils.zig");
const syntax_theme_mod = @import("../../editor/standalone/browser/standaloneThemeService.zig");
const theme_colors_mod = @import("./themeColors.zig");
const SettingsWatcher = configuration_mod.SettingsWatcher;
const lifecycle_mod = @import("../../base/common/lifecycle.zig");
const IDisposable = lifecycle_mod.IDisposable;
const breadcrumbs_mod = @import("./parts/editor/breadcrumbs.zig");
const BreadcrumbsService = breadcrumbs_mod.BreadcrumbsService;
const BreadcrumbsSettings = breadcrumbs_mod.Settings;
const breadcrumbs_model = @import("./parts/editor/breadcrumbsModel.zig");
const breadcrumbs_picker = @import("./parts/editor/breadcrumbsPicker.zig");
const breadcrumbs_control_mod = @import("./parts/editor/breadcrumbsControl.zig");
const BreadcrumbsControl = breadcrumbs_control_mod.BreadcrumbsControl;
const BreadcrumbsSelection = breadcrumbs_control_mod.Selection;
const BreadcrumbsSelectMode = breadcrumbs_control_mod.SelectMode;
const BreadcrumbsHost = breadcrumbs_control_mod.Host;
const outline_service_mod = @import("../services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const outline_mod = @import("../services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const IOutlineCreator = outline_mod.IOutlineCreator;
const DocumentSymbolsOutline = @import("../contrib/codeEditor/browser/outline/documentSymbolsOutline.zig").DocumentSymbolsOutline;
const OutlineModel = @import("../../editor/contrib/documentSymbols/browser/outlineModel.zig").OutlineModel;
const quick_input_common = @import("../../platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input_common.QuickPickItem;
const QuickPick = @import("../../platform/quickinput/browser/quickInput.zig").QuickPick;
const dialogs = @import("../../platform/dialogs/common/dialogs.zig");
const markers_common = @import("../contrib/markers/common/markers.zig");
const MarkersStatusBar = @import("../contrib/markers/browser/markersStatusBar.zig").MarkersStatusBar;
const problems_view_mod = @import("../../../tui/problemsView.zig");
const ProblemsView = problems_view_mod.ProblemsView;
const range_highlight_mod = @import("./codeeditor.zig");
const RangeHighlightDecorations = range_highlight_mod.RangeHighlightDecorations;

const search_view_mod = @import("../contrib/search/browser/searchViewTerminal.zig");
const SearchView = search_view_mod.SearchView;
const search_service_mod = @import("../services/search/common/searchService.zig");
const SearchService = search_service_mod.SearchService;
const search_types = @import("../services/search/common/search.zig");
const FileContentProvider = search_types.FileContentProvider;
const replace_service_mod = @import("../contrib/search/browser/replaceService.zig");
const replace_types = replace_service_mod;
const search_configuration = @import("../contrib/search/common/searchConfiguration.zig");
const tree = @import("../contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const group_mod = @import("../common/editor/editorGroupModel.zig");
const editor_groups = @import("../services/editor/common/editorGroupsService.zig");
const extensions_registry = @import("../services/extensions/common/extensionsRegistry.zig");
const time_compat = @import("../../base/common/timeCompat.zig");
const json_language = @import("../services/language/common/jsonLanguageClient.zig");
const configuration_extension_point = @import("../api/common/configurationExtensionPoint.zig");
const editor_input = @import("../common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const editorBrowser = @import("../../editor/browser/editorBrowser.zig");
const Range = @import("../../editor/common/core/range.zig").Range;
const LanguageFeaturesService = @import("../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const languages = @import("../../editor/common/languages.zig");
const CancellationToken = @import("../../base/common/cancellation.zig").CancellationToken;
const go_to_symbol = @import("../../editor/contrib/gotoSymbol/browser/goToSymbol.zig");
const references_model = @import("../../editor/contrib/gotoSymbol/browser/referencesModel.zig");
const ReferencesModel = references_model.ReferencesModel;
const go_to_commands = @import("../../editor/contrib/gotoSymbol/browser/goToCommands.zig");
const goto_symbol_quick_access = @import("../contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const hover_operation = @import("../../editor/contrib/hover/browser/hoverOperation.zig");
const hover_types = @import("../../editor/contrib/hover/browser/hoverTypes.zig");
const strings = @import("../../base/common/strings.zig");
const topmost_line_monitor = @import("../contrib/markdown/browser/topmostLineMonitor.zig");
const MarkdownPreviewConfig = @import("../contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const std_uri = @import("../../base/common/stdUri.zig");
const MarkerService = @import("../../platform/markers/common/markerService.zig").MarkerService;
const MarkerDecorationsService = @import("../../editor/common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers_mod = @import("../../platform/markers/common/markers.zig");
const WordBasedCompletionProvider = @import("../../editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const Position = @import("../../editor/common/core/position.zig").Position;
const Selection = @import("../../editor/common/core/selection.zig").Selection;
const EOL = @import("../../editor/common/core/misc/eolCounter.zig").EOL;
const encoding_mod = @import("../services/textfile/common/encoding.zig");
const SearchOption = @import("../contrib/search/browser/searchWidget.zig").Option;
const terminal_service_mod = @import("../contrib/terminal/browser/terminalService.zig");
const terminal_configuration = @import("../contrib/terminal/common/terminalConfiguration.zig");
const terminal_common = @import("../contrib/terminal/common/terminal.zig");
const terminal_panel = @import("../contrib/terminal/browser/terminalTabbedView.zig");
const terminal_input_mod = @import("../contrib/terminal/browser/terminalInput.zig");
const terminal_view = @import("../contrib/terminal/browser/terminalRenderer.zig");
const diff_widget_mod = @import("../../editor/browser/widget/diffEditor/diffEditorWidget.zig");
const git_cli_mod = @import("../../../tui/gitCli.zig");
const git_service_mod = @import("../contrib/git/browser/gitService.zig");
const git_common_mod = @import("../contrib/git/common/gitService.zig");
const scm_service_mod = @import("../contrib/scm/common/scmService.zig");
const scm_common = @import("../contrib/scm/common/scm.zig");
const quick_diff_service_mod = @import("../contrib/scm/common/quickDiffService.zig");
const quick_diff_controller_mod = @import("../../../tui/quickDiffController.zig");
const git_scm_provider_mod = @import("../../../tui/gitScmProvider.zig");
const scm_view_mod = @import("../../../tui/scmView.zig");
const text_diff_editor_mod = @import("./parts/editor/textDiffEditor.zig");
const storage_mod = @import("../../platform/storage/common/storage.zig");
const TerminalService = terminal_service_mod.TerminalService;

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = grid_mod.Orientation;
pub const Focus = enum { editor, sidebar, statusbar, breadcrumbs, terminal };

/// Handles for the context keys the workbench maintains. User keybindings use
/// them in `when` clauses; keys the terminal cannot know stay undefined, which
/// evaluates to false (e.g. `treeFindOpen`).
const ContextKeyHandles = struct {
    editor_focus: context_key_mod.IContextKey,
    editor_text_focus: context_key_mod.IContextKey,
    input_focus: context_key_mod.IContextKey,
    list_focus: context_key_mod.IContextKey,
    side_bar_focus: context_key_mod.IContextKey,
    status_bar_focus: context_key_mod.IContextKey,
    terminal_focus: context_key_mod.IContextKey,
    in_quick_open: context_key_mod.IContextKey,
    in_files_picker: context_key_mod.IContextKey,
    explorer_viewlet_visible: context_key_mod.IContextKey,
    explorer_viewlet_focus: context_key_mod.IContextKey,
    files_explorer_focus: context_key_mod.IContextKey,
    search_viewlet_visible: context_key_mod.IContextKey,
    search_view_focus: context_key_mod.IContextKey,
    scm_viewlet_visible: context_key_mod.IContextKey,
    scm_view_focus: context_key_mod.IContextKey,
    explorer_resource_is_root: context_key_mod.IContextKey,
    explorer_resource_readonly: context_key_mod.IContextKey,
    tree_find_open: context_key_mod.IContextKey,
    resource_scheme: context_key_mod.IContextKey,
    editor_read_only: context_key_mod.IContextKey,
};

/// Terminal host color scheme. The terminal has no portable OS color-scheme
/// API, so the default is dark; `COLORFGBG`-style detection is left to the
/// host application. High contrast is reported as false.
const TerminalColorSchemeHost = struct {
    dark: bool = true,
    high_contrast: bool = false,

    fn isDark(context: *anyopaque) bool {
        return @as(*TerminalColorSchemeHost, @ptrCast(@alignCast(context))).dark;
    }

    fn isHighContrast(context: *anyopaque) bool {
        return @as(*TerminalColorSchemeHost, @ptrCast(@alignCast(context))).high_contrast;
    }

    fn interface(self: *TerminalColorSchemeHost) host_color_scheme_mod.IHostColorSchemeService {
        return .{
            .context = self,
            .is_dark = isDark,
            .is_high_contrast = isHighContrast,
        };
    }
};
pub const DiffRef = enum { head, index, working, empty };
const DiffWidgetOptions = diff_widget_mod.Options;

const SymbolActionContext = struct {
    workbench: *Workbench,
    action: *const go_to_commands.ActionDescriptor,
};

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

/// The tab a save confirmation is currently acting on. The dialog itself
/// owns the message/detail strings; these pointers stay valid because the
/// modal blocks every other close path until the dialog is resolved.
const CloseTabRequest = struct {
    pane: *GroupPane,
    tab: *Tab,
};

/// What a modal save confirmation resolves to. Closing one tab and quitting
/// share the same Save / Don't Save / Cancel wording but act on different
/// editor sets, matching upstream `doHandleCloseConfirmation` and
/// `AbstractCloseAllAction`.
const DialogRequest = union(enum) {
    close_tab: CloseTabRequest,
    quit,
};

const editor_mod = @import("../common/editor.zig");

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
    markers_status: ?*MarkersStatusBar = null,
    problems_view: ?*ProblemsView = null,
    range_highlights: ?*RangeHighlightDecorations = null,
    search_badge_buf: [32]u8 = undefined,
    search_badge_count: usize = 0,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    settings_watcher: ?*SettingsWatcher = null,
    /// Workspace file watcher. Kept separate from the settings watcher so a
    /// workspace change never triggers a settings reload.
    files_watcher: ?*UniversalWatcher = null,
    user_settings_paths: []const []const u8,
    /// User keybinding files (VS Code profile then TUI override). Watched by
    /// the settings watcher; reloaded with the rest of the configuration.
    keybindings_paths: []const []const u8,
    history: HistoryService,
    commands: CommandRegistry,
    working_copy_service: WorkingCopyService,
    tab_service: ?*keybinding_service.KeybindingService,
    tab_command_result: ?TabKeyResult = null,
    global_service: ?*keybinding_service.KeybindingService,
    statusbar_service: ?*keybinding_service.KeybindingService,
    context_keys: ?*context_key_mod.ContextKeyService,
    context_key_handles: ?ContextKeyHandles,
    user_keybindings: ?*user_keybindings_mod.UserKeybindings,
    /// Filtered user bindings passed to the global host; owned by the workbench.
    global_user_overrides: []const *const resolved_keybinding_item.ResolvedKeybindingItem,
    theme_colors: ?*color_utils.ColorRegistry,
    theme_service: ?*theme_service_mod.ThemeService,
    syntax_theme: syntax_theme_mod.SyntaxTheme,
    syntax_theme_ready: bool,
    theme_scheme_host: TerminalColorSchemeHost,
    theme_palette: ?*theme_colors_mod.ThemeColors,
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
    navigation_arena: std.heap.ArenaAllocator,
    pending_references: ?*ReferencesModel = null,
    pending_symbols: ?[]goto_symbol_quick_access.Entry = null,
    symbol_action_contexts: [go_to_commands.actions.len]SymbolActionContext = undefined,
    breadcrumbs_dirty: bool = false,
    hovered_tab: ?*Tab = null,
    hovered_pane: ?*GroupPane = null,
    hovered_title_action_pane: ?*GroupPane = null,
    last_tab_click: ?TabClick = null,
    expanded_pane: ?*GroupPane = null,
    declarative: ?*const extensions_registry.Registry = null,
    json_client: ?*json_language.Client = null,
    language_features: ?*LanguageFeaturesService = null,
    marker_service: ?*MarkerService = null,
    marker_decorations: ?*MarkerDecorationsService = null,
    word_completion_provider: ?*WordBasedCompletionProvider = null,
    word_completion_registration: ?IDisposable = null,
    outline_registration: ?IDisposable = null,
    document_symbol_listener: ?@import("../../base/common/event.zig").Emitter(usize).ListenerId = null,
    focus: Focus = .editor,
    is_pasting: bool = false,
    terminal_service: ?*TerminalService = null,
    terminal_input: terminal_input_mod.Encoder = .{},
    suppress_global_command: bool = false,
    git_cli: ?*git_cli_mod.GitCli = null,
    git_delegate: ?*git_common_mod.IGitExtensionDelegate = null,
    git_service: ?*git_service_mod.GitService = null,
    scm_service: ?*scm_service_mod.SCMService = null,
    quick_diff_storage: ?*storage_mod.InMemoryStorageService = null,
    quick_diff_service: ?*quick_diff_service_mod.QuickDiffService = null,
    quick_diff_controller: ?*quick_diff_controller_mod.Controller = null,
    scm_view: ?*scm_view_mod.ScmView = null,
    git_scm_provider: ?*git_scm_provider_mod.GitScmProvider = null,
    git_root: ?[]u8 = null,
    scm_interface: ?*scm_common.ISCMService = null,
    git_status_accessor: ?EntryAccessor = null,
    git_status_buf: [96]u8 = undefined,
    git_badge_buf: [32]u8 = undefined,
    git_badge_count: usize = 0,
    next_git_refresh: i64 = 0,
    git_status_dirty: bool = true,
    /// Set when the quit confirmation commits to closing the window.
    quit_requested: bool = false,
    /// The modal save confirmation, if one is open.
    dialog: ?*ui.Dialog = null,
    pending_dialog: ?DialogRequest = null,

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
        self.context_keys = null;
        self.context_key_handles = null;
        self.user_keybindings = null;
        self.global_user_overrides = &.{};
        self.theme_colors = null;
        self.theme_service = null;
        self.syntax_theme = .{};
        self.syntax_theme_ready = false;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git_cli = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.git_scm_provider = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
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
        self.navigation_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.navigation_arena.deinit();
        self.pending_references = null;
        self.pending_symbols = null;
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
        self.declarative = null;
        self.json_client = null;
        self.language_features = null;
        self.marker_service = null;
        self.marker_decorations = null;
        self.word_completion_provider = null;
        self.word_completion_registration = null;
        self.outline_registration = null;
        self.document_symbol_listener = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_paths = &.{};
        self.keybindings_paths = &.{};

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
        self.context_keys = null;
        self.context_key_handles = null;
        self.user_keybindings = null;
        self.global_user_overrides = &.{};
        self.theme_colors = null;
        self.theme_service = null;
        self.syntax_theme = .{};
        self.syntax_theme_ready = false;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git_cli = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.git_scm_provider = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
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
        self.navigation_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.navigation_arena.deinit();
        self.pending_references = null;
        self.pending_symbols = null;
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
        self.declarative = null;
        self.json_client = null;
        self.language_features = null;
        self.marker_service = null;
        self.marker_decorations = null;
        self.word_completion_provider = null;
        self.word_completion_registration = null;
        self.outline_registration = null;
        self.document_symbol_listener = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_paths = &.{};
        self.keybindings_paths = &.{};

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
            if (tab.file_input != null) try tab.view.setStatusBarVisible(false);
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
        self.context_keys = null;
        self.context_key_handles = null;
        self.user_keybindings = null;
        self.global_user_overrides = &.{};
        self.theme_colors = null;
        self.theme_service = null;
        self.syntax_theme = .{};
        self.syntax_theme_ready = false;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git_cli = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.git_scm_provider = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
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
        self.navigation_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.navigation_arena.deinit();
        self.pending_references = null;
        self.pending_symbols = null;
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
        self.declarative = null;
        self.json_client = null;
        self.language_features = null;
        self.marker_service = null;
        self.marker_decorations = null;
        self.word_completion_provider = null;
        self.word_completion_registration = null;
        self.outline_registration = null;
        self.document_symbol_listener = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        self.configuration = null;
        self.settings_watcher = null;
        self.files_watcher = null;
        self.user_settings_paths = &.{};
        self.keybindings_paths = &.{};

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
                if (tab.file_input != null) try tab.view.setStatusBarVisible(false);
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
        self.problems_view = null;
        self.markers_status = null;
        self.range_highlights = null;
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
        try self.layout_model.setSize(.panel, 10);
        try self.layout_model.setVisible(.panel, false);

        for (activity_bar_mod.default_activities) |activity| {
            try self.activity_bar_part.addActivity(activity);
        }
        try self.activity_bar_part.setVisible(true);

        try self.sidebar_part.pane.addComposite(.{ .id = "explorer", .name = "Explorer", .order = 1 });
        try self.sidebar_part.pane.addComposite(.{ .id = "search", .name = "Search", .order = 2 });
        try self.sidebar_part.pane.addComposite(.{ .id = "scm", .name = "Source Control", .order = 3 });
        try self.sidebar_part.pane.addComposite(.{ .id = markers_common.PROBLEMS_ACTIVITY_ID, .name = markers_common.PROBLEMS_TITLE, .order = 4 });
        try self.sidebar_part.pane.addComposite(.{ .id = "settings", .name = "Settings", .order = 5 });
        try self.sidebar_part.setWidth(28);

        try self.initStatusHint();
    }

    fn initStatusHint(self: *Workbench) !void {
        self.status_hint_accessor = try self.statusbar.addEntry(.{
            .name = "Quit hint",
            .text = "Ctrl-Q quit",
        }, "workbench.hint", .right, .{ .number = 0 });
        self.markers_status = try MarkersStatusBar.init(self.allocator, &self.statusbar);
        const highlights = try self.allocator.create(RangeHighlightDecorations);
        errdefer self.allocator.destroy(highlights);
        highlights.* = RangeHighlightDecorations.init(self.allocator, .{
            .context = self,
            .active_resource = markerHighlightActiveResource,
            .set_range_highlight = markerHighlightSetRange,
        });
        self.range_highlights = highlights;
    }

    fn deinitShellModels(self: *Workbench) void {
        if (self.problems_view) |view| {
            view.deinit();
            self.problems_view = null;
        }
        if (self.range_highlights) |highlights| {
            highlights.deinit();
            self.allocator.destroy(highlights);
            self.range_highlights = null;
        }
        if (self.markers_status) |status| {
            status.deinit();
            self.markers_status = null;
        }
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
            .{ .id = "list.focusUp", .label = "Focus Previous Item", .category = "List", .context = self, .run = commandListFocusUp },
            .{ .id = "list.focusDown", .label = "Focus Next Item", .category = "List", .context = self, .run = commandListFocusDown },
            .{ .id = "list.focusFirst", .label = "Focus First Item", .category = "List", .context = self, .run = commandListFocusFirst },
            .{ .id = "list.focusLast", .label = "Focus Last Item", .category = "List", .context = self, .run = commandListFocusLast },
            .{ .id = "list.focusPageUp", .label = "Focus Previous Page", .category = "List", .context = self, .run = commandListFocusPageUp },
            .{ .id = "list.focusPageDown", .label = "Focus Next Page", .category = "List", .context = self, .run = commandListFocusPageDown },
            .{ .id = "list.collapse", .label = "Collapse", .category = "List", .context = self, .run = commandListCollapse },
            .{ .id = "list.expand", .label = "Expand", .category = "List", .context = self, .run = commandListExpand },
            .{ .id = "list.toggleExpand", .label = "Toggle Expand", .category = "List", .context = self, .run = commandListToggleExpand },
            .{ .id = "list.select", .label = "Select", .category = "List", .context = self, .run = commandListSelect },
            .{ .id = "workbench.action.openSettingsJson", .label = "Open User Settings (JSON)", .category = "Preferences", .context = self, .run = commandOpenSettingsJson },
            .{ .id = "workbench.action.openGlobalKeybindingsFile", .label = "Open Keyboard Shortcuts (JSON)", .category = "Preferences", .context = self, .run = commandOpenKeybindingsJson },
            .{ .id = "workbench.action.closeActiveEditor", .label = "Close Editor", .category = "View", .context = self, .run = commandCloseEditor },
            .{ .id = "breadcrumbs.focusAndSelect", .label = "Focus and Select Breadcrumbs", .category = "View", .context = self, .run = commandFocusAndSelectBreadcrumbs },
            .{ .id = "breadcrumbs.focus", .label = "Focus Breadcrumbs", .category = "View", .context = self, .run = commandFocusBreadcrumbs },
            .{ .id = "workbench.action.splitEditor", .label = "Split Editor", .category = "View", .context = self, .run = commandSplitEditor },
            .{ .id = "workbench.action.splitEditorOrthogonal", .label = "Split Editor Orthogonal", .category = "View", .context = self, .run = commandSplitEditorOrthogonal },
            .{ .id = "workbench.action.navigateLeft", .label = "Focus Group Left", .category = "View", .context = self, .run = commandNavigateLeft },
            .{ .id = "workbench.action.navigateRight", .label = "Focus Group Right", .category = "View", .context = self, .run = commandNavigateRight },
            .{ .id = "workbench.action.navigateUp", .label = "Focus Group Up", .category = "View", .context = self, .run = commandNavigateUp },
            .{ .id = "workbench.action.navigateDown", .label = "Focus Group Down", .category = "View", .context = self, .run = commandNavigateDown },
            .{ .id = "workbench.action.navigateEditorGroups", .label = "Cycle Editor Groups", .category = "View", .context = self, .run = commandCycleGroup },
            .{ .id = "workbench.action.evenEditorWidths", .label = "Reset Editor Group Sizes", .category = "View", .context = self, .run = commandEvenEditorWidths },
            .{ .id = "workbench.action.increaseViewWidth", .label = "Increase Editor Width", .category = "View", .context = self, .run = commandIncreaseViewWidth },
            .{ .id = "workbench.action.decreaseViewWidth", .label = "Decrease Editor Width", .category = "View", .context = self, .run = commandDecreaseViewWidth },
            .{ .id = "workbench.action.increaseViewHeight", .label = "Increase Editor Height", .category = "View", .context = self, .run = commandIncreaseViewHeight },
            .{ .id = "workbench.action.decreaseViewHeight", .label = "Decrease Editor Height", .category = "View", .context = self, .run = commandDecreaseViewHeight },
            .{ .id = "workbench.action.maximizeEditor", .label = "Maximize Editor Group", .category = "View", .context = self, .run = commandMaximizeEditor },
            .{ .id = "workbench.action.closePanel", .label = "Close Panel", .category = "View", .context = self, .run = commandClosePanel },
            .{ .id = "workbench.action.closeAllEditors", .label = "Close All Editors", .category = "View", .context = self, .run = commandCloseAllEditors },
            .{ .id = "workbench.action.closeOtherEditors", .label = "Close Other Editors", .category = "View", .context = self, .run = commandCloseOtherEditors },
            .{ .id = "workbench.action.joinAllGroups", .label = "Join All Groups", .category = "View", .context = self, .run = commandJoinAllGroups },
            .{ .id = "workbench.action.lastEditorInGroup", .label = "Last Editor in Group", .category = "View", .context = self, .run = commandLastEditorInGroup },
            .{ .id = "workbench.action.previousEditor", .label = "Previous Editor", .category = "View", .context = self, .run = commandPreviousEditor },
            .{ .id = "workbench.action.openEditorAtIndex1", .label = "Open Editor 1", .category = "View", .context = self, .run = commandOpenEditorAtIndex1 },
            .{ .id = "workbench.action.revertAndCloseActiveEditor", .label = "Revert and Close Editor", .category = "View", .context = self, .run = commandRevertAndCloseActiveEditor },
            .{ .id = "workbench.action.createTerminalEditor", .label = "Create Terminal Editor", .category = "View", .context = self, .run = commandCreateTerminalEditor },
            .{ .id = "workbench.view.explorer", .label = "View: Show Explorer", .category = "View", .context = self, .run = commandViewExplorer },
            .{ .id = "workbench.view.scm", .label = "View: Show Source Control", .category = "View", .context = self, .run = commandViewScm },
            .{ .id = markers_common.Markers.SHOW_MARKERS_VIEW_ACTION_ID, .label = "View: Show Problems", .category = "View", .context = self, .run = commandShowProblems },
            .{ .id = markers_common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .label = "View: Toggle Problems", .category = "View", .context = self, .run = commandToggleProblems },
            .{ .id = "git.refresh", .label = "Refresh", .category = "Source Control", .context = self, .run = commandGitRefresh },
            .{ .id = "git.openChange", .label = "Open Change", .category = "Source Control", .context = self, .run = commandGitOpenChange },
            .{ .id = "git.openFile", .label = "Open File", .category = "Source Control", .context = self, .run = commandGitOpenFile },
            .{ .id = "workbench.action.compareEditor.nextChange", .label = "Go to Next Change", .category = "Diff", .context = self, .run = commandDiffNext },
            .{ .id = "workbench.action.compareEditor.previousChange", .label = "Go to Previous Change", .category = "Diff", .context = self, .run = commandDiffPrevious },
            .{ .id = "workbench.action.compareEditor.swapSides", .label = "Swap Sides", .category = "Diff", .context = self, .run = commandDiffSwap },
            .{ .id = "workbench.action.compareEditor.refreshDiff", .label = "Refresh Diff", .category = "Diff", .context = self, .run = commandDiffRefresh },
            .{ .id = "workbench.action.toggleSidebarVisibility", .label = "Toggle Primary Side Bar Visibility", .category = "View", .context = self, .run = commandToggleSidebar },
            .{ .id = "workbench.action.focusStatusBar", .label = "Focus Status Bar", .category = "View", .context = self, .run = commandFocusStatusBar },
            .{ .id = "workbench.action.terminal.toggleTerminal", .label = "Toggle Terminal", .category = "Terminal", .context = self, .run = commandToggleTerminal },
            .{ .id = "workbench.action.terminal.new", .label = "New Terminal", .category = "Terminal", .context = self, .run = commandNewTerminal },
            .{ .id = "workbench.action.terminal.kill", .label = "Kill Terminal", .category = "Terminal", .context = self, .run = commandKillTerminal },
            .{ .id = "workbench.action.terminal.focus", .label = "Focus Terminal", .category = "Terminal", .context = self, .run = commandFocusTerminal },
            .{ .id = "workbench.action.terminal.focusNext", .label = "Focus Next Terminal", .category = "Terminal", .context = self, .run = commandFocusNextTerminal },
            .{ .id = "workbench.action.terminal.focusPrevious", .label = "Focus Previous Terminal", .category = "Terminal", .context = self, .run = commandFocusPreviousTerminal },
            .{ .id = "workbench.action.terminal.resizeUp", .label = "Resize Terminal Panel Up", .category = "Terminal", .context = self, .run = commandResizeTerminalUp },
            .{ .id = "workbench.action.terminal.resizeDown", .label = "Resize Terminal Panel Down", .category = "Terminal", .context = self, .run = commandResizeTerminalDown },
            .{ .id = "markdown.showPreviewToSide", .label = "Open Preview to the Side", .category = "Markdown", .requires_editor = true, .context = self, .run = commandShowMarkdownPreview },
            .{ .id = "markdown.togglePreview", .label = "Toggle Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandToggleMarkdownPreview },
            .{ .id = "markdown.preview.refresh", .label = "Refresh Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandRefreshMarkdownPreview },
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
            .{ .id = "editor.action.smartSelect.grow", .label = "Expand Selection", .category = "Selection", .context = self, .requires_editor = true, .run = commandExpandSelection },
            .{ .id = "editor.action.smartSelect.shrink", .label = "Shrink Selection", .category = "Selection", .context = self, .requires_editor = true, .run = commandShrinkSelection },
            .{ .id = "editor.action.formatSelection", .label = "Format Selection", .category = "Editor", .context = self, .requires_editor = true, .run = commandFormatSelection },
            .{ .id = "editor.action.indentationToSpaces", .label = "Convert Indentation to Spaces", .category = "Editor", .context = self, .requires_editor = true, .run = commandIndentationToSpaces },
            .{ .id = "editor.action.indentationToTabs", .label = "Convert Indentation to Tabs", .category = "Editor", .context = self, .requires_editor = true, .run = commandIndentationToTabs },
            .{ .id = "editor.action.wordHighlight.trigger", .label = "Trigger Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightTrigger },
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

        for (go_to_commands.actions, 0..) |_, index| {
            const action = &go_to_commands.actions[index];
            self.symbol_action_contexts[index] = .{ .workbench = self, .action = action };
            try self.commands.register(.{
                .id = action.id,
                .label = action.label,
                .description = action.description,
                .category = "Go",
                .context = &self.symbol_action_contexts[index],
                .requires_editor = true,
                .run = commandSymbolNavigation,
            });
        }
        try self.commands.register(.{
            .id = goto_symbol_quick_access.command_id,
            .label = goto_symbol_quick_access.command_label,
            .description = "Go to a symbol in the active editor.",
            .category = "Go",
            .context = self,
            .requires_editor = true,
            .run = commandGotoSymbol,
        });
        try self.commands.register(.{
            .id = "editor.action.showHover",
            .label = "Show or Focus Hover",
            .description = "Show or focus the editor hover at the cursor.",
            .category = "Editor",
            .context = self,
            .requires_editor = true,
            .run = commandShowHover,
        });
    }

    pub fn handleQuickAccessKey(self: *Workbench, event: *ui.KeyEvent) !bool {
        return self.quick_access.handleKey(event);
    }

    pub fn handleQuickAccessMouse(self: *Workbench, event: *ui.MouseEvent) bool {
        return self.quick_access.handleMouse(event);
    }

    /// Routes one key to the modal dialog. Returns false when no dialog is
    /// open. Every key is consumed while it is open; Escape cancels, Enter or
    /// Space activates the focused button.
    pub fn handleDialogKey(self: *Workbench, event: *ui.KeyEvent) bool {
        const dialog = self.dialog orelse return false;
        switch (dialog.handleKey(event)) {
            .none => {},
            .activate => |index| self.resolveDialogButton(index),
            .cancel => self.resolveDialog(.CANCEL),
        }
        return true;
    }

    /// Routes one mouse event to the modal dialog. Every event is consumed
    /// while it is open; a click outside the buttons only changes focus.
    pub fn handleDialogMouse(self: *Workbench, event: *ui.MouseEvent) bool {
        const dialog = self.dialog orelse return false;
        if (dialog.handleMouse(event)) |index| self.resolveDialogButton(index);
        return true;
    }

    pub fn isDialogOpen(self: *const Workbench) bool {
        return self.dialog != null;
    }

    /// True once the quit confirmation saved or discarded every dirty tab and
    /// the host should leave the event loop.
    pub fn shouldQuit(self: *const Workbench) bool {
        return self.quit_requested;
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
        if (self.dialog) |dialog| {
            dialog.deinit();
            self.dialog = null;
        }
        self.pending_dialog = null;
        if (self.outline_registration) |registration| {
            registration.dispose();
            self.outline_registration = null;
        }
        if (self.document_symbol_listener) |listener| {
            if (self.language_features) |features| features.document_symbol_provider.on_did_change.unlisten(listener);
            self.document_symbol_listener = null;
        }
        self.disposeBreadcrumbs();
        self.breadcrumbs_arena.deinit();
        self.navigation_arena.deinit();
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
        self.freeUserOverrides(self.global_user_overrides);
        self.global_user_overrides = &.{};
        if (self.user_keybindings) |bindings| bindings.deinit();
        if (self.context_keys) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.theme_palette) |palette| self.allocator.destroy(palette);
        if (self.syntax_theme_ready) self.syntax_theme.deinit();
        if (self.theme_service) |service| service.deinit();
        if (self.theme_colors) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
        }
        self.quick_access.deinit();
        self.working_copy_service.deinit();
        self.commands.deinit();
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.service.deinit();
        self.deinitGit();
        if (self.sidebar) |sidebar| sidebar.deinit();
        self.destroySearch();
        if (self.settings_watcher) |watcher| watcher.deinit();
        if (self.files_watcher) |watcher| {
            watcher.stop();
            watcher.deinit();
        }
        if (self.terminal_service) |service| {
            service.deinit();
            self.terminal_service = null;
        }
        if (self.configuration) |configuration| configuration.deinit();
        freeOwnedPaths(self.allocator, self.user_settings_paths);
        freeOwnedPaths(self.allocator, self.keybindings_paths);
        self.workspace.deinit();
        // The part owns the group views; disposing it disposes the tab views.
        self.part.deinit();
        if (self.word_completion_registration) |registration| registration.dispose();
        if (self.word_completion_provider) |provider| self.allocator.destroy(provider);
        if (self.marker_decorations) |service| service.deinit();
        if (self.marker_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.language_features) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
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

    fn workbenchRows(self: *const Workbench) usize {
        return if (self.statusBarVisible()) self.rows - 1 else self.rows;
    }

    /// The bottom panel is visible only while it has a terminal. Hiding the
    /// layout state keeps the editor area full height when the last tab closes.
    pub fn terminalVisible(self: *const Workbench) bool {
        return self.layout_model.isVisible(.panel) and
            self.terminal_service != null and
            self.terminal_service.?.count() > 0;
    }

    fn panelHeight(self: *const Workbench) usize {
        if (!self.terminalVisible()) return 0;
        const available = self.workbenchRows();
        const wanted = if (self.layout_model.size(.panel) == 0) 10 else self.layout_model.size(.panel);
        const max_height = @max(@min(available / 2, available -| 1), 1);
        return @min(@max(wanted, 1), max_height);
    }

    fn editorRows(self: *const Workbench) usize {
        return @max(self.workbenchRows() -| self.panelHeight(), 1);
    }

    pub fn panelRect(self: *const Workbench) ui.Rect {
        if (!self.terminalVisible()) return .{};
        const x = self.editorAreaX();
        const width = self.editorAreaWidth();
        const height = self.panelHeight();
        return .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(self.editorRows()),
            .w = @floatFromInt(width),
            .h = @floatFromInt(height),
        };
    }

    fn editorAreaX(self: *const Workbench) usize {
        if (self.sidebarShown()) {
            return self.activityBarWidth() + self.sidebarWidth() + 1;
        }
        return 0;
    }

    fn editorAreaWidth(self: *const Workbench) usize {
        return self.cols -| self.editorAreaX();
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

    /// Shows the activity container with `id` (for example `workbench.view.scm`).
    pub fn showActivityById(self: *Workbench, id: []const u8) !bool {
        for (self.activity_bar_part.activities.items, 0..) |activity, index| {
            if (!std.mem.eql(u8, activity.id, id)) continue;
            try self.showActivity(index);
            return true;
        }
        return false;
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
            .h = @floatFromInt(self.workbenchRows()),
        };
    }

    fn sidebarRect(self: *const Workbench) ui.Rect {
        return .{
            .x = @floatFromInt(self.activityBarWidth()),
            .y = 0,
            .w = @floatFromInt(self.sidebarWidth()),
            .h = @floatFromInt(self.workbenchRows()),
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

    /// Sets the user settings files before the Explorer/configuration service
    /// is created. The app derives them from the VS Code profile and the
    /// terminal's own config directory; later layers override earlier ones.
    pub fn setUserSettingsPaths(self: *Workbench, paths: []const []const u8) !void {
        freeOwnedPaths(self.allocator, self.user_settings_paths);
        self.user_settings_paths = try dupeOwnedPaths(self.allocator, paths);
        if (self.configuration) |configuration| {
            if (self.settings_watcher) |watcher| {
                watcher.deinit();
                self.settings_watcher = null;
            }
            configuration.deinit();
            self.configuration = null;
            try self.ensureConfiguration();
            self.applyEditorSettingsToAllTabs();
            self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
            self.disposeBreadcrumbs();
            self.layoutAll();
        }
    }

    /// Sets the user keybinding files. They are watched by the settings
    /// watcher; the keymap itself is rebuilt by the keybinding phase.
    pub fn setKeybindingsPaths(self: *Workbench, paths: []const []const u8) !void {
        freeOwnedPaths(self.allocator, self.keybindings_paths);
        self.keybindings_paths = try dupeOwnedPaths(self.allocator, paths);
        if (self.settings_watcher) |watcher| {
            watcher.setExtraPaths(self.keybindings_paths) catch {};
        }
        self.reloadKeybindings();
    }

    fn ensureConfiguration(self: *Workbench) !void {
        if (self.configuration != null) return;
        self.configuration = try ConfigurationService.init(
            self.allocator,
            self.io,
            self.workspace,
            .{
                .user_settings_paths = self.user_settings_paths,
                .defaults_json = &.{ search_configuration.defaults_json, terminal_configuration.defaults_json, theme_configuration_mod.defaults_json },
            },
        );
        self.settings_watcher = SettingsWatcher.init(self.allocator, self.io, self.configuration.?) catch null;
        if (self.settings_watcher) |watcher| {
            watcher.setOnReload(.{ .context = self, .callback = onSettingsReloaded });
            watcher.setExtraPaths(self.keybindings_paths) catch {};
        }
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
    }

    fn onSettingsReloaded(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyConfiguredLanguageAssociationsToAllEditors();
        self.applyEditorSettingsToAllTabs();
        self.reloadKeybindings();
        self.applyThemeSettings();
        self.applyBreadcrumbsSettings();
        self.applyMarkdownPreviewConfig();
        if (self.quick_diff_controller) |controller| {
            controller.setIgnoreTrimWhitespace(self.resolvedIgnoreTrimWhitespace());
            controller.setConfig(.{
                .decorations = self.resolvedDiffDecorations(),
                .gutter_pattern = .{ .added = true, .modified = true },
            });
        }
        if (self.git_scm_provider != null) self.refreshGitStatus();
    }

    fn editorSettingsReader(self: *Workbench) terminal_editor_config.Reader {
        return .{ .context = self, .get_value = readEditorSetting };
    }

    fn applyEditorSettingsToTab(self: *Workbench, tab: *Tab) void {
        if (tab.isDiff()) return;
        const reader = self.editorSettingsReader();
        const language_id = tab.editor.languageId();
        const resource = tab.editor.path;
        _ = tab.editor.applyEditorSettings(reader, language_id, resource) catch false;
        _ = tab.view.applyEditorSettings(reader, language_id, resource) catch false;
        if (self.theme_palette) |palette| tab.view.setThemeColors(palette);
    }

    fn applyEditorSettingsToAllTabs(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| self.applyEditorSettingsToTab(tab);
        }
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
    pub fn handleFileChanges(self: *Workbench, changes: []const @import("../../platform/files/common/files.zig").FileChange) void {
        for (changes) |change| {
            if (change.type != .UPDATED) continue;
            self.git_status_dirty = true;
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    if (tab.isDiff()) continue;
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
        self.working_copy_service.registerWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor)) catch {};
    }

    fn unregisterWorkingCopy(self: *Workbench, tab: *Tab) void {
        _ = self.working_copy_service.unregisterWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor));
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

    fn onWorkspaceFileChanges(changes: []const @import("../../platform/files/common/files.zig").FileChange, self: *Workbench) !void {
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
        if (tab.isDiff()) return;
        if (!self.autoRevealEnabled(tab.editor.path)) return;
        if (self.sidebar) |sidebar| sidebar.revealPath(tab.editor.path) catch {};
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
        if (std.mem.eql(u8, activity.id, markers_common.PROBLEMS_ACTIVITY_ID)) {
            try self.ensureProblemsView();
            if (self.problems_view) |view| view.refresh();
            self.updateProblemsHighlight();
        } else if (self.range_highlights) |highlights| {
            highlights.removeHighlightRange();
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
        if (!visible) {
            if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        }
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
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (self.search_view) |view| view.blur();
    }

    pub fn focusStatusBar(self: *Workbench) void {
        if (!self.statusBarVisible()) return;
        self.focus = .statusbar;
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        if (self.statusbar.main_part.focusedHandle() == null) {
            if (self.statusbar.main_part.lastFocusedHandle()) |handle| {
                self.statusbar.main_part.setFocused(handle);
            }
            if (self.statusbar.main_part.focusedHandle() == null) {
                _ = self.statusbar.main_part.focusNextEntry();
            }
        }
        if (self.activeTab()) |tab| tab.focusEditor();
        if (self.search_view) |view| view.blur();
    }

    fn ensureProblemsView(self: *Workbench) !void {
        if (self.problems_view) |view| {
            view.setService(self.marker_service);
            return;
        }
        const view = try ProblemsView.init(self.allocator, self.marker_service, .{
            .context = self,
            .preview_marker = problemsPreviewMarker,
            .open_marker = problemsOpenMarker,
            .selection_changed = problemsSelectionChanged,
            .workspace_root = problemsWorkspaceRoot,
            .focus_editor = problemsFocusEditor,
        });
        self.problems_view = view;
    }

    pub fn showProblems(self: *Workbench) !void {
        if (!try self.showActivityById(markers_common.PROBLEMS_ACTIVITY_ID)) return;
        self.focusSidebar();
        if (self.problems_view) |view| view.refresh();
        self.updateProblemsHighlight();
    }

    pub fn toggleProblems(self: *Workbench) !void {
        const active = self.activity_bar_part.active_id orelse "";
        if (self.sidebarShown() and self.focus == .sidebar and
            std.mem.eql(u8, active, markers_common.PROBLEMS_ACTIVITY_ID))
        {
            try self.toggleSidebar();
            return;
        }
        try self.showProblems();
    }

    fn problemsFocused(self: *const Workbench) bool {
        if (self.focus != .sidebar or !self.sidebarShown()) return false;
        return std.mem.eql(
            u8,
            self.activity_bar_part.active_id orelse "",
            markers_common.PROBLEMS_ACTIVITY_ID,
        );
    }

    /// Keeps the editor range highlight in sync with the Problems selection.
    /// The highlight is only shown while Problems owns focus, matching the
    /// upstream `updateRangeHighlights` rule.
    pub fn updateProblemsHighlight(self: *Workbench) void {
        const highlights = self.range_highlights orelse return;
        if (!self.problemsFocused()) {
            highlights.removeHighlightRange();
            return;
        }
        const view = self.problems_view orelse {
            highlights.removeHighlightRange();
            return;
        };
        const marker = view.selectedMarker() orelse {
            highlights.removeHighlightRange();
            return;
        };
        if (!std.mem.eql(u8, marker.resource.scheme, "file")) {
            highlights.removeHighlightRange();
            return;
        }
        const tab = self.activeTab() orelse {
            highlights.removeHighlightRange();
            return;
        };
        if (!self.samePath(tab.editor.path, marker.resource.path)) {
            highlights.removeHighlightRange();
            return;
        }
        highlights.highlightRange(tab.editor.path, markerEditorRange(tab.editor, marker));
    }

    pub fn terminalFocused(self: *const Workbench) bool {
        return self.focus == .terminal and self.terminalVisible();
    }

    pub fn ensureTerminalService(self: *Workbench) !*TerminalService {
        if (self.terminal_service) |service| return service;
        const service = try TerminalService.init(self.allocator, self.io, .{
            .workspace_root = self.workspaceFolderPath(),
            .configuration = self.configuration,
            .multi_root = self.workspace.getWorkspace().folders.items.len > 1,
        });
        self.terminal_service = service;
        return service;
    }

    pub fn showTerminal(self: *Workbench) !void {
        const service = try self.ensureTerminalService();
        if (service.count() == 0) _ = try service.create();
        self.revealTerminalPanel();
    }

    pub fn hideTerminal(self: *Workbench) void {
        self.layout_model.setVisible(.panel, false) catch {};
        self.focus = .editor;
        self.layoutAll();
    }

    pub fn toggleTerminal(self: *Workbench) !void {
        if (self.terminalVisible() and self.focus == .terminal) {
            self.hideTerminal();
            return;
        }
        try self.showTerminal();
    }

    pub fn newTerminal(self: *Workbench) !void {
        const service = try self.ensureTerminalService();
        _ = try service.create();
        self.revealTerminalPanel();
    }

    /// Reveals the panel and moves focus to the terminal. Creation is the
    /// caller's job: upstream's toggle reveals an existing terminal and only
    /// the new-terminal command creates one, so `showTerminal` and
    /// `newTerminal` must not both create.
    fn revealTerminalPanel(self: *Workbench) void {
        self.layout_model.setVisible(.panel, true) catch {};
        self.focus = .terminal;
        self.statusbar.main_part.clearFocus();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        if (self.search_view) |view| view.blur();
        self.layoutAll();
    }

    pub fn killTerminal(self: *Workbench) !void {
        const service = self.terminal_service orelse return;
        service.killActive();
        if (service.count() == 0) {
            self.hideTerminal();
            return;
        }
        self.focus = .terminal;
        self.layoutAll();
    }

    pub fn focusTerminal(self: *Workbench) !void {
        try self.showTerminal();
    }

    pub fn focusNextTerminal(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        service.next();
        self.focus = .terminal;
    }

    pub fn focusPreviousTerminal(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        service.previous();
        self.focus = .terminal;
    }

    pub fn resizeTerminalPanel(self: *Workbench, delta: isize) void {
        if (!self.terminalVisible()) return;
        const current = self.panelHeight();
        const available = self.workbenchRows();
        const max_height = @max(@min(available / 2, available -| 1), 1);
        const next_value = @as(isize, @intCast(current)) + delta;
        const next: usize = @intCast(@min(@max(next_value, 1), @as(isize, @intCast(max_height))));
        if (next == current) return;
        self.layout_model.setSize(.panel, next) catch {};
        self.layoutAll();
    }

    pub fn terminalAcceptsPaste(self: *const Workbench) bool {
        return self.terminalFocused() and !self.quick_access.isOpen() and self.dialog == null;
    }

    pub fn pasteTerminal(self: *Workbench, content: []const u8) !void {
        const service = self.terminal_service orelse return;
        const instance = service.active() orelse return;
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try self.terminal_input.paste(&instance.emulator, self.allocator, content, &out);
        if (out.items.len == 0) return;
        instance.writeInput(out.items);
        instance.scrollToBottom();
    }

    pub fn handleTerminalKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (!self.terminalFocused()) return false;
        if (self.dialog != null or self.quick_access.isOpen()) return false;
        const service = self.terminal_service orelse return false;
        const instance = service.active() orelse return false;

        if (event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .page_up => {
                    service.previous();
                    return true;
                },
                .page_down => {
                    service.next();
                    return true;
                },
                else => {},
            }
        }
        if (event.mods.alt and event.mods.shift and !event.mods.ctrl) {
            switch (event.key) {
                .up => {
                    self.resizeTerminalPanel(1);
                    return true;
                },
                .down => {
                    self.resizeTerminalPanel(-1);
                    return true;
                },
                .char => |ch| switch (ch) {
                    'T' => {
                        self.toggleTerminal() catch {};
                        return true;
                    },
                    'N' => {
                        self.newTerminal() catch {};
                        return true;
                    },
                    'W' => {
                        self.killTerminal() catch {};
                        return true;
                    },
                    else => {},
                },
                else => {},
            }
        }

        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        self.terminal_input.key(&instance.emulator, event.*, &out) catch return true;
        if (out.items.len > 0) {
            instance.writeInput(out.items);
            instance.scrollToBottom();
        }
        // The shell owns the focused keyboard. Even keys that produce no bytes
        // (for example bracketed-paste markers) must not fall through to the
        // editor beneath the panel.
        return true;
    }

    pub fn handleTerminalMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (!self.terminalVisible()) return false;
        const service = self.terminal_service orelse return false;
        const rect = self.panelRect();
        const hit = terminal_panel.hitTest(service, rect, event.x, event.y);
        // Tab-strip actions are click gestures. The app enables all-motion
        // reporting (mode 1003), so motion, releases, wheel notches and
        // non-left buttons must not create, close or switch terminals.
        const left_press = event.kind == .down and event.button == .left;
        switch (hit) {
            .none => return false,
            .tab => |index| {
                if (!left_press) return true;
                _ = service.setActive(index);
                self.focus = .terminal;
                return true;
            },
            .new_terminal => {
                if (!left_press) return true;
                self.newTerminal() catch {};
                return true;
            },
            .kill_terminal => {
                if (!left_press) return true;
                self.killTerminal() catch {};
                return true;
            },
            .content => {},
        }

        // A click focuses the terminal; hovering and wheel scrolling leave the
        // editor's focus alone, as xterm.js only focuses on a press.
        if (left_press) self.focus = .terminal;
        const instance = service.active() orelse return true;
        const content = terminal_panel.contentRect(rect);
        const local = ui.MouseEvent{
            .kind = event.kind,
            .x = event.x -| ui.cell.snap(content.x),
            .y = event.y -| ui.cell.snap(content.y),
            .button = event.button,
            .mods = event.mods,
            .delta_x = event.delta_x,
            .delta_y = event.delta_y,
        };
        if ((event.kind == .wheel or event.kind == .down or event.kind == .up or event.kind == .move) and
            !instance.emulator.mouseReporting())
        {
            if (event.kind == .wheel) {
                instance.scroll(event.delta_y);
            }
            return true;
        }
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        const written = self.terminal_input.mouse(
            &instance.emulator,
            local,
            instance.cols,
            instance.rows,
            &out,
        ) catch false;
        if (written) instance.writeInput(out.items);
        return true;
    }

    pub fn terminalCount(self: *const Workbench) usize {
        const service = self.terminal_service orelse return 0;
        return service.count();
    }

    pub fn terminalFd(self: *const Workbench, index: usize) ?std.posix.fd_t {
        const service = self.terminal_service orelse return null;
        const instance = service.at(index) orelse return null;
        return instance.fd();
    }

    pub fn onTerminalReady(self: *Workbench, index: usize) bool {
        const service = self.terminal_service orelse return false;
        const instance = service.at(index) orelse return false;
        const changed = instance.feedOutput() catch false;
        if (instance.exit != null) return true;
        return changed;
    }

    pub fn flushTerminals(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        for (service.group.instances.items) |instance| instance.flushInput();
    }

    pub fn hasPendingTerminalWrites(self: *const Workbench) bool {
        const service = self.terminal_service orelse return false;
        for (service.group.instances.items) |instance| {
            if (instance.hasPendingWrite()) return true;
        }
        return false;
    }

    pub fn pollTerminalExits(self: *Workbench) bool {
        const service = self.terminal_service orelse return false;
        return service.pollExits();
    }

    fn editorAreaRect(self: *const Workbench) ui.Rect {
        return .{
            .x = @floatFromInt(self.editorAreaX()),
            .y = 0,
            .w = @floatFromInt(self.editorAreaWidth()),
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
        self.syncTerminalSize();
    }

    /// Applies the panel's measured cell dimensions to every terminal, like
    /// upstream `TerminalGroup.layout`. The view owns the measurement: the tab
    /// strip reserves one row and the rest is already in terminal cells. Each
    /// instance ignores an unchanged size, so a terminal created while the
    /// panel is visible is laid out on the reveal pass without a size cache.
    fn syncTerminalSize(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        if (!self.terminalVisible()) return;
        const l = terminal_panel.layout(self.panelRect());
        const cols: u16 = @intCast(@min(l.content_width, std.math.maxInt(u16)));
        const rows: u16 = @intCast(@min(l.content_height, std.math.maxInt(u16)));
        if (cols == 0 or rows == 0) return;
        service.layoutAll(cols, rows);
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

    /// Whether `editor` still belongs to an open tab. The extension-host
    /// bridge stores a raw pointer to the editor that owns its scroll
    /// listener; closing a tab frees that editor before the next `pump`
    /// observes the active-editor change, so callers validate the pointer
    /// against the live tab views instead of dereferencing it.
    pub fn ownsEditor(self: *const Workbench, editor: *const Editor) bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor == editor) return true;
            }
        }
        return false;
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
    /// Creates the shared language-feature and marker services. Idempotent;
    /// app startup calls it before the extension host and JSON client attach.
    pub fn enableLanguageFeatures(self: *Workbench) !void {
        if (self.language_features != null) return;
        const features = try self.allocator.create(LanguageFeaturesService);
        errdefer self.allocator.destroy(features);
        features.* = LanguageFeaturesService.init(self.allocator);
        errdefer features.deinit();
        const marker_service = try self.allocator.create(MarkerService);
        errdefer self.allocator.destroy(marker_service);
        marker_service.* = MarkerService.init(self.allocator);
        errdefer marker_service.deinit();
        const marker_decorations = try MarkerDecorationsService.init(self.allocator, marker_service);
        errdefer marker_decorations.deinit();

        const word_provider = try self.allocator.create(WordBasedCompletionProvider);
        errdefer self.allocator.destroy(word_provider);
        word_provider.* = WordBasedCompletionProvider.init();

        self.language_features = features;
        self.marker_service = marker_service;
        self.marker_decorations = marker_decorations;
        self.word_completion_provider = word_provider;
        self.word_completion_registration = try features.completion_provider.register(.{ .language = "*" }, word_provider.interface());
        if (self.markers_status) |status| status.attach(marker_service);
        if (self.problems_view) |view| view.setService(marker_service);
        self.document_symbol_listener = try features.document_symbol_provider.on_did_change.listen(self, onDocumentSymbolsChanged);
        self.outline_registration = try self.outline_service.registerOutlineCreator(.{
            .context = self,
            .matches = outlineMatches,
            .create_outline = outlineCreate,
        });

        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.attachLanguageServices(features, marker_service, marker_decorations);
                tab.attachLanguageRegistry(features);
            }
        }
        self.refreshStatus();
    }

    fn onDocumentSymbolsChanged(_: usize, self: *Workbench) !void {
        self.outline_service.notifyOutlineChanged();
    }

    /// Applies declarative language/grammar contributions to the open tabs and
    /// to tabs opened later.
    pub fn setDeclarativeExtensions(self: *Workbench, registry: *const extensions_registry.Registry) void {
        self.declarative = registry;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| tab.editor.applyDeclarativeExtensions(registry) catch {};
        }
    }

    /// Ensures the workspace configuration service exists. Extension
    /// contributions are registered before the host starts, so this can run
    /// before the first settings path/workspace folder is installed.
    pub fn ensureConfigurationReady(self: *Workbench) void {
        self.ensureConfiguration() catch {};
    }

    /// Registers `contributes.configuration` defaults from one extension
    /// manifest and reloads the effective configuration.
    pub fn registerExtensionConfiguration(self: *Workbench, manifest: std.json.Value, extension_id: []const u8) void {
        self.ensureConfigurationReady();
        const config = self.configuration orelse return;
        configuration_extension_point.registerManifest(config.registry, manifest, extension_id) catch return;
        config.reload() catch {};
    }

    /// Effective configuration data for the extension host's
    /// `$initializeConfiguration` payload.
    pub fn configurationData(self: *Workbench, arena: Allocator) !std.json.Value {
        self.ensureConfigurationReady();
        const config = self.configuration orelse return .null;
        return config.getConfigurationData(arena);
    }

    /// Raw `json.schemas` setting used by the JSON language server.
    pub fn jsonSchemasValue(self: *Workbench) ?*const std.json.Value {
        const config = self.configuration orelse return null;
        return config.getValue("json.schemas", .{});
    }

    pub fn setJsonLanguageClient(self: *Workbench, client: ?*json_language.Client) void {
        self.json_client = client;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.setJsonLanguageClient(client);
            }
        }
    }

    /// Polls JSON diagnostics for the active editor. Returns true when the
    /// editor status changed and the frame should be repainted.
    pub fn pollJsonLanguage(self: *Workbench) bool {
        const tab = self.activeTab() orelse return false;
        return tab.editor.pollJsonLanguage();
    }

    /// Advances the ported background tokenizer for every open editor, like
    /// upstream's per-model background tokenization. Returns true when the
    /// active editor's tokens changed and the view should repaint.
    pub fn pollBackgroundTokenization(self: *Workbench) bool {
        const active = self.activeTab();
        var active_changed = false;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const changed = tab.editor.pollBackgroundTokenization();
                if (changed and active == tab) active_changed = true;
            }
        }
        return active_changed;
    }

    pub fn backgroundTokenizationPending(self: *Workbench) bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor.backgroundTokenizationPending()) return true;
            }
        }
        return false;
    }

    /// Drives the active editor's debounced folding pass. Called from the
    /// main-loop tick so a full-document range scan never blocks a key echo.
    pub fn pollFolding(self: *Workbench, now_ms: i64) bool {
        const tab = self.activeTab() orelse return false;
        return tab.editor.pollFolding(now_ms);
    }

    pub fn foldingTimeout(self: *Workbench, now_ms: i64) ?u32 {
        const tab = self.activeTab() orelse return null;
        return tab.editor.foldingTimeout(now_ms);
    }

    /// Drives the deferred bracket-pair AST/guide build for large documents.
    pub fn pollBracketGuides(self: *Workbench, now_ms: i64) bool {
        const tab = self.activeTab() orelse return false;
        return tab.editor.pollBracketGuides(now_ms);
    }

    pub fn bracketGuidesTimeout(self: *Workbench, now_ms: i64) ?u32 {
        const tab = self.activeTab() orelse return null;
        return tab.editor.bracketGuidesTimeout(now_ms);
    }

    // --- begin git / source control

    fn deinitGit(self: *Workbench) void {
        // Detach quick diff while the tab editors and their models still exist:
        // the decorator removes model decorations on detach.
        if (self.quick_diff_controller) |controller| {
            controller.deinit();
            self.allocator.destroy(controller);
            self.quick_diff_controller = null;
        }
        if (self.scm_view) |view| {
            view.deinit();
            self.allocator.destroy(view);
            self.scm_view = null;
        }
        if (self.scm_interface) |interface| {
            self.allocator.destroy(interface);
            self.scm_interface = null;
        }
        if (self.quick_diff_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
            self.quick_diff_service = null;
        }
        if (self.scm_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
            self.scm_service = null;
        }
        if (self.git_scm_provider) |provider| {
            provider.destroy();
            self.git_scm_provider = null;
        }
        if (self.git_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
            self.git_service = null;
        }
        if (self.git_delegate) |delegate| {
            self.allocator.destroy(delegate);
            self.git_delegate = null;
        }
        if (self.git_cli) |cli| {
            cli.deinit();
            self.git_cli = null;
        }
        if (self.quick_diff_storage) |storage| {
            storage.deinit();
            self.allocator.destroy(storage);
            self.quick_diff_storage = null;
        }
        if (self.git_root) |root| self.allocator.free(root);
        self.git_root = null;
    }

    /// Creates the git CLI/service, the SCM provider/view and the quick-diff
    /// controller for the workspace folder. A missing git binary, a disabled
    /// `git.enabled` or a non-repository leaves the editor untouched.
    pub fn initGit(self: *Workbench) !void {
        if (self.git_cli != null) return;
        const root_value = self.workspaceFolderPath() orelse return;
        if (self.configuration) |configuration| {
            if (!configuration.getBool("git.enabled", true)) return;
        }

        var options = git_cli_mod.Options{
            .git_path = null,
            .enabled = true,
            .timeout_ms = 5000,
            .io = self.io,
            .on_disabled = gitDisabled,
            .on_disabled_context = self,
        };
        if (self.configuration) |configuration| {
            if (configuration.getValue("git.path", .{})) |value| {
                switch (value.*) {
                    .string => |text| options.git_path = text,
                    else => {},
                }
            }
            if (configuration.getValue("diffEditor.maxFileSize", .{})) |value| {
                const megabytes: f64 = switch (value.*) {
                    .integer => |number| @floatFromInt(number),
                    .float => |number| number,
                    else => 50,
                };
                if (megabytes > 0 and megabytes < 1024) {
                    options.max_file_size_kb = @intFromFloat(megabytes * 1024);
                }
            }
        }

        const cli = git_cli_mod.GitCli.init(self.allocator, options) catch return;
        self.git_cli = cli;
        errdefer self.deinitGit();
        if (cli.isDisabled()) return;

        const opened = cli.openRepository(root_value) catch null;
        if (opened == null) return;
        const concrete = cli.repositoryForRoot(root_value) orelse return;

        const service = try self.allocator.create(git_service_mod.GitService);
        service.* = git_service_mod.GitService.init(self.allocator);
        self.git_service = service;

        const delegate = try self.allocator.create(git_common_mod.IGitExtensionDelegate);
        delegate.* = cli.interface();
        self.git_delegate = delegate;
        _ = service.setDelegate(delegate) catch {};

        const root = try self.allocator.dupe(u8, root_value);
        self.git_root = root;

        const scm_service = try self.allocator.create(scm_service_mod.SCMService);
        scm_service.* = scm_service_mod.SCMService.init(self.allocator);
        self.scm_service = scm_service;

        const provider = try git_scm_provider_mod.GitScmProvider.create(
            self.allocator,
            cli,
            concrete,
            root,
            .{
                .context = self,
                .open_change = providerOpenChange,
            },
        );
        self.git_scm_provider = provider;
        _ = try scm_service.registerSCMProvider(provider.interface());

        const storage = try self.allocator.create(storage_mod.InMemoryStorageService);
        storage.* = storage_mod.InMemoryStorageService.init(self.allocator);
        self.quick_diff_storage = storage;
        const quick_service = try self.allocator.create(quick_diff_service_mod.QuickDiffService);
        quick_service.* = quick_diff_service_mod.QuickDiffService.init(self.allocator, storage);
        self.quick_diff_service = quick_service;
        for (provider.quickDiffProviders()) |quick| {
            _ = quick_service.addQuickDiffProvider(quick) catch {};
        }

        const controller = try self.allocator.create(quick_diff_controller_mod.Controller);
        controller.* = quick_diff_controller_mod.Controller.init(self.allocator, quick_service);
        self.quick_diff_controller = controller;
        if (self.configuration != null) {
            controller.setIgnoreTrimWhitespace(self.resolvedIgnoreTrimWhitespace());
            controller.setConfig(.{
                .decorations = self.resolvedDiffDecorations(),
                .gutter_pattern = .{ .added = true, .modified = true },
            });
        }
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.file_input == null) continue;
                controller.attach(tab.editor, tab.editor.path) catch {};
            }
        }

        const scm_view = try self.allocator.create(scm_view_mod.ScmView);
        const scm_interface = scm_service.interface();
        // The view only reads the service through the interface; keep a stable
        // copy because `interface()` returns by value.
        const service_copy = try self.allocator.create(scm_common.ISCMService);
        service_copy.* = scm_interface;
        self.scm_interface = service_copy;
        scm_view.* = scm_view_mod.ScmView.init(self.allocator, service_copy, .{
            .context = self,
            .open_change = scmViewOpen,
            .refresh = scmRefresh,
            .focus_editor = scmFocusEditor,
        });
        self.scm_view = scm_view;
        scm_view.refresh();

        self.git_status_accessor = try self.statusbar.addEntry(.{
            .name = "Source Control",
            .text = "",
            .command = .{ .id = "workbench.view.scm" },
        }, "workbench.scm.branch", .left, .{ .number = 100 });
        self.next_git_refresh = time_compat.milliTimestamp();
        self.syncGitStatus();
        self.syncGitActivity();
        self.refreshStatus();
    }

    fn resolvedIgnoreTrimWhitespace(self: *Workbench) bool {
        const configuration = self.configuration orelse return true;
        if (configuration.getValue("scm.diffDecorationsIgnoreTrimWhitespace", .{})) |value| {
            switch (value.*) {
                .bool => |enabled| return enabled,
                .string => |text| {
                    if (std.mem.eql(u8, text, "inherit")) {
                        return configuration.getBool("diffEditor.ignoreTrimWhitespace", true);
                    }
                    return std.mem.eql(u8, text, "true");
                },
                else => {},
            }
        }
        return configuration.getBool("diffEditor.ignoreTrimWhitespace", true);
    }

    fn resolvedDiffDecorations(self: *Workbench) quick_diff_controller_mod.DecorationsMode {
        const configuration = self.configuration orelse return .all;
        if (configuration.getValue("scm.diffDecorations", .{})) |value| {
            switch (value.*) {
                .string => |text| {
                    if (std.mem.eql(u8, text, "none")) return .none;
                    if (std.mem.eql(u8, text, "gutter")) return .gutter;
                    if (std.mem.eql(u8, text, "overview")) return .overview;
                    if (std.mem.eql(u8, text, "minimap")) return .minimap;
                },
                else => {},
            }
        }
        return .all;
    }

    fn diffEditorOptions(self: *Workbench) DiffWidgetOptions {
        var options = DiffWidgetOptions{};
        options.ignore_trim_whitespace = self.resolvedIgnoreTrimWhitespace();
        if (self.configuration) |configuration| {
            options.render_side_by_side = configuration.getBool("diffEditor.renderSideBySide", true);
            options.render_indicators = configuration.getBool("diffEditor.renderIndicators", true);
            options.render_overview_ruler = configuration.getBool("diffEditor.renderOverviewRuler", true);
            options.enable_split_view_resizing = configuration.getBool("diffEditor.enableSplitViewResizing", true);
            if (configuration.getValue("diffEditor.maxComputationTime", .{})) |value| {
                switch (value.*) {
                    .integer => |number| options.max_computation_time_ms = number,
                    else => {},
                }
            }
            if (configuration.getValue("diffEditor.splitViewDefaultRatio", .{})) |value| {
                switch (value.*) {
                    .float => |number| options.split_view_default_ratio = number,
                    .integer => |number| options.split_view_default_ratio = @floatFromInt(number),
                    else => {},
                }
            }
            if (configuration.getValue("diffEditor.experimental.showMoves", .{})) |value| {
                switch (value.*) {
                    .bool => |enabled| options.show_moves = enabled,
                    else => {},
                }
            }
            if (configuration.getValue("diffEditor.diffAlgorithm", .{})) |value| {
                switch (value.*) {
                    .string => |name| options.diff_algorithm = diffAlgorithmFromName(name),
                    else => {},
                }
            }
        }
        return options;
    }

    /// Polls quick diff and the debounced SCM status refresh. Returns true when
    /// the frame should be repainted.
    pub fn pollGit(self: *Workbench, now_ms: i64) bool {
        var changed = false;
        if (self.quick_diff_controller) |controller| {
            if (controller.poll(now_ms)) changed = true;
        }
        if (self.git_scm_provider == null) return changed;
        const scm_visible = self.sidebarShown() and std.mem.eql(
            u8,
            self.activity_bar_part.active_id orelse "",
            "scm",
        );
        if (now_ms >= self.next_git_refresh and (self.git_status_dirty or scm_visible)) {
            self.git_status_dirty = false;
            self.next_git_refresh = now_ms + 5000;
            self.refreshGitStatus();
            changed = true;
        }
        return changed;
    }

    pub fn gitWantsTick(self: *const Workbench) bool {
        return self.git_scm_provider != null;
    }

    /// Re-reads git status, the SCM rows, the quick-diff baselines, the
    /// branch/status entry and the activity badge.
    pub fn refreshGitStatus(self: *Workbench) void {
        const provider = self.git_scm_provider orelse return;
        provider.refresh() catch {};
        if (self.scm_view) |view| view.refresh();
        if (self.quick_diff_controller) |controller| _ = controller.refreshAll();
        self.syncGitStatus();
        self.syncGitActivity();
    }

    fn syncGitStatus(self: *Workbench) void {
        const accessor = self.git_status_accessor orelse return;
        const provider = self.git_scm_provider orelse {
            accessor.update(.{ .name = "Source Control", .text = "" });
            return;
        };
        const state = provider.repository.stateRef();
        var branch: []const u8 = "";
        if (state.head) |head| {
            if (head.ref.name) |name| branch = name;
        }
        var ahead: usize = 0;
        var behind: usize = 0;
        if (state.head) |head| {
            ahead = head.ahead orelse 0;
            behind = head.behind orelse 0;
        }
        const text = if (branch.len > 0)
            std.fmt.bufPrint(&self.git_status_buf, "\u{2387} {s} \u{2191}{d} \u{2193}{d} ({d})", .{
                branch,
                ahead,
                behind,
                provider.count(),
            }) catch "Git"
        else
            std.fmt.bufPrint(&self.git_status_buf, "\u{2387} (detached) ({d})", .{provider.count()}) catch "Git";
        accessor.update(.{ .name = "Source Control", .text = text, .tooltip = "workbench.view.scm" });
    }

    fn syncGitActivity(self: *Workbench) void {
        const provider = self.git_scm_provider orelse return;
        var badge_mode: []const u8 = "all";
        if (self.configuration) |configuration| {
            if (configuration.getValue("scm.countBadge", .{})) |value| {
                switch (value.*) {
                    .string => |text| badge_mode = text,
                    else => {},
                }
            }
        }
        const scm_visible = self.sidebarShown() and std.mem.eql(
            u8,
            self.activity_bar_part.active_id orelse "",
            "scm",
        );
        const count = if (std.mem.eql(u8, badge_mode, "off") or
            (std.mem.eql(u8, badge_mode, "focused") and !scm_visible))
            0
        else
            provider.count();
        if (self.git_badge_count == count) return;
        self.git_badge_count = count;
        if (count == 0) {
            self.activity_service.removeActivity("scm", "scm.changes");
            return;
        }
        const text = std.fmt.bufPrint(&self.git_badge_buf, "{d}", .{count}) catch "?";
        self.activity_service.setViewContainerActivity("scm", .{
            .id = "scm.changes",
            .badge = .{ .description = text },
        }) catch {};
    }

    /// Opens a diff between two refs of `path`. `working` uses the open buffer
    /// (including unsaved edits) when the file is open, otherwise the file on
    /// disk. `empty` produces the untracked/deleted side.
    pub fn openDiff(
        self: *Workbench,
        path: []const u8,
        left_ref: DiffRef,
        right_ref: DiffRef,
    ) !void {
        const provider = self.git_scm_provider orelse return error.NoRepository;
        const root = self.git_root orelse return error.NoRepository;
        _ = provider;
        const relative = relativeToRoot(path, root) orelse return error.OutsideRepository;
        const git = self.git_cli orelse return error.NoGit;

        const left_label = diffRefLabel(left_ref);
        const right_label = diffRefLabel(right_ref);

        if (self.findDiffTab(path, left_label, right_label)) |tab| {
            const pane = self.activePane();
            const dims = if (pane) |value| editorDimensions(self, value) else Dimensions{ .width = self.cols, .height = self.editorRows() };
            const text = try self.resolveDiffTexts(git, path, relative, left_ref, right_ref);
            defer self.allocator.free(text.original);
            defer self.allocator.free(text.modified);
            try tab.diff.?.replace(text.original, text.modified, dims.width, dims.height, self.diffEditorOptions());
            tab.syncDiffViews();
            if (pane) |value| {
                try value.activateTab(tab);
                tab.layoutCells(dims.width, dims.height);
            }
            tab.focusEditor();
            self.refreshStatus();
            return;
        }

        const text = try self.resolveDiffTexts(git, path, relative, left_ref, right_ref);
        defer self.allocator.free(text.original);
        defer self.allocator.free(text.modified);
        if (text.original.len == 0 and text.modified.len == 0) {
            const file_exists = if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| true else |_| false;
            if (file_exists) {
                if (self.status_hint_accessor) |hint| {
                    hint.update(.{ .name = "Source Control", .text = "Diff skipped: binary or too large" });
                }
                return error.DiffUnavailable;
            }
        }

        const pane = self.activePane();
        const dims = if (pane) |value| editorDimensions(self, value) else Dimensions{ .width = self.cols, .height = self.editorRows() };

        const view = try text_diff_editor_mod.DiffView.create(
            self.allocator,
            self.io,
            .{
                .original_path = path,
                .modified_path = path,
                .original_text = text.original,
                .modified_text = text.modified,
                .original_label = left_label,
                .modified_label = right_label,
            },
            dims.width,
            dims.height,
            self.diffEditorOptions(),
        );
        var view_owned = true;
        errdefer if (view_owned) view.destroy();

        const opened = try self.service.openEditor(
            view.input(),
            null,
            .{ .open = .{ .pinned = true, .active = true } },
        );
        const group_pane = self.paneForGroup(opened.group) orelse return error.GroupPaneMissing;
        if (!opened.result.is_new) {
            view.destroy();
            if (group_pane.tabForInput(view.input()) == null) {
                // The matching tab owns its own view; activate it.
                for (group_pane.tabs.items) |candidate| {
                    if (candidate.diff != null and candidate.input.matches(.{ .input = view.input() })) {
                        try group_pane.activateTab(candidate);
                        self.focusEditor();
                        return;
                    }
                }
            }
            return;
        }

        const tab = try Tab.initDiff(self.allocator, view);
        // The tab owns the view from here on; its deinit frees the editors and
        // inputs. Defuse the view errdefer so an addTab failure does not free
        // the same widget twice.
        view_owned = false;
        errdefer tab.deinit();
        try group_pane.addTab(tab);
        try group_pane.activateTab(tab);
        tab.layoutCells(dims.width, dims.height);
        tab.focusEditor();
        self.focusEditor();
        self.refreshStatus();
    }

    const ResolvedDiffTexts = struct {
        original: []u8,
        modified: []u8,
    };

    fn resolveDiffTexts(
        self: *Workbench,
        git: *git_cli_mod.GitCli,
        path: []const u8,
        relative: []const u8,
        left_ref: DiffRef,
        right_ref: DiffRef,
    ) !ResolvedDiffTexts {
        const original = try self.diffTextFor(git, path, relative, left_ref);
        errdefer self.allocator.free(original);
        const modified = try self.diffTextFor(git, path, relative, right_ref);
        return .{ .original = original, .modified = modified };
    }

    fn diffTextFor(
        self: *Workbench,
        git: *git_cli_mod.GitCli,
        path: []const u8,
        relative: []const u8,
        ref: DiffRef,
    ) ![]u8 {
        if (ref == .empty) return self.allocator.dupe(u8, "");
        if (ref == .working) {
            if (self.findOpenInput(path)) |input| {
                var value = try input.editor.model.getValue(.TextDefined, true);
                return value.toOwnedSlice();
            }
        }
        const kind: git_cli_mod.RefKind = switch (ref) {
            .head => .head,
            .index => .index,
            .working => .working,
            .empty => unreachable,
        };
        const root = self.git_root orelse return self.allocator.dupe(u8, "");
        if (try git.readRef(root, relative, kind)) |content| return content;
        return self.allocator.dupe(u8, "");
    }

    fn findDiffTab(self: *Workbench, path: []const u8, left_label: []const u8, right_label: []const u8) ?*Tab {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const diff = tab.diff orelse continue;
                if (diff.matches(path, left_label, right_label)) return tab;
            }
        }
        return null;
    }

    fn openScmChange(self: *Workbench, provider: *git_scm_provider_mod.GitScmProvider, resource: *git_scm_provider_mod.GitScmResource) !void {
        _ = provider;
        switch (resource.kind) {
            .merge => try self.openPath(resource.absolute_path),
            .untracked => try self.openDiff(resource.absolute_path, .empty, .working),
            .index => try self.openDiff(resource.absolute_path, .head, .index),
            .working => {
                // If the path is staged as well, compare index->working; an
                // unstaged path compares HEAD->working.
                const staged = self.git_scm_provider.?.repository.stateRef().index_changes;
                var is_staged = false;
                for (staged) |change| {
                    if (std.mem.eql(u8, change.path, resource.relative_path)) {
                        is_staged = true;
                        break;
                    }
                }
                if (is_staged) {
                    try self.openDiff(resource.absolute_path, .index, .working);
                } else {
                    try self.openDiff(resource.absolute_path, .head, .working);
                }
            },
        }
    }

    /// Reports a hard git disable once through the status hint entry. The
    /// editor stays usable; the SCM view shows its welcome/placeholder text.
    fn gitDisabled(context: ?*anyopaque, reason: []const u8) void {
        const raw_context = context orelse return;
        const self: *Workbench = @ptrCast(@alignCast(raw_context));
        if (self.status_hint_accessor) |hint| {
            const text = std.fmt.bufPrint(&self.git_status_buf, "Source Control disabled: {s}", .{reason}) catch "Source Control disabled";
            hint.update(.{ .name = "Source Control", .text = text });
        }
    }

    fn providerOpenChange(context: *anyopaque, provider: *git_scm_provider_mod.GitScmProvider, resource: *git_scm_provider_mod.GitScmResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.openScmChange(provider, resource);
    }

    fn scmOpenChange(context: *anyopaque, resource: *scm_common.ISCMResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const provider = self.git_scm_provider orelse return;
        const git_resource = @as(*git_scm_provider_mod.GitScmResource, @ptrCast(@alignCast(resource.context)));
        return self.openScmChange(provider, git_resource);
    }

    fn scmViewOpen(context: *anyopaque, resource: *scm_common.ISCMResource) anyerror!void {
        return scmOpenChange(context, resource);
    }

    fn scmRefresh(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.git_status_dirty = true;
        self.refreshGitStatus();
    }

    fn scmFocusEditor(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.focusEditor();
    }

    fn diffRefLabel(ref: DiffRef) []const u8 {
        return switch (ref) {
            .head => "HEAD",
            .index => "Index",
            .working => "Working Tree",
            .empty => "Empty",
        };
    }

    fn diffAlgorithmFromName(name: []const u8) diff_widget_mod.DiffAlgorithmName {
        return diff_widget_mod.DiffAlgorithmName.fromName(name) orelse .advanced;
    }

    fn relativeToRoot(path: []const u8, root: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimEnd(u8, root, "/\\");
        if (trimmed.len == 0) return null;
        if (path.len <= trimmed.len + 1) return null;
        if (!std.mem.startsWith(u8, path, trimmed)) return null;
        if (path[trimmed.len] != '/' and path[trimmed.len] != '\\') return null;
        return path[trimmed.len + 1 ..];
    }

    fn pathForUri(allocator: Allocator, uri: []const u8) []const u8 {
        const parsed = std.Uri.parse(uri) catch return uri;
        if (!std.mem.eql(u8, parsed.scheme, "file")) return uri;
        return std_uri.fsPath(parsed, allocator) catch uri;
    }

    const Dimensions = struct { width: usize, height: usize };

    fn editorDimensions(self: *Workbench, pane: *GroupPane) Dimensions {
        _ = self;
        return .{
            .width = @max(ui.cell.snap(pane.rect.w), 1),
            .height = @max(ui.cell.snap(pane.rect.h) -| pane.chromeHeight(), 1),
        };
    }

    // --- end git / source control

    pub fn markdownPreviewConfig(self: *Workbench) MarkdownPreviewConfig {
        return MarkdownPreviewConfig.load(self.configuration);
    }

    fn applyMarkdownPreviewConfig(self: *Workbench) void {
        const config = self.markdownPreviewConfig();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.markdown_preview == null) continue;
                const previous = tab.markdown_preview.?.options;
                tab.setMarkdownPreviewConfig(config);
                if (!MarkdownPreviewConfig.eql(previous, config) and tab.markdown_preview_visible) {
                    tab.refreshMarkdownPreview(true);
                }
            }
        }
    }

    pub fn toggleMarkdownPreview(self: *Workbench, pane: *GroupPane) !void {
        const tab = pane.activeTab() orelse return;
        if (!tab.isMarkdown()) {
            tab.editor.setMessage("Markdown preview is available for Markdown files only.", .{});
            return;
        }
        if (tab.markdown_preview_visible) {
            try tab.setMarkdownPreviewVisible(false);
            pane.layout();
            self.refreshStatus();
            return;
        }

        const start_line = topmost_line_monitor.getVisibleLine(tab.editor);
        tab.setMarkdownPreviewConfig(self.markdownPreviewConfig());
        try tab.setMarkdownPreviewVisible(true);
        pane.layout();
        if (tab.markdown_preview) |preview| {
            if (self.theme_palette) |palette| preview.setThemeColors(palette);
            preview.open(start_line) catch |err| {
                tab.editor.setMessage("markdown preview: {s}", .{@errorName(err)});
            };
        }
        self.focusEditor();
        self.refreshStatus();
    }

    pub fn showMarkdownPreviewToSide(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        if (!tab.isMarkdown()) {
            tab.editor.setMessage("Markdown preview is available for Markdown files only.", .{});
            return;
        }
        if (!tab.markdown_preview_visible) try self.toggleMarkdownPreview(pane);
    }

    pub fn refreshMarkdownPreview(self: *Workbench) void {
        if (self.activeTab()) |tab| tab.refreshMarkdownPreview(true);
    }

    pub fn markdownPreviewTick(self: *Workbench, now_ms: i64) bool {
        if (self.activeTab()) |tab| return tab.onMarkdownPreviewTick(now_ms);
        return false;
    }

    pub fn markdownPreviewTimeout(self: *Workbench, now_ms: i64) ?u32 {
        if (self.activeTab()) |tab| return tab.markdownPreviewTimeout(now_ms);
        return null;
    }

    pub fn openPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{});
    }

    pub fn openPreviewPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{ .pinned = false });
    }

    /// True when two filesystem paths name the same file after resolving
    /// relative segments. The editor keeps the path spelling supplied by the
    /// caller while language providers return canonical absolute URIs, so a
    /// plain string compare is not enough to detect the current buffer.
    fn samePath(self: *Workbench, left: []const u8, right: []const u8) bool {
        if (std.mem.eql(u8, left, right)) return true;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const resolved_left = self.normalizePath(arena.allocator(), left) catch return false;
        const resolved_right = self.normalizePath(arena.allocator(), right) catch return false;
        return std.mem.eql(u8, resolved_left, resolved_right);
    }

    /// Resolves a path to an absolute, normalized spelling. Existing files go
    /// through `realpath` so symlinks compare equal; otherwise the path is
    /// joined with the current directory and normalized lexically.
    fn normalizePath(self: *Workbench, allocator: Allocator, path: []const u8) ![]const u8 {
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        if (Io.Dir.cwd().realPathFile(self.io, path, &buffer)) |length| {
            return try allocator.dupe(u8, buffer[0..length]);
        } else |_| {}
        var cwd_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_length = try Io.Dir.cwd().realPathFile(self.io, ".", &cwd_buffer);
        return try std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], path });
    }

    /// Finds the tab/input already showing `path`, if the group model still
    /// owns it. Reusing it avoids reading and constructing a whole editor for
    /// a file that is already open.
    pub fn findOpenInput(self: *Workbench, path: []const u8) ?*FileEditorInput {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const file_input = tab.file_input orelse continue;
                if (!self.samePath(file_input.editor.path, path)) continue;
                if (!pane.group.model.contains(.{ .input = &file_input.base }, .{})) continue;
                return file_input;
            }
        }
        return null;
    }

    fn openExistingInput(self: *Workbench, path: []const u8, existing: *FileEditorInput, options: OpenOptions) !void {
        const opened = try self.service.openEditor(
            &existing.base,
            null,
            .{ .open = .{ .pinned = options.pinned, .active = true } },
        );
        const pane = self.paneForGroup(opened.group) orelse return error.GroupPaneMissing;
        if (self.autoRevealEnabled(path)) {
            if (self.sidebar) |sidebar| sidebar.revealPath(path) catch {};
        }
        if (pane.tabForInput(opened.result.editor)) |tab| {
            try pane.activateTab(tab);
            if (self.language_features) |features| tab.attachLanguageRegistry(features);
            try tab.ensureControllers();
            tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    pub fn openPathWithOptions(self: *Workbench, path: []const u8, options: OpenOptions) !void {
        if (self.findOpenInput(path)) |existing| {
            return self.openExistingInput(path, existing, options);
        }
        const editor = try Editor.createWithExtensionsOptions(self.allocator, self.io, path, self.cols, self.editorContentHeight(), self.declarative, self.json_client, .{ .reserve_scrollbar = true });
        errdefer {
            editor.deinit();
            self.allocator.destroy(editor);
        }
        self.applyConfiguredLanguageAssociations(editor);
        if (self.language_features) |features| {
            editor.attachLanguageServices(features, self.marker_service, self.marker_decorations);
        }
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
                if (self.language_features) |features| tab.attachLanguageRegistry(features);
                try tab.ensureControllers();
                tab.focusEditor();
            }
            try self.history.add(path);
            self.pruneTabs(pane);
            return;
        }

        const tab = try Tab.initFromInput(self.allocator, input);
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        self.applyEditorSettingsToTab(tab);
        self.registerWorkingCopy(tab);
        if (self.quick_diff_controller) |controller| controller.attach(tab.editor, tab.editor.path) catch {};
        if (self.language_features) |features| tab.attachLanguageRegistry(features);
        try tab.ensureControllers();
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    /// Opens the first definition target for the cursor. Ports the action
    /// behind upstream's `editor.action.revealDefinition` (F12 in VS Code);
    /// the terminal surfaces it as `Ctrl-]` and through the command bridge.
    pub fn revealDefinition(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.definition.id);
    }

    pub fn revealDeclaration(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.declaration.id);
    }

    pub fn goToTypeDefinition(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.type_definition.id);
    }

    pub fn goToImplementation(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.implementation.id);
    }

    pub fn goToReferences(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.go_to_references.id);
    }

    pub fn showReferences(self: *Workbench) !bool {
        return self.runLspAction(go_to_commands.find_references.id);
    }

    /// Runs one of the ported `gotoSymbol` actions by its upstream command id.
    pub fn runLspAction(self: *Workbench, id: []const u8) !bool {
        const action = go_to_commands.find(id) orelse return false;
        return self.executeSymbolNavigation(action);
    }

    fn executeSymbolNavigation(self: *Workbench, action: *const go_to_commands.ActionDescriptor) !bool {
        const tab = self.activeTab() orelse return false;
        if (tab.isDiff()) return false;
        const features = self.language_features orelse return false;
        if (self.quick_access.isOpen()) self.quick_access.inputService().hide();

        self.pending_references = null;
        self.pending_symbols = null;
        _ = self.navigation_arena.reset(.retain_capacity);
        const arena = self.navigation_arena.allocator();

        const model = tab.editor.model;
        const position = tab.editor.modelCursorPosition();
        const links = switch (action.kind) {
            .definition => try go_to_symbol.getDefinitionsAtPosition(arena, &features.definition_provider, model, position, false, CancellationToken.None),
            .declaration => try go_to_symbol.getDeclarationsAtPosition(arena, &features.declaration_provider, model, position, false, CancellationToken.None),
            .type_definition => try go_to_symbol.getTypeDefinitionsAtPosition(arena, &features.type_definition_provider, model, position, false, CancellationToken.None),
            .implementation => try go_to_symbol.getImplementationsAtPosition(arena, &features.implementation_provider, model, position, false, CancellationToken.None),
            .references => try go_to_symbol.getReferencesAtPosition(arena, &features.reference_provider, model, position, action.compact_references, false, CancellationToken.None),
        };

        const references = try arena.create(ReferencesModel);
        references.* = try ReferencesModel.init(arena, links, action.title);
        if (references.references.len == 0) {
            self.setNoResultMessage(tab.editor, action.kind, position);
            return false;
        }
        if (references.references.len == 1 and !action.always_show_list) {
            self.navigateToReference(&references.references[0]) catch |err| {
                tab.editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }

        self.pending_references = references;
        self.showReferencePicker(tab, references, action) catch |err| {
            self.pending_references = null;
            tab.editor.setMessage("References failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn showReferencePicker(
        self: *Workbench,
        tab: *Tab,
        references: *ReferencesModel,
        action: *const go_to_commands.ActionDescriptor,
    ) !void {
        const arena = self.navigation_arena.allocator();
        const current_uri = try std_uri.resourceKey(arena, tab.editor.model.uri());
        const current_reference = references.referenceAt(current_uri, tab.editor.modelCursorPosition());

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        var active_id: ?[]const u8 = null;
        var index: usize = 0;
        for (references.groups) |*group| {
            const path = pathForUri(arena, group.uri);
            const basename = std.fs.path.basename(path);
            const separator_label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ basename, group.children.len });
            try items.append(.{ .separator = .{ .label = separator_label } });

            const root = self.workspaceFolderPath();
            const description = if (root) |value| relativeToRoot(path, value) orelse path else path;
            for (group.children) |*reference| {
                const id = try std.fmt.allocPrint(arena, "ref:{d}", .{index});
                const label = try self.referenceItemLabel(arena, reference);
                try items.append(.{ .item = .{
                    .id = id,
                    .label = label,
                    .description = description,
                } });
                if (current_reference != null and current_reference.? == reference) active_id = id;
                index += 1;
            }
        }

        self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = action.title, .active_id = active_id },
            onReferencePick,
            self,
        ) catch |err| {
            self.pending_references = null;
            tab.editor.setMessage("References failed: {s}", .{@errorName(err)});
        };
    }

    fn referenceItemLabel(self: *Workbench, allocator: Allocator, reference: *const references_model.OneReference) ![]u8 {
        const path = pathForUri(allocator, reference.uri());
        const basename = std.fs.path.basename(path);
        const range = reference.range();
        var preview: []const u8 = "";
        if (self.findOpenInput(path)) |input| {
            const line = input.editor.model.getLineContent(range.startLineNumber) catch null;
            if (line) |value| {
                var owned_line = value;
                defer owned_line.deinit();
                const trimmed = std.mem.trim(u8, owned_line.items, " \t\r");
                preview = try allocator.dupe(u8, strings.safeUtf8Prefix(trimmed, 60));
            }
        }
        if (preview.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}:{d}:{d}  {s}", .{
                basename,
                range.startLineNumber,
                range.startColumn,
                preview,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{
            basename,
            range.startLineNumber,
            range.startColumn,
        });
    }

    fn navigateToReference(self: *Workbench, reference: *const references_model.OneReference) !void {
        try self.navigateToLink(reference.link);
    }

    fn navigateToLink(self: *Workbench, link: languages.LocationLink) !void {
        const range = link.target_selection_range;
        const active = self.activeTab() orelse return;
        const parsed = std.Uri.parse(link.uri) catch {
            active.editor.setMessage("Cannot open location: {s}", .{link.uri});
            return;
        };
        if (!std.mem.eql(u8, parsed.scheme, "file")) {
            active.editor.setMessage("Cannot open non-file location: {s}", .{link.uri});
            return;
        }

        var path_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer path_arena.deinit();
        const path = try std_uri.fsPath(parsed, path_arena.allocator());
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const current_uri = try std_uri.resourceKey(scratch.allocator(), active.editor.model.uri());
        if (std.mem.eql(u8, current_uri, link.uri) or self.samePath(active.editor.path, path)) {
            try active.editor.setSelection(range);
            self.focusEditor();
        } else {
            self.openPath(path) catch |err| {
                if (self.activeTab()) |tab| tab.editor.setMessage("Cannot open location: {s}", .{@errorName(err)});
                return;
            };
            if (self.activeTab()) |opened| opened.editor.setSelection(range) catch {};
        }
        self.refreshStatus();
        self.revealActiveEditor();
    }

    fn setNoResultMessage(self: *Workbench, editor: *Editor, kind: go_to_commands.Kind, position: Position) void {
        _ = self;
        const word = editor.model.getWordAtPosition(position);
        if (word) |value| {
            var owned = value;
            defer owned.deinit();
            switch (kind) {
                .definition => editor.setMessage("No definition found for '{s}'", .{owned.word.items}),
                .declaration => editor.setMessage("No declaration found for '{s}'", .{owned.word.items}),
                .type_definition => editor.setMessage("No type definition found for '{s}'", .{owned.word.items}),
                .implementation => editor.setMessage("No implementation found for '{s}'", .{owned.word.items}),
                .references => editor.setMessage("No references found for '{s}'", .{owned.word.items}),
            }
        } else {
            switch (kind) {
                .definition => editor.setMessage("No definition found", .{}),
                .declaration => editor.setMessage("No declaration found", .{}),
                .type_definition => editor.setMessage("No type definition found", .{}),
                .implementation => editor.setMessage("No implementation found", .{}),
                .references => editor.setMessage("No references found", .{}),
            }
        }
    }

    /// Opens the document-symbol picker for the active editor. Ports the
    /// portable behavior of `workbench.action.gotoSymbol`.
    pub fn gotoSymbolInEditor(self: *Workbench) !bool {
        const tab = self.activeTab() orelse return false;
        if (tab.isDiff()) return false;
        const features = self.language_features orelse return false;
        if (self.quick_access.isOpen()) self.quick_access.inputService().hide();

        self.pending_references = null;
        self.pending_symbols = null;
        _ = self.navigation_arena.reset(.retain_capacity);
        const arena = self.navigation_arena.allocator();

        const providers = try features.document_symbol_provider.ordered(self.allocator, tab.editor.model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) {
            tab.editor.setMessage("{s}", .{goto_symbol_quick_access.no_provider_message});
            return false;
        }
        const outline = OutlineModel.create(arena, tab.editor.model, providers[0]) catch |err| {
            tab.editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
            return false;
        };
        const entries = goto_symbol_quick_access.collect(arena, outline) catch |err| {
            tab.editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
            return false;
        };
        if (entries.len == 0) {
            tab.editor.setMessage("{s}", .{goto_symbol_quick_access.no_symbols_message});
            return false;
        }

        const active_index = goto_symbol_quick_access.activeIndex(entries, tab.editor.modelCursorPosition());
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        for (entries, 0..) |entry, index| {
            const id = try std.fmt.allocPrint(arena, "sym:{d}", .{index});
            const label = try goto_symbol_quick_access.label(arena, entry);
            try items.append(.{ .item = .{
                .id = id,
                .label = label,
                .description = goto_symbol_quick_access.kindLabel(entry.symbol.symbol.kind),
            } });
        }
        const active_id = if (active_index) |index| try std.fmt.allocPrint(arena, "sym:{d}", .{index}) else null;

        self.pending_symbols = entries;
        self.quick_access.inputService().showPick(
            items.items,
            .{
                .placeholder = goto_symbol_quick_access.placeholder,
                .active_id = active_id,
                .no_results_label = goto_symbol_quick_access.no_matching_message,
            },
            onSymbolPick,
            self,
        ) catch |err| {
            self.pending_symbols = null;
            tab.editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// Shows or focuses the content hover at the cursor, matching upstream's
    /// `editor.action.showHover`.
    pub fn showHover(self: *Workbench) !bool {
        const tab = self.activeTab() orelse return false;
        if (tab.isDiff()) return false;
        try tab.ensureControllers();
        const controllers = tab.controllers orelse return false;
        if (controllers.hover.isVisible()) {
            controllers.hover.widget().focus();
            return true;
        }
        const position = tab.editor.modelCursorPosition();
        controllers.hover.showContentHover(
            Range.init(position.lineNumber, position.column, position.lineNumber, position.column),
            hover_operation.HoverStartMode.immediate,
            hover_types.HoverStartSource.keyboard,
            false,
        );
        return true;
    }

    /// Removes tab views whose input the group model no longer contains. This
    /// is needed when a preview editor is replaced by the next preview.
    fn pruneTabs(self: *Workbench, pane: *GroupPane) void {
        var index = pane.tabs.items.len;
        var removed_active = false;
        while (index > 0) {
            index -= 1;
            const tab = pane.tabs.items[index];
            if (pane.group.model.contains(.{ .input = tab.input }, .{})) continue;
            if (pane.activeTab() == tab) removed_active = true;
            _ = pane.removeTab(tab);
            if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
            self.unregisterWorkingCopy(tab);
            if (self.quick_diff_controller) |controller| controller.detach(tab.editor);
            tab.deinit();
        }
        if (removed_active) pane.syncActivePane();
    }

    fn pinDirtyPreviews(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.editor.isDirty()) continue;
                if (pane.group.model.isPinned(.{ .editor = tab.input })) continue;
                _ = pane.group.model.pin(tab.input) catch {};
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
        tab.focusEditor();
        tab.onEditorChanged(@import("../../base/common/timeCompat.zig").milliTimestamp());
        try tab.refresh();
        try self.history.add(tab.editor.path);
        self.revealActiveEditor();
    }

    /// Closes the tab showing `path`, if any. Used by extension tab commands.
    pub fn closePath(self: *Workbench, path: []const u8) !bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!self.samePath(tab.editor.path, path)) continue;
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

    pub const GroupDirection = enum { left, right, up, down };

    /// `<C-w>h/j/k/l`: focus the nearest pane in a direction using the laid-out
    /// grid rectangles. This mirrors VS Code's directional group navigation
    /// without needing the browser grid's DOM geometry.
    pub fn navigateGroup(self: *Workbench, direction: GroupDirection) !void {
        self.layoutAll();
        const current = self.activePane() orelse return;
        const source = current.rect;
        const source_left = ui.cell.snap(source.x);
        const source_top = ui.cell.snap(source.y);
        const source_right = ui.cell.snap(source.right());
        const source_bottom = ui.cell.snap(source.bottom());

        var best: ?*GroupPane = null;
        var best_distance: usize = std.math.maxInt(usize);
        for (self.part.group_views.items) |pane| {
            if (pane == current or pane.tabs.items.len == 0) continue;
            const rect = pane.rect;
            const left = ui.cell.snap(rect.x);
            const top = ui.cell.snap(rect.y);
            const right = ui.cell.snap(rect.right());
            const bottom = ui.cell.snap(rect.bottom());
            const overlaps_x = left < source_right and right > source_left;
            const overlaps_y = top < source_bottom and bottom > source_top;
            const distance: ?usize = switch (direction) {
                .left => if (right <= source_left and overlaps_y) source_left - right else null,
                .right => if (left >= source_right and overlaps_y) left - source_right else null,
                .up => if (bottom <= source_top and overlaps_x) source_top - bottom else null,
                .down => if (top >= source_bottom and overlaps_x) top - source_bottom else null,
            };
            if (distance) |value| {
                if (value < best_distance) {
                    best_distance = value;
                    best = pane;
                }
            }
        }
        const target = best orelse return;
        self.service.activateGroup(target.group);
        if (target.activeTab() == null and target.tabs.items.len > 0) {
            try target.activateTab(target.tabs.items[0]);
        }
        target.syncActivePane();
        if (self.activeTab()) |tab| try tab.ensureControllers();
        self.revealActiveEditor();
    }

    pub fn cycleGroup(self: *Workbench) !void {
        try self.switchGroup(1);
    }

    /// Port of `workbench.action.maximizeEditor`: expand the active group.
    pub fn maximizeActiveGroup(self: *Workbench) void {
        const pane = self.activePane() orelse return;
        if (self.expanded_pane == pane) return;
        self.service.activateGroup(pane.group);
        pane.syncActivePane();
        self.expanded_pane = pane;
        self.layoutAll();
        self.breadcrumbs_dirty = true;
    }

    pub fn minimizeActiveGroup(self: *Workbench) void {
        if (self.expanded_pane == null) return;
        self.expanded_pane = null;
        self.layoutAll();
        self.breadcrumbs_dirty = true;
    }

    pub fn closePanel(self: *Workbench) void {
        self.hideTerminal();
    }

    /// Close every editor in every group, stopping at the first dirty-close
    /// confirmation instead of silently discarding the remaining editors.
    pub fn closeAllEditors(self: *Workbench) !void {
        while (self.tabCount() > 0) {
            var closed = false;
            for (self.part.group_views.items) |pane| {
                if (pane.tabs.items.len == 0) continue;
                if (!try self.closeTab(pane, pane.tabs.items[0])) break;
                closed = true;
                break;
            }
            if (!closed) break;
        }
    }

    /// Port of `workbench.action.closeOtherEditors`: close every tab in the
    /// active group except the active one.
    pub fn closeOtherEditors(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        const active = pane.activeTab() orelse return;
        while (pane.tabs.items.len > 1) {
            var candidate: ?*Tab = null;
            for (pane.tabs.items) |tab| {
                if (tab != active) {
                    candidate = tab;
                    break;
                }
            }
            const tab = candidate orelse break;
            if (!try self.closeTab(pane, tab)) break;
        }
    }

    /// Port of `workbench.action.joinAllGroups`: move every tab into the
    /// active group, then drop the empty groups.
    pub fn joinAllGroups(self: *Workbench) !void {
        const target = self.activePane() orelse return;
        for (self.part.group_views.items) |pane| {
            if (pane == target) continue;
            while (pane.tabs.items.len > 0) {
                const tab = pane.tabs.items[0];
                _ = try pane.group.model.closeEditor(tab.input, .MOVE, false);
                _ = pane.removeTab(tab);
                _ = try target.group.model.openEditor(tab.input, .{ .pinned = true, .active = false });
                try target.addTab(tab);
            }
            pane.syncActivePane();
        }
        var index: usize = 0;
        while (index < self.part.group_views.items.len) {
            const pane = self.part.group_views.items[index];
            if (pane == target or pane.tabs.items.len > 0) {
                index += 1;
                continue;
            }
            _ = self.part.collapseView(pane);
        }
        target.syncActivePane();
        self.layoutAll();
        if (self.activeTab()) |tab| try tab.ensureControllers();
    }

    pub fn lastEditorInGroup(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (ordered.items.len == 0) return;
        const tab = ordered.items[ordered.items.len - 1];
        try pane.activateTab(tab);
        try tab.ensureControllers();
        self.focusEditor();
        tab.focusEditor();
        try tab.refresh();
    }

    pub fn previousEditor(self: *Workbench) !void {
        try self.switchTab(-1);
    }

    pub fn revertAndCloseActiveEditor(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        tab.editor.reloadFromDisk() catch {};
        _ = try self.closeActive();
    }

    /// Port of `moveActiveEditor` for `:tabmove`.
    pub fn moveActiveEditor(self: *Workbench, to: []const u8, by: []const u8, value: usize) !void {
        if (!std.mem.eql(u8, by, "tab")) return;
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        const current = pane.activeIndex(ordered.items);
        const count = ordered.items.len;
        if (count == 0) return;

        const target: usize = if (std.mem.eql(u8, to, "first"))
            0
        else if (std.mem.eql(u8, to, "last"))
            count - 1
        else if (std.mem.eql(u8, to, "left"))
            current -| 1
        else if (std.mem.eql(u8, to, "right"))
            @min(current + 1, count - 1)
        else if (std.mem.eql(u8, to, "position"))
            @min(value -| 1, count - 1)
        else
            return;
        _ = try pane.group.model.moveEditor(tab.input, @intCast(target));
        pane.syncActivePane();
        self.layoutAll();
    }

    /// Port of `workbench.action.evenEditorWidths` for the terminal grid.
    pub fn equalizeEditorGroups(self: *Workbench) void {
        equalizeGrid(self.part.root);
        self.layoutAll();
    }

    fn equalizeGrid(node: *LayoutNode) void {
        switch (node.kind) {
            .leaf => {},
            .split => |*split| {
                split.ratio = 0.5;
                equalizeGrid(split.first);
                equalizeGrid(split.second);
            },
        }
    }

    /// Approximate the editor-part resize actions by changing the sidebar and
    /// panel sizes that determine the editor area.
    pub fn resizeEditorArea(self: *Workbench, width_delta: isize, height_delta: isize) !void {
        if (width_delta != 0 and self.sidebarShown()) {
            const current: isize = @intCast(self.layout_model.size(.sidebar));
            const next = @min(@max(current - width_delta, 10), @as(isize, @intCast(@max(self.cols / 2, 10))));
            try self.layout_model.setSize(.sidebar, @intCast(next));
        }
        if (height_delta != 0 and self.terminalVisible()) {
            const current: isize = @intCast(self.layout_model.size(.panel));
            const next = @min(@max(current - height_delta, 3), @as(isize, @intCast(@max(self.rows / 2, 3))));
            try self.layout_model.setSize(.panel, @intCast(next));
        }
        self.layoutAll();
    }

    pub fn showExplorer(self: *Workbench) !void {
        if (try self.showActivityById("explorer")) self.focusSidebar();
    }

    /// Splits the active group and moves the active tab into the new group.
    pub fn splitActive(self: *Workbench, direction: SplitDirection) !void {
        self.part.active_sash = null;
        self.expanded_pane = null;
        self.clearTabDrag();
        const source = self.activePane() orelse return;
        const tab = source.activeTab() orelse return;

        const new_pane = try self.part.splitGroup(source, direction, false);

        _ = try source.group.model.closeEditor(tab.input, .MOVE, false);
        _ = source.removeTab(tab);
        source.syncActivePane();
        _ = try new_pane.group.model.openEditor(tab.input, .{ .pinned = true, .active = true });
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

    /// Closes `tab` from `pane`, applying upstream's dirty-close confirmation
    /// and the empty-pane collapse. Used by Ctrl-W, the tab close cell and
    /// middle click.
    fn closeTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !bool {
        if (self.dialog != null) return false;
        if (self.shouldConfirmClose(pane, tab)) {
            try self.openSaveConfirm(pane, tab);
            return false;
        }
        try self.performCloseTab(pane, tab);
        return false;
    }

    /// Upstream `EditorGroupView.shouldConfirmClose`: a custom close handler
    /// wins, otherwise a dirty editor asks unless it is opened elsewhere.
    /// Saving is synchronous in the terminal editor, so `isSaving()` is always
    /// false and needs no separate check.
    fn shouldConfirmClose(self: *Workbench, pane: *GroupPane, tab: *Tab) bool {
        if (tab.input.close_handler) |handler| {
            return handler.show_confirm(handler.context);
        }
        if (!tab.editor.isDirty()) return false;
        return !self.isOpenedInAnotherGroup(pane, tab);
    }

    fn isOpenedInAnotherGroup(self: *const Workbench, pane: *GroupPane, tab: *Tab) bool {
        for (self.part.group_views.items) |candidate| {
            if (candidate == pane) continue;
            if (candidate.group.model.contains(.{ .input = tab.input }, .{})) return true;
        }
        return false;
    }

    /// Opens the modal save confirmation. Upstream reveals the editor before
    /// asking (`doHandleCloseConfirmation`); the terminal does the same by
    /// activating the tab so the user sees which buffer is being closed.
    fn openSaveConfirm(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        if (self.dialog != null) return;

        var prompt = (try dialogs.saveConfirmPrompt(self.allocator, &.{tab.input.getName()})) orelse return;
        errdefer prompt.deinit();
        const dialog = try ui.Dialog.init(
            self.allocator,
            prompt.message,
            prompt.detail,
            &.{ prompt.save_label, dialogs.dont_save_label, dialogs.cancel_label },
        );
        errdefer dialog.deinit();

        self.part.active_sash = null;
        self.clearTabDrag();
        self.pending_tab_drag = null;
        self.last_tab_click = null;
        self.service.activateGroup(pane.group);
        try pane.activateTab(tab);
        try tab.ensureControllers();
        self.focusEditor();
        tab.focusEditor();

        prompt.deinit();
        self.dialog = dialog;
        self.pending_dialog = .{ .close_tab = .{ .pane = pane, .tab = tab } };
    }

    /// Upstream `AbstractCloseAllAction.run` for the close-window path: collect
    /// every dirty editor, reveal one per group to help the user decide, and
    /// ask a single multi-file save confirmation. Ctrl-Q uses this path.
    fn openQuitConfirm(self: *Workbench) !void {
        if (self.dialog != null) return;

        var names = std.array_list.Managed([]const u8).init(self.allocator);
        defer names.deinit();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor.isDirty()) try names.append(tab.input.getName());
            }
        }
        if (names.items.len == 0) return;

        var prompt = (try dialogs.saveConfirmPrompt(self.allocator, names.items)) orelse return;
        errdefer prompt.deinit();
        const dialog = try ui.Dialog.init(
            self.allocator,
            prompt.message,
            prompt.detail,
            &.{ prompt.save_label, dialogs.dont_save_label, dialogs.cancel_label },
        );
        errdefer dialog.deinit();

        self.part.active_sash = null;
        self.clearTabDrag();
        self.pending_tab_drag = null;
        self.last_tab_click = null;

        // Upstream reveals the editors to confirm, one per group. The active
        // group ends up being the last group that had a dirty editor.
        var reveal_pane: ?*GroupPane = null;
        for (self.part.group_views.items) |pane| {
            var dirty_tab: ?*Tab = null;
            for (pane.tabs.items) |tab| {
                if (tab.editor.isDirty()) dirty_tab = tab;
            }
            if (dirty_tab) |tab| {
                try pane.activateTab(tab);
                reveal_pane = pane;
            }
        }
        if (reveal_pane) |pane| self.service.activateGroup(pane.group);
        if (self.activeTab()) |tab| try tab.ensureControllers();
        self.focusActiveEditor();

        prompt.deinit();
        self.dialog = dialog;
        self.pending_dialog = .quit;
    }

    fn resolveDialogButton(self: *Workbench, index: usize) void {
        const result: dialogs.ConfirmResult = switch (index) {
            0 => .SAVE,
            1 => .DONT_SAVE,
            else => .CANCEL,
        };
        self.resolveDialog(result);
    }

    fn resolveDialog(self: *Workbench, result: dialogs.ConfirmResult) void {
        const dialog = self.dialog orelse return;
        const request = self.pending_dialog;
        self.dialog = null;
        self.pending_dialog = null;
        dialog.deinit();

        const pending = request orelse {
            self.focusActiveEditor();
            return;
        };
        switch (pending) {
            .close_tab => |close| self.resolveCloseTab(close, result) catch |err| self.reportDialogError(err),
            .quit => self.resolveQuit(result) catch |err| self.reportDialogError(err),
        }
    }

    fn reportDialogError(self: *Workbench, err: anyerror) void {
        if (self.activeTab()) |tab| {
            tab.editor.setMessage("Close failed: {s}", .{@errorName(err)});
        }
        self.focusActiveEditor();
    }

    /// Upstream `doHandleCloseConfirmation`: Save closes only when the save
    /// leaves the buffer clean; Don't Save discards the buffer and closes;
    /// Cancel vetoes the close.
    fn resolveCloseTab(self: *Workbench, close: CloseTabRequest, result: dialogs.ConfirmResult) !void {
        if (close.pane.indexOfTab(close.tab) == null) {
            self.focusActiveEditor();
            return;
        }

        switch (result) {
            .SAVE => {
                close.tab.editor.save() catch |err| {
                    close.tab.editor.setMessage(
                        "Unable to save {s}: {s}",
                        .{ close.tab.input.getName(), @errorName(err) },
                    );
                    self.focusEditorAfterDialog(close.tab);
                    return;
                };
                if (close.tab.editor.isDirty()) {
                    // Upstream vetoes the close when the save did not clear
                    // the dirty state.
                    self.focusEditorAfterDialog(close.tab);
                    return;
                }
                try self.performCloseTab(close.pane, close.tab);
            },
            .DONT_SAVE => {
                // Upstream tries a normal revert first and falls back to a
                // soft revert. This tab's single view is destroyed immediately
                // afterwards, so a failed reload still closes.
                close.tab.editor.reloadFromDisk() catch {};
                try self.performCloseTab(close.pane, close.tab);
            },
            .CANCEL => {
                self.focusEditorAfterDialog(close.tab);
                return;
            },
        }

        self.focusActiveEditor();
    }

    /// Upstream `AbstractCloseAllAction` then `doCloseAll`: save or revert every
    /// dirty editor, close the whole workbench and let the host exit. A failed
    /// save vetoes the quit and keeps the window open.
    fn resolveQuit(self: *Workbench, result: dialogs.ConfirmResult) !void {
        var save_failure: ?CloseTabRequest = null;
        switch (result) {
            .CANCEL => {
                self.focusActiveEditor();
                return;
            },
            .SAVE => {
                for (self.part.group_views.items) |pane| {
                    for (pane.tabs.items) |tab| {
                        if (!tab.editor.isDirty()) continue;
                        tab.editor.save() catch |err| {
                            tab.editor.setMessage(
                                "Unable to save {s}: {s}",
                                .{ tab.input.getName(), @errorName(err) },
                            );
                            save_failure = .{ .pane = pane, .tab = tab };
                            break;
                        };
                        if (tab.editor.isDirty()) {
                            save_failure = .{ .pane = pane, .tab = tab };
                            break;
                        }
                    }
                    if (save_failure != null) break;
                }
            },
            .DONT_SAVE => {
                for (self.part.group_views.items) |pane| {
                    for (pane.tabs.items) |tab| {
                        if (tab.editor.isDirty()) tab.editor.reloadFromDisk() catch {};
                    }
                }
            },
        }

        if (save_failure) |failure| {
            self.service.activateGroup(failure.pane.group);
            try failure.pane.activateTab(failure.tab);
            try failure.tab.ensureControllers();
            self.focusEditorAfterDialog(failure.tab);
            return;
        }

        try self.closeAllTabs();
        self.quit_requested = true;
    }

    fn closeAllTabs(self: *Workbench) !void {
        while (self.tabCount() > 0) {
            var closed = false;
            for (self.part.group_views.items) |pane| {
                if (pane.tabs.items.len == 0) continue;
                try self.performCloseTab(pane, pane.tabs.items[0]);
                closed = true;
                break;
            }
            if (!closed) break;
        }
    }

    fn focusEditorAfterDialog(self: *Workbench, tab: *Tab) void {
        self.focusEditor();
        tab.focusEditor();
    }

    fn focusActiveEditor(self: *Workbench) void {
        self.focusEditor();
        if (self.activeTab()) |tab| tab.focusEditor();
    }

    fn performCloseTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        _ = try pane.group.model.closeEditor(tab.input, .UNKNOWN, true);
        _ = pane.removeTab(tab);
        pane.syncActivePane();
        if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
        if (self.hovered_tab == tab) self.hovered_tab = null;
        self.unregisterWorkingCopy(tab);
        if (self.quick_diff_controller) |controller| controller.detach(tab.editor);
        tab.deinit();

        if (self.tabCount() == 0) return;

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

    fn ensureContextKeys(self: *Workbench) !*context_key_mod.ContextKeyService {
        if (self.context_keys) |service| return service;
        const service = try self.allocator.create(context_key_mod.ContextKeyService);
        errdefer self.allocator.destroy(service);
        service.* = context_key_mod.ContextKeyService.init(self.allocator);
        errdefer service.deinit();
        self.context_key_handles = .{
            .editor_focus = try service.createKey("editorFocus", .{ .boolean = false }),
            .editor_text_focus = try service.createKey("editorTextFocus", .{ .boolean = false }),
            .input_focus = try service.createKey("inputFocus", .{ .boolean = false }),
            .list_focus = try service.createKey("listFocus", .{ .boolean = false }),
            .side_bar_focus = try service.createKey("sideBarFocus", .{ .boolean = false }),
            .status_bar_focus = try service.createKey("statusBarFocus", .{ .boolean = false }),
            .terminal_focus = try service.createKey("terminalFocus", .{ .boolean = false }),
            .in_quick_open = try service.createKey("inQuickOpen", .{ .boolean = false }),
            .in_files_picker = try service.createKey("inFilesPicker", .{ .boolean = false }),
            .explorer_viewlet_visible = try service.createKey("explorerViewletVisible", .{ .boolean = false }),
            .explorer_viewlet_focus = try service.createKey("explorerViewletFocus", .{ .boolean = false }),
            .files_explorer_focus = try service.createKey("filesExplorerFocus", .{ .boolean = false }),
            .search_viewlet_visible = try service.createKey("searchViewletVisible", .{ .boolean = false }),
            .search_view_focus = try service.createKey("searchViewFocus", .{ .boolean = false }),
            .scm_viewlet_visible = try service.createKey("scmViewletVisible", .{ .boolean = false }),
            .scm_view_focus = try service.createKey("scmViewFocus", .{ .boolean = false }),
            .explorer_resource_is_root = try service.createKey("explorerResourceIsRoot", .{ .boolean = false }),
            .explorer_resource_readonly = try service.createKey("explorerResourceReadonly", .{ .boolean = false }),
            .tree_find_open = try service.createKey("treeFindOpen", .{ .boolean = false }),
            .resource_scheme = try service.createKey("resourceScheme", .{ .string = "file" }),
            .editor_read_only = try service.createKey("editorReadOnly", .{ .boolean = false }),
        };
        self.context_keys = service;
        self.updateContextKeys();
        return service;
    }

    fn updateContextKeys(self: *Workbench) void {
        const keys = self.context_key_handles orelse return;
        const active_activity = self.activity_bar_part.active_id orelse "";
        const sidebar_focused = self.focus == .sidebar and self.sidebarShown();
        const explorer_active = std.mem.eql(u8, active_activity, "explorer");
        const search_active = std.mem.eql(u8, active_activity, "search");
        const scm_active = std.mem.eql(u8, active_activity, "scm");
        const search_results_focused = if (self.search_view) |view| view.results_focused else false;
        const editor_focused = self.focus == .editor;
        keys.editor_focus.set(.{ .boolean = editor_focused });
        keys.editor_text_focus.set(.{ .boolean = editor_focused and self.dialog == null and !self.quick_access.isOpen() });
        keys.side_bar_focus.set(.{ .boolean = sidebar_focused });
        keys.list_focus.set(.{ .boolean = sidebar_focused and (!search_active or search_results_focused) });
        keys.input_focus.set(.{ .boolean = sidebar_focused and search_active and !search_results_focused });
        keys.status_bar_focus.set(.{ .boolean = self.focus == .statusbar });
        keys.terminal_focus.set(.{ .boolean = self.focus == .terminal });
        keys.in_quick_open.set(.{ .boolean = self.quick_access.isOpen() });
        keys.in_files_picker.set(.{ .boolean = self.quick_access.isOpen() and !self.quick_access.isPickOpen() });
        keys.explorer_viewlet_visible.set(.{ .boolean = self.sidebarShown() and explorer_active });
        keys.explorer_viewlet_focus.set(.{ .boolean = sidebar_focused and explorer_active });
        keys.files_explorer_focus.set(.{ .boolean = sidebar_focused and explorer_active });
        keys.search_viewlet_visible.set(.{ .boolean = self.sidebarShown() and search_active });
        keys.search_view_focus.set(.{ .boolean = sidebar_focused and search_active });
        keys.scm_viewlet_visible.set(.{ .boolean = self.sidebarShown() and scm_active });
        keys.scm_view_focus.set(.{ .boolean = sidebar_focused and scm_active });
        // Explorer file operations are not ported; these keys keep bindings
        // that require them inert rather than active.
        keys.explorer_resource_is_root.set(.{ .boolean = false });
        keys.explorer_resource_readonly.set(.{ .boolean = false });
        keys.tree_find_open.set(.{ .boolean = false });
        keys.resource_scheme.set(.{ .string = "file" });
        keys.editor_read_only.set(.{ .boolean = if (self.activeTab()) |tab| tab.editor.read_only else false });
    }

    fn themeColor(self: *const Workbench, id: []const u8, fallback: [3]u8) ui.Color {
        const palette = self.theme_palette orelse return .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
        return palette.color(id, fallback);
    }

    fn ensureUserKeybindings(self: *Workbench) !void {
        if (self.user_keybindings != null) return;
        if (self.keybindings_paths.len == 0) return;
        self.user_keybindings = try user_keybindings_mod.UserKeybindings.load(
            self.allocator,
            self.io,
            self.keybindings_paths,
        );
    }

    fn userRemovalOverrides(self: *Workbench) []const *const resolved_keybinding_item.ResolvedKeybindingItem {
        const bindings = self.user_keybindings orelse return &.{};
        return bindings.removals();
    }

    fn isKnownCommand(self: *const Workbench, command: []const u8) bool {
        if (self.commands.get(command) != null) return true;
        for (global_keybinding_rules) |rule| {
            if (std.mem.eql(u8, rule.id, command)) return true;
        }
        for (tab_keybinding_rules) |rule| {
            if (std.mem.eql(u8, rule.id, command)) return true;
        }
        for (statusbar_keybinding_rules) |rule| {
            if (std.mem.eql(u8, rule.id, command)) return true;
        }
        return false;
    }

    fn buildGlobalUserOverrides(self: *Workbench) ![]const *const resolved_keybinding_item.ResolvedKeybindingItem {
        self.ensureUserKeybindings() catch return &.{};
        const bindings = self.user_keybindings orelse return &.{};
        var overrides = std.array_list.Managed(*const resolved_keybinding_item.ResolvedKeybindingItem).init(self.allocator);
        errdefer overrides.deinit();
        for (bindings.userItems()) |item| {
            const command = item.command orelse continue;
            if (!self.isKnownCommand(command)) continue;
            try overrides.append(item);
        }
        for (bindings.removals()) |item| try overrides.append(item);
        return overrides.toOwnedSlice();
    }

    fn freeUserOverrides(
        self: *Workbench,
        overrides: []const *const resolved_keybinding_item.ResolvedKeybindingItem,
    ) void {
        if (overrides.len > 0) self.allocator.free(overrides);
    }

    /// Rebuilds every keybinding host after the user keymap changed. The old
    /// hosts are disposed before the keymap owner so no service keeps borrowed
    /// items past their lifetime.
    pub fn reloadKeybindings(self: *Workbench) void {
        if (self.global_service) |service| {
            service.deinit();
            self.global_service = null;
        }
        if (self.tab_service) |service| {
            service.deinit();
            self.tab_service = null;
        }
        if (self.statusbar_service) |service| {
            service.deinit();
            self.statusbar_service = null;
        }
        self.freeUserOverrides(self.global_user_overrides);
        self.global_user_overrides = &.{};
        if (self.user_keybindings) |bindings| {
            bindings.deinit();
            self.user_keybindings = null;
        }
        self.ensureUserKeybindings() catch {};
        const removals = self.userRemovalOverrides();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.editor.reloadShortcutKeybindings(removals);
            }
        }
        if (self.search_view) |view| view.reloadKeybindings(removals);
    }

    fn ensureThemeService(self: *Workbench) !*theme_service_mod.ThemeService {
        if (self.theme_service) |service| return service;
        const registry = try self.allocator.create(color_utils.ColorRegistry);
        registry.* = color_utils.ColorRegistry.init(self.allocator);
        errdefer {
            registry.deinit();
            self.allocator.destroy(registry);
        }
        const service = try theme_service_mod.ThemeService.init(self.allocator, registry, null);
        self.theme_colors = registry;
        self.theme_service = service;
        return service;
    }

    /// Registers the color themes discovered from the built-in and installed
    /// extension roots. Later registrations win, so the TUI extension root can
    /// override a profile or built-in theme with the same settings id.
    pub fn registerThemeSources(self: *Workbench, themes: []const extensions_registry.Theme) !void {
        const service = try self.ensureThemeService();
        for (themes) |theme| {
            try service.registerThemeFile(
                theme.settings_id,
                theme.label,
                theme_service_mod.colorSchemeForUiTheme(theme.ui_theme),
                theme.root,
                theme.path,
            );
        }
    }

    /// Applies `workbench.colorTheme`, the preferred-scheme settings and the
    /// color/token customizations, then reinstalls the token theme. Falls back
    /// to the default dark theme and, for a checkout without theme assets, to
    /// the bundled syntax theme.
    pub fn applyThemeSettings(self: *Workbench) void {
        self.ensureConfiguration() catch {};
        const configuration = self.configuration orelse return;
        const service = self.ensureThemeService() catch return;

        const theme_configuration = theme_configuration_mod.ThemeConfiguration.init(
            configuration.interface(),
            self.theme_scheme_host.interface(),
        );
        const requested = theme_configuration.getColorTheme() orelse
            theme_service_mod.ThemeSettingDefaults.COLOR_THEME_DARK;
        var loaded = service.activateSettingsId(requested) catch false;
        if (!loaded) {
            loaded = service.activateSettingsId(theme_service_mod.ThemeSettingDefaults.COLOR_THEME_DARK) catch false;
        }
        if (!loaded) loaded = service.activateSettingsId("vs-dark") catch false;

        service.applyColorCustomizations(
            self.allocator,
            configuration.getValue(theme_service_mod.ThemeSettings.COLOR_CUSTOMIZATIONS, .{}),
        ) catch {};
        service.applyTokenColorCustomizations(
            self.allocator,
            configuration.getValue(theme_service_mod.ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS, .{}),
        ) catch {};
        service.applySemanticTokenColorCustomizations(
            self.allocator,
            configuration.getValue(theme_service_mod.ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS, .{}),
        ) catch {};

        self.refreshSyntaxTheme(loaded);

        const palette = self.allocator.create(theme_colors_mod.ThemeColors) catch return;
        palette.* = theme_colors_mod.ThemeColors.init(service.getActiveTheme());
        const previous = self.theme_palette;
        self.theme_palette = palette;
        self.applyThemeToParts(palette);
        if (previous) |old| self.allocator.destroy(old);
        self.refreshOpenViews();
    }

    fn applyThemeToParts(self: *Workbench, palette: ?*const theme_colors_mod.ThemeColors) void {
        if (self.sidebar) |sidebar| sidebar.setThemeColors(palette);
        if (self.search_view) |view| view.setThemeColors(palette);
        if (self.scm_view) |view| view.setThemeColors(palette);
        if (self.breadcrumbs_control) |control| control.setThemeColors(palette);
        self.statusbar.main_part.setThemeColors(palette);
        self.quick_access.setThemeColors(palette);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.view.setThemeColors(palette);
                if (tab.markdown_preview) |preview| preview.setThemeColors(palette);
            }
        }
    }

    fn refreshSyntaxTheme(self: *Workbench, loaded: bool) void {
        const service = self.theme_service orelse return;
        if (self.syntax_theme_ready) {
            self.syntax_theme.deinit();
            self.syntax_theme_ready = false;
        }
        if (loaded and service.getActiveTheme().is_loaded) {
            self.syntax_theme.initFromColorThemeData(self.allocator, service.getActiveTheme()) catch {};
            self.syntax_theme_ready = true;
        }
        if (!self.syntax_theme_ready) {
            self.syntax_theme.init(self.allocator) catch return;
            self.syntax_theme_ready = true;
        }
    }

    fn refreshOpenViews(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.view.invalidate();
            }
        }
    }

    fn ensureGlobalService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.global_service) |service| return service;
        const context = try self.ensureContextKeys();
        self.updateContextKeys();
        const overrides = try self.buildGlobalUserOverrides();
        errdefer self.freeUserOverrides(overrides);
        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &global_keybinding_rules,
            .executor = .{ .context = self, .execute = executeGlobalCommand },
            .context = context,
            .overrides = overrides,
        });
        self.global_user_overrides = overrides;
        self.global_service = service;
        return service;
    }

    /// Workbench-global shortcuts through the abstract keybinding service.
    /// Skipped while quick access owns the keyboard so Ctrl+P keeps cycling
    /// the open picker.
    pub fn handleGlobalKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        _ = try self.ensureContextKeys();
        self.updateContextKeys();
        if (self.quick_access.isOpen()) return false;
        self.suppress_global_command = false;
        // Ctrl-] is the TUI-specific definition alias. F12 and its modified
        // variants are registered in the global keybinding rules below.
        if (isCtrlChar(event, ']')) {
            if (try self.revealDefinition()) return true;
        }
        const service = try self.ensureGlobalService();
        const handled = service.dispatch(event.*);
        if (self.suppress_global_command) {
            self.suppress_global_command = false;
            return false;
        }
        return handled;
    }

    fn ensureTabService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.tab_service) |service| return service;
        self.ensureUserKeybindings() catch {};
        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &tab_keybinding_rules,
            .executor = .{ .context = self, .execute = executeTabCommand },
            .overrides = self.userRemovalOverrides(),
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
                .down => {
                    if (self.activeTab()) |tab| {
                        if (tab.nextDiffChange()) return .handled;
                    }
                },
                .up => {
                    if (self.activeTab()) |tab| {
                        if (tab.previousDiffChange()) return .handled;
                    }
                },
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
        if (self.dialog != null) return false;
        if (!self.hasDirtyTabs()) return true;

        self.openQuitConfirm() catch |err| {
            if (self.activeTab()) |tab| {
                tab.editor.setMessage("Unable to open quit confirmation: {s}", .{@errorName(err)});
            }
            return false;
        };
        return false;
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
        _ = try source.group.model.closeEditor(tab.input, .MOVE, false);
        _ = source.removeTab(tab);
        source.syncActivePane();
        _ = try dest.group.model.openEditor(tab.input, .{ .pinned = true, .active = true });
        try dest.addTab(tab);
        self.service.activateGroup(dest.group);
        try tab.ensureControllers();
        tab.focusEditor();
        self.focus = .editor;
    }

    fn dropTab(self: *Workbench, source: *GroupPane, tab: *Tab, target: *GroupPane, zone: DropZone) !void {
        if (zone == .center) {
            if (source == target) return;
            // The target group may already show this input; moving would
            // create a second Tab for one model.
            if (target.tabForInput(tab.input) != null) return;
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
            .color = .{ .rgb = self.themeColor("focusBorder", .{ 0xe5, 0xc0, 0x7b }) },
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
        self.ensureUserKeybindings() catch {};
        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &statusbar_keybinding_rules,
            .executor = .{ .context = self, .execute = executeStatusbarKeyCommand },
            .overrides = self.userRemovalOverrides(),
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
            if (self.activeTab()) |tab| tab.focusEditor();
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
        if (std.mem.eql(u8, active_id, "scm")) {
            if (self.scm_view) |view| {
                _ = view.handleKey(@constCast(event)) catch {};
            }
            return true;
        }
        if (std.mem.eql(u8, active_id, markers_common.PROBLEMS_ACTIVITY_ID)) {
            if (self.problems_view) |view| {
                _ = view.handleKey(@constCast(event)) catch {};
            }
            return true;
        }
        if (std.mem.eql(u8, active_id, "search")) {
            if (self.search_view) |view| {
                switch (view.handleKey(event)) {
                    .handled => return true,
                    .focus_editor => {
                        self.focusEditor();
                        if (self.activeTab()) |tab| tab.focusEditor();
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
        if (std.mem.eql(u8, active_id, "scm")) {
            if (self.scm_view) |view| _ = view.handleMouse(@constCast(event), self.sidebarRect()) catch false;
            return true;
        }
        if (std.mem.eql(u8, active_id, markers_common.PROBLEMS_ACTIVITY_ID)) {
            if (self.problems_view) |view| _ = view.handleMouse(@constCast(event), self.sidebarRect()) catch false;
            return true;
        }
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
                if (pane.title_action_hit) |hit| {
                    if (event.x >= hit.start and event.x < hit.end) {
                        self.hovered_title_action_pane = pane;
                        self.hovered_tab = null;
                        return true;
                    }
                }
                self.hovered_title_action_pane = null;
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
            const now = @import("../../base/common/timeCompat.zig").milliTimestamp();
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
                        if (pane.group.model.isPinned(.{ .editor = previous.tab.input })) {
                            self.toggleExpandGroup(pane);
                        } else {
                            _ = pane.group.model.pin(previous.tab.input) catch {};
                        }
                        self.focusEditor();
                        self.breadcrumbs_dirty = true;
                        return true;
                    }
                }
            }

            if (event.button == .left) {
                if (pane.title_action_hit) |hit| {
                    if (event.x >= hit.start and event.x < hit.end) {
                        self.toggleMarkdownPreview(pane) catch {};
                        self.focusEditor();
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
                            .at_ms = @import("../../base/common/timeCompat.zig").milliTimestamp(),
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
        self.hovered_title_action_pane = null;
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
        if (self.theme_palette) |palette| {
            self.frame.next.fillRect(
                0,
                0,
                @floatFromInt(self.cols),
                @floatFromInt(self.rows),
                .{ .bg = ui.cell.packColor(palette.background) },
            );
        }

        if (self.sidebarShown()) {
            const focused = self.focus == .sidebar;
            activity_bar_mod.render(&self.activity_bar_part, &self.activity_service, &self.frame.next, self.activityRect(), self.activeActivity(), focused, self.theme_palette);
            const active_id = self.activity_bar_part.active_id orelse "";
            if (std.mem.eql(u8, active_id, "explorer")) {
                if (self.sidebar) |sidebar| {
                    if (self.theme_palette) |palette| sidebar.setThemeColors(palette);
                    try sidebar.render(&self.frame.next, self.sidebarRect(), focused);
                }
            } else if (std.mem.eql(u8, active_id, "search")) {
                if (self.search_view) |view| {
                    if (self.theme_palette) |palette| view.setThemeColors(palette);
                    try view.render(&self.frame.next, self.sidebarRect());
                }
            } else if (std.mem.eql(u8, active_id, "scm")) {
                if (self.scm_view) |view| {
                    if (self.theme_palette) |palette| view.setThemeColors(palette);
                    try view.render(&self.frame.next, self.sidebarRect(), focused);
                } else {
                    self.renderPlaceholder(self.sidebarRect(), focused);
                }
            } else if (std.mem.eql(u8, active_id, markers_common.PROBLEMS_ACTIVITY_ID)) {
                if (self.problems_view) |view| {
                    try view.render(&self.frame.next, self.sidebarRect(), focused);
                } else {
                    self.renderPlaceholder(self.sidebarRect(), focused);
                }
            } else {
                self.renderPlaceholder(self.sidebarRect(), focused);
            }

            const divider_x = self.activityBarWidth() + self.sidebarWidth();
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(self.themeColor("sideBar.border", .{ 70, 70, 70 })),
            };
            var row: usize = 0;
            while (row < self.workbenchRows()) : (row += 1) {
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
        if (self.terminalVisible()) {
            if (self.terminal_service) |service| {
                try terminal_panel.render(
                    &self.frame.next,
                    service,
                    self.panelRect(),
                    self.focus == .terminal,
                    self.theme_palette,
                );
            }
        }
        if (self.statusBarVisible()) {
            if (self.theme_palette) |palette| self.statusbar.main_part.setThemeColors(palette);
            try self.statusbar.main_part.render(&self.frame.next, self.statusBarRect(), .{
                .no_folder = self.workspace.getWorkbenchState() == .EMPTY,
                .part_focused = self.focus == .statusbar,
            });
        }
        try self.quick_access.render(&self.frame.next);
        if (self.dialog) |dialog| dialog.render(&self.frame.next);

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
                .label = tab.input.getName(),
                .language = tab.editor.languageId(),
                .dirty = tab.input.isDirty(),
                .pinned = pane.group.model.isPinned(.{ .editor = tab.input }),
                .sticky = pane.group.model.isSticky(.{ .editor = tab.input }),
                .closeable = !tab.input.hasCapability(editor_mod.EditorInputCapabilities.CannotClose),
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
        const active_tab = pane.activeTab();
        const title_action: ?tab_bar.TitleAction = if (active_tab) |tab| blk: {
            if (!tab.isMarkdown()) break :blk null;
            break :blk .{
                .active = tab.markdownPreviewVisible(),
                .hovered = self.hovered_title_action_pane == pane,
            };
        } else null;
        pane.title_action_hit = try tab_bar.draw(
            &self.frame.next,
            infos,
            pane.activeIndex(ordered.items),
            x,
            y,
            width,
            &pane.hits,
            .{ .group_active = active_group, .hovered = hovered_index, .title_action = title_action },
            self.theme_palette,
        );

        const chrome = pane.chromeHeight();
        if (chrome > height) return;
        if (chrome > editor_group_view.title_height) {
            try self.renderBreadcrumbs(pane, x, y + editor_group_view.title_height, width, active_group);
        }
        if (pane.activeTab()) |active| {
            try active.paint(&self.frame, x, y + chrome, width, height -| chrome);
        }
    }

    fn renderPlaceholder(self: *Workbench, rect: ui.Rect, focused: bool) void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const bg = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(self.themeColor("sideBar.foreground", .{ 190, 190, 190 })),
            .bg = ui.cell.packColor(self.themeColor("sideBar.background", .{ 30, 30, 33 })),
        };
        const active_id = self.activity_bar_part.active_id orelse "";
        const is_scm = std.mem.eql(u8, active_id, "scm");
        const is_problems = std.mem.eql(u8, active_id, markers_common.PROBLEMS_ACTIVITY_ID);
        const header = if (std.mem.eql(u8, active_id, "search"))
            " SEARCH "
        else if (is_scm)
            " SOURCE CONTROL "
        else if (is_problems)
            " PROBLEMS "
        else
            " SETTINGS ";
        const title = if (is_scm)
            "Source Control is unavailable (no Git repository)"
        else if (is_problems)
            "Problems view could not be created"
        else
            "Settings view is not ported yet";
        self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), bg);
        const header_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(self.themeColor("sideBarTitle.foreground", .{ 220, 220, 220 })),
            .bg = ui.cell.packColor(self.themeColor("sideBarSectionHeader.background", .{ 38, 38, 42 })),
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
                    .fg = ui.cell.packColor(self.themeColor("editorGroup.border", .{ 70, 70, 70 })),
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
        var inactive_color = inactive_pane_border;
        var active_color = active_pane_border;
        if (self.theme_palette) |palette| {
            inactive_color = palette.color("editorGroup.border", .{ 70, 70, 70 });
            active_color = palette.color("focusBorder", .{ 0x4d, 0x9b, 0xd6 });
        }
        const stroke = ui.cell_border.Stroke{
            .width = pane_border_width,
            .color = .{ .rgb = if (active) active_color else inactive_color },
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
        control.setThemeColors(self.theme_palette);
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
            .bg = ui.cell.packColor(self.themeColor("breadcrumb.background", .{ 37, 37, 38 })),
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
        if (self.dialog != null) return null;
        if (self.focus == .terminal) {
            if (!self.terminalVisible()) return null;
            const service = self.terminal_service orelse return null;
            const instance = service.active() orelse return null;
            const cursor = terminal_view.cursorCell(&instance.emulator, terminal_panel.contentRect(self.panelRect())) orelse return null;
            return .{ .row = cursor.row, .col = cursor.col };
        }
        if (self.focus != .editor) return null;
        const pane = self.activePane() orelse return null;
        const active = pane.activeTab() orelse return null;
        const cell = active.cursorCell() orelse return null;
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
        if (new_cols == self.cols and new_rows == self.rows) return;

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
            try ui.screen.moveCursor(out, cell.row + 1, cell.col + 1);
            try ui.screen.showCursor(out);
        } else {
            try ui.screen.hideCursor(out);
        }
    }
};

fn outlineMatches(context: *anyopaque, editor: OutlineEditor) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const active: *Tab = @ptrCast(@alignCast(editor.context));
    const resource = editor.resource orelse return false;
    if (!std.mem.eql(u8, active.editor.path, resource)) return false;
    const features = self.language_features orelse return false;
    return features.document_symbol_provider.has(active.editor.model);
}

fn outlineCreate(context: *anyopaque, editor: OutlineEditor, target: outline_mod.OutlineTarget) !?*outline_mod.IOutline {
    _ = target;
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab: *Tab = @ptrCast(@alignCast(editor.context));
    const features = self.language_features orelse return null;
    const providers = try features.document_symbol_provider.ordered(self.allocator, tab.editor.model, false);
    defer self.allocator.free(providers);
    if (providers.len == 0) return null;
    const model = try OutlineModel.create(self.allocator, tab.editor.model, providers[0]);
    const outline = try DocumentSymbolsOutline.create(self.allocator, model, .{
        .context = tab,
        .current_position = outlineCurrentPosition,
        .reveal_range = outlineRevealRange,
        .request_render = outlineRequestRender,
    });
    return outline.interfacePtr();
}

fn outlineCurrentPosition(context: *anyopaque) ?Position {
    const tab: *Tab = @ptrCast(@alignCast(context));
    return tab.editor.modelSelection().getStartPosition();
}

fn outlineRevealRange(context: *anyopaque, range: Range) !void {
    const tab: *Tab = @ptrCast(@alignCast(context));
    try tab.editor.setSelections(&.{Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn)});
}

fn outlineRequestRender(_: *anyopaque) void {}

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
    return tab_bar.languageBadge(breadcrumbActiveLanguage(context));
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
    if (self.workbench.activeTab()) |tab| tab.focusEditor();
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

fn onReferencePick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const model = self.pending_references orelse return;
    const item = picker.selectedItem() orelse picker.activeItem() orelse return;
    self.pending_references = null;
    const index = itemIndex(item.id, "ref:") orelse return;
    if (index >= model.references.len) return;
    self.navigateToReference(&model.references[index]) catch |err| {
        if (self.activeTab()) |tab| tab.editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
    };
}

fn onSymbolPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const entries = self.pending_symbols orelse return;
    const item = picker.selectedItem() orelse picker.activeItem() orelse return;
    self.pending_symbols = null;
    const index = itemIndex(item.id, "sym:") orelse return;
    if (index >= entries.len) return;
    const tab = self.activeTab() orelse return;
    tab.editor.setSelection(entries[index].symbol.symbol.selection_range) catch |err| {
        tab.editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
        return;
    };
    self.focusEditor();
    self.refreshStatus();
    self.revealActiveEditor();
}

fn itemIndex(id: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}

fn commandSymbolNavigation(context: *anyopaque) anyerror!void {
    const ctx: *SymbolActionContext = @ptrCast(@alignCast(context));
    _ = ctx.workbench.executeSymbolNavigation(ctx.action) catch |err| {
        if (ctx.workbench.activeTab()) |tab| tab.editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
    };
}

fn commandGotoSymbol(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.gotoSymbolInEditor() catch |err| {
        if (self.activeTab()) |tab| tab.editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
    };
}

fn commandShowHover(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.showHover() catch |err| {
        if (self.activeTab()) |tab| tab.editor.setMessage("Hover failed: {s}", .{@errorName(err)});
    };
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

fn markerHighlightActiveResource(context: *anyopaque) ?[]const u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.path;
}

fn markerHighlightSetRange(context: *anyopaque, range: ?Range) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (range) |value| {
        const tab = self.activeTab() orelse return;
        const decorations = [_]editorBrowser.Decoration{.{ .range = value, .kind = .marker_selection_highlight }};
        tab.view.setMarkerSelectionHighlights(&decorations) catch {};
        return;
    }
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| tab.view.setMarkerSelectionHighlights(&.{}) catch {};
    }
}

fn problemsWorkspaceRoot(context: *anyopaque) ?[]const u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.workspaceFolderPath();
}

fn problemsPreviewMarker(context: *anyopaque, marker: *const markers_mod.Marker) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, marker.resource.scheme, "file")) return;
    try self.openPathWithOptions(marker.resource.path, .{ .pinned = false });
    const tab = self.activeTab() orelse return;
    try tab.editor.setSelection(markerEditorRange(tab.editor, marker));
    self.focusSidebar();
    self.updateProblemsHighlight();
}

fn problemsOpenMarker(context: *anyopaque, marker: *const markers_mod.Marker) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, marker.resource.scheme, "file")) return;
    try self.openPath(marker.resource.path);
    if (self.activeTab()) |tab| {
        try tab.editor.setSelection(markerEditorRange(tab.editor, marker));
        tab.editor.ensureCursorVisible();
    }
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn problemsSelectionChanged(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.updateProblemsHighlight();
}

fn problemsFocusEditor(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn markerEditorRange(editor: *Editor, marker: *const markers_mod.Marker) Range {
    const model = editor.model;
    const line_count = @max(model.getLineCount(), 1);
    const start_line = @min(@max(@as(usize, marker.start_line_number), 1), line_count);
    const end_line = @min(@max(@as(usize, marker.end_line_number), start_line), line_count);
    const start_column = @min(
        @max(@as(usize, marker.start_column), 1),
        model.getLineMaxColumn(start_line),
    );
    const end_column = @min(
        @max(@as(usize, marker.end_column), 1),
        model.getLineMaxColumn(end_line),
    );
    return Range.init(start_line, start_column, end_line, end_column);
}

fn commandViewScm(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!try self.showActivityById("scm")) return;
    self.focusSidebar();
    if (self.scm_view) |view| view.refresh();
}

fn commandShowProblems(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showProblems();
}

fn commandToggleProblems(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.toggleProblems();
}

fn commandGitRefresh(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.refreshGitStatus();
}

fn commandGitOpenChange(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm_view orelse return;
    const resource = view.selectedResource() orelse return;
    const provider = self.git_scm_provider orelse return;
    const git_resource: *git_scm_provider_mod.GitScmResource = @ptrCast(@alignCast(resource.context));
    try self.openScmChange(provider, git_resource);
}

fn commandGitOpenFile(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const diff = tab.diff orelse return;
    try self.openPath(diff.model.modified_path);
}

fn commandDiffNext(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| _ = tab.nextDiffChange();
    self.refreshStatus();
}

fn commandDiffPrevious(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| _ = tab.previousDiffChange();
    self.refreshStatus();
}

fn commandDiffSwap(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| tab.swapDiffSides();
}

fn commandDiffRefresh(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const diff = tab.diff orelse return;
    const left = diffRefFromLabel(diff.model.original_label);
    const right = diffRefFromLabel(diff.model.modified_label);
    try self.openDiff(diff.model.modified_path, left, right);
}

fn diffRefFromLabel(label: []const u8) DiffRef {
    if (std.mem.eql(u8, label, "HEAD")) return .head;
    if (std.mem.eql(u8, label, "Index")) return .index;
    if (std.mem.eql(u8, label, "Working Tree")) return .working;
    return .empty;
}

fn commandSave(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    if (tab.isDiff()) return;
    try tab.editor.save();
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.git_status_dirty = true;
}

fn commandRevert(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    if (tab.isDiff()) return;
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

fn commandShowMarkdownPreview(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showMarkdownPreviewToSide();
}

fn commandToggleMarkdownPreview(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const pane = self.activePane() orelse return;
    try self.toggleMarkdownPreview(pane);
}

fn commandRefreshMarkdownPreview(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.refreshMarkdownPreview();
}

fn commandSplitEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.splitActive(.horizontal);
}

fn commandSplitEditorOrthogonal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.splitActive(.vertical);
}

fn commandNavigateLeft(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.navigateGroup(.left);
}

fn commandNavigateRight(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.navigateGroup(.right);
}

fn commandNavigateUp(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.navigateGroup(.up);
}

fn commandNavigateDown(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.navigateGroup(.down);
}

fn commandCycleGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.cycleGroup();
}

fn commandEvenEditorWidths(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.equalizeEditorGroups();
}

fn commandIncreaseViewWidth(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.resizeEditorArea(4, 0);
}

fn commandDecreaseViewWidth(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.resizeEditorArea(-4, 0);
}

fn commandIncreaseViewHeight(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.resizeEditorArea(0, 2);
}

fn commandDecreaseViewHeight(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.resizeEditorArea(0, -2);
}

fn commandMaximizeEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.maximizeActiveGroup();
}

fn commandClosePanel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.closePanel();
}

fn commandCloseAllEditors(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.closeAllEditors();
}

fn commandCloseOtherEditors(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.closeOtherEditors();
}

fn commandJoinAllGroups(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.joinAllGroups();
}

fn commandLastEditorInGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.lastEditorInGroup();
}

fn commandPreviousEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.previousEditor();
}

fn commandOpenEditorAtIndex1(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.activateIndex(0);
}

fn commandRevertAndCloseActiveEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.revertAndCloseActiveEditor();
}

fn commandCreateTerminalEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.newTerminal();
}

fn commandViewExplorer(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showExplorer();
}

fn commandToggleSidebar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.toggleSidebar();
}

fn listCommandKey(command: []const u8) ?ui.Key {
    if (std.mem.eql(u8, command, "list.focusUp")) return .up;
    if (std.mem.eql(u8, command, "list.focusDown")) return .down;
    if (std.mem.eql(u8, command, "list.focusFirst")) return .home;
    if (std.mem.eql(u8, command, "list.focusLast")) return .end;
    if (std.mem.eql(u8, command, "list.focusPageUp")) return .page_up;
    if (std.mem.eql(u8, command, "list.focusPageDown")) return .page_down;
    if (std.mem.eql(u8, command, "list.collapse")) return .left;
    if (std.mem.eql(u8, command, "list.expand")) return .right;
    if (std.mem.eql(u8, command, "list.toggleExpand")) return .{ .char = ' ' };
    if (std.mem.eql(u8, command, "list.select")) return .enter;
    return null;
}

fn runListCommand(context: *anyopaque, command: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const key = listCommandKey(command) orelse return;
    var event = ui.KeyEvent{ .key = key };
    const active_id = self.activity_bar_part.active_id orelse "";
    if (std.mem.eql(u8, active_id, "explorer")) {
        if (self.sidebar) |sidebar| {
            _ = try sidebar.handleKey(&event);
            return;
        }
    }
    if (std.mem.eql(u8, active_id, "search")) {
        if (self.search_view) |view| {
            _ = view.handleKey(&event);
            return;
        }
    }
    if (std.mem.eql(u8, active_id, "scm")) {
        if (self.scm_view) |view| {
            _ = try view.handleKey(&event);
            return;
        }
    }
}

fn commandListFocusUp(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusUp");
}
fn commandListFocusDown(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusDown");
}
fn commandListFocusFirst(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusFirst");
}
fn commandListFocusLast(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusLast");
}
fn commandListFocusPageUp(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusPageUp");
}
fn commandListFocusPageDown(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.focusPageDown");
}
fn commandListCollapse(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.collapse");
}
fn commandListExpand(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.expand");
}
fn commandListToggleExpand(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.toggleExpand");
}
fn commandListSelect(context: *anyopaque) anyerror!void {
    return runListCommand(context, "list.select");
}

fn commandOpenSettingsJson(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try openConfigJson(self, self.user_settings_paths, "{\n}\n");
}

fn commandOpenKeybindingsJson(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try openConfigJson(self, self.keybindings_paths, "[\n]\n");
}

/// Opens the highest-precedence (TUI) settings or keybindings file, creating
/// it with valid empty JSONC when it does not exist yet. VS Code's profile
/// files stay read-only inputs.
fn openConfigJson(self: *Workbench, paths: []const []const u8, empty_contents: []const u8) !void {
    if (paths.len == 0) return error.NoConfigPath;
    const target = paths[paths.len - 1];
    if (std.fs.path.dirname(target)) |dir| {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
    }
    if (std.Io.Dir.cwd().access(self.io, target, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            var file = try std.Io.Dir.cwd().createFile(self.io, target, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, empty_contents);
        },
        else => return err,
    }
    try self.openPath(target);
}

fn statusFocusEditor(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusEditor();
}

fn commandFocusStatusBar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusStatusBar();
}

fn commandToggleTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.toggleTerminal();
}

fn commandNewTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.newTerminal();
}

fn commandKillTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.killTerminal();
}

fn commandFocusTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.focusTerminal();
}

fn commandFocusNextTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusNextTerminal();
}

fn commandFocusPreviousTerminal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusPreviousTerminal();
}

fn commandResizeTerminalUp(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.resizeTerminalPanel(1);
}

fn commandResizeTerminalDown(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.resizeTerminalPanel(-1);
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

fn commandFormatSelection(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.formatSelection();
}

fn commandIndentationToSpaces(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.indentationToSpaces();
}

fn commandIndentationToTabs(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.editor.indentationToTabs();
}

fn commandWordHighlightTrigger(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    tab.controllers.?.word_highlighter.trigger();
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
        tab.focusEditor();
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
            if (!tab.isDiff() and pathsEqual(tab.editor.path, path)) {
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

fn frameText(allocator: Allocator, frame: *const ui.Frame) ![]u8 {
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    var row: usize = 0;
    while (row < frame.prev.rows) : (row += 1) {
        const line = try frame.prev.rowText(allocator, row);
        defer allocator.free(line);
        try text.appendSlice(line);
        try text.append('\n');
    }
    return text.toOwnedSlice();
}

test "Workbench: declarative markdown configuration applies to open tabs" {
    const allocator = std.testing.allocator;
    var registry = extensions_registry.scan(allocator, &.{"vscode/extensions/markdown-basics"}) catch return error.SkipZigTest;
    defer registry.deinit();
    if (registry.language("markdown") == null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "README.md", .data = "# Hello\n" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(time_compat.io, "README.md", &buffer);

    const workbench = try Workbench.init(allocator, time_compat.io, &.{buffer[0..length]}, 40, 9);
    defer workbench.deinit();
    workbench.setDeclarativeExtensions(&registry);

    const tab = workbench.activeTab().?;
    try std.testing.expectEqualStrings("markdown", tab.editor.languageId());
    const config = tab.editor.language_service.getLanguageConfiguration("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(config.comments != null);
    try std.testing.expectEqualStrings("<!--", config.comments.?.blockComment.?[0]);
    try std.testing.expect(config.folding.?.offSide orelse false);
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
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b.txt") != null);
    try std.testing.expectEqual(@as(usize, 2), workbench.cursorCell().?.row);

    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try workbench.switchTab(1);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: ownsEditor follows tab ownership across close" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "owned-a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "owned-b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();

    const closed = workbench.activeTab().?.editor;
    const kept = workbench.part.group_views.items[0].tabs.items[0].editor;
    try std.testing.expect(workbench.ownsEditor(closed));
    try std.testing.expect(workbench.ownsEditor(kept));

    try workbench.activeTab().?.ensureControllers();
    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    // `closed` is only compared, never dereferenced: the tab close freed it.
    try std.testing.expect(!workbench.ownsEditor(closed));
    try std.testing.expect(workbench.ownsEditor(kept));
}

test "Workbench: reopening an open file reuses its tab and editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "reuse.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();

    const tab = workbench.activeTab().?;
    const editor = tab.editor;
    try workbench.openPath(path);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().? == tab);
    try std.testing.expect(workbench.activeTab().?.editor == editor);
}

test "Workbench: opening a new file rebuilds its view once" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "one.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "two.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{path_a}, 40, 9);
    defer workbench.deinit();

    try workbench.openPath(path_b);
    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(@as(usize, 0), tab.view.rebuildCount());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), tab.view.rebuildCount());
}

test "Workbench: markdown preview icon and split render the document" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "preview.md", "# Title\n\nHello **world**\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 14);
    defer workbench.deinit();

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try std.testing.expect(tab.isMarkdown());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const hit = pane.title_action_hit orelse return error.TestUnexpectedResult;
    const row = ui.cell.snap(pane.rect.y);
    const grid = &workbench.frame.prev;
    try std.testing.expectEqual(@as(u32, 0x25EB), grid.cluster[grid.index(hit.start, row)]);
    try std.testing.expectEqual(@as(u32, 0x2315), grid.cluster[grid.index(hit.start + 1, row)]);

    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(tab.markdown_preview_visible);
    try std.testing.expect(tab.markdown_preview != null);

    var close_key = ui.KeyEvent{ .key = .{ .char = 'v' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&close_key));
    try std.testing.expect(!tab.markdown_preview_visible);
    try std.testing.expect(try workbench.handleGlobalKey(&close_key));
    try std.testing.expect(tab.markdown_preview_visible);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "world") != null);

    const preview_surface = &tab.markdown_preview.?.surface.?;
    var saw_title = false;
    var saw_world = false;
    var preview_row: usize = 0;
    while (preview_row < preview_surface.grid().rows) : (preview_row += 1) {
        const text = try preview_surface.grid().rowText(allocator, preview_row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "Title") != null) saw_title = true;
        if (std.mem.indexOf(u8, text, "world") != null) saw_world = true;
    }
    try std.testing.expect(saw_title);
    try std.testing.expect(saw_world);
}

test "Workbench: markdown preview title action is absent for plain text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "plain.txt", "plain\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(pane.title_action_hit == null);
    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(!pane.activeTab().?.markdown_preview_visible);
}

test "Workbench: markdown preview follows editor scroll and can reveal the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var line: usize = 0;
    while (line < 80) : (line += 1) {
        try body.writer.print("paragraph {d}\n\n", .{line});
    }
    const path = try seedFile(allocator, io, &tmp, "scroll.md", body.written());
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 18);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(tab.markdown_preview_visible);

    _ = tab.editor.setTopViewLine(30);
    const now = @import("../../base/common/timeCompat.zig").milliTimestamp();
    _ = tab.onMarkdownPreviewTick(now + 60);
    try std.testing.expect(tab.markdown_preview.?.scroll > 0);
    _ = tab.onMarkdownPreviewTick(now + 120);

    const before = tab.editor.topViewLine();
    var wheel = ui.MouseEvent{
        .kind = .wheel,
        .x = ui.cell.snap(tab.preview_rect.?.x) + 2,
        .y = 1,
        .delta_y = 20,
    };
    _ = tab.handleMarkdownPreviewMouse(&wheel, now + 100);
    try std.testing.expect(tab.editor.topViewLine() != before);
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
    try std.testing.expectEqualStrings("split_b.txt", workbench.activeTab().?.input.getName());

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

test "Workbench: directional group navigation and join all groups" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "nav_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "nav_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqualStrings("nav_b.txt", workbench.activeTab().?.input.getName());

    try workbench.navigateGroup(.left);
    try std.testing.expectEqualStrings("nav_a.txt", workbench.activeTab().?.input.getName());
    try workbench.navigateGroup(.right);
    try std.testing.expectEqualStrings("nav_b.txt", workbench.activeTab().?.input.getName());

    try workbench.joinAllGroups();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
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
    try std.testing.expectEqualStrings("reveal_b.txt", workbench.activeTab().?.input.getName());

    try workbench.openPath(path_a);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("reveal_a.txt", workbench.activeTab().?.input.getName());
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
    try std.testing.expectEqualStrings("restore_b.txt", restored.activeTab().?.input.getName());

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
    try std.testing.expectEqualStrings("part_b.txt", restored.activeTab().?.input.getName());

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
    try std.testing.expectEqualStrings("side_open.txt", workbench.activeTab().?.input.getName());
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
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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

    const scm_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 3 };
    try std.testing.expect(workbench.handleSidebarMouse(&scm_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SOURCE CONTROL") != null);

    const problems_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 4 };
    try std.testing.expect(workbench.handleSidebarMouse(&problems_click));
    try std.testing.expectEqual(@as(usize, 3), workbench.activeActivity());
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") != null);

    const settings_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 5 };
    try std.testing.expect(workbench.handleSidebarMouse(&settings_click));
    try std.testing.expectEqual(@as(usize, 4), workbench.activeActivity());

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SETTINGS") != null);

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.activeActivity());
}

test "Workbench: Problems panel, status count and range highlight" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "diag.txt", "one\ntwo\nthree");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.enableLanguageFeatures();
    const service = workbench.marker_service orelse return error.TestUnexpectedResult;

    const tab = workbench.activeTab() orelse return error.TestExpectedTab;
    var resource = markers_mod.Resource.fromUri(allocator, tab.editor.model.uri()) catch return error.TestUnexpectedResult;
    defer resource.deinit(allocator);
    try service.changeOne("test", resource, &.{
        .{
            .severity = markers_mod.MarkerSeverity.Error,
            .message = "boom",
            .start_line_number = 2,
            .start_column = 1,
            .end_line_number = 2,
            .end_column = 4,
        },
    }, null);

    const status = workbench.statusbar.main_part.model.findEntry("status.problems") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, status.item.text(), "1") != null);

    try workbench.showProblems();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "diag.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
    try std.testing.expect(workbench.range_highlights.?.highlighted);

    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try workbench.handleSidebarKey(&enter));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(!workbench.range_highlights.?.highlighted);
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
    try std.testing.expectEqualStrings("folder_file.txt", workbench.activeTab().?.input.getName());
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
    try std.testing.expectEqualStrings("alpha.txt", workbench.activeTab().?.input.getName());
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
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
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

test "Workbench: list keybindings route to the focused sidebar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var file_a = try tmp.dir.createFile(io, "a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);

    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/list-keybindings.json", .{root});
    defer allocator.free(keybindings_path);
    var keybindings = try std.Io.Dir.cwd().createFile(io, keybindings_path, .{});
    try keybindings.writeStreamingAll(io,
        \\[ { "key": "j", "command": "list.focusDown", "when": "listFocus" } ]
    );
    keybindings.close(io);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    try workbench.setKeybindingsPaths(&.{keybindings_path});

    var j = ui.KeyEvent{ .key = .{ .char = 'j' } };
    // The binding is gated by `listFocus`; the editor does not match it.
    workbench.focusEditor();
    try std.testing.expect(!(try workbench.handleGlobalKey(&j)));
    workbench.focusSidebar();
    try std.testing.expect(try workbench.handleGlobalKey(&j));
}

test "Workbench: color theme settings load a registered theme palette" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var theme_file = try tmp.dir.createFile(io, "theme.json", .{});
    try theme_file.writeStreamingAll(io,
        \\{ "colors": { "editor.background": "#ffffff", "editor.foreground": "#101010", "statusBar.background": "#eeeeee" } }
    );
    theme_file.close(io);
    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io,
        \\{ "workbench.colorTheme": "Test Theme" }
    );
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = try allocator.dupe(u8, buffer[0..root_len]);
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 12);
    defer workbench.deinit();
    try workbench.registerThemeSources(&.{
        .{
            .root = root,
            .id = "Test Theme",
            .settings_id = "Test Theme",
            .label = "Test Theme",
            .ui_theme = "vs",
            .path = "theme.json",
        },
    });
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.applyThemeSettings();

    const service = workbench.theme_service.?;
    try std.testing.expectEqualStrings("Test Theme", service.getActiveThemeId());
    const palette = workbench.theme_palette.?;
    try std.testing.expectEqual(@as(u8, 0xff), palette.background.r);
    try std.testing.expectEqual(@as(u8, 0x10), palette.foreground.g);
    const status = palette.color("statusBar.background", .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 0xee), status.r);
}

test "Workbench: Preferences JSON commands create and open the TUI layer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/config/settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);
    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/config/keybindings.json", .{buffer[0..root_len]});
    defer allocator.free(keybindings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.setKeybindingsPaths(&.{keybindings_path});

    try workbench.commands.execute("workbench.action.openSettingsJson");
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("settings.json", workbench.activeTab().?.input.getName());
    var settings_content = try workbench.activeTab().?.editor.model.getValue(.TextDefined, false);
    defer settings_content.deinit();
    try std.testing.expectEqualStrings("{\n}\n", settings_content.items);

    try workbench.commands.execute("workbench.action.openGlobalKeybindingsFile");
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("keybindings.json", workbench.activeTab().?.input.getName());
    var keybindings_content = try workbench.activeTab().?.editor.model.getValue(.TextDefined, false);
    defer keybindings_content.deinit();
    try std.testing.expectEqualStrings("[\n]\n", keybindings_content.items);
}

test "Workbench: user keybindings override defaults, honor when and removals" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/keybindings.json", .{buffer[0..root_len]});
    defer allocator.free(keybindings_path);

    try writeKeybindingsFile(&tmp, io, keybindings_path, allocator,
        \\[
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.showCommands" },
        \\  { "key": "ctrl+b", "command": "workbench.action.showCommands" },
        \\  { "key": "ctrl+alt+n", "command": "workbench.action.showCommands", "when": "editorTextFocus" },
        \\  { "key": "ctrl+alt+m", "command": "workbench.action.showCommands", "when": "!editorTextFocus" },
        \\  { "key": "ctrl+alt+u", "command": "no.such.command" },
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    workbench.focusEditor();

    const ctrl_alt_g = ui.KeyEvent{ .key = .{ .char = 'g' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_alt_g));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // A user binding with the same chord as a default wins.
    var ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_b));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // `when` clauses use the shared context keys.
    const ctrl_alt_n = ui.KeyEvent{ .key = .{ .char = 'n' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_alt_n));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);
    const ctrl_alt_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_m)));
    try std.testing.expect(!workbench.isQuickAccessOpen());

    // Unknown commands are filtered so they cannot swallow typing.
    const ctrl_alt_u = ui.KeyEvent{ .key = .{ .char = 'u' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_u)));

    // Reloading applies removals: Ctrl+B no longer resolves globally.
    try writeKeybindingsFile(&tmp, io, keybindings_path, allocator,
        \\[
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_b)));
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_g)));
}

fn closeQuickAccess(workbench: *Workbench) !void {
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);
    try std.testing.expect(!workbench.isQuickAccessOpen());
}

fn writeKeybindingsFile(
    tmp: *std.testing.TmpDir,
    io: Io,
    path: []const u8,
    allocator: Allocator,
    contents: []const u8,
) !void {
    _ = path;
    _ = allocator;
    var file = try tmp.dir.createFile(io, "keybindings.json", .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

test "Workbench: editor settings apply to open editors and reload" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "settings_editor.txt", "alpha\nbeta\n");
    defer allocator.free(path);
    var settings_file = try tmp.dir.createFile(io, "editor-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"editor.lineNumbers\":\"relative\",\"editor.renderWhitespace\":\"all\",\"editor.matchBrackets\":\"never\"}");
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/editor-settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});

    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(
        editor_options.RenderLineNumbersType.Relative,
        tab.view.terminal_view_host.options.get(.lineNumbers).render_type,
    );
    try std.testing.expectEqual(
        editor_options.RenderWhitespace.all,
        tab.view.terminal_view_host.options.get(.renderWhitespace),
    );
    try std.testing.expectEqual(
        editor_options.MatchBrackets.never,
        tab.view.terminal_view_host.options.get(.matchBrackets),
    );

    // Editing the file and re-applying the layer updates the open editor.
    var reloaded_settings = try tmp.dir.createFile(io, "editor-settings.json", .{ .truncate = true });
    try reloaded_settings.writeStreamingAll(io, "{\"editor.lineNumbers\":\"off\"}");
    reloaded_settings.close(io);
    try workbench.setUserSettingsPaths(&.{settings_path});
    try std.testing.expectEqual(
        editor_options.RenderLineNumbersType.Off,
        tab.view.terminal_view_host.options.get(.lineNumbers).render_type,
    );
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
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.initSidebar(root);
    try workbench.findInFiles();
    const view = workbench.search_view.?;

    try view.widget.setValue(.search, "zzz-not-found");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results found") != null);

    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    guard = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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
            _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
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
    .{ .id = markers_common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyM) } },
    .{ .id = "breadcrumbs.focusAndSelect", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Period) } },
    .{ .id = "breadcrumbs.focus", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Semicolon) } },
    .{ .id = "workbench.action.terminal.toggleTerminal", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyT) } },
    .{ .id = "markdown.togglePreview", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyV) } },
    .{ .id = "workbench.action.terminal.new", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyN) } },
    .{ .id = "workbench.action.terminal.kill", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyW) } },
    .{ .id = "workbench.action.terminal.resizeUp", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.UpArrow) } },
    .{ .id = "workbench.action.terminal.resizeDown", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.DownArrow) } },
    .{ .id = "editor.action.revealDefinition", .weight = 200, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.F12) } },
    .{ .id = "editor.action.goToReferences", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.F12) } },
    .{ .id = "editor.action.goToImplementation", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.F12) } },
    // Legacy terminals cannot distinguish Ctrl+Shift+O from Ctrl+O; the
    // secondary binding keeps Go to Symbol reachable in both cases.
    .{ .id = "workbench.action.gotoSymbol", .weight = 200, .bindings = .{
        .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyO),
        .secondary = &.{key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyO)},
    } },
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
    if (self.focus == .terminal and self.terminalVisible() and !terminalCommandSkipsShell(command_id)) {
        // The shell owns this chord. Tell handleGlobalKey it was not handled so
        // the app can hand the bytes to the pty instead of the workbench.
        self.suppress_global_command = true;
        return;
    }
    try self.commands.execute(command_id);
}

fn terminalCommandSkipsShell(command_id: []const u8) bool {
    return terminal_common.skipsShell(command_id);
}

fn readEditorSetting(
    context: *anyopaque,
    key: []const u8,
    language_id: ?[]const u8,
    resource: ?[]const u8,
) ?*const configuration_mod.Value {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const configuration = self.configuration orelse return null;
    return configuration.getValue(key, .{ .override_identifier = language_id, .resource = resource });
}

fn dupeOwnedPaths(allocator: Allocator, paths: []const []const u8) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, paths.len);
    errdefer allocator.free(copies);
    var initialized: usize = 0;
    errdefer {
        for (copies[0..initialized]) |path| allocator.free(path);
    }
    for (paths, 0..) |path, index| {
        copies[index] = try allocator.dupe(u8, path);
        initialized += 1;
    }
    return copies;
}

fn freeOwnedPaths(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    if (paths.len > 0) allocator.free(paths);
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
    try workbench.setUserSettingsPaths(&.{settings_path});
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

test "Workbench: closing a dirty tab asks, cancel keeps it and save closes it" {
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

    // A dirty tab opens the save confirmation instead of closing.
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    try workbench.render(&out.writer);
    const pane2 = workbench.activePane().?;
    var click2 = ui.MouseEvent{
        .kind = .down,
        .x = pane2.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane2.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click2));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.isDialogOpen());

    try workbench.render(&out.writer);
    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "close.txt?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Your changes will be lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Don't Save") != null);

    // Escape cancels the close and leaves the buffer dirty.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Enter activates the focused primary button, saves, then closes.
    try workbench.render(&out.writer);
    const pane3 = workbench.activePane().?;
    var click3 = ui.MouseEvent{
        .kind = .down,
        .x = pane3.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane3.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click3));
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("xalpha", saved);
}

test "Workbench: don't save closes a dirty tab without writing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "discard.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("local ");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const pane = workbench.activePane().?;
    var click = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expect(workbench.isDialogOpen());

    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(workbench.handleDialogKey(&down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const unchanged = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha", unchanged);
}

test "Workbench: Ctrl-W on a dirty tab opens the save confirmation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "ctrl-w.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");

    var ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expect(workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
}

test "Workbench: Ctrl-Q quits clean and confirms one dirty tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "quit_one.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();

    // A clean workbench closes the window immediately.
    try std.testing.expect(workbench.requestQuit());
    try std.testing.expect(!workbench.isDialogOpen());

    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_one.txt?") != null);

    // Cancel keeps the window and the dirty tab.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Save All saves the dirty tab, closes the window and lets the host exit.
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expect(workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("xalpha", saved);
}

test "Workbench: Ctrl-Q lists every dirty tab and don't save closes all" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "quit_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "quit_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 20);
    defer workbench.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("a");
    try workbench.activateIndex(1);
    try workbench.activeTab().?.editor.insertText("b");

    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "following 2 files?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Save All") != null);

    // Down moves focus to Don't Save; Enter discards both tabs and quits.
    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(workbench.handleDialogKey(&down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved_a = try Io.Dir.cwd().readFileAlloc(io, path_a, allocator, .limited(1024));
    defer allocator.free(saved_a);
    const saved_b = try Io.Dir.cwd().readFileAlloc(io, path_b, allocator, .limited(1024));
    defer allocator.free(saved_b);
    try std.testing.expectEqualStrings("alpha", saved_a);
    try std.testing.expectEqualStrings("beta", saved_b);
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
    try std.testing.expect(!workbench.activePane().?.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));

    try workbench.openPreviewPath(path_b);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(std.mem.endsWith(u8, workbench.activeTab().?.editor.path, "preview_b.txt"));

    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    workbench.refreshStatus();
    try std.testing.expect(workbench.activePane().?.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));

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
    try workbench.setUserSettingsPaths(&.{settings_path});
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
    try std.testing.expect(!pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
    // A real terminal also delivers the release between the two presses.
    var up = ui.MouseEvent{ .kind = .up, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&up));
    // Simulate a slow second click caused by the first activation's work.
    workbench.last_tab_click.?.at_ms -= 700;
    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
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
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
}

test "Workbench: git scm integration, diff tabs and read-only snapshots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    _ = try runGitTest(allocator, root, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "published.txt", .data = "published\n" });
    if (!try runGitTest(allocator, root, &.{ "add", "a.txt", "published.txt" })) return error.SkipZigTest;
    if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;

    // Working-tree modification (two change blocks), staged addition and
    // untracked file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\nTWO\nthree\nFOUR\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "staged.txt", .data = "staged\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.txt", .data = "untracked\n" });
    if (!try runGitTest(allocator, root, &.{ "add", "staged.txt" })) return error.SkipZigTest;

    const path = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path);
    const staged_path = try std.fmt.allocPrint(allocator, "{s}/staged.txt", .{root});
    defer allocator.free(staged_path);
    const untracked_path = try std.fmt.allocPrint(allocator, "{s}/untracked.txt", .{root});
    defer allocator.free(untracked_path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 30);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.initGit();

    try std.testing.expect(workbench.git_scm_provider != null);
    try std.testing.expect(workbench.scm_view != null);
    try std.testing.expect(workbench.quick_diff_controller != null);
    const initial_tabs = workbench.tabCount();
    const provider = workbench.git_scm_provider.?;
    try std.testing.expect(provider.count() >= 3);
    try std.testing.expect(workbench.scm_view.?.resourceCount() >= 3);

    // The branch/status entry and activity badge follow the repository.
    try std.testing.expect(workbench.git_status_accessor != null);
    try std.testing.expectEqual(@as(usize, provider.count()), workbench.git_badge_count);

    // HEAD <-> working tree diff for the modified file.
    try workbench.openDiff(path, .head, .working);
    var tab = workbench.activeTab() orelse return error.TestExpectedTab;
    try std.testing.expect(tab.isDiff());
    try std.testing.expectEqual(@as(usize, 2), tab.diff.?.widget.changeCount());
    try std.testing.expect(tab.editor.isReadOnly());

    // The diff tab composites both panes, the center gutter and its title.
    var diff_frame: std.Io.Writer.Allocating = .init(allocator);
    defer diff_frame.deinit();
    try workbench.render(&diff_frame.writer);
    try std.testing.expect(std.mem.indexOf(u8, diff_frame.written(), "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_frame.written(), "Working Tree") != null);
    try std.testing.expect(workbench.cursorCell() != null);

    // Navigation keys are TUI-specific (Alt-Up/Alt-Down).
    const before_change = tab.diff.?.widget.current_change;
    const next_key = ui.KeyEvent{ .key = .down, .mods = .{ .alt = true } };
    const result = try workbench.handleTabKey(&next_key);
    try std.testing.expectEqual(TabKeyResult.handled, result);
    try std.testing.expect(tab.diff.?.widget.current_change != before_change);
    const previous_key = ui.KeyEvent{ .key = .up, .mods = .{ .alt = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&previous_key));
    try std.testing.expectEqual(before_change, tab.diff.?.widget.current_change);

    // Save/revert are inert for a diff tab (the read-only snapshot editor
    // rejects the low-level save as well).
    try std.testing.expectError(error.ReadOnly, tab.editor.save());

    // Staged and untracked diffs open with distinct titles/keys.
    try workbench.openDiff(staged_path, .head, .index);
    const staged_tab = workbench.activeTab().?;
    try std.testing.expect(staged_tab.isDiff());
    try std.testing.expect(std.mem.indexOf(u8, staged_tab.input.getName(), "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_tab.input.getName(), "Index") != null);

    // Index <-> working tree diff for a file that was staged and then edited.
    try tmp.dir.writeFile(io, .{ .sub_path = "staged.txt", .data = "staged\nmore\n" });
    try workbench.openDiff(staged_path, .index, .working);
    const index_working_tab = workbench.activeTab().?;
    try std.testing.expect(index_working_tab.isDiff());
    try std.testing.expect(std.mem.indexOf(u8, index_working_tab.input.getName(), "Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_working_tab.input.getName(), "Working Tree") != null);

    try workbench.openDiff(untracked_path, .empty, .working);
    const untracked_tab = workbench.activeTab().?;
    try std.testing.expect(untracked_tab.isDiff());
    try std.testing.expectEqual(initial_tabs + 4, workbench.tabCount());

    // A second open of the same ref pair refreshes the existing tab.
    try workbench.openDiff(path, .head, .working);
    try std.testing.expectEqual(initial_tabs + 4, workbench.tabCount());

    // Session save has no serializer for diff tabs and skips them.
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = workbench.createFileSerializer();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    var serialized = try workbench.serializePart(allocator, &registry);
    defer serialized.deinit(allocator);
    var serialized_editors: usize = 0;
    for (serialized.groups) |group_data| serialized_editors += group_data.editors.len;
    // Only the normal file tab is serialized; the three diff inputs have no
    // serializer and are skipped.
    try std.testing.expectEqual(initial_tabs, serialized_editors);

    // Quick-diff decorations can be disabled and detach the gutter cell.
    try workbench.openPath(path);
    const file_tab = workbench.activeTab().?;
    try std.testing.expect(!file_tab.isDiff());
    workbench.quick_diff_controller.?.setConfig(.{ .decorations = .none });
    try std.testing.expectEqual(@as(usize, 0), file_tab.editor.lineDecorationsWidth());
    workbench.quick_diff_controller.?.setConfig(.{ .decorations = .all });
    try std.testing.expectEqual(@as(usize, 1), file_tab.editor.lineDecorationsWidth());
}

fn runGitTest(allocator: Allocator, root: []const u8, args: []const []const u8) !bool {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(root);
    try argv.appendSlice(args);
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20_000), .clock = .awake } },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

test "Workbench: LSP navigation, references and symbol picker" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/sample.ts",
        \\\const value = 1;
        \\\value;
        \\\value;
    );
    defer allocator.free(path);

    const Fake = struct {
        fn definition(_: *anyopaque, allocator_: Allocator, model: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const links = try allocator_.alloc(languages.LocationLink, 1);
            const range = Range.init(2, 1, 2, 6);
            links[0] = .{ .uri = uri, .range = range, .target_selection_range = range };
            return links;
        }
        fn references(_: *anyopaque, allocator_: Allocator, model: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const locations = try allocator_.alloc(languages.Location, 2);
            locations[0] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(1, 1, 1, 6) };
            locations[1] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(2, 1, 2, 6) };
            allocator_.free(uri);
            return locations;
        }
        fn symbols(_: *anyopaque, allocator_: Allocator, model: *@import("../../editor/common/model/textModel.zig").TextModel, _: CancellationToken) ![]languages.DocumentSymbol {
            _ = model;
            const result = try allocator_.alloc(languages.DocumentSymbol, 1);
            result[0] = .{
                .name = try allocator_.dupe(u8, "value"),
                .kind = 13,
                .range = Range.init(1, 1, 3, 6),
                .selection_range = Range.init(2, 1, 2, 6),
            };
            return result;
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const definition_registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer definition_registration.dispose();
    const reference_registration = try features.reference_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = Fake.references,
    });
    defer reference_registration.dispose();
    const symbol_registration = try features.document_symbol_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .display_name = "fake",
        .provide_document_symbols = Fake.symbols,
    });
    defer symbol_registration.dispose();

    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(3, 1));
    try std.testing.expect(try workbench.revealDefinition());
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try std.testing.expect(try workbench.gotoSymbolInEditor());
    try std.testing.expect(workbench.quick_access.isOpen());
    const picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expectEqual(@as(usize, 1), picker.items.items.len);
    picker.accept();
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(3, 1));
    try std.testing.expect(try workbench.goToReferences());
    try std.testing.expect(workbench.quick_access.isOpen());
    const reference_picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expectEqual(@as(usize, 3), reference_picker.items.items.len);
    reference_picker.accept();
    try std.testing.expectEqual(@as(usize, 1), tab.editor.modelCursorPosition().lineNumber);

    try std.testing.expect(try workbench.showHover());
    try std.testing.expect(tab.controllers.?.hover.isVisible());
}

test "Workbench: LSP no-result message keeps the word" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/empty.ts", "value");
    defer allocator.free(path);

    const Fake = struct {
        fn empty(_: *anyopaque, _: Allocator, _: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            return &.{};
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 10);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.empty,
    });
    defer registration.dispose();

    try std.testing.expect(!(try workbench.revealDefinition()));
    try std.testing.expect(std.mem.indexOf(u8, workbench.activeTab().?.editor.message(), "No definition found for 'value'") != null);
}

test "Workbench: F12 and Shift+F12 dispatch through keybindings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/keys.ts",
        \\\alpha
        \\\beta
    );
    defer allocator.free(path);

    const Fake = struct {
        fn definition(_: *anyopaque, allocator_: Allocator, model: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const links = try allocator_.alloc(languages.LocationLink, 1);
            links[0] = .{ .uri = uri, .range = Range.init(2, 1, 2, 5), .target_selection_range = Range.init(2, 1, 2, 5) };
            return links;
        }
        fn references(_: *anyopaque, allocator_: Allocator, model: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const locations = try allocator_.alloc(languages.Location, 2);
            locations[0] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(1, 1, 1, 5) };
            locations[1] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(2, 1, 2, 5) };
            allocator_.free(uri);
            return locations;
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 10);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const definition_registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer definition_registration.dispose();
    const reference_registration = try features.reference_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = Fake.references,
    });
    defer reference_registration.dispose();

    const tab = workbench.activeTab().?;
    var f12 = ui.KeyEvent{ .key = .f12 };
    try std.testing.expect(try workbench.handleGlobalKey(&f12));
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(1, 1));
    var shift_f12 = ui.KeyEvent{ .key = .f12, .mods = .{ .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&shift_f12));
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
}

test "Workbench: same-file navigation reuses the current editor across path forms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/relative.ts",
        \\\const value = 1;
        \\\value;
    );
    defer allocator.free(path);
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try Io.Dir.cwd().realPathFile(io, path, &absolute_buffer);
    const absolute = try allocator.dupe(u8, absolute_buffer[0..absolute_length]);
    defer allocator.free(absolute);
    const directory = std.fs.path.dirname(absolute) orelse "/";
    const basename = std.fs.path.basename(absolute);

    const Fake = struct {
        dir: []const u8,
        base: []const u8,
        fn definition(context: *anyopaque, allocator_: Allocator, _: *@import("../../editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const self: *@This() = @ptrCast(@alignCast(context));
            const uri = try std.fmt.allocPrint(allocator_, "file:///{s}/./{s}", .{ self.dir, self.base });
            const links = try allocator_.alloc(languages.LocationLink, 1);
            links[0] = .{
                .uri = uri,
                .range = Range.init(2, 1, 2, 6),
                .target_selection_range = Range.init(2, 1, 2, 6),
            };
            return links;
        }
    };
    var context = Fake{ .dir = directory, .base = basename };

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const registration = try workbench.language_features.?.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer registration.dispose();

    try std.testing.expect(try workbench.revealDefinition());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings(path, workbench.activeTab().?.editor.path);
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
}

/// Test seam for the terminal service: a real, immediately-exiting process, so
/// no interactive shell is needed to exercise creation and layout.
fn launchTestTerminal(service: *TerminalService, allocator: Allocator) anyerror!*terminal_service_mod.TerminalInstance {
    const instance = try terminal_service_mod.TerminalInstance.create(allocator, service.io, service.next_id, .{
        .shell = "/bin/true",
        .profile_name = "true",
    });
    service.next_id += 1;
    return instance;
}

test "Workbench: new terminal creates one tab and hover does not act" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 20);
    defer workbench.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = service;

    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    // Toggling the panel with a terminal present must not create another.
    try workbench.showTerminal();
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    const layout = terminal_panel.layout(workbench.panelRect());
    const expected_cols: u16 = @intCast(layout.content_width);
    const expected_rows: u16 = @intCast(layout.content_height);
    const first = service.at(0).?;
    try std.testing.expectEqual(expected_cols, first.cols);
    try std.testing.expectEqual(expected_rows, first.rows);

    const plus_x = layout.content_x + layout.content_width - 3;
    var move = ui.MouseEvent{ .kind = .move, .x = plus_x, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&move));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var right = ui.MouseEvent{ .kind = .down, .button = .right, .x = plus_x, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&right));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = plus_x, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&click));
    try std.testing.expectEqual(@as(usize, 2), workbench.terminalCount());
    // A terminal created while the panel is visible adopts the panel size.
    const second = service.at(1).?;
    try std.testing.expectEqual(expected_cols, second.cols);
    try std.testing.expectEqual(expected_rows, second.rows);

    // The tab strip switches on a left press only.
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_move = ui.MouseEvent{ .kind = .move, .x = layout.content_x + 1, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_move));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_right = ui.MouseEvent{ .kind = .down, .button = .right, .x = layout.content_x + 1, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_right));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_click = ui.MouseEvent{ .kind = .down, .button = .left, .x = layout.content_x + 1, .y = layout.tab_y };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_click));
    try std.testing.expectEqual(@as(usize, 0), service.group.active);
}

test "Workbench: wheel scrolls the terminal viewport without moving focus" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 20);
    defer workbench.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = service;
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };

    const instance = service.at(0).?;
    const layout = terminal_panel.layout(workbench.panelRect());
    const content = terminal_panel.contentRect(workbench.panelRect());
    const local_rect = ui.Rect{ .x = 0, .y = 0, .w = content.w, .h = content.h };

    var line_buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < 60) : (index += 1) {
        const line = try std.fmt.bufPrint(&line_buffer, "line-{d}\r\n", .{index});
        instance.emulator.feed(line);
    }

    var grid = try ui.CellGrid.init(allocator, ui.cell.snap(content.w), ui.cell.snap(content.h));
    defer grid.deinit();
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const active_top = try grid.rowText(allocator, 0);
    defer allocator.free(active_top);

    // Wheel-up over the content scrolls into the scrollback but must not steal
    // keyboard focus from the editor.
    workbench.focus = .editor;
    var wheel_up = ui.MouseEvent{
        .kind = .wheel,
        .x = layout.content_x + 1,
        .y = layout.content_y + 1,
        .delta_y = -3,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&wheel_up));
    try std.testing.expect(workbench.focus == .editor);
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const scrolled_top = try grid.rowText(allocator, 0);
    defer allocator.free(scrolled_top);
    try std.testing.expect(!std.mem.eql(u8, active_top, scrolled_top));

    // Wheel-down returns to the active viewport.
    var wheel_down = ui.MouseEvent{
        .kind = .wheel,
        .x = layout.content_x + 1,
        .y = layout.content_y + 1,
        .delta_y = 3,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&wheel_down));
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const returned_top = try grid.rowText(allocator, 0);
    defer allocator.free(returned_top);
    try std.testing.expectEqualStrings(active_top, returned_top);

    // A click focuses the terminal; the wheel alone does not.
    var click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = layout.content_x + 1,
        .y = layout.content_y + 1,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&click));
    try std.testing.expect(workbench.focus == .terminal);
}
